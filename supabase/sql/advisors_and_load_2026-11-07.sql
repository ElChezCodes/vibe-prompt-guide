-- Supabase advisors and idle load (2026-11-07).
-- Rehearsed on a restored copy with a before/after behaviour matrix.
-- See "Database health" in CLAUDE.md for what stays flagged and why.
begin;
set local lock_timeout = '15s';

-- 1. Idle load ---------------------------------------------------------------
-- The retired curated library was the only 'active' arena: battle_lifecycle_job
-- ran create_next_battle for it every second, 79 % of all database time.
update public.arenas set state = 'finished', ended_at = now()
where arena_code = '0101CE' and state = 'active';

-- A row per second: keep 15 minutes of the fast jobs, not an hour.
select cron.schedule('cron_log_retention', '*/10 * * * *', $job$
  delete from cron.job_run_details
  where (jobid in (select jobid from cron.job where jobname in ('battle_lifecycle_job', 'spotify_playback_watch_job'))
         and end_time < now() - interval '15 minutes')
     or end_time < now() - interval '3 days';
  $job$);

-- Debug leftovers nothing reads or writes.
drop table if exists public.cron_seconds_test_log;
drop table if exists public.cron_debug_log;

-- 2. arena_live_state ran as its owner, so the public key alone read every
-- battle. Now it runs as the caller.
create index if not exists battles_song_a_id_idx on public.battles (song_a_id);
create index if not exists battles_song_b_id_idx on public.battles (song_b_id);

create policy songs_select_in_battle on public.songs
  for select to authenticated
  using (exists (select 1 from public.battles b where b.song_a_id = songs.id or b.song_b_id = songs.id));

-- Rewritten so a client's "latest battle of this arena" stops at one row: as a
-- GROUP BY it computed every battle of the arena on each 2 s poll.
create index if not exists battles_arena_id_created_at_idx on public.battles (arena_id, created_at desc);

create or replace view public.arena_live_state with (security_invoker = true) as
select b.id as battle_id,
       b.arena_id,
       b.state as status,
       b.started_at,
       b.duration_ms,
       b.lockin_at,
       b.resolution_type,
       b.winner_song_id,
       b.created_at as battle_created_at,
       sa.id as song_a_id,
       sa.title as song_a_title,
       sa.artist as song_a_artist,
       sa.source as song_a_source,
       sa.spotify_track_id as song_a_spotify_track_id,
       sa.duration_ms as song_a_duration_ms,
       sb.id as song_b_id,
       sb.title as song_b_title,
       sb.artist as song_b_artist,
       sb.source as song_b_source,
       sb.spotify_track_id as song_b_spotify_track_id,
       sb.duration_ms as song_b_duration_ms,
       v.votes_a,
       v.votes_b,
       b.sudden_death_active,
       sa.artwork_url as song_a_artwork_url,
       sb.artwork_url as song_b_artwork_url,
       t.passive_a,
       t.passive_b
from public.battles b
join public.songs sa on sa.id = b.song_a_id
join public.songs sb on sb.id = b.song_b_id
cross join lateral (
  select count(*) filter (where x.song_id = b.song_a_id) as votes_a,
         count(*) filter (where x.song_id = b.song_b_id) as votes_b
  from public.votes x
  where x.battle_id = b.id
    and x.status = 'active'
    and x.vote_type <> 'passive'
    and (b.sudden_death_started_at is null or x.vote_type = 'sudden_death')
) v
cross join lateral public.battle_passive_tally(b.id) t(passive_a, passive_b)
where b.state = any (array['pending', 'active', 'closing', 'completed']);

revoke all on public.arena_live_state from anon;

-- 3. RLS: one permissive policy per action, auth.uid() evaluated once per query.
-- Several permissive policies OR their USING and their WITH CHECK independently,
-- so a single policy with both ORs behaves the same.
drop policy arena_select_authenticated on public.arenas;
drop policy host_select_arena on public.arenas;
create policy arenas_select on public.arenas
  for select to authenticated
  using (((select auth.uid()) is not null and state <> 'expired') or host_id = (select auth.uid()));

alter policy battle_presence_snapshots_select on public.battle_presence_snapshots
  using (identity_anchor_id = (select auth.uid())
         or arena_id in (select a.id from public.arenas a where a.host_id = (select auth.uid())));

