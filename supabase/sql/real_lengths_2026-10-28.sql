-- Step 18 follow-up (2026-10-28): the version of a song Spotify plays can be
-- longer than the stored one (relinking; MusicBrainz/ISRC data doesn't help:
-- lengths come from Spotify). The player is the source of truth for length:
-- correct_track_duration runs as soon as a song is seen playing, and now also
-- for the previous song still playing past its planned end (spotify-host
-- doesn't take that for a manual change; it needs prev_planned_start).

CREATE OR REPLACE FUNCTION public.arena_playback_plan(p_arena_id uuid, p_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    'prev_planned_start', (select x.planned_start from p x join e on x.idx = e.idx - 1),
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
$function$;

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
    and p.planned_start <= now()
    and now() < p.planned_start + greatest(p.duration_ms, p_duration_ms) * interval '1 millisecond'
  order by p.planned_start desc
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
