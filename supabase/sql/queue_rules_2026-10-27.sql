-- Step 12: queue rules (2026-10-27).
--
-- Sources: Backend_Block_1 §7, Backend_Block_3 §3-5, Backend_Block_4 §3,
-- v3.2 "Propuestas y colas", v4 §2.1-2.4. User decisions 2026-10-27:
--   * each battle takes at most 1 song per proposer (decided 2026-10-26: a
--     user may keep several queued); slot B fallback chain = another
--     proposer's song -> the same proposer's next song -> a previous loser of
--     this arena ("revancha", a real Spotify track) -> the curated library
--     (last resort until step 13);
--   * order = turns per person: everyone's 1st song, then everyone's 2nd...
--     counting the songs each person already sent into battle; FIFO inside a
--     turn; a song already in the next 10 never drops back to waiting;
--   * at most 5 queued songs per person;
--   * "Your proposals" = queue (state + place) + this arena's history
--     (competing/won/lost/draw/purged/withdrawn) + withdraw (v3.2/v4 allow it).
-- Spec rules applied as written: active_10 (the next 10) + waiting_50, "full"
-- notice when both are full (v4 §2.2), purge after 20 battles in waiting
-- without reaching the next 10, no song again within 60 min of sounding (v4
-- §2.4: winners, both songs of a draw and the warm-up; losers never sounded).
-- Humans before the system: system rows (proposed_by NULL) sort after every
-- human row (none exist until step 13). The host is one more proposer.
--
-- "Sounded" = entered the arena's playlist (playlist_queue.created_at, the
-- same table step 18 appends to Spotify from) or the warm-up start. Step 18
-- may switch this to the real play time.

-- ============================================================
-- 1. Schema
-- ============================================================

alter table public.queues
  add column if not exists battles_waited integer not null default 0;

create index if not exists playlist_queue_arena_track_idx
  on public.playlist_queue (arena_id, spotify_track_id, created_at);

-- What happened to each proposal once it left the queue. Written only
-- server-side; read through get_my_proposals. Battle outcomes are read from
-- battles (never copied); step 15 (PI) also needs proposer per battle song.
create table if not exists public.proposal_history (
  id uuid primary key default gen_random_uuid(),
  arena_id uuid not null references public.arenas(id) on delete cascade,
  song_id uuid not null references public.songs(id) on delete cascade,
  proposed_by uuid not null,
  proposed_at timestamptz not null,
  outcome text not null check (outcome in ('battled', 'purged', 'withdrawn')),
  battle_id uuid references public.battles(id) on delete cascade,
  ended_at timestamptz not null default now()
);

create index if not exists proposal_history_arena_proposer_idx
  on public.proposal_history (arena_id, proposed_by);
create index if not exists proposal_history_battle_idx
  on public.proposal_history (battle_id);

alter table public.proposal_history enable row level security;
revoke all on public.proposal_history from anon, authenticated;

-- ============================================================
-- 2. Helpers
-- ============================================================

-- Serialises every queue change of one arena (proposals, withdrawals, pulls)
create or replace function public.lock_arena_queue(p_arena_id uuid)
returns void
language sql
set search_path to 'public'
as $$
  select pg_advisory_xact_lock(hashtextextended('queues:' || p_arena_id::text, 0));
$$;

-- When a track may sound again in this arena: NULL = available now (v4 §2.4)
create or replace function public.track_available_at(p_arena_id uuid, p_track text)
returns timestamptz
language sql
stable
security definer
set search_path to 'public'
as $$
  select case when t.last_sounded > now() - interval '60 minutes'
              then t.last_sounded + interval '60 minutes' end
  from (
    select greatest(
      (select max(pq.created_at) from playlist_queue pq
        where pq.arena_id = p_arena_id and pq.spotify_track_id = p_track),
      (select a.warmup_started_at from arenas a join songs w on w.id = a.warmup_song_id
        where a.id = p_arena_id and w.spotify_track_id = p_track)
    ) as last_sounded
  ) t;
$$;