-- battles_select_authenticated already covered the other two.
drop policy participants_can_read_active_battle on public.battles;
drop policy participants_can_read_battles on public.battles;
alter policy battles_select_authenticated on public.battles
  to authenticated using ((select auth.uid()) is not null);

drop policy participant_can_insert_self on public.participants;
alter policy participant_insert_self on public.participants
  to authenticated with check (identity_anchor_id = (select auth.uid()));
drop policy participant_can_view_arena_participants on public.participants;
alter policy participant_select on public.participants
  to authenticated
  using (identity_anchor_id = (select auth.uid())
         or arena_id in (select a.id from public.arenas a where a.host_id = (select auth.uid())));
alter policy participant_can_update_self on public.participants
  to authenticated using (identity_anchor_id = (select auth.uid()));
alter policy participants_is_host_matches_arena on public.participants
  to authenticated
  with check (is_host = false or exists (select 1 from public.arenas a
              where a.id = participants.arena_id and a.host_id = (select auth.uid())));
alter policy participants_update_is_host_matches_arena on public.participants
  to authenticated
  with check (is_host = false or exists (select 1 from public.arenas a
              where a.id = participants.arena_id and a.host_id = (select auth.uid())));
alter policy participants_require_open_arena on public.participants to authenticated;

alter policy queues_insert_proposal on public.queues
  to authenticated
  with check (exists (select 1 from public.participants p
              where p.arena_id = queues.arena_id and p.identity_anchor_id = (select auth.uid())));
alter policy queues_select_arena on public.queues
  to authenticated
  using (exists (select 1 from public.participants p
         where p.arena_id = queues.arena_id and p.identity_anchor_id = (select auth.uid())));
alter policy queues_require_open_arena on public.queues to authenticated;

alter policy song_likes_select_arena on public.song_likes
  to authenticated
  using (exists (select 1 from public.participants p
         where p.arena_id = song_likes.arena_id and p.identity_anchor_id = (select auth.uid())));

drop policy votes_insert_regular_active on public.votes;
drop policy votes_insert_sudden_death on public.votes;
create policy votes_insert_by_phase on public.votes
  for insert to authenticated
  with check (status = 'active' and (
    (vote_type = 'regular'
     and exists (select 1 from public.battles b where b.id = votes.battle_id and b.lockin_at is null))
    or
    (vote_type = 'sudden_death'
     and exists (select 1 from public.participants p
                 where p.id = votes.participant_id and p.identity_anchor_id = (select auth.uid()))
     and exists (select 1 from public.battles b where b.id = votes.battle_id and b.sudden_death_active = true))
  ));
alter policy votes_insert_own_participant on public.votes
  to authenticated
  with check (exists (select 1 from public.participants p
              where p.id = votes.participant_id and p.identity_anchor_id = (select auth.uid())
                and p.arena_id = votes.arena_id));
alter policy votes_require_active_arena on public.votes to authenticated;
alter policy votes_select_authenticated on public.votes
  to authenticated using ((select auth.uid()) is not null);

drop policy votes_update_before_lockin on public.votes;
drop policy votes_upgrade_to_sudden_death on public.votes;
create policy votes_update_own on public.votes
  for update to authenticated
  using (exists (select 1 from public.participants p
                 where p.id = votes.participant_id and p.identity_anchor_id = (select auth.uid()))
         and (exists (select 1 from public.battles b where b.id = votes.battle_id and b.lockin_at is null)
              or vote_type = 'regular'))
  with check (exists (select 1 from public.participants p
                      where p.id = votes.participant_id and p.identity_anchor_id = (select auth.uid()))
              and (status in ('active', 'cancelled')
                   or (vote_type = 'sudden_death'
                       and exists (select 1 from public.battles b
                                   where b.id = votes.battle_id and b.sudden_death_active = true))));
alter policy votes_sd_immutable on public.votes to authenticated;
alter policy votes_update_matches_phase on public.votes to authenticated;
alter policy votes_update_require_active_arena on public.votes to authenticated;

