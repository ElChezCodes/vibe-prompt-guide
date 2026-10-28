-- Step 18 (2026-10-28): real playback end to end. Winners go into the arena's
-- Spotify playlist and play on the host's device; each battle runs while the
-- previous winner plays and its clock follows the real music.
--
-- User decisions 2026-10-28:
-- * A winner is added the moment it is decided: normal win at lock-in
--   (end - 15 s); Sudden Death starts at lock-in and lasts 10 s, resolved at
--   end - 5 s (v4 §5.3), so the winner (or A then B on a draw) reaches the
--   playlist before the song ends. Last 5 s: no votes. playlist_queue inserts
--   nudge spotify-host at once (pg_net); the 15 s watcher retries.
-- * No pair after the last winner: Spotify's own Autoplay may fill the gap
--   (music is not expected there, nothing pauses). A battle that starts late
--   (its soundtrack already playing or over) lasts what is left of the song
--   playing if >= 60 s (a winner, or an Autoplay track via fit_battle_to_track),
--   else 60 s; when it ends Music Fighter plays the winner (out of Autoplay).
-- * Manual changes inside the playlist (skip, back, reorder, songs added by
--   hand, skipping past the end): MF puts the expected track back at the right
--   point and asks the host whether they want to control the music. If they
--   confirm (control_mode = 'manual', for the rest of the arena, revertible),
--   MF follows skips forward (battle not restarted, lock-in/SD recalculated,
--   v4 §8.3/§10.3; skipping the last song before a winner = immediate lock-in)
--   and anything else counts as off_playlist (step-6 pause). Pausing Spotify
--   or playing another playlist keeps the step-6 pause rules.
-- * The arena finishing leaves Spotify playing to the end of the playlist.
--
-- Model: the arena's sound plan (arena_sound_plan) = the warm-up, then every
-- playlist_queue row in order (seq). Battle N's soundtrack is battle N-1's
-- winners (battle 1: the warm-up) and the soundtrack is anchored on the open
-- battle's started_at, so moving the open battle moves the plan with it.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------

alter table public.playlist_queue add column if not exists seq bigint generated always as identity;
alter table public.playlist_queue add column if not exists added_to_playlist_at timestamptz;
-- Rows from before this step never went to Spotify and never will
update public.playlist_queue set added_to_playlist_at = created_at where added_to_playlist_at is null;

-- It feeds the host's Spotify playlist now: server-only (it had RLS off and
-- full client grants; nothing in the frontend reads it)
alter table public.playlist_queue enable row level security;
revoke all on public.playlist_queue from anon, authenticated;

-- 'arena' = plays during the previous winners (anchored on them);
-- 'autoplay' = started late, over Spotify's Autoplay or silence
alter table public.battles add column if not exists soundtrack text not null default 'arena';
alter table public.battles drop constraint if exists battles_soundtrack_check;
alter table public.battles add constraint battles_soundtrack_check check (soundtrack in ('arena', 'autoplay'));
alter table public.battles add column if not exists soundtrack_fitted_at timestamptz;

alter table public.arena_playback add column if not exists control_mode text not null default 'auto';
alter table public.arena_playback drop constraint if exists arena_playback_control_mode_check;
alter table public.arena_playback add constraint arena_playback_control_mode_check check (control_mode in ('auto', 'manual'));
-- Last time MF put the expected track back (the host is asked about it)
alter table public.arena_playback add column if not exists manual_change_at timestamptz;
-- What the player was doing at the last check: our playlist, something else, nothing
alter table public.arena_playback add column if not exists player_context text;

-- ---------------------------------------------------------------------------
-- Sound plan
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
    select 0::bigint as ord, w.id as song_id, w.spotify_track_id, w.duration_ms,
           case when fb.soundtrack = 'arena' and fb.started_at is not null then fb.started_at
                else a.warmup_started_at end as base,
           0::bigint as offset_ms, null::uuid as battle_id, true as added
    from arenas a
    join songs w on w.id = a.warmup_song_id
    left join bt fb on fb.rn = 1
    where a.id = p_arena_id and a.warmup_started_at is not null
    union all
    -- Each battle's winners (A then B on a draw): from the battle anchored on
    -- them, else from the end of their own battle
    select pq.seq, pq.winner_song_id, pq.spotify_track_id, pq.song_duration_ms,
           case when bt.next_soundtrack = 'arena' and bt.next_started is not null then bt.next_started
                else bt.started_at + bt.duration_ms * interval '1 millisecond' end,
           coalesce(sum(pq.song_duration_ms) over (
             partition by pq.battle_id order by pq.seq
             rows between unbounded preceding and 1 preceding), 0),
           pq.battle_id, pq.added_to_playlist_at is not null
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

