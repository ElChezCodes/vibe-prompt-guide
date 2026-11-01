-- Like the song playing now (user request 2026-11-01): NowPlaying gets a
-- heart like the battle cards'. The like itself is unchanged (spotify-host
-- `like` -> toggle_song_like, mirrored in the liker's own Spotify Liked Songs,
-- removed on unlike only if MF added it); a song playing now isn't in the open
-- battle, so the like never casts a vote. Only the song id is exposed here.
begin;
drop function public.get_arena_playback(uuid);
drop function public.arena_playback_state(uuid, uuid);

CREATE FUNCTION public.arena_playback_state(p_arena_id uuid, p_viewer uuid)
 RETURNS TABLE(paused_at timestamp with time zone, pause_reason text, is_playing boolean, expected_until timestamp with time zone, checked_at timestamp with time zone, device_name text, playlist_url text, player_context text, now_playing_kind text, now_playing_title text, now_playing_artist text, now_playing_artwork_url text, now_playing_spotify_track_id text, next_title text, next_artist text, control_mode text, manual_change_at timestamp with time zone, unplayable_title text, unplayable_artist text, now_playing_song_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with a as (select a.* from arenas a where a.id = p_arena_id),
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
         case when a.host_id = p_viewer then pb.device_name end,
         case when a.host_id = p_viewer and pb.playlist_id is not null
              then 'https://open.spotify.com/playlist/' || pb.playlist_id end,
         pb.player_context,
         case when np.idx is null then null when np.battle_id is null then 'warmup' else 'winner' end,
         s.title, s.artist, s.artwork_url, s.spotify_track_id,
         ns.title, ns.artist,
         pb.control_mode,
         case when a.host_id = p_viewer then pb.manual_change_at end,
         gs.title, gs.artist,
         s.id
  from a
  left join pb on true
  left join np on true
  left join songs s on s.id = np.song_id
  left join plan nx on nx.idx = np.idx + 1
  left join songs ns on ns.id = nx.song_id
  left join gone on true
  left join songs gs on gs.id = gone.song_id;
$function$;
revoke all on function public.arena_playback_state(uuid, uuid) from public, anon, authenticated;
grant execute on function public.arena_playback_state(uuid, uuid) to service_role;

CREATE FUNCTION public.get_arena_playback(p_arena_id uuid)
 RETURNS TABLE(paused_at timestamp with time zone, pause_reason text, is_playing boolean, expected_until timestamp with time zone, checked_at timestamp with time zone, device_name text, playlist_url text, player_context text, now_playing_kind text, now_playing_title text, now_playing_artist text, now_playing_artwork_url text, now_playing_spotify_track_id text, next_title text, next_artist text, control_mode text, manual_change_at timestamp with time zone, unplayable_title text, unplayable_artist text, now_playing_song_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from arena_playback_state(p_arena_id, auth.uid())
  where exists (select 1 from arenas a where a.id = p_arena_id
                and (a.host_id = auth.uid()
                  or exists (select 1 from participants p where p.arena_id = a.id and p.identity_anchor_id = auth.uid())));
$function$;
revoke all on function public.get_arena_playback(uuid) from public, anon;
grant execute on function public.get_arena_playback(uuid) to authenticated, service_role;
commit;