-- 4. Functions clients must not call. A trigger needs no EXECUTE from whoever
-- fires it, and SECURITY DEFINER callers run these as the owner.
do $$
declare f text;
begin
  foreach f in array array[
    'clear_reserve_on_arena_end()', 'link_battle_proposals()', 'pi_on_battle_completed()',
    'pi_on_battle_created()', 'queue_recording_lookup()', 'reject_warmup_song()',
    'signal_on_battle_completed()', 'signal_on_proposal()', 'snapshot_presence_at_lockin()',
    'touch_activity_on_arena_start()', 'touch_activity_on_proposal()', 'touch_activity_on_vote()',
    'validate_queue_proposal()', 'track_available_at(uuid, text)']
  loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
  -- Used by the app, always with a session.
  foreach f in array array[
    'battle_passive_tally(uuid)', 'can_read_warmup_audio(text)',
    'get_arena_warmup(uuid)', 'start_arena_battles(uuid)']
  loop
    execute format('revoke all on function public.%s from public, anon', f);
  end loop;
end $$;

-- 5. Fixed search_path.
do $$
declare f text;
begin
  foreach f in array array[
    'clear_vote_preassigned()', 'ensure_mock_songs_for_arena(uuid)', 'fill_song_like_fields()',
    'fill_vote_fields()', 'generate_arena_code()', 'library_arena_id()', 'normalize_isrc(text)',
    'process_battle_lifecycle(uuid)', 'calculate_lockin_vote_totals(uuid)',
    'presence_state(timestamptz, timestamptz, timestamptz, timestamptz, text, timestamptz)']
  loop
    execute format('alter function public.%s set search_path = public, extensions, pg_temp', f);
  end loop;
end $$;

-- 6. Server-only tables say so: same result as RLS with no policy.
do $$
declare t text;
begin
  foreach t in array array[
    'account_merge_tickets', 'affinity_signals', 'arena_library_contributors', 'arena_pi_standings',
    'arena_playback', 'arena_song_reserve', 'hosts', 'matchmaking_config', 'matchmaking_log',
    'mb_artists', 'mb_enrich_state', 'mb_genres', 'passive_vote_config', 'pi_config', 'pi_ledger',
    'playback_events', 'playlist_queue', 'privacy_consents', 'proposal_history', 'queue_backers',
    'recordings', 'spotify_oauth_states', 'spotify_rate_limit', 'streaming_accounts',
    'system_song_config', 'user_profiles']
  loop
    execute format('create policy server_only on public.%I for all to anon using (false) with check (false)', t);
  end loop;
end $$;

-- 7. Indexes and keys.
drop index public.votes_one_active_per_participant;
drop index public.user_profiles_country_idx;
alter table public.arena_pi_standings add column id bigint generated by default as identity primary key;
create index if not exists account_merge_tickets_anon_user_id_fk_idx on public.account_merge_tickets (anon_user_id);
create index if not exists arena_library_contributors_user_id_fk_idx on public.arena_library_contributors (user_id);
create index if not exists arena_playback_host_id_fk_idx on public.arena_playback (host_id);
create index if not exists arena_song_reserve_contributed_by_fk_idx on public.arena_song_reserve (contributed_by);
create index if not exists arena_song_reserve_song_id_fk_idx on public.arena_song_reserve (song_id);
create index if not exists arenas_warmup_song_id_fk_idx on public.arenas (warmup_song_id);
create index if not exists battle_presence_snapshots_participant_id_fk_idx on public.battle_presence_snapshots (participant_id);
create index if not exists matchmaking_log_battle_id_fk_idx on public.matchmaking_log (battle_id);
create index if not exists pi_ledger_battle_id_fk_idx on public.pi_ledger (battle_id);
create index if not exists pi_ledger_song_id_fk_idx on public.pi_ledger (song_id);
create index if not exists playlist_queue_battle_id_fk_idx on public.playlist_queue (battle_id);
create index if not exists playlist_queue_winner_song_id_fk_idx on public.playlist_queue (winner_song_id);
create index if not exists proposal_history_song_id_fk_idx on public.proposal_history (song_id);
create index if not exists queue_backers_song_id_fk_idx on public.queue_backers (song_id);
create index if not exists queue_backers_user_id_fk_idx on public.queue_backers (user_id);
create index if not exists song_likes_participant_id_fk_idx on public.song_likes (participant_id);
create index if not exists song_likes_song_id_fk_idx on public.song_likes (song_id);

commit;

-- 8. Leftovers of the browser MP3 warm-up, unused since step 6.
begin;
drop policy if exists host_reads_active_warmup_audio on storage.objects;
drop function if exists public.can_read_warmup_audio(text);
commit;