-- What spotify-host needs for one check: the track expected at p_at and its
-- position, its neighbours, what comes after it, the open battle, the mode
create or replace function public.arena_playback_plan(p_arena_id uuid, p_at timestamptz default now())
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with p as (select * from arena_sound_plan(p_arena_id)),
  e as (
    select * from p
    where p.added and p.planned_start <= p_at
      and p_at < p.planned_start + p.duration_ms * interval '1 millisecond'
    order by p.idx desc
    limit 1
  )
  select jsonb_build_object(
    'expected', (select to_jsonb(e) || jsonb_build_object(
                   'position_ms', floor(extract(epoch from p_at - e.planned_start) * 1000)::bigint,
                   'is_last', not exists (select 1 from p x where x.idx > e.idx and x.added))
                 from e),
    'prev_uri', (select x.track_uri from p x join e on x.idx = e.idx - 1),
    'next_uri', (select x.track_uri from p x join e on x.idx = e.idx + 1 where x.added),
    'later_uris', coalesce((select jsonb_agg(x.track_uri order by x.idx) from p x join e on x.idx > e.idx where x.added), '[]'::jsonb),
    'arena_uris', coalesce((select jsonb_agg(distinct x.track_uri) from p x where x.added), '[]'::jsonb),
    'music_until', (select max(x.planned_start + x.duration_ms * interval '1 millisecond') from p x where x.added),
    'open_battle', (select jsonb_build_object('id', b.id, 'state', b.state, 'soundtrack', b.soundtrack,
                                              'started_at', b.started_at, 'duration_ms', b.duration_ms,
                                              'fitted', b.soundtrack_fitted_at is not null)
                    from battles b
                    where b.arena_id = p_arena_id and b.state in ('pending', 'active', 'closing')
                    order by b.created_at desc limit 1),
    'control_mode', (select pb.control_mode from arena_playback pb where pb.arena_id = p_arena_id)
  );
$$;

-- ---------------------------------------------------------------------------
-- The battle clock follows the music
-- ---------------------------------------------------------------------------

-- Shared by sync/skip: move the open battle (and the warm-up when it is its
-- soundtrack) by p_shift
create or replace function public.shift_open_battle(p_battle_id uuid, p_shift interval, p_warmup boolean)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_arena uuid;
begin
  update battles
  set started_at = started_at + p_shift,
      lockin_at = lockin_at + p_shift,
      sudden_death_started_at = sudden_death_started_at + p_shift,
      updated_at = now()
  where id = p_battle_id
  returning arena_id into v_arena;

  if p_warmup then
    update arenas set warmup_started_at = warmup_started_at + p_shift, updated_at = now() where id = v_arena;
  end if;
end;
$$;

-- Generalised from step 6 (battle 1 on the warm-up): p_track_uri really
-- started at p_track_started_at on the host's player. The plan entry it is
-- (the one planned closest to that time: a song may come back after 60 min)
-- re-anchors the open battle, if it is the open battle's soundtrack or one of
-- its own winners (a skip forward ends the battle early, v4 §8.3). Drifts
-- under 3 s are ignored.
drop function if exists public.sync_arena_clock(uuid, timestamptz);
create or replace function public.sync_arena_clock(p_arena_id uuid, p_track_uri text, p_track_started_at timestamptz)
returns interval
language plpgsql
security definer
set search_path to 'public'
as $$
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
  if abs(extract(epoch from v_shift)) < 3 then
    return interval '0';
  end if;

  perform shift_open_battle(v_battle.id, v_shift, v_entry.battle_id is null);
  return v_shift;
end;
$$;

-- Manual control, the host skipped past the last song before a winner exists:
-- lock-in now (Sudden Death in progress: resolve now). Idempotent.
create or replace function public.skip_to_lockin(p_arena_id uuid)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
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
    v_target := v_battle.started_at + (v_battle.duration_ms - 15000) * interval '1 millisecond';
  elsif v_battle.sudden_death_active then
    v_target := v_battle.started_at + (v_battle.duration_ms - 5000) * interval '1 millisecond';
  else
    return false;
  end if;
  if v_target <= now() then
    return false;
  end if;

  perform shift_open_battle(v_battle.id, now() - v_target, false);
  return true;
