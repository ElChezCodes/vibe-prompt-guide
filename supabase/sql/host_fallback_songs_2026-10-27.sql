-- Step 12b: the curated library leaves Music Fighter; fallback songs come
-- from the host's own Spotify (2026-10-27, user decisions).
--
-- Slot chain of pull_next_battle_songs, after the queue (another proposer ->
-- the same proposer's next song):
--   1. a previous loser of this arena ("revancha", not from the battle that
--      just ended)
--   2. the host's source, chosen at creation: their Liked Songs (default) or
--      one of their own/collaborative playlists      (reserve: host_library)
--   3. catalog search (host's token) by the artists of this arena's proposed
--      or winning songs and the warm-up's artist     (reserve: arena_artist)
--   4. songs proposed here that were purged or withdrawn without fighting
--   5. nothing: no battle; the arena waits ("Waiting for songs") and
--      battle_lifecycle_job retries every second (create_next_battle).
-- Not chosen by the user: winners again after 60 min, an immediate rematch.
-- Spotify can't be called from SQL, so spotify-host keeps a small per-arena
-- reserve of 2 and 3 (refilled at Start and on every watch tick; deleted
-- when used and with the arena). Reserve songs are system songs: they never
-- enter `queues`, so they never take a human's place.
--
-- A pair is only applied (queue rows/reserve rows deleted, history written,
-- purge counted) when both slots are filled.

-- ============================================================
-- 1. Schema
-- ============================================================

-- 'liked' (or NULL) = the host's Liked Songs; else one of their playlist ids
alter table public.arenas add column if not exists fallback_source text;

create table if not exists public.arena_song_reserve (
  id uuid primary key default gen_random_uuid(),
  arena_id uuid not null references public.arenas(id) on delete cascade,
  song_id uuid not null references public.songs(id) on delete cascade,
  source text not null check (source in ('host_library', 'arena_artist')),
  created_at timestamptz not null default now(),
  unique (arena_id, song_id)
);

alter table public.arena_song_reserve enable row level security;
revoke all on public.arena_song_reserve from anon, authenticated;

-- The curated library is retired: test data only (user decision 2026-10-27)
update public.songs set status = 'retired', updated_at = now()
where arena_id = library_arena_id() and status <> 'retired';

drop function if exists public.pick_library_song(uuid, text[], uuid);

-- ============================================================
-- 2. Reserve (service-only, called by spotify-host)
-- ============================================================

-- How many of each kind are missing (target 3 each), the host's source and
-- seed artists (first credited artist of this arena's proposed/winning songs
-- and the warm-up, random order)
create or replace function public.reserve_needs(p_arena_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'host_library', greatest(0, 3 - (select count(*) from arena_song_reserve where arena_id = p_arena_id and source = 'host_library')),
    'arena_artist', greatest(0, 3 - (select count(*) from arena_song_reserve where arena_id = p_arena_id and source = 'arena_artist')),
    'source', coalesce((select fallback_source from arenas where id = p_arena_id), 'liked'),
    'artists', coalesce((
      select jsonb_agg(x.artist) from (
        select distinct split_part(s.artist, ', ', 1) as artist
        from songs s
        where s.arena_id = p_arena_id
          and s.source = 'spotify'
          and (s.id = (select warmup_song_id from arenas where id = p_arena_id)
               or exists (select 1 from queues q where q.song_id = s.id)
               or exists (select 1 from proposal_history h where h.song_id = s.id)
               or exists (select 1 from playlist_queue pq where pq.winner_song_id = s.id))
        order by 1
      ) x
    ), '[]'::jsonb)
  );
$$;

-- Adds up to p_limit of p_tracks ({spotify_track_id,title,artist,duration_ms,
-- artwork_url}) that may fight now: not the warm-up, not sounded in 60 min,
-- not queued, not fighting, not already reserved. Returns how many.
create or replace function public.add_reserve_songs(p_arena_id uuid, p_source text, p_tracks jsonb, p_limit integer)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_track jsonb;
  v_id text;
  v_song uuid;
  v_added integer := 0;
begin
  for v_track in select * from jsonb_array_elements(coalesce(p_tracks, '[]'::jsonb)) loop
    exit when v_added >= p_limit;
    v_id := v_track->>'spotify_track_id';
    continue when v_id is null
      or (v_track->>'duration_ms') is null
      or track_available_at(p_arena_id, v_id) is not null
      or exists (select 1 from arenas a join songs w on w.id = a.warmup_song_id
                 where a.id = p_arena_id and w.spotify_track_id = v_id)
      or exists (select 1 from songs s where s.arena_id = p_arena_id and s.spotify_track_id = v_id
                 and (exists (select 1 from queues q where q.song_id = s.id)
                      or exists (select 1 from arena_song_reserve r where r.song_id = s.id)
                      or exists (select 1 from battles b where b.arena_id = p_arena_id
                                 and b.state in ('pending', 'active', 'closing')
                                 and s.id in (b.song_a_id, b.song_b_id))));
    v_song := upsert_spotify_song(p_arena_id, v_track);
    insert into arena_song_reserve (arena_id, song_id, source) values (p_arena_id, v_song, p_source)
    on conflict do nothing;
    v_added := v_added + 1;
  end loop;
  return v_added;
end;
$$;

revoke execute on function public.reserve_needs(uuid) from public, anon, authenticated;
revoke execute on function public.add_reserve_songs(uuid, text, jsonb, integer) from public, anon, authenticated;

-- ============================================================
-- 3. Fallback picks (read-only; pull applies the pair)
-- ============================================================

create or replace function public.pick_fallback_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid)
returns uuid
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
  v_song uuid;
begin
  -- 1. revancha
  v_song := pick_rematch_song(p_arena_id, p_exclude, p_last_battle);
  if v_song is not null then
    return v_song;
  end if;

  -- 2-3. reserve: the host's source first, then the arena's artists
  select s.id into v_song
  from arena_song_reserve r join songs s on s.id = r.song_id
  where r.arena_id = p_arena_id
    and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
    and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = s.id)
    and track_available_at(p_arena_id, s.spotify_track_id) is null
  order by r.source = 'arena_artist', r.created_at, random()
  limit 1;
  if v_song is not null then
    return v_song;
  end if;

  -- 4. proposed here, left the queue without fighting
  select s.id into v_song
  from proposal_history h join songs s on s.id = h.song_id
  where h.arena_id = p_arena_id
    and h.outcome in ('purged', 'withdrawn')
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

