-- ===========================================================================
-- Step 19a: real-data Stage View (user decisions 2026-10-29).
-- The Stage View (/a/:code/stage) is the party's shared screen (TV /
-- projector at home): anyone with the link may open it, it is never a
-- participant (no heartbeat, no presence, no passive vote, not counted for
-- PI) and it only shows information (no playback controls: the host keeps
-- NowPlaying + their own Spotify app). Everything comes from the database:
-- no Spotify calls per viewer or per tick.
--
-- Shows: the live battle (arena_live_state, already readable), proposers'
-- MF nicknames + arena PI on the cards (system songs, lent Liked Songs and
-- system revanchas stay anonymous: they have no 'proposal' history row for
-- the battle), backers count, now playing / next, "Next up to fight", join
-- QR, presence counts, top PI of the arena; the lobby and final ranking.
--
-- The member-only RPCs keep their checks; their bodies move into internal
-- functions taking the viewer (NULL = Stage View: no host-only fields, no
-- "is mine") so the Stage View reuses them without duplicating logic.
-- ===========================================================================

-- --- Playback (body of get_arena_playback) ---------------------------------
create or replace function public.arena_playback_state(p_arena_id uuid, p_viewer uuid)
returns table(paused_at timestamp with time zone, pause_reason text, is_playing boolean, expected_until timestamp with time zone, checked_at timestamp with time zone, device_name text, playlist_url text, player_context text, now_playing_kind text, now_playing_title text, now_playing_artist text, now_playing_artwork_url text, now_playing_spotify_track_id text, next_title text, next_artist text, control_mode text, manual_change_at timestamp with time zone, unplayable_title text, unplayable_artist text)
language sql
stable security definer
set search_path = public
as $$
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

create or replace function public.get_arena_playback(p_arena_id uuid)
returns table(paused_at timestamp with time zone, pause_reason text, is_playing boolean, expected_until timestamp with time zone, checked_at timestamp with time zone, device_name text, playlist_url text, player_context text, now_playing_kind text, now_playing_title text, now_playing_artist text, now_playing_artwork_url text, now_playing_spotify_track_id text, next_title text, next_artist text, control_mode text, manual_change_at timestamp with time zone, unplayable_title text, unplayable_artist text)
language sql
stable security definer
set search_path = public
as $$
  select * from arena_playback_state(p_arena_id, auth.uid())
  where exists (select 1 from arenas a where a.id = p_arena_id
                and (a.host_id = auth.uid()
                  or exists (select 1 from participants p where p.arena_id = a.id and p.identity_anchor_id = auth.uid())));
$$;

-- --- Next up to fight (body of get_arena_next_up) --------------------------
create or replace function public.arena_next_up(p_arena_id uuid, p_viewer uuid)
returns table(pos integer, song_id uuid, spotify_track_id text, title text, artist text, artwork_url text, duration_ms integer, pair_no integer, vs_system boolean, is_mine boolean, available_at timestamp with time zone)
language sql
stable security definer
set search_path = public
as $$
  with plan as (select * from matchmaking_plan(p_arena_id))
  select p.pos, s.id, s.spotify_track_id, s.title, s.artist, s.artwork_url, s.duration_ms, p.pair_no,
         -- Only the next battle: later lone songs may still get a partner
         p.pair_no = 1 and (select count(*) from plan o where o.pair_no = 1) = 1,
         p_viewer is not null and p.proposed_by is not distinct from p_viewer,
         p.available_at
  from plan p join songs s on s.id = p.song_id
  where exists (select 1 from arenas a where a.id = p_arena_id and a.state in ('waiting', 'active'))
  order by p.pos;
$$;

create or replace function public.get_arena_next_up(p_arena_id uuid)
returns table(pos integer, song_id uuid, spotify_track_id text, title text, artist text, artwork_url text, duration_ms integer, pair_no integer, vs_system boolean, is_mine boolean, available_at timestamp with time zone)
language sql
stable security definer
set search_path = public
as $$
  select * from arena_next_up(p_arena_id, auth.uid())
  where exists (select 1 from participants pa where pa.arena_id = p_arena_id and pa.identity_anchor_id = auth.uid());
$$;