end;
$$;

-- A late battle over Spotify's Autoplay: if the track playing when it began
-- still has >= 60 s from the battle's start, the battle lasts until it ends
-- (user decision 2026-10-28: let songs finish). One adjustment per battle,
-- only in its first 20 s; p_track_ends_at NULL = nothing to fit (silence).
create or replace function public.fit_battle_to_track(p_arena_id uuid, p_track_ends_at timestamptz)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_battle battles%rowtype;
begin
  select * into v_battle
  from battles
  where arena_id = p_arena_id and state = 'active' and soundtrack = 'autoplay' and soundtrack_fitted_at is null
  order by created_at desc
  limit 1
  for update;
  if not found or v_battle.started_at < now() - interval '20 seconds' then
    return false;
  end if;

  update battles
  set soundtrack_fitted_at = now(),
      duration_ms = case when p_track_ends_at - v_battle.started_at >= interval '60 seconds'
                         then floor(extract(epoch from p_track_ends_at - v_battle.started_at) * 1000)::integer
                         else duration_ms end,
      updated_at = now()
  where id = v_battle.id;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- Next battle: anchored on the winners it plays during
-- ---------------------------------------------------------------------------

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
  -- ends (battle 1: the warm-up, the "winner of battle 0")
  select * into v_last from battles where arena_id = p_arena_id order by created_at desc limit 1;
  if v_last.id is not null then
    select sum(song_duration_ms) into v_duration from playlist_queue where battle_id = v_last.id;
    v_start := v_last.started_at + v_last.duration_ms * interval '1 millisecond';
  else
    select w.duration_ms, a.warmup_started_at into v_duration, v_start
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

-- ---------------------------------------------------------------------------
-- Battle lifecycle: Sudden Death 10 s, resolved 5 s before the real end
-- ---------------------------------------------------------------------------

create or replace function public.process_battle_lifecycle(p_arena_id uuid)
returns void
language plpgsql
as $$
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

    -- Lock-in 15 s before the end, Sudden Death until 5 s before (v4 §5.3)
    v_lockin_at := v_battle.started_at + ((v_battle.duration_ms - 15000) * interval '1 millisecond');
    v_sd_close_at := v_battle.started_at + ((v_battle.duration_ms - 5000) * interval '1 millisecond');
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

    -- SUDDEN DEATH closes 5 s before the end: the result reaches the playlist
    -- before the song ends; the last 5 s take no votes
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
$$;

-- A paused arena also freezes a pending battle's anchor
create or replace function public.resume_arena(p_arena_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_paused interval;
begin
  select now() - paused_at into v_paused
  from arenas
  where id = p_arena_id and paused_at is not null
  for update;

  if v_paused is null then
    return;
  end if;

  update battles
  set started_at = started_at + v_paused,
      lockin_at = lockin_at + v_paused,
      sudden_death_started_at = sudden_death_started_at + v_paused
  where arena_id = p_arena_id and state in ('pending', 'active', 'closing') and started_at is not null;

  update arena_playback
  set expected_until = expected_until + v_paused,
      strikes = 0,
      strike_reason = null,
      updated_at = now()
  where arena_id = p_arena_id;

  update arenas
  set paused_at = null,
      pause_reason = null,
      warmup_started_at = warmup_started_at + v_paused,
      updated_at = now()
  where id = p_arena_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Appending to Spotify (spotify-host claims, appends, releases on failure)
-- ---------------------------------------------------------------------------

create or replace function public.claim_playlist_appends(p_arena_id uuid)
returns table(id uuid, seq bigint, spotify_track_id text)
language sql
security definer
set search_path to 'public'
as $$
  update playlist_queue pq
  set added_to_playlist_at = now()
  where pq.arena_id = p_arena_id
    and pq.added_to_playlist_at is null
    and exists (select 1 from arena_playback pb where pb.arena_id = p_arena_id and pb.playlist_id is not null)
  returning pq.id, pq.seq, pq.spotify_track_id;
$$;

create or replace function public.release_playlist_appends(p_ids uuid[])
returns void
language sql
security definer
set search_path to 'public'
as $$
  update playlist_queue set added_to_playlist_at = null where id = any (p_ids);
$$;

-- The playlist was recreated with every entry (reconnect after a disconnect)
create or replace function public.mark_playlist_appended(p_arena_id uuid)
returns void
language sql
security definer
set search_path to 'public'
as $$
  update playlist_queue set added_to_playlist_at = now()
  where arena_id = p_arena_id and added_to_playlist_at is null;
$$;

-- One check at a time per arena: watcher every 12 s, nudges every 1.5 s
create or replace function public.begin_playback_check(p_arena_id uuid, p_min_ms integer)
returns boolean
language sql
security definer
set search_path to 'public'
as $$
  with claimed as (
    update arena_playback
    set checked_at = now()
    where arena_id = p_arena_id
      and (checked_at is null or checked_at < now() - p_min_ms * interval '1 millisecond')
    returning 1
  )
  select exists (select 1 from claimed);
$$;

-- ---------------------------------------------------------------------------
-- Nudges: spotify-host acts right away (same secret as the watcher)
-- ---------------------------------------------------------------------------

create or replace function public.nudge_spotify_host(p_arena_id uuid)
returns void
language sql
security definer
set search_path to 'public'
as $$
  select net.http_post(
    url := 'https://uuxzjroikbzwaszpgiks.supabase.co/functions/v1/spotify-host',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-watch-secret', coalesce((select decrypted_secret from vault.decrypted_secrets where name = 'spotify_watch_secret'), '')
    ),
    body := jsonb_build_object('action', 'nudge', 'arena_id', p_arena_id),
    timeout_milliseconds := 10000
  )
  where exists (select 1 from arena_playback pb where pb.arena_id = p_arena_id and pb.playlist_id is not null);
