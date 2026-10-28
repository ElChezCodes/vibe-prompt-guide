-- Step 18 follow-up (2026-10-28): songs that can't be played in the host's
-- country. Found in-app: a winner greyed out in the host's Spotify (not
-- available in their country) made Spotify skip it; MF took that for a manual
-- change and put it back every 15 s, Spotify fell back to the warm-up, and so on.
--
-- User decisions 2026-10-28:
-- * During the arena an unplayable song (winner or warm-up) counts as skipped:
--   MF marks it, follows Spotify to the next song and the battle playing over
--   it is shortened by its length; if it was the last one, lock-in comes at once
--   (as a manual skip past the end). No pause, no host prompt; the app says
--   "not available in the host's country".
-- * Prevention lives in spotify-host: with the new user-read-private scope it
--   knows the host's Spotify country (streaming_accounts.country) and passes it
--   as `market`, so search/playlists mark unplayable tracks and propose /
--   reserve / warm-up refuse them.

alter table public.streaming_accounts add column if not exists country text;
alter table public.playlist_queue add column if not exists unplayable_at timestamptz;
alter table public.arenas add column if not exists warmup_unplayable_at timestamptz;

-- ---------------------------------------------------------------------------
-- Sound plan: an unplayable entry lasts 0 and is not "added" (never expected,
-- never put back, not recreated in the playlist), the next ones move up
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
    -- them, else from the end of their own battle
    select pq.seq, pq.winner_song_id, pq.spotify_track_id,
           case when pq.unplayable_at is null then pq.song_duration_ms else 0 end,
           case when bt.next_soundtrack = 'arena' and bt.next_started is not null then bt.next_started
                else bt.started_at + bt.duration_ms * interval '1 millisecond' end,
           coalesce(sum(case when pq.unplayable_at is null then pq.song_duration_ms else 0 end) over (
             partition by pq.battle_id order by pq.seq
             rows between unbounded preceding and 1 preceding), 0),
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

-- ---------------------------------------------------------------------------
-- Marking a song unplayable (spotify-host, when Spotify can't play the
-- expected track): it leaves the plan and the battle playing over it is
-- shortened by its length, never below what is needed to close it now
-- (lock-in 15 s ahead / Sudden Death 5 s ahead / the end). Idempotent.
-- ---------------------------------------------------------------------------

create or replace function public.skip_unplayable_track(p_arena_id uuid, p_track_uri text)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
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
      when v_battle.state in ('pending', 'active') then 15000
      when v_battle.sudden_death_active then 5000
      else 0 end;
  end if;

  update battles
  set duration_ms = greatest(duration_ms - v_entry.duration_ms, v_floor),
      updated_at = now()
  where id = v_battle.id;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- Next battle: an unplayable winner doesn't count towards its soundtrack
-- (only the duration sum changes from real_playback_2026-10-28.sql)
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
    select nullif(sum(song_duration_ms) filter (where unplayable_at is null), 0) into v_duration
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

-- ---------------------------------------------------------------------------
-- Display: the last song skipped as unplayable (2 min), for "not available in
-- the host's country"
-- ---------------------------------------------------------------------------

drop function if exists public.get_arena_playback(uuid);
create or replace function public.get_arena_playback(p_arena_id uuid)
returns table(paused_at timestamptz, pause_reason text, is_playing boolean, expected_until timestamptz,
              checked_at timestamptz, device_name text, playlist_url text,
              player_context text, now_playing_kind text, now_playing_title text, now_playing_artist text,
              now_playing_artwork_url text, now_playing_spotify_track_id text,
              next_title text, next_artist text, control_mode text, manual_change_at timestamptz,
              unplayable_title text, unplayable_artist text)
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
  ),
  gone as (
    select u.song_id, u.at from (
      select pq.winner_song_id as song_id, pq.unplayable_at as at
      from playlist_queue pq where pq.arena_id = p_arena_id and pq.unplayable_at is not null
      union all
      select a.warmup_song_id, a.warmup_unplayable_at from a where a.warmup_unplayable_at is not null
    ) u
    where u.at > now() - interval '2 minutes'
    order by u.at desc limit 1
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
         case when a.host_id = auth.uid() then pb.manual_change_at end,
         gs.title, gs.artist
  from a
  left join pb on true
  left join np on true
  left join songs s on s.id = np.song_id
  left join plan nx on nx.idx = np.idx + 1
  left join songs ns on ns.id = nx.song_id
  left join gone on true
  left join songs gs on gs.id = gone.song_id;
$$;

revoke all on function public.skip_unplayable_track(uuid, text) from public, anon, authenticated;
grant execute on function public.skip_unplayable_track(uuid, text) to service_role;
revoke all on function public.get_arena_playback(uuid) from public, anon;
grant execute on function public.get_arena_playback(uuid) to authenticated;

-- spotify-host: the same track put back several checks in a row without
-- sticking = unplayable, when the host's country isn't known
alter table public.arena_playback add column if not exists put_back_uri text;
alter table public.arena_playback add column if not exists put_back_count integer not null default 0;
