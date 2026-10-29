-- ===========================================================================
-- Roadmap step 14 (2026-10-28): a duplicate proposal is a pre-assigned vote.
--
-- Spec: v4 "MANEJO DE DUPLICADOS", v3.2 l.59, v3.0 §3.5, v2.6 §3.4/§8, PRD
-- v1.2x "Duplicate Proposal". Proposing a song that is already in the queue
-- doesn't create a new entry: it backs the queued song with one active vote
-- (1 point) that is cast when that song fights, changeable only during that
-- battle like any regular vote.
--
-- User decisions 2026-10-28:
--   * The vote is real from the start of its battle: when the battle row is
--     inserted, a regular 'active' vote row with preassigned = true is
--     written for every backer. It counts in votes_a/b, can be switched or
--     toggled off (= abstention: a votes row exists, so no passive vote),
--     upgraded once in Sudden Death like any regular vote. No timing changes.
--   * Spec conflict (PRD "voto activo" vs v2.6/v4 "no cuenta como actividad
--     reciente"): everything counts. Backing a song is an action (touches
--     activity), and so is the vote when it is cast (last_active_at only:
--     it doesn't make a closed app look connected).
--   * The vote is cast unless the backer left the arena ("Leave arena");
--     a locked phone or closed app doesn't drop it.
--   * Edge cases: a song fighting right now -> proposing it votes for it at
--     once (no active vote yet, before lock-in, not Sudden Death; else
--     in_battle as before); warm-up and recently_played keep their refusals;
--     a song no longer queued is a normal new proposal.
--   * Limits: one backing per person and song (already_backed), the original
--     proposer can't back their own song (own_proposal), backings don't use
--     the 5-proposals limit but have their own: 5 queued (backing_full).
--     Backings don't change the queue order.
--   * One person backing both songs of a battle: the oldest backing is cast,
--     the other is recorded as not applied.
--   * The original proposal withdrawn or purged after 20 battles: its
--     backings go with it (withdrawn/purged in each backer's history).
--   * A backer may remove their backing while the song is queued
--     (withdraw_backing, "Remove my vote" in "Your proposals").
--
-- Step 15 (half PI to duplicate proposers) reads proposal_history rows with
-- kind = 'backing' (battle_id, vote_applied). Readers of the original
-- proposer (turns per person, the arena's style, purged/withdrawn fallback)
-- now filter kind = 'proposal'.
--
-- System songs (step 13 reserve, revancha, artist search) never enter
-- queues, so they can't be backed and never carry pre-assigned votes.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Backings of queued songs (service-only, read through get_my_proposals)
-- ---------------------------------------------------------------------------
create table if not exists public.queue_backers (
  arena_id uuid not null references public.arenas(id) on delete cascade,
  song_id uuid not null references public.songs(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (arena_id, song_id, user_id)
);
create index if not exists queue_backers_user_idx on public.queue_backers (arena_id, user_id);
alter table public.queue_backers enable row level security;
revoke all on public.queue_backers from anon, authenticated;

-- History: original proposals and backings, for "Your proposals" and step 15
alter table public.proposal_history
  add column if not exists kind text not null default 'proposal',
  add column if not exists vote_applied boolean;
alter table public.proposal_history drop constraint if exists proposal_history_kind_check;
alter table public.proposal_history
  add constraint proposal_history_kind_check check (kind in ('proposal', 'backing'));

-- A vote cast by Music Fighter for a backer; cleared as soon as they touch it
alter table public.votes add column if not exists preassigned boolean not null default false;

-- ---------------------------------------------------------------------------
-- Votes: only apply_preassigned_votes may write preassigned = true
-- ---------------------------------------------------------------------------
create or replace function public.fill_vote_fields()
 returns trigger
 language plpgsql
as $function$
BEGIN
  IF NEW.vote_type = 'passive' THEN
    IF auth.uid() IS NOT NULL THEN
      RAISE EXCEPTION 'passive votes are system-only';
    END IF;
    NEW.preassigned := false;
  ELSIF NEW.preassigned AND current_setting('mf.preassigning', true) = 'on' THEN
    -- Step 14: cast by apply_preassigned_votes for the backer, whose
    -- identity it sets (auth.uid() is the cron's or the host's at Start)
    NULL;
  ELSE
    NEW.preassigned := false;

    -- Debe existir usuario autenticado
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION 'auth.uid() is required to vote';
    END IF;

    -- Identity SIEMPRE viene del backend
    NEW.identity_anchor_id := auth.uid();
  END IF;

  -- Derivar arena_id desde battle
  SELECT arena_id
  INTO NEW.arena_id
  FROM public.battles
  WHERE id = NEW.battle_id;

  RETURN NEW;
END;
$function$;

-- The backer switching or toggling it: it is their own vote from then on
create or replace function public.clear_vote_preassigned()
 returns trigger
 language plpgsql
as $function$
begin
  if not old.preassigned and not new.preassigned then
    return new;
  end if;
  new.preassigned := old.preassigned
    and new.song_id = old.song_id and new.status = old.status and new.vote_type = old.vote_type;
  return new;
end;
$function$;

drop trigger if exists trg_votes_clear_preassigned on public.votes;
create trigger trg_votes_clear_preassigned
  before update on public.votes
  for each row execute function public.clear_vote_preassigned();

-- Activity: the caller's own votes as before; a pre-assigned vote also counts
-- (user decision 2026-10-28) but only as activity, not as being connected
create or replace function public.touch_activity_on_vote()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if new.vote_type = 'passive' then
    return null;
  end if;
  if auth.uid() is not null and new.identity_anchor_id = auth.uid() then
    perform touch_participant_activity(new.arena_id, auth.uid());
  elsif tg_op = 'INSERT' and new.preassigned then
    update participants
    set last_active_at = now(), updated_at = now()
    where arena_id = new.arena_id and identity_anchor_id = new.identity_anchor_id;
  end if;
  return null;
end;
$function$;

-- ---------------------------------------------------------------------------
-- A battle starts: its songs' backers get their vote, backings go to history
-- ---------------------------------------------------------------------------
create or replace function public.apply_preassigned_votes()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if not exists (select 1 from queue_backers k
                 where k.arena_id = new.arena_id and k.song_id in (new.song_a_id, new.song_b_id)) then
    return null;
  end if;

  perform set_config('mf.preassigning', 'on', true);
  -- Backers still in the arena; both songs backed -> the oldest backing
  insert into votes (battle_id, song_id, participant_id, identity_anchor_id, vote_type, status, preassigned)
  select distinct on (k.user_id) new.id, k.song_id, p.id, k.user_id, 'regular', 'active', true
  from queue_backers k
  join participants p on p.arena_id = k.arena_id and p.identity_anchor_id = k.user_id and p.left_at is null
  where k.arena_id = new.arena_id and k.song_id in (new.song_a_id, new.song_b_id)
  order by k.user_id, k.created_at, k.song_id
  on conflict (battle_id, participant_id) do nothing;
  perform set_config('mf.preassigning', '', true);

  with gone as (
    delete from queue_backers k
    where k.arena_id = new.arena_id and k.song_id in (new.song_a_id, new.song_b_id)
    returning k.*
  )
  insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome, battle_id, kind, vote_applied)
  select g.arena_id, g.song_id, g.user_id, g.created_at, 'battled', new.id, 'backing',
         exists (select 1 from votes v
                 where v.battle_id = new.id and v.identity_anchor_id = g.user_id
                   and v.song_id = g.song_id and v.preassigned)
  from gone g;

  return null;
end;
$function$;
revoke all on function public.apply_preassigned_votes() from public, anon, authenticated;

drop trigger if exists trg_battles_apply_preassigned on public.battles;
create trigger trg_battles_apply_preassigned
  after insert on public.battles
  for each row execute function public.apply_preassigned_votes();

-- ---------------------------------------------------------------------------
-- Backings leaving with their song (withdrawn / purged) or removed by the backer
-- ---------------------------------------------------------------------------
create or replace function public.drop_queue_backers(p_arena_id uuid, p_song_ids uuid[], p_outcome text)
 returns void
 language sql
 security definer
 set search_path to 'public'
as $function$
  with gone as (
    delete from queue_backers
    where arena_id = p_arena_id and song_id = any (coalesce(p_song_ids, '{}'))
    returning *
  )
  insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome, kind)
  select arena_id, song_id, user_id, created_at, p_outcome, 'backing' from gone;
$function$;
revoke all on function public.drop_queue_backers(uuid, uuid[], text) from public, anon, authenticated;

create or replace function public.withdraw_backing(p_arena_id uuid, p_song_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_rows int;
begin
  if auth.uid() is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from arenas where id = p_arena_id and state in ('waiting', 'active')) then
    raise exception 'arena_closed' using errcode = '55000';
  end if;

  perform lock_arena_queue(p_arena_id);

  -- Under the lock: its battle may have just started (then it is a vote)
  with gone as (
    delete from queue_backers
    where arena_id = p_arena_id and song_id = p_song_id and user_id = auth.uid()
    returning *
  )
  insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome, kind)
  select arena_id, song_id, user_id, created_at, 'withdrawn', 'backing' from gone;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  perform touch_participant_activity(p_arena_id, auth.uid());
end;
$function$;
revoke all on function public.withdraw_backing(uuid, uuid) from public, anon;
grant execute on function public.withdraw_backing(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Proposing a song that is queued or fighting (spotify-host propose, as the
-- caller, after the queues insert refused it with 23505 / in_battle).
-- Results: backed | already_backed | own_proposal | backing_full | voted |
-- already_voted | in_battle | not_queued (it just left the queue)
-- ---------------------------------------------------------------------------
create or replace function public.back_proposal(p_arena_id uuid, p_song_id uuid)
 returns text
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_participant uuid;
  v_track text;
  v_battle battles;
  v_song uuid;
  v_vote votes;
  v_rows int;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select p.id into v_participant
  from participants p join arenas a on a.id = p.arena_id
  where p.arena_id = p_arena_id and p.identity_anchor_id = v_uid
    and p.left_at is null and a.state in ('waiting', 'active');
  if v_participant is null then
    raise exception 'not a member of an open arena' using errcode = '42501';
  end if;
  select spotify_track_id into v_track from songs where id = p_song_id and arena_id = p_arena_id;
  if v_track is null then
    raise exception 'song not in this arena' using errcode = '22023';
  end if;

  perform lock_arena_queue(p_arena_id);
  -- Proposing is an action, whatever the answer
  perform touch_participant_activity(p_arena_id, v_uid);

  -- Queued: a pre-assigned vote for its battle, not a new entry
  if exists (select 1 from queues where arena_id = p_arena_id and song_id = p_song_id) then
    if exists (select 1 from queues where arena_id = p_arena_id and song_id = p_song_id and proposed_by = v_uid) then
      return 'own_proposal';
    end if;
    if exists (select 1 from queue_backers where arena_id = p_arena_id and song_id = p_song_id and user_id = v_uid) then
      return 'already_backed';
    end if;
    if (select count(*) from queue_backers where arena_id = p_arena_id and user_id = v_uid) >= 5 then
      return 'backing_full';
    end if;
    insert into queue_backers (arena_id, song_id, user_id) values (p_arena_id, p_song_id, v_uid);
    perform record_affinity_signal(v_uid, p_song_id, 'proposal', p_arena_id);
    return 'backed';
  end if;

  -- Fighting now: vote for it at once (same rule as a like)
  select b.* into v_battle
  from battles b join songs s on s.id in (b.song_a_id, b.song_b_id)
  where b.arena_id = p_arena_id and b.state in ('pending', 'active', 'closing')
    and s.spotify_track_id = v_track
  order by b.created_at desc
  limit 1;
  if not found then
    return 'not_queued';
  end if;
  select s.id into v_song from songs s
  where s.id in (v_battle.song_a_id, v_battle.song_b_id) and s.spotify_track_id = v_track
  limit 1;

  select * into v_vote from votes
  where battle_id = v_battle.id and participant_id = v_participant and status = 'active';
  if found then
    return case when v_vote.song_id = v_song then 'already_voted' else 'in_battle' end;
  end if;
  if v_battle.state <> 'active' or v_battle.lockin_at is not null or v_battle.sudden_death_active
     or exists (select 1 from arenas a where a.id = p_arena_id and (a.state <> 'active' or a.paused_at is not null)) then
    return 'in_battle';
  end if;

  insert into votes (battle_id, song_id, participant_id, vote_type, status)
  values (v_battle.id, v_song, v_participant, 'regular', 'active')
  on conflict (battle_id, participant_id) do update
    set song_id = excluded.song_id, status = 'active', updated_at = now()
    where votes.status = 'cancelled' and votes.vote_type = 'regular';
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    return 'in_battle';
  end if;

  -- Step 15: a duplicate of someone else's proposal fighting now
  if exists (select 1 from proposal_history h
             where h.battle_id = v_battle.id and h.song_id = v_song and h.kind = 'proposal' and h.proposed_by <> v_uid)
     and not exists (select 1 from proposal_history h
                     where h.battle_id = v_battle.id and h.song_id = v_song and h.kind = 'backing' and h.proposed_by = v_uid) then
    insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome, battle_id, kind, vote_applied)
    values (p_arena_id, v_song, v_uid, now(), 'battled', v_battle.id, 'backing', true);
  end if;
  return 'voted';
end;
$function$;
revoke all on function public.back_proposal(uuid, uuid) from public, anon;
grant execute on function public.back_proposal(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- "Your proposals": own proposals and backings, queued then history
-- ---------------------------------------------------------------------------
drop function if exists public.get_my_proposals(uuid);
create function public.get_my_proposals(p_arena_id uuid)
 returns table(queue_id uuid, song_id uuid, spotify_track_id text, title text, artist text, artwork_url text,
               status text, place bigint, battles_left integer, at timestamp with time zone,
               kind text, vote_applied boolean)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with r as (select * from queue_ranked(p_arena_id))
  select x.queue_id, x.song_id, x.spotify_track_id, x.title, x.artist, x.artwork_url, x.status, x.place,
         x.battles_left, x.at, x.kind, x.vote_applied
  from (
    select case when r.proposed_by = auth.uid() then r.id end as queue_id,
           s.id as song_id, s.spotify_track_id, s.title, s.artist, s.artwork_url,
           case r.queue_type when 'active' then 'next' else 'waiting' end as status,
           r.rank_in_list as place,
           case when r.queue_type = 'waiting' then 20 - r.battles_waited end as battles_left,
           coalesce(qb.created_at, r.created_at) as at,
           case when qb.user_id is null then 'proposal' else 'backing' end as kind,
           null::boolean as vote_applied,
           0 as grp, r.global_rank as k
    from r
    join songs s on s.id = r.song_id
    left join queue_backers qb on qb.arena_id = p_arena_id and qb.song_id = r.song_id and qb.user_id = auth.uid()
    where auth.uid() is not null and (r.proposed_by = auth.uid() or qb.user_id is not null)
    union all
    select null, s.id, s.spotify_track_id, s.title, s.artist, s.artwork_url,
           case
             when h.outcome <> 'battled' then h.outcome
             when b.resolution_type = 'cancelled' then 'cancelled'
             when b.resolution_type = 'draw' then 'draw'
             when b.winner_song_id = h.song_id then 'won'
             when b.winner_song_id is not null then 'lost'
             else 'competing'
           end,
           null, null, h.ended_at, h.kind, h.vote_applied,
           1, -extract(epoch from h.ended_at)::bigint
    from proposal_history h
    join songs s on s.id = h.song_id
    left join battles b on b.id = h.battle_id
    where h.arena_id = p_arena_id and h.proposed_by = auth.uid() and auth.uid() is not null
  ) x
  order by x.grp, x.k;
$function$;
revoke all on function public.get_my_proposals(uuid) from public, anon;
grant execute on function public.get_my_proposals(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Existing functions (live definitions, changes marked "Step 14")
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.queue_ranked(p_arena_id uuid)
 RETURNS TABLE(id uuid, song_id uuid, proposed_by uuid, queue_type text, battles_waited integer, created_at timestamp with time zone, rank_in_list bigint, global_rank bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with battled as (
    select h.proposed_by, count(*) as n
    from proposal_history h
    where h.arena_id = p_arena_id and h.outcome = 'battled' and h.kind = 'proposal'  -- Step 14
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
$function$;

CREATE OR REPLACE FUNCTION public.arena_style_songs(p_arena_id uuid)
 RETURNS TABLE(isrc text, w real)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with c as (select style_half_life_minutes from system_song_config where id = 1),
  heard as (
    select s.isrc, coalesce(a.warmup_started_at, a.created_at) as at
    from arenas a join songs s on s.id = a.warmup_song_id
    where a.id = p_arena_id
    union all
    select s.isrc, q.created_at
    from queues q join songs s on s.id = q.song_id
    where q.arena_id = p_arena_id and q.proposed_by is not null
    union all
    select s.isrc, h.proposed_at
    from proposal_history h join songs s on s.id = h.song_id
    where h.arena_id = p_arena_id and h.proposed_by is not null and h.kind = 'proposal'  -- Step 14
    union all
    select s.isrc, pq.created_at
    from playlist_queue pq join songs s on s.id = pq.winner_song_id
    where pq.arena_id = p_arena_id
  )
  select h.isrc,
         sum(power(0.5, greatest(0, extract(epoch from now() - h.at)) / 60.0 / c.style_half_life_minutes))::real
  from heard h, c
  where h.isrc is not null
  group by h.isrc;
$function$;

CREATE OR REPLACE FUNCTION public.pick_fallback_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_song uuid;
  v_bucket real;
begin
  -- 1. revancha
  v_song := pick_rematch_song(p_arena_id, p_exclude, p_last_battle);
  if v_song is not null then
    return v_song;
  end if;

  -- 2-3. reserve: libraries (host's source, guests'), then the arena's
  -- artists; inside each, known fit first (buckets), taste, random
  select fit_bucket into v_bucket from system_song_config where id = 1;
  select s.id into v_song
  from arena_song_reserve r join songs s on s.id = r.song_id
  where r.arena_id = p_arena_id
    and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
    and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = s.id)
    and track_available_at(p_arena_id, s.spotify_track_id) is null
  order by r.source = 'arena_artist', r.fit is null, floor(r.fit / v_bucket) desc,
           r.taste desc nulls last, random()
  limit 1;
  if v_song is not null then
    return v_song;
  end if;

  -- 4. proposed here, left the queue without fighting
  select s.id into v_song
  from proposal_history h join songs s on s.id = h.song_id
  where h.arena_id = p_arena_id
    and h.outcome in ('purged', 'withdrawn')
    and h.kind = 'proposal'  -- Step 14
    and s.status = 'active'
    and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
    and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = s.id)
    and not exists (select 1 from battles b where b.arena_id = p_arena_id and s.id in (b.song_a_id, b.song_b_id))
    and track_available_at(p_arena_id, s.spotify_track_id) is null
  order by random()
  limit 1;
  return v_song;
end;
$function$;

CREATE OR REPLACE FUNCTION public.withdraw_proposal(p_queue_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- Step 14: its backings go with it
  perform drop_queue_backers(v_row.arena_id, array[v_row.song_id], 'withdrawn');

  perform refill_active_queue(v_arena_id);
  perform touch_participant_activity(v_arena_id, auth.uid());
end;
$function$;

CREATE OR REPLACE FUNCTION public.pull_next_battle_songs(p_arena_id uuid)
 RETURNS TABLE(song_a uuid, song_b uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_last uuid;
  v_a_row uuid;
  v_a_song uuid;
  v_a_by uuid;
  v_a_track text;
  v_b_row uuid;
  v_b_song uuid;
  v_b_track text;
  v_purged uuid[];
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

  -- Missing slots: revancha -> host's source -> arena artists -> purged/withdrawn
  if v_a_song is null then
    v_a_song := pick_fallback_song(p_arena_id, array_remove(array[v_b_track], null), v_last);
    select spotify_track_id into v_a_track from songs where id = v_a_song;
  end if;
  if v_b_song is null then
    v_b_song := pick_fallback_song(p_arena_id, array_remove(array[v_a_track], null), v_last);
  end if;

  -- No pair: nothing changes, the arena waits
  if v_a_song is null or v_b_song is null then
    return;
  end if;

  -- Picked songs leave the queue/reserve; the battles trigger links history
  insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome)
  select q.arena_id, q.song_id, q.proposed_by, q.created_at, 'battled'
  from queues q
  where q.id in (v_a_row, v_b_row) and q.proposed_by is not null;

  delete from queues where id in (v_a_row, v_b_row);
  delete from arena_song_reserve where arena_id = p_arena_id and song_id in (v_a_song, v_b_song);

  -- Purge: 20 battles in waiting without reaching the next 10
  update queues set battles_waited = battles_waited + 1, updated_at = now()
  where arena_id = p_arena_id and queue_type = 'waiting';

  with purged as (
    delete from queues
    where arena_id = p_arena_id and queue_type = 'waiting' and battles_waited >= 20
    returning arena_id, song_id, proposed_by, created_at
  ), hist as (
    insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome)
    select arena_id, song_id, proposed_by, created_at, 'purged'
    from purged where proposed_by is not null
  )
  select array_agg(song_id) into v_purged from purged;

  -- Step 14: their backings go with them
  perform drop_queue_backers(p_arena_id, v_purged, 'purged');

  perform refill_active_queue(p_arena_id);

  return query select v_a_song, v_b_song;
end;
$function$;

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

  -- Step 14: backings (one per song; none for a song the account proposed)
  delete from queue_backers a
  using queue_backers b
  where a.user_id = p_from and b.user_id = p_to and a.arena_id = b.arena_id and a.song_id = b.song_id;
  update queue_backers set user_id = p_to where user_id = p_from;
  delete from queue_backers k
  using queues q
  where k.user_id = p_to and q.arena_id = k.arena_id and q.song_id = k.song_id and q.proposed_by = p_to;

  -- Step 8: the anonymous in-arena profile becomes part of the account's
  delete from affinity_signals a
  using affinity_signals b
  where a.user_id = p_from and b.user_id = p_to
    and a.kind = b.kind and a.isrc = b.isrc and a.arena_id is not distinct from b.arena_id;
  update affinity_signals set user_id = p_to where user_id = p_from;

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
    set final_votes_a = c.va, final_votes_b = c.vb,
        final_passive_a = c.pa, final_passive_b = c.pb
    from (
      select b2.id,
        count(v.id) filter (where v.song_id = b2.song_a_id and v.status = 'active' and v.vote_type <> 'passive'
          and (b2.sudden_death_started_at is null or v.vote_type = 'sudden_death'))::int as va,
        count(v.id) filter (where v.song_id = b2.song_b_id and v.status = 'active' and v.vote_type <> 'passive'
          and (b2.sudden_death_started_at is null or v.vote_type = 'sudden_death'))::int as vb,
        coalesce(sum(v.weight) filter (where v.song_id = b2.song_a_id and v.status = 'active' and v.vote_type = 'passive'), 0)::real as pa,
        coalesce(sum(v.weight) filter (where v.song_id = b2.song_b_id and v.status = 'active' and v.vote_type = 'passive'), 0)::real as pb
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
    delete from queue_backers where arena_id = r.id;  -- Step 14

    -- Anonymous users' in-arena profile goes with the votes; accounts keep theirs
    delete from affinity_signals s
    using auth.users u
    where s.arena_id = r.id and u.id = s.user_id and u.is_anonymous;

    update arenas set votes_purged_at = now() where id = r.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$function$;