revoke execute on function public.pick_fallback_song(uuid, text[], uuid) from public, anon, authenticated;

-- ============================================================
-- 4. Pairs: choose first, apply only a complete pair
-- ============================================================

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
  )
  insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome)
  select arena_id, song_id, proposed_by, created_at, 'purged'
  from purged where proposed_by is not null;

  perform refill_active_queue(p_arena_id);

  return query select v_a_song, v_b_song;
end;
$$;

revoke execute on function public.pull_next_battle_songs(uuid) from public, anon, authenticated;

-- The arena's next battle, when there is none open and a pair exists.
-- Duration = what sounds meanwhile: the last battle's winner(s), or the
-- warm-up before any battle (battle 1). Returns the battle id or NULL.
create or replace function public.create_next_battle(p_arena_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_pair record;
  v_last uuid;
  v_duration integer;
  v_id uuid;
begin
  -- Same lock as pull/proposals: one creator per arena at a time
  perform lock_arena_queue(p_arena_id);
  if exists (select 1 from battles where arena_id = p_arena_id and state in ('pending', 'active', 'closing')) then
    return null;
  end if;

  select * into v_pair from pull_next_battle_songs(p_arena_id);
  if v_pair.song_a is null then
    return null;
  end if;

  select id into v_last from battles where arena_id = p_arena_id order by created_at desc limit 1;
  if v_last is not null then
    select sum(song_duration_ms) into v_duration from playlist_queue where battle_id = v_last;
  else
    select w.duration_ms into v_duration
    from arenas a join songs w on w.id = a.warmup_song_id where a.id = p_arena_id;
  end if;

  insert into battles (arena_id, song_a_id, song_b_id, state, duration_ms, sudden_death_active)
  values (p_arena_id, v_pair.song_a, v_pair.song_b, 'pending', coalesce(v_duration, 45000), false)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_next_battle(uuid) from public, anon, authenticated;

-- ============================================================
-- 5. Start: battle 1 from the same chain, no library, no mock ids
-- ============================================================

create or replace function public.start_arena_battles(p_arena_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_arena arenas%rowtype;
  v_battle_id uuid;
begin
  select * into v_arena from arenas where id = p_arena_id for update;

  if not found then
    raise exception 'arena not found' using errcode = 'P0002';
  end if;
  if v_arena.host_id is distinct from auth.uid() then
    raise exception 'only the host can start battles' using errcode = '42501';
  end if;

  -- idempotent: host re-entering an arena that is already running
  if v_arena.state = 'active' then
    select id into v_battle_id
    from battles
    where arena_id = p_arena_id and state in ('pending', 'active', 'closing')
    order by created_at desc
    limit 1;

    return v_battle_id;
  elsif v_arena.state <> 'waiting' then
    raise exception 'arena is %', v_arena.state using errcode = '22023';
  end if;

  if not exists (select 1 from arena_playback where arena_id = p_arena_id and playlist_id is not null) then
    raise exception 'start the arena from Music Fighter so Spotify can play the warm-up'
      using errcode = '55000';
  end if;

  update arenas
  set state = 'active',
      started_at = now(),
      warmup_started_at = case when warmup_song_id is not null then now() end,
      updated_at = now()
  where id = p_arena_id;

  -- Battle 1 lasts the warm-up (the "winner of battle 0"). No pair yet:
  -- NULL, the arena waits and battle_lifecycle_job creates it later.
  return create_next_battle(p_arena_id);
end;
$$;

-- ============================================================
-- 6. Queue summary (low-queue notice, lobby count)
-- ============================================================

-- Human proposals still queued; members only
create or replace function public.get_arena_queue_summary(p_arena_id uuid)
returns table (human_queued integer, waiting_for_songs boolean)
language sql
stable
security definer
set search_path to 'public'
as $$
  select
    (select count(*)::int from queues q where q.arena_id = a.id and q.proposed_by is not null),
    a.state = 'active'
      and not exists (select 1 from battles b where b.arena_id = a.id and b.state in ('pending', 'active', 'closing'))
  from arenas a
  where a.id = p_arena_id
    and exists (select 1 from participants p where p.arena_id = a.id and p.identity_anchor_id = auth.uid());
$$;

revoke execute on function public.get_arena_queue_summary(uuid) from public, anon;
grant execute on function public.get_arena_queue_summary(uuid) to authenticated;

-- ============================================================
-- 7. Lifecycle: next battle via create_next_battle (no repeated pair)
-- ============================================================

CREATE OR REPLACE FUNCTION public.process_battle_lifecycle(p_arena_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_battle RECORD;
    v_now timestamptz := now();
    v_lockin_at timestamptz;
    v_end_at timestamptz;

    v_votes RECORD;
    v_winner uuid;
BEGIN

    -- 1️⃣ Obtener battle viva y lockearla
    SELECT *
    INTO v_battle
    FROM battles
    WHERE arena_id = p_arena_id
      AND state IN ('pending','active','closing')
    ORDER BY created_at
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- 2️⃣ pending → active
    IF v_battle.state = 'pending' THEN
        UPDATE battles
        SET state = 'active',
            started_at = v_now
        WHERE id = v_battle.id;
        RETURN;
    END IF;

    -- Calcular tiempos deterministas
    v_lockin_at :=
        v_battle.started_at
        + ((v_battle.duration_ms - 15000) * interval '1 millisecond');

    v_end_at :=
        v_battle.started_at
        + (v_battle.duration_ms * interval '1 millisecond');

    -- 3️⃣ ACTIVE → CLOSING (LOCK-IN)
    IF v_battle.state = 'active'
       AND v_now >= v_lockin_at
    THEN

        SELECT *
        INTO v_votes
        FROM calculate_lockin_vote_totals(v_battle.id);

        IF v_votes.is_tie = false THEN

            v_winner := CASE
                WHEN v_votes.votes_a > v_votes.votes_b THEN v_battle.song_a_id
                ELSE v_battle.song_b_id
            END;

            INSERT INTO playlist_queue (
                arena_id,
                battle_id,
                winner_song_id,
                spotify_track_id,
                song_duration_ms,
                created_at
            )
            SELECT
                v_battle.arena_id,
                v_battle.id,
                s.id,
                s.spotify_track_id,
                s.duration_ms,
                v_now
            FROM songs s
            WHERE s.id = v_winner;

            UPDATE battles
            SET state = 'closing',
                lockin_at = v_lockin_at,
                winner_song_id = v_winner,
                resolution_type = 'normal'
            WHERE id = v_battle.id;

        ELSE
            UPDATE battles
            SET state = 'closing',
                lockin_at = v_lockin_at,
                sudden_death_active = true,
                sudden_death_started_at = v_lockin_at
            WHERE id = v_battle.id;
        END IF;

        RETURN;
    END IF;

    -- 4️⃣ END OF BATTLE
    IF v_battle.state = 'closing'
       AND v_now >= v_end_at
    THEN

        -- Releer estado real antes de resolver
        SELECT *
        INTO v_battle
        FROM battles
        WHERE id = v_battle.id
        FOR UPDATE;

        -- Resolver Sudden Death si estaba activo
        IF v_battle.sudden_death_active = true THEN

            SELECT
                COALESCE(SUM(weight) FILTER (
                    WHERE song_id = v_battle.song_a_id
                    AND vote_type = 'sudden_death'
                    AND status = 'active'
                ),0) AS votes_a,
                COALESCE(SUM(weight) FILTER (
                    WHERE song_id = v_battle.song_b_id
                    AND vote_type = 'sudden_death'
                    AND status = 'active'
                ),0) AS votes_b
            INTO v_votes
            FROM votes
            WHERE battle_id = v_battle.id;

            IF v_votes.votes_a <> v_votes.votes_b THEN

                v_winner := CASE
                    WHEN v_votes.votes_a > v_votes.votes_b THEN v_battle.song_a_id
                    ELSE v_battle.song_b_id
                END;

                INSERT INTO playlist_queue (
                    arena_id,
                    battle_id,
                    winner_song_id,
                    spotify_track_id,
                    song_duration_ms,
                    created_at
                )
                SELECT
                    v_battle.arena_id,
                    v_battle.id,
                    s.id,
                    s.spotify_track_id,
                    s.duration_ms,
                    v_now
                FROM songs s
                WHERE s.id = v_winner;

                UPDATE battles
                SET winner_song_id = v_winner,
                    resolution_type = 'sudden_death',
                    sudden_death_active = false
                WHERE id = v_battle.id;

            ELSE
                -- SD empate real (0-0 o X-X) → DRAW
                INSERT INTO playlist_queue (
                    arena_id,
                    battle_id,
                    winner_song_id,
                    spotify_track_id,
                    song_duration_ms,
                    created_at
                )
                SELECT
                    v_battle.arena_id,
                    v_battle.id,
                    s.id,
                    s.spotify_track_id,
                    s.duration_ms,
                    v_now
                FROM songs s
                WHERE s.id IN (v_battle.song_a_id, v_battle.song_b_id);

                UPDATE battles
                SET resolution_type = 'draw',
                    sudden_death_active = false
                WHERE id = v_battle.id;
            END IF;
        END IF;

        -- Garantizar resolución antes de completar
        SELECT resolution_type
        INTO v_votes
        FROM battles
        WHERE id = v_battle.id;

        IF v_votes.resolution_type IS NULL THEN
            RETURN; -- no completar si no hay resolución válida
        END IF;

        -- Cierre final
        UPDATE battles
        SET state = 'completed',
            ended_at = v_end_at,
            enqueue_done = true
        WHERE id = v_battle.id;

        -- Next battle from the queue chain (step 12b); no pair = the arena
        -- waits and battle_lifecycle_job retries via create_next_battle
        PERFORM create_next_battle(v_battle.arena_id);

        RETURN;
    END IF;

END;
$function$;

-- Arenas waiting for songs (no open battle) get their next battle as soon
-- as a pair exists
select cron.alter_job(
  (select jobid from cron.job where jobname = 'battle_lifecycle_job'),
  command := $cmd$
  SELECT process_battle_lifecycle(a.id)
  FROM arenas a
  WHERE a.state = 'active'
    AND a.paused_at IS NULL
    AND EXISTS (
      SELECT 1
      FROM battles b
      WHERE b.arena_id = a.id
        AND b.state IN ('pending','active','closing')
    );
  SELECT create_next_battle(a.id)
  FROM arenas a
  WHERE a.state = 'active'
    AND a.paused_at IS NULL
    AND NOT EXISTS (
      SELECT 1
      FROM battles b
      WHERE b.arena_id = a.id
        AND b.state IN ('pending','active','closing')
    );
  $cmd$
);