-- The arena's queue in battle order. turn = songs this proposer already sent
-- into battle here + rank among their queued ones; humans before the system.
-- global_rank: the next 10 first, then waiting.
create or replace function public.queue_ranked(p_arena_id uuid)
returns table (
  id uuid, song_id uuid, proposed_by uuid, queue_type text,
  battles_waited integer, created_at timestamptz, rank_in_list bigint, global_rank bigint
)
language sql
stable
security definer
set search_path to 'public'
as $$
  with battled as (
    select h.proposed_by, count(*) as n
    from proposal_history h
    where h.arena_id = p_arena_id and h.outcome = 'battled'
    group by h.proposed_by
  ),
  q as (
    select q.*, q.proposed_by is null as is_system,
           coalesce(b.n, 0) + row_number() over (partition by q.proposed_by order by q.created_at, q.id) as turn
    from queues q
    left join battled b on b.proposed_by = q.proposed_by
    where q.arena_id = p_arena_id
  )
  select q.id, q.song_id, q.proposed_by, q.queue_type, q.battles_waited, q.created_at,
         row_number() over (partition by q.queue_type order by q.is_system, q.turn, q.created_at, q.id),
         row_number() over (order by q.queue_type = 'waiting', q.is_system, q.turn, q.created_at, q.id)
  from q;
$$;

-- Keep the next 10 full from waiting, best first (Block_4 §3: active_10 is
-- filled only from waiting_50)
create or replace function public.refill_active_queue(p_arena_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_free integer;
begin
  select 10 - count(*) into v_free from queues where arena_id = p_arena_id and queue_type = 'active';
  if v_free <= 0 then
    return;
  end if;

  update queues
  set queue_type = 'active', updated_at = now()
  where id in (
    select r.id from queue_ranked(p_arena_id) r
    where r.queue_type = 'waiting'
    order by r.rank_in_list
    limit v_free
  );
end;
$$;

-- ============================================================
-- 3. Proposal rules (BEFORE INSERT on queues)
-- ============================================================
-- Runs after trg_queues_reject_warmup and trg_queues_stamp_proposer (BEFORE
-- triggers fire in name order). Client-sent queue_type/position/priority are
-- ignored. Errors are P0001 with a code as message (spotify-host maps them):
-- in_battle, is_warmup, recently_played (hint = available at),
-- proposer_queue_full, queue_full.

create or replace function public.validate_queue_proposal()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_arena arenas%rowtype;
  v_track text;
  v_until timestamptz;
  v_active integer;
  v_waiting integer;
begin
  perform lock_arena_queue(new.arena_id);

  new.position := 0;
  new.priority := 1;
  new.battles_waited := 0;
  new.created_at := now();
  new.updated_at := now();

  select * into v_arena from arenas where id = new.arena_id;
  select spotify_track_id into v_track from songs where id = new.song_id;

  -- Already queued: same unique violation the frontend reads as "already in the queue"
  if exists (select 1 from queues where arena_id = new.arena_id and song_id = new.song_id) then
    raise exception 'duplicate key value violates unique constraint "queues_arena_song_unique"'
      using errcode = '23505';
  end if;

  if exists (
    select 1 from battles b join songs s on s.id in (b.song_a_id, b.song_b_id)
    where b.arena_id = new.arena_id
      and b.state in ('pending', 'active', 'closing')
      and s.spotify_track_id = v_track
  ) then
    raise exception 'in_battle' using errcode = 'P0001';
  end if;

  -- Lobby: the warm-up is about to sound
  if v_arena.warmup_started_at is null
     and exists (select 1 from songs w where w.id = v_arena.warmup_song_id and w.spotify_track_id = v_track) then
    raise exception 'is_warmup' using errcode = 'P0001';
  end if;

  v_until := track_available_at(new.arena_id, v_track);
  if v_until is not null then
    raise exception 'recently_played' using errcode = 'P0001',
      hint = to_char(v_until at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  end if;

  if new.proposed_by is not null
     and (select count(*) from queues where arena_id = new.arena_id and proposed_by = new.proposed_by) >= 5 then
    raise exception 'proposer_queue_full' using errcode = 'P0001';
  end if;

  select count(*) filter (where queue_type = 'active'), count(*) filter (where queue_type = 'waiting')
  into v_active, v_waiting
  from queues where arena_id = new.arena_id;

  if v_active < 10 then
    new.queue_type := 'active';
  elsif v_waiting < 50 then
    new.queue_type := 'waiting';
  else
    raise exception 'queue_full' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_queues_validate on public.queues;
create trigger trg_queues_validate
  before insert on public.queues
  for each row execute function public.validate_queue_proposal();

-- queue_type is now decided by the trigger (WITH CHECK sees the row after it)
drop policy if exists queues_insert_proposal on public.queues;
create policy queues_insert_proposal on public.queues
  for insert
  with check (exists (
    select 1 from participants p
    where p.arena_id = queues.arena_id and p.identity_anchor_id = auth.uid()
  ));

-- ============================================================
-- 4. Battle pairs
-- ============================================================

-- A loser of an earlier battle here (never sounded), least recently fought,
-- not in the battle that just ended, not queued, not one of p_exclude
create or replace function public.pick_rematch_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid)
returns uuid
language sql
volatile
security definer
set search_path to 'public'
as $$
  select s.id
  from songs s
  join battles b on b.arena_id = p_arena_id
                and b.state = 'completed'
                and b.resolution_type in ('normal', 'sudden_death')
                and s.id in (b.song_a_id, b.song_b_id)
                and s.id <> b.winner_song_id
  where s.arena_id = p_arena_id
    and s.role = 'competitor'
    and s.status = 'active'
    and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
    and not exists (select 1 from battles lb where lb.id = p_last_battle and s.id in (lb.song_a_id, lb.song_b_id))
    and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = s.id)
    and track_available_at(p_arena_id, s.spotify_track_id) is null
  group by s.id
  order by max(b.created_at), random()
  limit 1;
