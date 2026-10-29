-- ===========================================================================
-- Two songs actively proposed by the same person never face each other
-- (user decision 2026-10-29, found reviewing step 15: proposing both songs of
-- a draw earned 22 PI). Overrides step 12's slot-B chain "another
-- proposer's -> the same proposer's next -> fallback": the middle step is
-- gone. B = another proposer's queued song, else a system song
-- (pick_fallback_song), which now also skips songs originally proposed by
-- A's proposer (revancha = a previous loser, purged/withdrawn proposals).
-- Even with a single person proposing (e.g. the host alone), their songs
-- fight the host's backup music / reserve; with no such song the arena
-- waits for songs, as before.
--
-- "Originally proposed by" = the queue row's proposer, else the latest
-- proposal_history row of kind 'proposal' (step 14: backings don't count).
-- System songs (reserve: host's source, lent Liked Songs, arena artists)
-- have no proposer and can face anyone.
-- ===========================================================================

create or replace function public.song_original_proposer(p_arena_id uuid, p_song_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select q.proposed_by from queues q
     where q.arena_id = p_arena_id and q.song_id = p_song_id and q.proposed_by is not null
     limit 1),
    (select h.proposed_by from proposal_history h
     where h.arena_id = p_arena_id and h.song_id = p_song_id and h.kind = 'proposal' and h.proposed_by is not null
     order by h.ended_at desc nulls last
     limit 1));
$$;
revoke all on function public.song_original_proposer(uuid, uuid) from public, anon, authenticated;

drop function if exists public.pick_rematch_song(uuid, text[], uuid);
create or replace function public.pick_rematch_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid,
                                                    p_avoid_proposer uuid default null)
returns uuid
language sql
security definer
set search_path = public
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
    and (p_avoid_proposer is null
         or not exists (select 1 from proposal_history h
                        where h.arena_id = p_arena_id and h.song_id = s.id
                          and h.kind = 'proposal' and h.proposed_by = p_avoid_proposer))
  group by s.id
  order by max(b.created_at), random()
  limit 1;
$$;
revoke all on function public.pick_rematch_song(uuid, text[], uuid, uuid) from public, anon, authenticated;

drop function if exists public.pick_fallback_song(uuid, text[], uuid);
create or replace function public.pick_fallback_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid,
                                                     p_avoid_proposer uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_song uuid;
  v_bucket real;
begin
  -- 1. revancha (not one of the other song's proposer)
  v_song := pick_rematch_song(p_arena_id, p_exclude, p_last_battle, p_avoid_proposer);
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

  -- 4. proposed here, left the queue without fighting (not by the other
  -- song's proposer)
  select s.id into v_song
  from proposal_history h join songs s on s.id = h.song_id
  where h.arena_id = p_arena_id
    and h.outcome in ('purged', 'withdrawn')
    and h.kind = 'proposal'  -- Step 14
    and (p_avoid_proposer is null or h.proposed_by is distinct from p_avoid_proposer)
    and s.status = 'active'
    and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
    and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = s.id)
    and not exists (select 1 from battles b where b.arena_id = p_arena_id and s.id in (b.song_a_id, b.song_b_id))
    and track_available_at(p_arena_id, s.spotify_track_id) is null
  order by random()
  limit 1;
  return v_song;
end;
$$;
revoke all on function public.pick_fallback_song(uuid, text[], uuid, uuid) from public, anon, authenticated;

create or replace function public.pull_next_battle_songs(p_arena_id uuid)
returns table(song_a uuid, song_b uuid)
language plpgsql
security definer
set search_path = public
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
    -- B: another proposer's song (1 per proposer per battle). Never the same
    -- proposer's next one (2026-10-29): that falls to a system song below.
    select r.id, r.song_id, s.spotify_track_id
    into v_b_row, v_b_song, v_b_track
    from queue_ranked(p_arena_id) r join songs s on s.id = r.song_id
    where r.id <> v_a_row
      and s.spotify_track_id is distinct from v_a_track
      and (r.proposed_by is null or v_a_by is null or r.proposed_by <> v_a_by)
      and track_available_at(p_arena_id, s.spotify_track_id) is null
    order by r.global_rank
    limit 1;
  end if;

  -- Missing slots: revancha -> host's source -> arena artists -> purged/withdrawn,
  -- never a song originally proposed by the other slot's proposer
  if v_a_song is null then
    v_a_song := pick_fallback_song(p_arena_id, array_remove(array[v_b_track], null), v_last);
    select spotify_track_id into v_a_track from songs where id = v_a_song;
    v_a_by := song_original_proposer(p_arena_id, v_a_song);
  end if;
  if v_b_song is null then
    v_b_song := pick_fallback_song(p_arena_id, array_remove(array[v_a_track], null), v_last, v_a_by);
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
$$;