$$;

create or replace function public.nudge_on_playlist_insert()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform nudge_spotify_host(x.arena_id) from (select distinct arena_id from new_rows) x;
  return null;
end;
$$;

drop trigger if exists trg_playlist_queue_nudge on public.playlist_queue;
create trigger trg_playlist_queue_nudge
  after insert on public.playlist_queue
  referencing new table as new_rows
  for each statement execute function public.nudge_on_playlist_insert();

-- A battle ending = its winners start (kick out of Autoplay, re-sync); a late
-- battle starting = fit it to the Autoplay track
create or replace function public.nudge_on_battle_change()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  perform nudge_spotify_host(new.arena_id);
  return null;
end;
$$;

drop trigger if exists trg_battles_nudge_completed on public.battles;
create trigger trg_battles_nudge_completed
  after update of state on public.battles
  for each row
  when (new.state = 'completed' and old.state is distinct from 'completed' and new.resolution_type is distinct from 'cancelled')
  execute function public.nudge_on_battle_change();

drop trigger if exists trg_battles_nudge_autoplay on public.battles;
create trigger trg_battles_nudge_autoplay
  after update of state on public.battles
  for each row
  when (new.state = 'active' and old.state = 'pending' and new.soundtrack = 'autoplay')
  execute function public.nudge_on_battle_change();

-- ---------------------------------------------------------------------------
-- Host: control mode; members: what is playing
-- ---------------------------------------------------------------------------