-- --- Arena PI ranking (body of get_arena_pi_leaderboard) -------------------
create or replace function public.arena_pi_ranking(p_arena_id uuid, p_viewer uuid)
returns table(place bigint, display_name text, pi integer, is_me boolean, is_host boolean)
language plpgsql
stable security definer
set search_path = public
as $$
declare
  v_arena arenas;
begin
  select * into v_arena from arenas where id = p_arena_id;
  if v_arena.id is null then
    return;
  end if;

  if v_arena.votes_purged_at is not null then
    return query
      select rank() over (order by s.pi desc),
             coalesce((select up.nickname from user_profiles up where up.user_id = s.user_id), s.display_name),
             s.pi, p_viewer is not null and s.user_id is not distinct from p_viewer,
             s.user_id is not distinct from v_arena.host_id
      from arena_pi_standings s
      where s.arena_id = p_arena_id
      order by s.pi desc, s.display_name;
    return;
  end if;

  return query
    with members as (
      select distinct p.identity_anchor_id as uid
      from participants p
      where p.arena_id = p_arena_id
        and exists (select 1 from auth.users u where u.id = p.identity_anchor_id)
    ),
    scored as (
      select m.uid,
             greatest(0, coalesce((select sum(l.delta) from pi_ledger l
                                   where l.arena_id = p_arena_id and l.user_id = m.uid), 0))::int as pi
      from members m
    )
    select rank() over (order by s.pi desc), mf_display_name(s.uid), s.pi,
           s.uid is not distinct from p_viewer, s.uid = v_arena.host_id
    from scored s
    order by s.pi desc, 2;
end;
$$;

create or replace function public.get_arena_pi_leaderboard(p_arena_id uuid)
returns table(place bigint, display_name text, pi integer, is_me boolean, is_host boolean)
language plpgsql
stable security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null
     or not (exists (select 1 from arenas a where a.id = p_arena_id and a.host_id = v_uid)
             or exists (select 1 from participants p where p.arena_id = p_arena_id and p.identity_anchor_id = v_uid)) then
    return;
  end if;
  return query select * from arena_pi_ranking(p_arena_id, v_uid);
end;
$$;

-- Internal: only the RPCs above (security definer) call them
revoke all on function public.arena_playback_state(uuid, uuid) from public, anon, authenticated;
revoke all on function public.arena_next_up(uuid, uuid) from public, anon, authenticated;
revoke all on function public.arena_pi_ranking(uuid, uuid) from public, anon, authenticated;

-- --- Stage View ------------------------------------------------------------
-- One call for everything around the live battle (the battle itself comes
-- from arena_live_state via useBattleOrchestrator). Anyone signed in (every
-- visitor has an anonymous session) with the arena code; expired = not found.
-- Polled every few seconds by one screen: no Spotify calls, no writes.
create or replace function public.get_stage_view(p_code text)
returns jsonb
language plpgsql
stable security definer
set search_path = public
as $$
declare
  v_arena arenas;
  v_battle battles;
  v_open boolean;
  v_result jsonb;
