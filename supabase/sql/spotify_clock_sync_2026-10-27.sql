-- Step 6 fixes (2026-10-27, after the user's checklist):
-- 1) Battle cards show the Spotify artwork: arena_live_state exposes
--    song_a/b_artwork_url (columns appended, so CREATE OR REPLACE keeps grants).
-- 2) The battle clock follows the song actually playing on Spotify. A pause is
--    only detected after ~30 s (2 checks), so freezing from paused_at alone
--    leaves the battle ahead of the music. sync_arena_clock re-anchors battle 1
--    (the one the warm-up plays during) on when the warm-up really started,
--    as observed from Spotify's progress: warmup_started_at, the battle's
--    timings and arena_playback.expected_until move by the same shift.
--    Step 18 must generalise this to the winners (anchor per playing track).

create or replace view public.arena_live_state as
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
    count(v.id) filter (where v.song_id = sa.id and v.status = 'active' and (b.sudden_death_started_at is null or v.vote_type = 'sudden_death')) as votes_a,
    count(v.id) filter (where v.song_id = sb.id and v.status = 'active' and (b.sudden_death_started_at is null or v.vote_type = 'sudden_death')) as votes_b,
    b.sudden_death_active,
    sa.artwork_url as song_a_artwork_url,
    sb.artwork_url as song_b_artwork_url
from battles b
  join songs sa on sa.id = b.song_a_id
  join songs sb on sb.id = b.song_b_id
  left join votes v on v.battle_id = b.id
where b.state = any (array['pending', 'active', 'closing', 'completed'])
group by b.id, sa.id, sb.id;

-- Service only (spotify-host): p_track_started_at = now - Spotify's progress
-- of the warm-up. Ignores drifts under 3 s (network jitter), paused arenas and
-- anything after battle 1 left 'active' (lock-in decided on the old clock).
create or replace function public.sync_arena_clock(p_arena_id uuid, p_track_started_at timestamptz)
returns interval
language plpgsql
security definer
set search_path = public
as $$
declare
  v_warmup_started timestamptz;
  v_shift interval;
begin
  select warmup_started_at into v_warmup_started
  from arenas
  where id = p_arena_id and state = 'active' and paused_at is null
  for update;

  if v_warmup_started is null or p_track_started_at is null then
    return interval '0';
  end if;

  v_shift := p_track_started_at - v_warmup_started;
  if abs(extract(epoch from v_shift)) < 3 then
    return interval '0';
  end if;

  -- Battle 1 starts with the warm-up (start_arena_battles, same transaction)
  update battles
  set started_at = started_at + v_shift
  where arena_id = p_arena_id
    and state = 'active'
    and abs(extract(epoch from started_at - v_warmup_started)) < 5;

  if not found then
    return interval '0';
  end if;

  update arenas
  set warmup_started_at = warmup_started_at + v_shift, updated_at = now()
  where id = p_arena_id;

  update arena_playback
  set expected_until = expected_until + v_shift, updated_at = now()
  where arena_id = p_arena_id;

  return v_shift;
end;
$$;

revoke all on function public.sync_arena_clock(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.sync_arena_clock(uuid, timestamptz) to service_role;
