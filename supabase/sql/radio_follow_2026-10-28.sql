-- Step 18 follow-up (2026-10-28, found in-app): after a radio lead-in the
-- arena song waited for the computed end of the radio track, but Spotify moved
-- on to another radio track earlier, and MF only woke at the computed time.
-- Also the song before it ended ~5 s before the plan (the version Spotify
-- plays was shorter than the stored duration), so the Sudden Death winner
-- again reached the playlist ~1 s before the end.
--
-- * The lead-in follows the radio track really playing: same track = its
--   real end (seeks included); another track = the arena song starts now
--   (spotify-host kicks it). playlist_queue.lead_in_track_uri.
-- * correct_track_duration: when an arena song plays, its real length in
--   Spotify replaces the stored one (plan, battle over it, lock-in/SD).

alter table public.playlist_queue add column if not exists lead_in_track_uri text;

-- The battle that plays over a plan entry: battle 1 for the warm-up (NULL),
-- else the one created right after the entry's own battle (open, 'arena')
create or replace function public.battle_over_entry(p_arena_id uuid, p_entry_battle_id uuid)
returns uuid
language sql
stable
security definer
set search_path to 'public'
as $$
  select b.id
  from battles b
  where b.arena_id = p_arena_id and b.soundtrack = 'arena' and b.state in ('pending', 'active', 'closing')
    and case when p_entry_battle_id is null
             then not exists (select 1 from battles x where x.arena_id = p_arena_id and x.created_at < b.created_at)
             else b.created_at > (select x.created_at from battles x where x.id = p_entry_battle_id)
                  and not exists (select 1 from battles x where x.arena_id = p_arena_id
                                    and x.created_at > (select y.created_at from battles y where y.id = p_entry_battle_id)
                                    and x.created_at < b.created_at)
        end
  order by b.created_at
  limit 1;
$$;

-- Lengthens/shortens a battle by p_delta_ms, never below what it needs to
-- close from now (lock-in 25 s ahead / Sudden Death 10 s ahead / the end)
create or replace function public.adjust_battle_duration(p_battle_id uuid, p_delta_ms integer)
returns void
language sql
security definer
set search_path to 'public'
as $$
  update battles b
  set duration_ms = greatest(b.duration_ms + p_delta_ms,
        case when b.started_at is null then 0
             else greatest(0, floor(extract(epoch from now() - b.started_at) * 1000))::integer + case
               when b.state in ('pending', 'active') then 25000
               when b.sudden_death_active then 10000
               else 0 end
        end),
      updated_at = now()
  where b.id = p_battle_id and p_delta_ms <> 0;
$$;

