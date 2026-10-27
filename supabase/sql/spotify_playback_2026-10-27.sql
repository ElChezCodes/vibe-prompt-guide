-- Step 6: Playback Provider + the arena's Spotify playlist (2026-10-27)
--
-- User decisions 2026-10-27 (step-6 chat):
-- * Start creates a private playlist "Music Fighter · <arena> · dd/mm/aa" in
--   the host's Spotify account; the warm-up is its first track and starts on
--   the host's chosen device. Start requires a connected Premium host with an
--   available device (checked by the spotify-host Edge Function, which is the
--   only caller able to create the arena_playback row start_arena_battles
--   now requires).
-- * The warm-up is picked from Spotify search (free search, no mood
--   suggestions: Spotify has no recommendations for new apps). Proposals are
--   Spotify tracks too, searched with the arena host's token.
-- * The arena pauses when no usable device is left for ~30 s (2 checks; if
--   the host moved playback to another device of theirs it is adopted), when
--   the host pauses Spotify or plays something outside the arena playlist
--   while Music Fighter expects it to be playing, and when the host
--   disconnects Spotify. Pause = frozen battle clock (the lifecycle cron
--   skips the arena, votes are blocked, proposals still allowed); it resumes
--   by itself when the cause is gone, and the paused time is added to the
--   open battle's timings.
-- * Disconnecting clears the per-arena Spotify data (playlist and device
--   ids); the playlist itself stays in the host's account.
-- * Battle 1's fallback to curated-library songs stays until steps 12/18.
--
-- Tokens never reach SQL: everything Spotify happens in the Edge Function
-- (service_role). Functions marked "service only" are not granted to clients.

-- ---------------------------------------------------------------------------
-- Songs: Spotify tracks
-- ---------------------------------------------------------------------------

alter table public.songs add column if not exists artwork_url text;

-- One row per track per arena *and role*: the warm-up's own row and a
-- proposal of the same track coexist (step-2 rule: only the warmup row is
-- excluded from competing). Proposals reuse the competitor row.
drop index if exists public.songs_arena_spotify_track_unique;
drop index if exists public.songs_unique_per_arena;
create unique index songs_unique_per_arena
  on public.songs (arena_id, source, spotify_track_id, role);

-- ---------------------------------------------------------------------------
-- Arena pause
-- ---------------------------------------------------------------------------

alter table public.arenas
  add column if not exists paused_at timestamptz,
  add column if not exists pause_reason text;

alter table public.arenas drop constraint if exists arenas_pause_reason_check;
alter table public.arenas add constraint arenas_pause_reason_check check (
  (paused_at is null and pause_reason is null)
  or (paused_at is not null and pause_reason in
      ('device_lost', 'playback_paused', 'off_playlist', 'spotify_disconnected'))
);

-- ---------------------------------------------------------------------------
-- Per-arena playback state (written only by spotify-host)
-- ---------------------------------------------------------------------------