$$;

-- Curated library, last resort until step 13 (mood first). Its
-- spotify_track_id values are placeholders: a library winner can't sound in
-- step 18.
create or replace function public.pick_library_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid)
returns uuid
language sql
volatile
security definer
set search_path to 'public'
as $$
  select s.id
  from songs s, arenas a
  where a.id = p_arena_id
    and s.arena_id = library_arena_id()
    and s.status = 'active'
    and s.source <> 'mock'
    and s.role = 'competitor'
    and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
    and s.spotify_track_id is distinct from (select w.spotify_track_id from songs w where w.id = a.warmup_song_id)
    and not exists (select 1 from battles lb where lb.id = p_last_battle and s.id in (lb.song_a_id, lb.song_b_id))
    and track_available_at(p_arena_id, s.spotify_track_id) is null
  order by coalesce(a.mood = any (s.moods), false) desc, random()
  limit 1;
$$;

-- The next battle's pair. Called by start_arena_battles (battle 1) and
-- process_battle_lifecycle (after each battle), right before the battle row
-- is inserted. Also counts the battle for the waiting purge.
create or replace function public.pull_next_battle_songs(p_arena_id uuid)
returns table (song_a uuid, song_b uuid)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_last uuid;
  v_a_row uuid;
  v_a_song uuid;
  v_a_by uuid;
  v_a_track text;
  v_b_row uuid;
  v_b_song uuid;
  v_b_track text;