drop function if exists public.autoplay_lead_in(uuid, timestamptz, timestamptz);
-- spotify-host, while Spotify plays a radio track (p_track_uri: not an arena
-- song, not in the playlist) from p_track_started_at to p_track_ends_at:
-- * an arena song already waiting for a radio track: the same track -> it
--   starts at that track's real end; another one -> it starts now (kick: true);
-- * else, if the track began before (or at) the start of an arena song due
--   now or within 10 s: that song waits for it (lead-in, once per song,
--   capped at 10 min) and the battle over it gets that much longer.
-- spotify-host is woken (wake_at) when the radio track ends. Returns
-- {track_uri, kick} or null.
create or replace function public.autoplay_lead_in(p_arena_id uuid, p_track_uri text,
                                                  p_track_started_at timestamptz, p_track_ends_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_entry record;
  v_old integer;
  v_lead integer;
  v_target timestamptz;
  v_kick boolean := false;
  v_battle uuid;
begin
  perform 1 from arenas where id = p_arena_id and state = 'active' and paused_at is null for update;
  if not found or p_track_uri is null or p_track_started_at is null or p_track_ends_at is null then
    return null;
  end if;

  -- An arena song waiting for a radio track right now (inside its lead-in)
  select p.*, pq.id as pq_id, pq.lead_in_ms, pq.lead_in_track_uri into v_entry
  from arena_sound_plan(p_arena_id) p
  join playlist_queue pq on pq.battle_id = p.battle_id and pq.winner_song_id = p.song_id
  where p.added and pq.lead_in_ms > 0 and p.planned_start > now() - interval '5 seconds'
    and p.planned_start - pq.lead_in_ms * interval '1 millisecond' <= now() + interval '5 seconds'
  order by p.planned_start
  limit 1;

  if found then
    if v_entry.lead_in_track_uri is distinct from p_track_uri then
      v_target := now();
      v_kick := true;
    else
      v_target := p_track_ends_at;
    end if;
    v_old := v_entry.lead_in_ms;
    v_lead := least(greatest(0, v_old + floor(extract(epoch from v_target - v_entry.planned_start) * 1000)), 600000)::integer;
    if not v_kick and abs(v_lead - v_old) < 1000 then
      return jsonb_build_object('track_uri', v_entry.track_uri, 'kick', false);
    end if;
  else
    -- First radio track before an arena song
    select p.*, pq.id as pq_id, pq.lead_in_ms, pq.lead_in_track_uri into v_entry
    from arena_sound_plan(p_arena_id) p
    join playlist_queue pq on pq.battle_id = p.battle_id and pq.winner_song_id = p.song_id
    where p.added
      and p.planned_start >= p_track_started_at - interval '5 seconds'
      and p.planned_start <= now() + interval '10 seconds'
    order by p.planned_start
    limit 1;
    if not found or v_entry.lead_in_ms > 0 then
      return null;
    end if;
    v_old := 0;
    v_target := p_track_ends_at;
    v_lead := least(floor(extract(epoch from v_target - v_entry.planned_start) * 1000), 600000)::integer;
    if v_lead <= 0 then
      return null;
    end if;
  end if;

  update playlist_queue set lead_in_ms = v_lead, lead_in_track_uri = p_track_uri where id = v_entry.pq_id;
  v_battle := battle_over_entry(p_arena_id, v_entry.battle_id);
  if v_battle is not null then
    perform 1 from battles where id = v_battle for update;
    perform adjust_battle_duration(v_battle, v_lead - v_old);
  end if;
  update arena_playback
  set wake_at = case when v_kick then null else v_target + interval '500 milliseconds' end
  where arena_id = p_arena_id;

  return jsonb_build_object('track_uri', v_entry.track_uri, 'kick', v_kick);
end;
$$;

-- spotify-host, while an arena song plays: Spotify's own length for it
-- (relinked versions can differ from the stored one) replaces the stored
-- length, and the battle over it follows, so lock-in and Sudden Death are
-- timed on the real end. Differences under 1 s or over 60 s are ignored.
create or replace function public.correct_track_duration(p_arena_id uuid, p_track_uri text, p_duration_ms integer)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_entry record;
  v_delta integer;
  v_battle uuid;
begin
  perform 1 from arenas where id = p_arena_id and state = 'active' and paused_at is null for update;
  if not found or p_track_uri is null or p_duration_ms is null then
    return 0;
  end if;

  select * into v_entry
  from arena_sound_plan(p_arena_id) p
  where p.track_uri = p_track_uri and p.added
    and p.planned_start <= now() and now() < p.planned_start + p.duration_ms * interval '1 millisecond'
  order by p.idx desc
  limit 1;
  if not found then
    return 0;
  end if;
  v_delta := p_duration_ms - v_entry.duration_ms;
  if abs(v_delta) < 1000 or abs(v_delta) > 60000 then
    return 0;
  end if;

  if v_entry.battle_id is null then
    update songs set duration_ms = p_duration_ms, updated_at = now() where id = v_entry.song_id;
  else
    update playlist_queue set song_duration_ms = p_duration_ms
    where battle_id = v_entry.battle_id and winner_song_id = v_entry.song_id;
  end if;
  v_battle := battle_over_entry(p_arena_id, v_entry.battle_id);
  if v_battle is not null then
    perform 1 from battles where id = v_battle for update;
    perform adjust_battle_duration(v_battle, v_delta);
  end if;
  return v_delta;
end;
$$;

revoke all on function public.battle_over_entry(uuid, uuid) from public, anon, authenticated;
revoke all on function public.adjust_battle_duration(uuid, integer) from public, anon, authenticated;
revoke all on function public.autoplay_lead_in(uuid, text, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.correct_track_duration(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.autoplay_lead_in(uuid, text, timestamptz, timestamptz) to service_role;
grant execute on function public.correct_track_duration(uuid, text, integer) to service_role;