create table if not exists public.arena_playback (
  arena_id uuid primary key references public.arenas(id) on delete cascade,
  host_id uuid not null references auth.users(id) on delete cascade,
  provider text not null default 'spotify' check (provider = 'spotify'),
  -- Host's Spotify data: cleared on disconnect (Developer Policy I.1.2)
  playlist_id text,
  playlist_uri text,
  -- "Music Fighter · <arena> · dd/mm/aa", to recreate it after a reconnect
  session_name text,
  device_id text,
  device_name text,
  -- Last observed state (the watcher, ~15 s)
  is_playing boolean not null default false,
  current_track_uri text,
  progress_ms integer,
  -- Where to resume after a pause (last good position in the playlist)
  resume_track_uri text,
  resume_position_ms integer,
  -- Music Fighter expects the playlist to be playing until then (step 6: the
  -- warm-up; step 18 extends it to the winners)
  expected_until timestamptz,
  -- Consecutive checks seeing the same problem (pause at 2)
  strikes integer not null default 0,
  strike_reason text,
  checked_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.arena_playback enable row level security;
revoke all on public.arena_playback from anon, authenticated;

-- What clients may see: pause state for members, device/playlist for the host
create or replace function public.get_arena_playback(p_arena_id uuid)
returns table (
  paused_at timestamptz,
  pause_reason text,
  is_playing boolean,
  expected_until timestamptz,
  checked_at timestamptz,
  device_name text,
  playlist_url text
)
language sql
stable
security definer
set search_path = public
as $$
  select a.paused_at, a.pause_reason, coalesce(pb.is_playing, false), pb.expected_until, pb.checked_at,
         case when a.host_id = auth.uid() then pb.device_name end,
         case when a.host_id = auth.uid() and pb.playlist_id is not null
              then 'https://open.spotify.com/playlist/' || pb.playlist_id end
  from arenas a
  left join arena_playback pb on pb.arena_id = a.id
  where a.id = p_arena_id
    and (a.host_id = auth.uid()
      or exists (
        select 1 from participants p
        where p.arena_id = a.id and p.identity_anchor_id = auth.uid()));
$$;

revoke all on function public.get_arena_playback(uuid) from public;
grant execute on function public.get_arena_playback(uuid) to authenticated;

-- Service only: pause an active arena (idempotent; keeps the first reason)
create or replace function public.pause_arena(p_arena_id uuid, p_reason text)
returns void
language sql
security definer
set search_path = public
as $$
  update arenas
  set paused_at = now(), pause_reason = p_reason, updated_at = now()
  where id = p_arena_id and state = 'active' and paused_at is null;
$$;

-- Service only: resume, adding the paused time to the open battle, the
-- warm-up clock and the playback expectation, so nobody loses battle time
create or replace function public.resume_arena(p_arena_id uuid)
returns void
language plpgsql
security definer
set search_path = public
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
  where arena_id = p_arena_id and state in ('active', 'closing');

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

-- Service only: host disconnected Spotify (or revoked access). Clears every
-- per-arena Spotify datum of theirs and pauses their running arenas.
create or replace function public.forget_host_spotify(p_host_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update arena_playback
  set playlist_id = null, playlist_uri = null, device_id = null, device_name = null,
      is_playing = false, current_track_uri = null, progress_ms = null,
      strikes = 0, strike_reason = null, updated_at = now()
  where host_id = p_host_id;

  update arenas
  set paused_at = now(), pause_reason = 'spotify_disconnected', updated_at = now()
  where host_id = p_host_id and state = 'active' and paused_at is null;
end;
$$;

-- A finished arena no longer needs the host's playlist/device ids
create or replace function public.finish_arena(p_arena_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update arenas
  set state = 'finished', ended_at = now(), updated_at = now(),
      paused_at = null, pause_reason = null
  where id = p_arena_id;

  perform close_open_battles(p_arena_id);

  delete from arena_playback where arena_id = p_arena_id;
end;
$$;

-- Votes need a running (not paused) arena
alter policy votes_require_active_arena on public.votes
  with check (exists (
    select 1 from battles b join arenas a on a.id = b.arena_id
    where b.id = votes.battle_id and a.state = 'active' and a.paused_at is null));

alter policy votes_update_require_active_arena on public.votes
  using (exists (
    select 1 from battles b join arenas a on a.id = b.arena_id
    where b.id = votes.battle_id and a.state = 'active' and a.paused_at is null))
  with check (exists (
    select 1 from battles b join arenas a on a.id = b.arena_id
    where b.id = votes.battle_id and a.state = 'active' and a.paused_at is null));

-- The battle clock stops while paused
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
  $cmd$
);

-- ---------------------------------------------------------------------------
-- Creating an arena with a Spotify warm-up (service only: the Edge Function
-- fetched the track from Spotify, so the metadata can't be forged)
-- ---------------------------------------------------------------------------

drop function if exists public.create_arena(text, text, uuid);
drop function if exists public.get_warmup_suggestions(text, text);

create or replace function public.create_arena_spotify(p_host_id uuid, p_name text, p_mood text, p_track jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_arena_id uuid;
  v_warmup_id uuid;
begin
  if p_host_id is null then
    raise exception 'host required' using errcode = '42501';
  end if;
  if coalesce(p_track->>'spotify_track_id', '') = '' or coalesce((p_track->>'duration_ms')::int, 0) <= 0 then
    raise exception 'a Spotify warm-up track is required' using errcode = '22023';
  end if;

  insert into arenas (name, host_id, state, mood)
  values (p_name, p_host_id, 'waiting', p_mood)
  returning id into v_arena_id;

  -- Block 3 §1: the arena gets its own Song with role = warmup
  insert into songs (arena_id, source, spotify_track_id, title, artist, duration_ms, artwork_url, status, role, moods)
  values (
    v_arena_id, 'spotify', p_track->>'spotify_track_id', p_track->>'title', p_track->>'artist',
    (p_track->>'duration_ms')::int, p_track->>'artwork_url', 'active', 'warmup', array[p_mood]
  )
  returning id into v_warmup_id;

  update arenas set warmup_song_id = v_warmup_id where id = v_arena_id;

  perform ensure_mock_songs_for_arena(v_arena_id);

  return v_arena_id;
end;
$$;

-- Service only: the competitor row for a proposed Spotify track
create or replace function public.upsert_spotify_song(p_arena_id uuid, p_track jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into songs (arena_id, source, spotify_track_id, title, artist, duration_ms, artwork_url, status, role)
  values (
    p_arena_id, 'spotify', p_track->>'spotify_track_id', p_track->>'title', p_track->>'artist',
    (p_track->>'duration_ms')::int, p_track->>'artwork_url', 'active', 'competitor'
  )
  on conflict (arena_id, source, spotify_track_id, role)
  do update set title = excluded.title, artist = excluded.artist,
                duration_ms = excluded.duration_ms, artwork_url = excluded.artwork_url,
                updated_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

-- Proposals now come from Spotify (spotify-host "search"/"propose")
drop function if exists public.search_songs(uuid, text);

-- Warm-up as clients see it (no more host-only MP3 path)
drop function if exists public.get_arena_warmup(uuid);
create function public.get_arena_warmup(p_arena_id uuid)
returns table (
  song_id uuid, title text, artist text, duration_ms integer, started_at timestamptz,
  spotify_track_id text, artwork_url text
)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.title, s.artist, s.duration_ms, a.warmup_started_at,
         case when s.source = 'spotify' then s.spotify_track_id end, s.artwork_url
  from arenas a
  join songs s on s.id = a.warmup_song_id
  where a.id = p_arena_id
    and (a.host_id = auth.uid()
      or exists (
        select 1 from participants p
        where p.arena_id = a.id and p.identity_anchor_id = auth.uid()));
$$;
revoke all on function public.get_arena_warmup(uuid) from public;
grant execute on function public.get_arena_warmup(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Start: only once spotify-host has created the playlist and started the
-- warm-up on the host's device (arena_playback row with a playlist)
-- ---------------------------------------------------------------------------

create or replace function public.start_arena_battles(p_arena_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_arena arenas%rowtype;
  v_battle_id uuid;
  v_duration integer;
  v_warmup_track text;
  v_pair record;
  v_song_a uuid;
  v_song_b uuid;
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

    if v_battle_id is not null then
      return v_battle_id;
    end if;
  elsif v_arena.state <> 'waiting' then
    raise exception 'arena is %', v_arena.state using errcode = '22023';
  end if;

  if v_arena.state = 'waiting' then
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

    -- Battle 1 lasts the warm-up (the "winner of battle 0")
    select duration_ms, spotify_track_id into v_duration, v_warmup_track
    from songs where id = v_arena.warmup_song_id;
  end if;

  -- Songs proposed during the lobby go first
  select * into v_pair from pull_next_battle_songs(p_arena_id);
  v_song_a := v_pair.song_a;
  v_song_b := v_pair.song_b;

  -- Nothing proposed yet: two library songs, arena mood first, never the
  -- warm-up track (kept until steps 12/18, user decision 2026-10-27)
  if v_song_a is null or v_song_b is null then
    select (array_agg(id))[1], (array_agg(id))[2]
    into v_song_a, v_song_b
    from (
      select id
      from songs
      where arena_id = library_arena_id()
        and status = 'active'
        and source <> 'mock'
        and role = 'competitor'
        and spotify_track_id is distinct from v_warmup_track
      order by coalesce(v_arena.mood = any(moods), false) desc, random()
      limit 2
    ) picked;
  end if;

  insert into battles (arena_id, song_a_id, song_b_id, state, duration_ms, sudden_death_active)
  values (
    p_arena_id,
    coalesce(v_song_a, '11111111-1111-1111-1111-111111111111'::uuid),
    coalesce(v_song_b, '22222222-2222-2222-2222-222222222222'::uuid),
    'pending',
    coalesce(v_duration, 45000),
    false
  )
  returning id into v_battle_id;

  return v_battle_id;
end;
$$;

-- Service-only functions: not callable by clients
revoke all on function public.pause_arena(uuid, text) from public, anon, authenticated;
revoke all on function public.resume_arena(uuid) from public, anon, authenticated;
revoke all on function public.forget_host_spotify(uuid) from public, anon, authenticated;
revoke all on function public.create_arena_spotify(uuid, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.upsert_spotify_song(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.pause_arena(uuid, text) to service_role;
grant execute on function public.resume_arena(uuid) to service_role;
grant execute on function public.forget_host_spotify(uuid) to service_role;
grant execute on function public.create_arena_spotify(uuid, text, text, jsonb) to service_role;
grant execute on function public.upsert_spotify_song(uuid, jsonb) to service_role;
grant select, insert, update, delete on public.arena_playback to service_role;

-- ---------------------------------------------------------------------------
-- Watcher (Playback Provider onProgress): every 15 s, only while some running
-- arena has Spotify playback. The function checks each arena at most every
-- 12 s, so extra calls change nothing. Optional hardening: a Vault secret
-- 'spotify_watch_secret' + the same value as Edge secret SPOTIFY_WATCH_SECRET
-- (created out of band, never in this file) makes the function require it.
-- ---------------------------------------------------------------------------

select cron.unschedule('spotify_playback_watch_job')
where exists (select 1 from cron.job where jobname = 'spotify_playback_watch_job');

select cron.schedule(
  'spotify_playback_watch_job',
  '15 seconds',
  $cmd$
  select net.http_post(
    url := 'https://uuxzjroikbzwaszpgiks.supabase.co/functions/v1/spotify-host',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-watch-secret', coalesce((select decrypted_secret from vault.decrypted_secrets where name = 'spotify_watch_secret'), '')
    ),
    body := '{"action":"watch"}'::jsonb,
    timeout_milliseconds := 10000
  )
  where exists (
    select 1 from arena_playback pb join arenas a on a.id = pb.arena_id
    where a.state = 'active'
  );
  $cmd$
);

-- Keep its run log as short as the battle job's
select cron.alter_job(
  (select jobid from cron.job where jobname = 'cron_log_retention'),
  command := $cmd$
  delete from cron.job_run_details
  where (jobid in (select jobid from cron.job where jobname in ('battle_lifecycle_job', 'spotify_playback_watch_job'))
         and end_time < now() - interval '1 hour')
     or end_time < now() - interval '3 days';
  $cmd$
);
