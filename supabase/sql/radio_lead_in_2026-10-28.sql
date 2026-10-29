-- Step 18 follow-up (2026-10-28, found in-app): a Sudden Death winner was
-- appended ~1 s before the song ended (Spotify ran ~3 s ahead of MF's clock,
-- drifts < 3 s were ignored), Spotify had already moved on to its Autoplay
-- radio and MF cut the radio track to put the old song back.
--
-- User decisions 2026-10-28:
-- * Lock-in 25 s before the end (was 15 s); Sudden Death lasts 15 s and is
--   resolved 10 s before the end (was 10 s, at -5 s); the last 10 s take no
--   votes. A normal winner reaches the playlist at -25 s, a Sudden Death one
--   at -10 s.
-- * A song that is already playing is never cut: if Spotify's Autoplay/radio
--   starts before an arena song is due, that radio track plays to its end and
--   lengthens the battle playing over it (lead-in before the next arena song,
--   whose order doesn't change); MF puts the arena song in Spotify's queue so
--   it follows the radio track.
-- * The battle clock follows Spotify from 1 s of drift (was 3 s); spotify-host
--   now times Spotify's progress at the moment it was read.

alter table public.playlist_queue add column if not exists lead_in_ms integer not null default 0;
-- When the radio track ends: battle_lifecycle_job (every second) nudges
-- spotify-host then, so the arena song starts right after it
alter table public.arena_playback add column if not exists wake_at timestamptz;

-- ---------------------------------------------------------------------------
-- Timings: lock-in -25 s, Sudden Death -25 s to -10 s (live definitions with
-- only the offsets changed; passive-vote ramp, skips and unplayable floors too)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.process_battle_lifecycle(p_arena_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare
    v_battle record;
    v_now timestamptz := now();
    v_lockin_at timestamptz;
    v_sd_close_at timestamptz;
    v_end_at timestamptz;

    v_votes record;
    v_winner uuid;
begin

    select *
    into v_battle
    from battles
    where arena_id = p_arena_id
      and state in ('pending','active','closing')
    order by created_at
    limit 1
    for update;

    if not found then
        return;
    end if;

    -- pending -> active (step 18: anchored on its soundtrack when known)
    if v_battle.state = 'pending' then
        update battles
        set state = 'active',
            started_at = coalesce(started_at, v_now)
        where id = v_battle.id;
        return;
    end if;

    -- Lock-in 25 s before the end, Sudden Death (15 s) until 10 s before
    -- (user decision 2026-10-28, over v4 §5.3's -15 s / -5 s)
    v_lockin_at := v_battle.started_at + ((v_battle.duration_ms - 25000) * interval '1 millisecond');
    v_sd_close_at := v_battle.started_at + ((v_battle.duration_ms - 10000) * interval '1 millisecond');
    v_end_at := v_battle.started_at + (v_battle.duration_ms * interval '1 millisecond');

    -- ACTIVE -> CLOSING (LOCK-IN)
    if v_battle.state = 'active' and v_now >= v_lockin_at then

        -- Step 9: presence frozen at lock-in, then the passive votes from it
        perform snapshot_battle_presence(v_battle.id, v_battle.arena_id);
        perform cast_passive_votes(v_battle.id);

        select * into v_votes from calculate_lockin_vote_totals(v_battle.id);

        if v_votes.is_tie = false then
            v_winner := case when v_votes.votes_a > v_votes.votes_b then v_battle.song_a_id else v_battle.song_b_id end;

            -- Into the Spotify playlist right away (nudge trigger)
            insert into playlist_queue (arena_id, battle_id, winner_song_id, spotify_track_id, song_duration_ms, created_at)
            select v_battle.arena_id, v_battle.id, s.id, s.spotify_track_id, s.duration_ms, v_now
            from songs s where s.id = v_winner;

            update battles
            set state = 'closing',
                lockin_at = v_lockin_at,
                winner_song_id = v_winner,
                resolution_type = 'normal'
            where id = v_battle.id;
        else
            update battles
            set state = 'closing',
                lockin_at = v_lockin_at,
                sudden_death_active = true,
                sudden_death_started_at = v_lockin_at
            where id = v_battle.id;
        end if;

        return;
    end if;

    -- SUDDEN DEATH closes 10 s before the end: the result reaches the playlist
    -- (and Spotify's queue) before the song ends; the last 10 s take no votes
    if v_battle.state = 'closing' and v_battle.sudden_death_active and v_now >= v_sd_close_at then

        select
            coalesce(sum(weight) filter (where song_id = v_battle.song_a_id and vote_type = 'sudden_death' and status = 'active'), 0) as votes_a,
            coalesce(sum(weight) filter (where song_id = v_battle.song_b_id and vote_type = 'sudden_death' and status = 'active'), 0) as votes_b
        into v_votes
        from votes
        where battle_id = v_battle.id;

        if v_votes.votes_a <> v_votes.votes_b then
            v_winner := case when v_votes.votes_a > v_votes.votes_b then v_battle.song_a_id else v_battle.song_b_id end;

            insert into playlist_queue (arena_id, battle_id, winner_song_id, spotify_track_id, song_duration_ms, created_at)
            select v_battle.arena_id, v_battle.id, s.id, s.spotify_track_id, s.duration_ms, v_now
            from songs s where s.id = v_winner;

            update battles
            set winner_song_id = v_winner,
                resolution_type = 'sudden_death',
                sudden_death_active = false
            where id = v_battle.id;
        else
            -- Still tied -> DRAW: both play, A then B (one statement, so seq
            -- keeps the order and a single nudge sends both)
            insert into playlist_queue (arena_id, battle_id, winner_song_id, spotify_track_id, song_duration_ms, created_at)
            select v_battle.arena_id, v_battle.id, s.id, s.spotify_track_id, s.duration_ms, v_now
            from songs s
            where s.id in (v_battle.song_a_id, v_battle.song_b_id)
            order by s.id = v_battle.song_b_id;

            update battles
            set resolution_type = 'draw',
                sudden_death_active = false
            where id = v_battle.id;
        end if;

        return;
    end if;

    -- END OF BATTLE = its soundtrack ends, its winners start
    if v_battle.state = 'closing' and v_now >= v_end_at then

        select resolution_type into v_votes from battles where id = v_battle.id;
        if v_votes.resolution_type is null then
            return; -- no completar si no hay resolución válida
        end if;

        update battles
        set state = 'completed',
            ended_at = v_end_at,
            enqueue_done = true
        where id = v_battle.id;

        -- Next battle from the queue chain (step 12b); no pair = the arena
        -- waits and battle_lifecycle_job retries via create_next_battle
        perform create_next_battle(v_battle.arena_id);

        return;
    end if;

end;
$function$;

CREATE OR REPLACE FUNCTION public.battle_passive_tally(p_battle_id uuid)
 RETURNS TABLE(passive_a real, passive_b real)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b battles;
  c passive_vote_config;
  v_paused timestamptz;
  v_now timestamptz;
  v_lockin timestamptz;
  v_ramp real;
begin
  select * into b from battles where id = p_battle_id;
  if not found or b.sudden_death_started_at is not null then
    return query select 0::real, 0::real;
    return;
  end if;

  if b.lockin_at is not null then
    return query
    select coalesce(sum(v.weight) filter (where v.song_id = b.song_a_id), 0)::real,
           coalesce(sum(v.weight) filter (where v.song_id = b.song_b_id), 0)::real
    from votes v where v.battle_id = b.id and v.vote_type = 'passive' and v.status = 'active';
    return;
  end if;

  if b.state <> 'active' or b.started_at is null then
    return query select 0::real, 0::real;
    return;
  end if;

  select * into c from passive_vote_config where id = 1;
  select paused_at into v_paused from arenas where id = b.arena_id;
  v_now := least(now(), coalesce(v_paused, now()));
  v_lockin := b.started_at + ((b.duration_ms - 25000) * interval '1 millisecond');
  v_ramp := extract(epoch from v_now - (v_lockin - make_interval(secs => c.ramp_seconds))) / c.ramp_seconds;
  if v_ramp <= 0 then
    return query select 0::real, 0::real;
    return;
  end if;
  v_ramp := least(v_ramp, 1);

  return query
  select round((coalesce(sum(x.weight) filter (where x.song_id = b.song_a_id), 0) * v_ramp)::numeric, 2)::real,
         round((coalesce(sum(x.weight) filter (where x.song_id = b.song_b_id), 0) * v_ramp)::numeric, 2)::real
  from passive_vote_candidates(b.id, true) x;
end;
$function$;

CREATE OR REPLACE FUNCTION public.skip_to_lockin(p_arena_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_battle battles%rowtype;
  v_target timestamptz;
begin
  perform 1 from arenas where id = p_arena_id and state = 'active' and paused_at is null for update;
  if not found then
    return false;
  end if;

  select * into v_battle
  from battles
  where arena_id = p_arena_id and state in ('active', 'closing') and soundtrack = 'arena'
  order by created_at desc
  limit 1
  for update;
  if not found then
    return false;
  end if;

  if v_battle.state = 'active' then
    v_target := v_battle.started_at + (v_battle.duration_ms - 25000) * interval '1 millisecond';
  elsif v_battle.sudden_death_active then
    v_target := v_battle.started_at + (v_battle.duration_ms - 10000) * interval '1 millisecond';
  else
    return false;
  end if;
  if v_target <= now() then
    return false;
  end if;

  perform shift_open_battle(v_battle.id, now() - v_target, false);
  return true;
end;
$function$;

CREATE OR REPLACE FUNCTION public.skip_unplayable_track(p_arena_id uuid, p_track_uri text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_entry record;
  v_battle battles%rowtype;
  v_elapsed integer;
  v_floor integer;
begin
  perform 1 from arenas where id = p_arena_id and state = 'active' and paused_at is null for update;
  if not found or p_track_uri is null then
    return false;
  end if;

  -- The entry due now with that track, else the closest one still to come
  select * into v_entry
  from arena_sound_plan(p_arena_id) p
  where p.track_uri = p_track_uri and p.added
    and p.planned_start + p.duration_ms * interval '1 millisecond' > now()
  order by (p.planned_start <= now()) desc, p.planned_start
  limit 1;
  if not found then
    return false;
  end if;

  if v_entry.battle_id is null then
    update arenas set warmup_unplayable_at = now(), updated_at = now() where id = p_arena_id;
  else
    update playlist_queue set unplayable_at = now()
    where battle_id = v_entry.battle_id and winner_song_id = v_entry.song_id and unplayable_at is null;
  end if;

  -- The battle that plays over it: battle 1 for the warm-up, else the one
  -- created after the entry's own battle
  select b.* into v_battle
  from battles b
  where b.arena_id = p_arena_id and b.soundtrack = 'arena' and b.state in ('pending', 'active', 'closing')
    and case when v_entry.battle_id is null
             then not exists (select 1 from battles x where x.arena_id = p_arena_id and x.created_at < b.created_at)
             else b.created_at > (select x.created_at from battles x where x.id = v_entry.battle_id)
                  and not exists (select 1 from battles x where x.arena_id = p_arena_id
                                    and x.created_at > (select y.created_at from battles y where y.id = v_entry.battle_id)
                                    and x.created_at < b.created_at)
        end
  for update;
  if not found then
    return true;
  end if;

  v_floor := 0;
  if v_battle.started_at is not null then
    v_elapsed := greatest(0, floor(extract(epoch from now() - v_battle.started_at) * 1000))::integer;
    v_floor := v_elapsed + case
      when v_battle.state in ('pending', 'active') then 25000
      when v_battle.sudden_death_active then 10000
      else 0 end;
  end if;

  update battles
  set duration_ms = greatest(duration_ms - v_entry.duration_ms, v_floor),
      updated_at = now()
  where id = v_battle.id;
  return true;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Clock sync from 1 s of drift (only the threshold changed)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.sync_arena_clock(p_arena_id uuid, p_track_uri text, p_track_started_at timestamp with time zone)
 RETURNS interval
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_entry record;
  v_battle battles%rowtype;
  v_shift interval;
begin
  perform 1 from arenas where id = p_arena_id and state = 'active' and paused_at is null for update;
  if not found or p_track_uri is null or p_track_started_at is null then
    return interval '0';
  end if;

  select * into v_battle
  from battles
  where arena_id = p_arena_id and state in ('active', 'closing') and soundtrack = 'arena'
  order by created_at desc
  limit 1
  for update;
  if not found then
    return interval '0';
  end if;

  select * into v_entry
  from arena_sound_plan(p_arena_id) p
  where p.track_uri = p_track_uri and p.added
    and p.planned_start >= v_battle.started_at - interval '1 second'
  order by abs(extract(epoch from p.planned_start - p_track_started_at))
  limit 1;
  if not found then
    return interval '0';
  end if;

  v_shift := p_track_started_at - v_entry.planned_start;
  if abs(extract(epoch from v_shift)) < 1 then
    return interval '0';
  end if;

  perform shift_open_battle(v_battle.id, v_shift, v_entry.battle_id is null);
  return v_shift;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Radio lead-ins in the plan and in the next battle's length
-- ---------------------------------------------------------------------------

create or replace function public.arena_sound_plan(p_arena_id uuid)
returns table(idx integer, song_id uuid, track_uri text, duration_ms integer, planned_start timestamptz,
              battle_id uuid, after_gap boolean, added boolean)
language sql
stable
security definer
set search_path to 'public'
as $$
  with bt as (
    select b.id, b.started_at, b.duration_ms, b.soundtrack,
           lead(b.started_at) over w as next_started,
           lead(b.soundtrack) over w as next_soundtrack,
           row_number() over w as rn
    from battles b
    where b.arena_id = p_arena_id
    window w as (order by b.created_at)
  ),
  raw as (
    -- The warm-up: battle 1 plays during it (anchored), else its own start
    select 0::bigint as ord, w.id as song_id, w.spotify_track_id,
           case when a.warmup_unplayable_at is null then w.duration_ms else 0 end as duration_ms,
           case when fb.soundtrack = 'arena' and fb.started_at is not null then fb.started_at
                else a.warmup_started_at end as base,
           0::bigint as offset_ms, null::uuid as battle_id, a.warmup_unplayable_at is null as added
    from arenas a
    join songs w on w.id = a.warmup_song_id
    left join bt fb on fb.rn = 1
    where a.id = p_arena_id and a.warmup_started_at is not null
    union all
    -- Each battle's winners (A then B on a draw): from the battle anchored on
    -- them, else from the end of their own battle; each one after the radio
    -- track Spotify played before it, if any (lead_in_ms)
    select pq.seq, pq.winner_song_id, pq.spotify_track_id,
           case when pq.unplayable_at is null then pq.song_duration_ms else 0 end,
           case when bt.next_soundtrack = 'arena' and bt.next_started is not null then bt.next_started
                else bt.started_at + bt.duration_ms * interval '1 millisecond' end,
           coalesce(sum(case when pq.unplayable_at is null then pq.song_duration_ms else 0 end + pq.lead_in_ms) over (
             partition by pq.battle_id order by pq.seq
             rows between unbounded preceding and 1 preceding), 0) + pq.lead_in_ms,
           pq.battle_id, pq.added_to_playlist_at is not null and pq.unplayable_at is null
    from playlist_queue pq
    join bt on bt.id = pq.battle_id
    where pq.arena_id = p_arena_id
  ),
  timed as (
    select (row_number() over (order by ord))::integer - 1 as idx, song_id,
           'spotify:track:' || spotify_track_id as track_uri, duration_ms,
           base + offset_ms * interval '1 millisecond' as planned_start, battle_id, added
    from raw
  )
  select t.idx, t.song_id, t.track_uri, t.duration_ms, t.planned_start, t.battle_id,
         coalesce(t.planned_start - ((lag(t.planned_start) over o) + (lag(t.duration_ms) over o) * interval '1 millisecond')
                  > interval '2 seconds', false),
         t.added
  from timed t
  window o as (order by t.idx)
  order by t.idx;
$$;

create or replace function public.create_next_battle(p_arena_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_pair record;
  v_last battles%rowtype;
  v_duration integer;
  v_start timestamptz;
  v_soundtrack text := 'arena';
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

  -- Its soundtrack: the last battle's winners, which start when that battle
  -- ends (battle 1: the warm-up, the "winner of battle 0"), and the radio
  -- tracks Spotify played before them
  select * into v_last from battles where arena_id = p_arena_id order by created_at desc limit 1;
  if v_last.id is not null then
    select nullif(sum(case when unplayable_at is null then song_duration_ms else 0 end + lead_in_ms), 0) into v_duration
    from playlist_queue where battle_id = v_last.id;
    v_start := v_last.started_at + v_last.duration_ms * interval '1 millisecond';
  else
    select case when a.warmup_unplayable_at is null then w.duration_ms end, a.warmup_started_at into v_duration, v_start
    from arenas a join songs w on w.id = a.warmup_song_id where a.id = p_arena_id;
  end if;

  -- On time: it lasts its soundtrack. Late (the arena waited for songs): what
  -- is left of it if >= 60 s, else 60 s over Autoplay/silence
  if v_duration is null or v_start is null
     or (now() - v_start > interval '5 seconds'
         and v_start + v_duration * interval '1 millisecond' - now() < interval '60 seconds') then
    v_soundtrack := 'autoplay';
    v_start := null;
    v_duration := 60000;
  end if;

  insert into battles (arena_id, song_a_id, song_b_id, state, duration_ms, sudden_death_active, started_at, soundtrack)
  values (p_arena_id, v_pair.song_a, v_pair.song_b, 'pending', v_duration, false, v_start, v_soundtrack)
  returning id into v_id;

  return v_id;
end;
$$;

-- spotify-host: Spotify is playing a radio track (not an arena song, not in
-- the playlist) that began at p_track_started_at and ends at p_track_ends_at.
-- If it began before (or at) the start of an arena song due now or within
-- 10 s, that song waits for it: lead_in_ms = the radio time before it, and the
-- battle playing over it gets that much longer, and spotify-host is woken
-- when the radio track ends to play the song. Once per song (a second radio
-- track after it is cut). Capped at 10 min. Returns the arena song, or null.
create or replace function public.autoplay_lead_in(p_arena_id uuid, p_track_started_at timestamptz, p_track_ends_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_entry record;
  v_battle battles%rowtype;
  v_lead integer;
begin
  perform 1 from arenas where id = p_arena_id and state = 'active' and paused_at is null for update;
  if not found or p_track_started_at is null or p_track_ends_at is null then
    return null;
  end if;

  select * into v_entry
  from arena_sound_plan(p_arena_id) p
  where p.added and p.battle_id is not null
    and p.planned_start >= p_track_started_at - interval '5 seconds'
    and p.planned_start <= now() + interval '10 seconds'
  order by p.planned_start
  limit 1;
  if not found then
    return null;
  end if;
  if exists (select 1 from playlist_queue
             where battle_id = v_entry.battle_id and winner_song_id = v_entry.song_id and lead_in_ms > 0) then
    return null;
  end if;

  v_lead := least(floor(extract(epoch from p_track_ends_at - v_entry.planned_start) * 1000), 600000)::integer;
  if v_lead <= 0 then
    return null;
  end if;

  update playlist_queue set lead_in_ms = v_lead
  where battle_id = v_entry.battle_id and winner_song_id = v_entry.song_id;
  update arena_playback set wake_at = v_entry.planned_start + (v_lead + 500) * interval '1 millisecond'
  where arena_id = p_arena_id;

  -- The battle that plays over it: the one created after the entry's battle
  select b.* into v_battle
  from battles b
  where b.arena_id = p_arena_id and b.soundtrack = 'arena' and b.state in ('pending', 'active', 'closing')
    and b.created_at > (select x.created_at from battles x where x.id = v_entry.battle_id)
    and not exists (select 1 from battles x where x.arena_id = p_arena_id
                      and x.created_at > (select y.created_at from battles y where y.id = v_entry.battle_id)
                      and x.created_at < b.created_at)
  for update;
  if found then
    update battles set duration_ms = duration_ms + v_lead, updated_at = now() where id = v_battle.id;
  end if;

  return jsonb_build_object('track_uri', v_entry.track_uri, 'lead_in_ms', v_lead);
end;
$$;

revoke all on function public.autoplay_lead_in(uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.autoplay_lead_in(uuid, timestamptz, timestamptz) to service_role;

-- Every second (battle_lifecycle_job): arenas whose radio track just ended
create or replace function public.wake_spotify_host()
returns void
language sql
security definer
set search_path to 'public'
as $$
  with due as (
    update arena_playback set wake_at = null
    where wake_at is not null and wake_at <= now()
    returning arena_id
  )
  select nudge_spotify_host(due.arena_id) from due;
$$;

revoke all on function public.wake_spotify_host() from public, anon, authenticated;
grant execute on function public.wake_spotify_host() to service_role;

select cron.schedule('battle_lifecycle_job', '1 second', $job$
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
  SELECT wake_spotify_host();
  $job$);