begin
  if auth.uid() is null then
    return null;
  end if;

  select * into v_arena from arenas
  where arena_code = upper(trim(p_code)) and state <> 'expired';
  if v_arena.id is null then
    return null;
  end if;
  v_open := v_arena.state in ('waiting', 'active');

  -- The same battle arena_live_state shows (the latest one)
  select * into v_battle from battles
  where arena_id = v_arena.id
  order by created_at desc limit 1;

  v_result := jsonb_build_object(
    'arena', jsonb_build_object(
      'id', v_arena.id,
      'name', v_arena.name,
      'code', v_arena.arena_code,
      'state', v_arena.state,
      'mood', v_arena.mood,
      'started_at', v_arena.started_at,
      'paused_at', v_arena.paused_at,
      'pause_reason', v_arena.pause_reason),
    'warmup', (select jsonb_build_object('title', s.title, 'artist', s.artist, 'artwork_url', s.artwork_url,
                                         'spotify_track_id', s.spotify_track_id, 'duration_ms', s.duration_ms)
               from songs s where s.id = v_arena.warmup_song_id),
    -- People in the arena (not left); the host counts like everyone
    'people', (select jsonb_build_object(
                 'joined', count(*) filter (where p.left_at is null),
                 'active', count(*) filter (where pp.state = 'active'),
                 'passive', count(*) filter (where pp.state = 'passive'))
               from participant_presence pp
               join participants p on p.id = pp.participant_id
               where pp.arena_id = v_arena.id),
    'waiting_for_songs', v_arena.state = 'active' and v_arena.paused_at is null
      and not exists (select 1 from battles b where b.arena_id = v_arena.id and b.state in ('pending', 'active', 'closing')),
    'playback', case when v_arena.state = 'active' then
      (select jsonb_build_object(
                'is_playing', ps.is_playing,
                'player_context', ps.player_context,
                'now_playing_kind', ps.now_playing_kind,
                'now_playing_title', ps.now_playing_title,
                'now_playing_artist', ps.now_playing_artist,
                'now_playing_artwork_url', ps.now_playing_artwork_url,
                'now_playing_spotify_track_id', ps.now_playing_spotify_track_id,
                'next_title', ps.next_title,
                'next_artist', ps.next_artist,
                'unplayable_title', ps.unplayable_title)
       from arena_playback_state(v_arena.id, null) ps) end,
    -- Who proposed each song of the battle on screen: MF nickname + arena PI.
    -- System songs (reserve, lent Liked Songs, member profiles, system
    -- revancha) have no 'proposal' row for this battle: anonymous.
    'battle', case when v_battle.id is not null then jsonb_build_object(
      'battle_id', v_battle.id,
      'a', (select jsonb_build_object('proposer', x.proposer, 'pi', x.pi, 'backers', x.backers)
            from stage_view_song_credit(v_arena.id, v_battle.id, v_battle.song_a_id) x),
      'b', (select jsonb_build_object('proposer', x.proposer, 'pi', x.pi, 'backers', x.backers)
            from stage_view_song_credit(v_arena.id, v_battle.id, v_battle.song_b_id) x)) end,
    'next_up', case when v_open then
      coalesce((select jsonb_agg(jsonb_build_object(
                  'pos', n.pos, 'song_id', n.song_id, 'spotify_track_id', n.spotify_track_id,
                  'title', n.title, 'artist', n.artist, 'artwork_url', n.artwork_url,
                  'duration_ms', n.duration_ms, 'pair_no', n.pair_no, 'vs_system', n.vs_system,
                  'is_mine', false, 'available_at', n.available_at) order by n.pos)
                -- The first 5 only (user, 2026-10-29: the top PI must fit without scrolling)
                from arena_next_up(v_arena.id, null) n where n.pos <= 5), '[]'::jsonb)
      else '[]'::jsonb end,
    -- Top 3 during the arena (user, 2026-10-29), the whole ranking once finished
    'leaderboard', coalesce((select jsonb_agg(jsonb_build_object(
                     'place', r.place, 'display_name', r.display_name, 'pi', r.pi, 'is_host', r.is_host))
                   from (select * from arena_pi_ranking(v_arena.id, null)
                         limit case when v_arena.state = 'finished' then null else 3 end) r), '[]'::jsonb)
  );
  return v_result;
end;
$$;

create or replace function public.stage_view_song_credit(p_arena_id uuid, p_battle_id uuid, p_song_id uuid)
returns table(proposer text, pi integer, backers integer)
language sql
stable security definer
set search_path = public
as $$
  with prop as (
    select h.proposed_by from proposal_history h
    where h.arena_id = p_arena_id and h.battle_id = p_battle_id and h.song_id = p_song_id
      and h.kind = 'proposal' and h.proposed_by is not null
    order by h.proposed_at limit 1
  )
  select (select mf_display_name(proposed_by) from prop),
         (select greatest(0, coalesce(sum(l.delta), 0))::int from pi_ledger l, prop
          where l.arena_id = p_arena_id and l.user_id = prop.proposed_by),
         (select count(*)::int from proposal_history h
          where h.arena_id = p_arena_id and h.battle_id = p_battle_id and h.song_id = p_song_id
            and h.kind = 'backing' and h.vote_applied);
$$;

revoke all on function public.stage_view_song_credit(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.get_stage_view(text) from public, anon;
grant execute on function public.get_stage_view(text) to authenticated;