begin
  perform lock_arena_queue(p_arena_id);

  select id into v_last from battles where arena_id = p_arena_id order by created_at desc limit 1;

  perform refill_active_queue(p_arena_id);

  -- A: first in battle order that may sound
  select r.id, r.song_id, r.proposed_by, s.spotify_track_id
  into v_a_row, v_a_song, v_a_by, v_a_track
  from queue_ranked(p_arena_id) r join songs s on s.id = r.song_id
  where track_available_at(p_arena_id, s.spotify_track_id) is null
  order by r.global_rank
  limit 1;

  if v_a_row is not null then
    -- B: another proposer's song (1 per proposer per battle)...
    select r.id, r.song_id, s.spotify_track_id
    into v_b_row, v_b_song, v_b_track
    from queue_ranked(p_arena_id) r join songs s on s.id = r.song_id
    where r.id <> v_a_row
      and s.spotify_track_id is distinct from v_a_track
      and (r.proposed_by is null or v_a_by is null or r.proposed_by <> v_a_by)
      and track_available_at(p_arena_id, s.spotify_track_id) is null
    order by r.global_rank
    limit 1;

    -- ...else the same proposer's next one
    if v_b_row is null then
      select r.id, r.song_id, s.spotify_track_id
      into v_b_row, v_b_song, v_b_track
      from queue_ranked(p_arena_id) r join songs s on s.id = r.song_id
      where r.id <> v_a_row
        and s.spotify_track_id is distinct from v_a_track
        and track_available_at(p_arena_id, s.spotify_track_id) is null
      order by r.global_rank
      limit 1;
    end if;
  end if;

  -- Picked songs leave the queue; the battles trigger links them to the battle
  insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome)
  select q.arena_id, q.song_id, q.proposed_by, q.created_at, 'battled'
  from queues q
  where q.id in (v_a_row, v_b_row) and q.proposed_by is not null;

  delete from queues where id in (v_a_row, v_b_row);

  -- Missing slots: a previous loser, then the library
  if v_a_song is null then
    v_a_song := pick_rematch_song(p_arena_id, array_remove(array[v_b_track], null), v_last);
    if v_a_song is null then
      v_a_song := pick_library_song(p_arena_id, array_remove(array[v_b_track], null), v_last);
    end if;
    select spotify_track_id into v_a_track from songs where id = v_a_song;
  end if;

  if v_b_song is null then
    v_b_song := pick_rematch_song(p_arena_id, array_remove(array[v_a_track], null), v_last);
    if v_b_song is null then
      v_b_song := pick_library_song(p_arena_id, array_remove(array[v_a_track], null), v_last);
    end if;
  end if;

  -- Purge: 20 battles in waiting without reaching the next 10
  update queues set battles_waited = battles_waited + 1, updated_at = now()
  where arena_id = p_arena_id and queue_type = 'waiting';

  with purged as (
    delete from queues
    where arena_id = p_arena_id and queue_type = 'waiting' and battles_waited >= 20
    returning arena_id, song_id, proposed_by, created_at
  )
  insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome)
  select arena_id, song_id, proposed_by, created_at, 'purged'
  from purged where proposed_by is not null;

  perform refill_active_queue(p_arena_id);

  return query select v_a_song, v_b_song where v_a_song is not null and v_b_song is not null;
end;
$$;

revoke execute on function public.pull_next_battle_songs(uuid) from public, anon, authenticated;
revoke execute on function public.pick_rematch_song(uuid, text[], uuid) from public, anon, authenticated;
revoke execute on function public.pick_library_song(uuid, text[], uuid) from public, anon, authenticated;
revoke execute on function public.refill_active_queue(uuid) from public, anon, authenticated;
revoke execute on function public.queue_ranked(uuid) from public, anon, authenticated;
revoke execute on function public.lock_arena_queue(uuid) from public, anon, authenticated;

create or replace function public.link_battle_proposals()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  update proposal_history
  set battle_id = new.id
  where arena_id = new.arena_id
    and outcome = 'battled'
    and battle_id is null
    and song_id in (new.song_a_id, new.song_b_id);
  return null;
end;
$$;

drop trigger if exists trg_battles_link_proposals on public.battles;
create trigger trg_battles_link_proposals
  after insert on public.battles
  for each row execute function public.link_battle_proposals();

-- ============================================================
-- 5. Withdraw + "Your proposals"
-- ============================================================