-- 'manual' = the host controls Spotify and MF follows skips; 'auto' = MF puts
-- the expected track back. Either answer clears the "you changed the music" prompt.
create or replace function public.set_arena_control_mode(p_arena_id uuid, p_mode text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if p_mode not in ('auto', 'manual') then
    raise exception 'invalid mode' using errcode = '22023';
  end if;
  if not exists (select 1 from arenas where id = p_arena_id and host_id = auth.uid()) then
    raise exception 'only the host can change this' using errcode = '42501';
  end if;
  update arena_playback
  set control_mode = p_mode, manual_change_at = null, strikes = 0, strike_reason = null, updated_at = now()
  where arena_id = p_arena_id;
  return p_mode;
end;
$$;

drop function if exists public.get_arena_playback(uuid);
create or replace function public.get_arena_playback(p_arena_id uuid)
returns table(paused_at timestamptz, pause_reason text, is_playing boolean, expected_until timestamptz,
              checked_at timestamptz, device_name text, playlist_url text,
              player_context text, now_playing_kind text, now_playing_title text, now_playing_artist text,
              now_playing_artwork_url text, now_playing_spotify_track_id text,
              next_title text, next_artist text, control_mode text, manual_change_at timestamptz)
language sql
stable
security definer
set search_path to 'public'
as $$
  with a as (
    select a.* from arenas a
    where a.id = p_arena_id
      and (a.host_id = auth.uid()
        or exists (select 1 from participants p where p.arena_id = a.id and p.identity_anchor_id = auth.uid()))
  ),
  plan as (select * from arena_sound_plan(p_arena_id) where added),
  pb as (select * from arena_playback where arena_id = p_arena_id),
  -- What Spotify is playing (on the playlist), else what should be playing
  cur as (
    select pl.* from plan pl, pb
    where pb.player_context = 'playlist' and pl.track_uri = pb.current_track_uri
    order by abs(extract(epoch from pl.planned_start - now()))
    limit 1
  ),
  exp as (
    select pl.* from plan pl
    where pl.planned_start <= now() and now() < pl.planned_start + pl.duration_ms * interval '1 millisecond'
    order by pl.idx desc limit 1
  ),
  np as (
    select * from cur
    union all
    select * from exp where not exists (select 1 from cur) and coalesce((select player_context from pb), 'playlist') = 'playlist'
    limit 1
  )
  select a.paused_at, a.pause_reason, coalesce(pb.is_playing, false),
         (select max(planned_start + duration_ms * interval '1 millisecond') from plan),
         pb.checked_at,
         case when a.host_id = auth.uid() then pb.device_name end,
         case when a.host_id = auth.uid() and pb.playlist_id is not null
              then 'https://open.spotify.com/playlist/' || pb.playlist_id end,
         pb.player_context,
         case when np.idx is null then null when np.battle_id is null then 'warmup' else 'winner' end,
         s.title, s.artist, s.artwork_url, s.spotify_track_id,
         ns.title, ns.artist,
         pb.control_mode,
         case when a.host_id = auth.uid() then pb.manual_change_at end
  from a
  left join pb on true
  left join np on true
  left join songs s on s.id = np.song_id
  left join plan nx on nx.idx = np.idx + 1
  left join songs ns on ns.id = nx.song_id;
$$;

-- ---------------------------------------------------------------------------
-- Grants: service-only except the two client RPCs
-- ---------------------------------------------------------------------------

revoke all on function public.arena_sound_plan(uuid) from public, anon, authenticated;
revoke all on function public.arena_playback_plan(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.shift_open_battle(uuid, interval, boolean) from public, anon, authenticated;
revoke all on function public.sync_arena_clock(uuid, text, timestamptz) from public, anon, authenticated;
revoke all on function public.skip_to_lockin(uuid) from public, anon, authenticated;
revoke all on function public.fit_battle_to_track(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.claim_playlist_appends(uuid) from public, anon, authenticated;
revoke all on function public.release_playlist_appends(uuid[]) from public, anon, authenticated;
revoke all on function public.mark_playlist_appended(uuid) from public, anon, authenticated;
revoke all on function public.begin_playback_check(uuid, integer) from public, anon, authenticated;
revoke all on function public.nudge_spotify_host(uuid) from public, anon, authenticated;
revoke all on function public.nudge_on_playlist_insert() from public, anon, authenticated;
revoke all on function public.nudge_on_battle_change() from public, anon, authenticated;
revoke all on function public.create_next_battle(uuid) from public, anon, authenticated;
revoke all on function public.resume_arena(uuid) from public, anon, authenticated;
grant execute on function public.arena_sound_plan(uuid) to service_role;
grant execute on function public.arena_playback_plan(uuid, timestamptz) to service_role;
grant execute on function public.sync_arena_clock(uuid, text, timestamptz) to service_role;
grant execute on function public.skip_to_lockin(uuid) to service_role;
grant execute on function public.fit_battle_to_track(uuid, timestamptz) to service_role;
grant execute on function public.claim_playlist_appends(uuid) to service_role;
grant execute on function public.release_playlist_appends(uuid[]) to service_role;
grant execute on function public.mark_playlist_appended(uuid) to service_role;
grant execute on function public.begin_playback_check(uuid, integer) to service_role;
grant execute on function public.create_next_battle(uuid) to service_role;
grant execute on function public.resume_arena(uuid) to service_role;

revoke all on function public.set_arena_control_mode(uuid, text) from public, anon;
grant execute on function public.set_arena_control_mode(uuid, text) to authenticated;
revoke all on function public.get_arena_playback(uuid) from public, anon;
grant execute on function public.get_arena_playback(uuid) to authenticated;