create or replace function public.withdraw_proposal(p_queue_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_arena_id uuid;
  v_row queues%rowtype;
begin
  select arena_id into v_arena_id from queues where id = p_queue_id and proposed_by = auth.uid();
  if v_arena_id is null or auth.uid() is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from arenas where id = v_arena_id and state in ('waiting', 'active')) then
    raise exception 'arena_closed' using errcode = '55000';
  end if;

  perform lock_arena_queue(v_arena_id);

  -- Re-read under the lock: it may have just entered a battle
  delete from queues where id = p_queue_id and proposed_by = auth.uid()
  returning * into v_row;
  if v_row.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome)
  values (v_row.arena_id, v_row.song_id, v_row.proposed_by, v_row.created_at, 'withdrawn');

  perform refill_active_queue(v_arena_id);
  perform touch_participant_activity(v_arena_id, auth.uid());
end;
$$;

revoke execute on function public.withdraw_proposal(uuid) from public, anon;
grant execute on function public.withdraw_proposal(uuid) to authenticated;

-- status: next | waiting (queued; place = rank in that list, battles_left
-- before the purge) or competing | won | lost | draw | cancelled | purged |
-- withdrawn (history). queue_id only for queued rows (withdraw).
drop function if exists public.get_my_proposals(uuid);
create function public.get_my_proposals(p_arena_id uuid)
returns table (
  queue_id uuid, song_id uuid, title text, artist text, artwork_url text,
  status text, place bigint, battles_left integer, at timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select x.queue_id, x.song_id, x.title, x.artist, x.artwork_url, x.status, x.place, x.battles_left, x.at
  from (
    select r.id as queue_id, s.id as song_id, s.title, s.artist, s.artwork_url,
           case r.queue_type when 'active' then 'next' else 'waiting' end as status,
           r.rank_in_list as place,
           case when r.queue_type = 'waiting' then 20 - r.battles_waited end as battles_left,
           r.created_at as at,
           0 as grp, r.global_rank as k
    from queue_ranked(p_arena_id) r
    join songs s on s.id = r.song_id
    where r.proposed_by = auth.uid() and auth.uid() is not null
    union all
    select null, s.id, s.title, s.artist, s.artwork_url,
           case
             when h.outcome <> 'battled' then h.outcome
             when b.resolution_type = 'cancelled' then 'cancelled'
             when b.resolution_type = 'draw' then 'draw'
             when b.winner_song_id = h.song_id then 'won'
             when b.winner_song_id is not null then 'lost'
             else 'competing'
           end,
           null, null, h.ended_at,
           1, -extract(epoch from h.ended_at)::bigint
    from proposal_history h
    join songs s on s.id = h.song_id
    left join battles b on b.id = h.battle_id
    where h.arena_id = p_arena_id and h.proposed_by = auth.uid() and auth.uid() is not null
  ) x
  order by x.grp, x.k;
$$;

revoke execute on function public.get_my_proposals(uuid) from public, anon;
grant execute on function public.get_my_proposals(uuid) to authenticated;

-- ============================================================
-- 6. Existing queued rows: fill the next 10 of open arenas
-- ============================================================

select refill_active_queue(a.id) from arenas a
where a.state in ('waiting', 'active') and exists (select 1 from queues q where q.arena_id = a.id);

-- ============================================================
-- 7. Accounts merge + retention (unchanged except the proposal_history line)
-- ============================================================
-- Merge (step 7b) moves the proposer; the 30-day purge (Block 5 §6) deletes
-- the history with the arena's votes.

CREATE OR REPLACE FUNCTION public.merge_anonymous_user(p_from uuid, p_to uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
  v_to_participant uuid;
  v_moved int := 0;
  v_fused int := 0;
begin
  if p_from = p_to then
    raise exception 'same user';
  end if;
  if not exists (select 1 from auth.users where id = p_from and is_anonymous) then
    raise exception 'source is not an anonymous user';
  end if;
  if not exists (select 1 from auth.users where id = p_to and not is_anonymous) then
    raise exception 'target is not an account';
  end if;

  -- Hosting
  update arenas set host_id = p_to where host_id = p_from;
  update arena_playback set host_id = p_to where host_id = p_from;

  for r in select * from participants where identity_anchor_id = p_from loop
    select id into v_to_participant
    from participants where arena_id = r.arena_id and identity_anchor_id = p_to;

    if v_to_participant is null then
      update participants
      set identity_anchor_id = p_to,
          is_host = exists (select 1 from arenas a where a.id = r.arena_id and a.host_id = p_to)
      where id = r.id;
      v_moved := v_moved + 1;
    else
      -- Votes: one row per participant and battle; keep the most recent
      delete from votes v
      using votes w
      where v.battle_id = w.battle_id
        and ((v.participant_id = r.id and w.participant_id = v_to_participant and w.updated_at >= v.updated_at)
          or (v.participant_id = v_to_participant and w.participant_id = r.id and w.updated_at > v.updated_at));
      update votes set participant_id = v_to_participant where participant_id = r.id;

      delete from song_likes l
      where l.participant_id = r.id
        and exists (select 1 from song_likes k
                    where k.participant_id = v_to_participant and k.arena_id = l.arena_id and k.song_id = l.song_id);
      update song_likes set participant_id = v_to_participant where participant_id = r.id;

      delete from battle_presence_snapshots s
      where s.participant_id = r.id
        and exists (select 1 from battle_presence_snapshots k
                    where k.participant_id = v_to_participant and k.battle_id = s.battle_id);
      update battle_presence_snapshots set participant_id = v_to_participant where participant_id = r.id;

      update participants p
      set joined_at = least(p.joined_at, r.joined_at),
          last_active_at = greatest(p.last_active_at, r.last_active_at),
          last_seen_at = greatest(p.last_seen_at, r.last_seen_at),
          -- Still in the arena if either side was
          left_at = case when p.left_at is null or r.left_at is null then null
                         else greatest(p.left_at, r.left_at) end,
          disconnected_at = case when p.disconnected_at is null or r.disconnected_at is null then null
                                 else greatest(p.disconnected_at, r.disconnected_at) end,
          is_host = exists (select 1 from arenas a where a.id = r.arena_id and a.host_id = p_to)
      where p.id = v_to_participant;

      delete from participants where id = r.id;
      v_fused := v_fused + 1;
    end if;
  end loop;

  update votes set identity_anchor_id = p_to where identity_anchor_id = p_from;
  update battle_presence_snapshots set identity_anchor_id = p_to where identity_anchor_id = p_from;
  update queues set proposed_by = p_to where proposed_by = p_from;
  update proposal_history set proposed_by = p_to where proposed_by = p_from;
  delete from spotify_oauth_states where user_id = p_from;
  delete from account_merge_tickets where anon_user_id = p_from;

  return jsonb_build_object('arenas_moved', v_moved, 'arenas_fused', v_fused);
end;
$function$;

CREATE OR REPLACE FUNCTION public.purge_old_arena_votes(p_retention interval DEFAULT '30 days'::interval)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_count integer := 0;
  r record;
begin
  for r in
    select id from arenas
    where state in ('finished', 'expired')
      and votes_purged_at is null
      and coalesce(ended_at, updated_at) < now() - p_retention
  loop
    update battles b
    set final_votes_a = c.va, final_votes_b = c.vb
    from (
      select b2.id,
        count(v.id) filter (where v.song_id = b2.song_a_id and v.status = 'active'
          and (b2.sudden_death_started_at is null or v.vote_type = 'sudden_death'))::int as va,
        count(v.id) filter (where v.song_id = b2.song_b_id and v.status = 'active'
          and (b2.sudden_death_started_at is null or v.vote_type = 'sudden_death'))::int as vb
      from battles b2
      left join votes v on v.battle_id = b2.id
      where b2.arena_id = r.id
      group by b2.id
    ) c
    where b.id = c.id;

    delete from votes v using battles b
    where v.battle_id = b.id and b.arena_id = r.id;

    delete from battle_presence_snapshots where arena_id = r.id;
    delete from proposal_history where arena_id = r.id;

    update arenas set votes_purged_at = now() where id = r.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$function$;
