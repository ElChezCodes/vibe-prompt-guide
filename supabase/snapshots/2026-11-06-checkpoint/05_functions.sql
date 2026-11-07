set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.add_reserve_songs(p_arena_id uuid, p_source text, p_tracks jsonb, p_limit integer, p_contributor uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      -- Step 20: already sounded here (covers the warm-up and the 60-min rule)
      or track_sounded_in_arena(p_arena_id, v_id, nullif(v_track->>'isrc', ''))
      -- 2026-11-01 (test arena): a song that already fought here comes back
      -- only as a revancha (once), never as a fresh reserve song
      or track_fought_in_arena(p_arena_id, v_id)
      or exists (select 1 from songs s where s.arena_id = p_arena_id and s.spotify_track_id = v_id
                 and (exists (select 1 from queues q where q.song_id = s.id)
                      or exists (select 1 from arena_song_reserve r where r.song_id = s.id)
                      or exists (select 1 from battles b where b.arena_id = p_arena_id
                                 and b.state in ('pending', 'active', 'closing')
                                 and s.id in (b.song_a_id, b.song_b_id))));
    v_song := upsert_spotify_song(p_arena_id, v_track);
    insert into arena_song_reserve (arena_id, song_id, source, contributed_by)
    values (p_arena_id, v_song, p_source, case when p_source = 'guest_library' then p_contributor end)
    on conflict do nothing;
    v_added := v_added + 1;
  end loop;
  return v_added;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.adjust_battle_duration(p_battle_id uuid, p_delta_ms integer)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.affinity_score(p_user uuid, p_isrc text, p_arena uuid)
 RETURNS real
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c passive_vote_config;
  v_anon boolean;
  v_isrcs text[];
  v_ws real[];
begin
  if p_isrc is null or p_user is null then
    return null;
  end if;
  select * into c from passive_vote_config where id = 1;
  select is_anonymous into v_anon from auth.users where id = p_user;
  if v_anon is null then
    return null;
  end if;

  -- The user's songs with their decayed weight
  select coalesce(array_agg(isrc), '{}'), coalesce(array_agg(w), '{}') into v_isrcs, v_ws
  from (
    select s.isrc,
           sum(s.weight * power(0.5, extract(epoch from now() - s.created_at) / 86400.0 / c.half_life_days))::real as w
    from affinity_signals s
    where s.user_id = p_user and (not v_anon or s.arena_id = p_arena)
    group by s.isrc
  ) x;

  if cardinality(v_isrcs) < c.min_signals then
    return null;
  end if;

  return coalesce(song_set_score(v_isrcs, v_ws, p_isrc), 0);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.apply_preassigned_votes()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from queue_backers k
                 where k.arena_id = new.arena_id and k.song_id in (new.song_a_id, new.song_b_id)) then
    return null;
  end if;

  perform set_config('mf.preassigning', 'on', true);
  -- Backers still in the arena; both songs backed -> the oldest backing
  insert into votes (battle_id, song_id, participant_id, identity_anchor_id, vote_type, status, preassigned)
  select distinct on (k.user_id) new.id, k.song_id, p.id, k.user_id, 'regular', 'active', true
  from queue_backers k
  join participants p on p.arena_id = k.arena_id and p.identity_anchor_id = k.user_id and p.left_at is null
  where k.arena_id = new.arena_id and k.song_id in (new.song_a_id, new.song_b_id)
  order by k.user_id, k.created_at, k.song_id
  on conflict (battle_id, participant_id) do nothing;
  perform set_config('mf.preassigning', '', true);

  with gone as (
    delete from queue_backers k
    where k.arena_id = new.arena_id and k.song_id in (new.song_a_id, new.song_b_id)
    returning k.*
  ),
  applied as (
    select g.*,
           exists (select 1 from votes v
                   where v.battle_id = new.id and v.identity_anchor_id = g.user_id
                     and v.song_id = g.song_id and v.preassigned) as cast_now
    from gone g
  )
  insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome, battle_id, kind,
                                vote_applied, vote_preassigned, backing_source)
  select a.arena_id, a.song_id, a.user_id, a.created_at, 'battled', new.id, 'backing', a.cast_now, a.cast_now, a.source
  from applied a;

  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.arena_fit_winner(p_battle_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b battles;
  v_isrc_a text;
  v_isrc_b text;
  v_isrcs text[];
  v_ws real[];
  v_fa real;
  v_fb real;
  v_ref public.song_feature;
  v_neutral real;
  v_ca real;
  v_cb real;
begin
  select * into b from battles where id = p_battle_id;
  select isrc into v_isrc_a from songs where id = b.song_a_id;
  select isrc into v_isrc_b from songs where id = b.song_b_id;

  -- Fit with the arena's style (step 13), without the two songs themselves
  select coalesce(array_agg(st.isrc), '{}'), coalesce(array_agg(st.w), '{}') into v_isrcs, v_ws
  from arena_style_songs(b.arena_id) st
  where st.isrc is distinct from v_isrc_a and st.isrc is distinct from v_isrc_b;
  if cardinality(v_isrcs) > 0 then
    v_fa := song_set_score(v_isrcs, v_ws, v_isrc_a);
    v_fb := song_set_score(v_isrcs, v_ws, v_isrc_b);
  end if;
  if v_fa is not null and v_fb is not null and abs(v_fa - v_fb) >= 0.01 then
    return case when v_fa > v_fb then b.song_a_id else b.song_b_id end;
  end if;

  -- Tie or unknown: the more compatible with what has just sounded (step 17 ref)
  select neutral_compat into v_neutral from matchmaking_config where id = 1;
  v_ref := song_features((select s.isrc from songs s where s.id = matchmaking_ref_song(b.arena_id)));
  v_ca := coalesce(song_compat(song_features(v_isrc_a), v_ref), v_neutral);
  v_cb := coalesce(song_compat(song_features(v_isrc_b), v_ref), v_neutral);
  if abs(v_ca - v_cb) >= 0.01 then
    return case when v_ca > v_cb then b.song_a_id else b.song_b_id end;
  end if;

  return case when random() < 0.5 then b.song_a_id else b.song_b_id end;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.arena_last_activity(p_arena_id uuid)
 RETURNS timestamp with time zone
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select greatest(
    a.created_at,
    a.started_at,
    a.updated_at,
    (select max(greatest(p.joined_at, coalesce(p.last_active_at, p.joined_at)))
       from participants p where p.arena_id = a.id),
    (select max(q.created_at) from queues q where q.arena_id = a.id),
    (select max(greatest(v.created_at, v.updated_at))
       from votes v join battles b on b.id = v.battle_id where b.arena_id = a.id))
  from arenas a
  where a.id = p_arena_id;
$function$
;

CREATE OR REPLACE FUNCTION public.arena_next_up(p_arena_id uuid, p_viewer uuid)
 RETURNS TABLE(pos integer, song_id uuid, spotify_track_id text, title text, artist text, artwork_url text, duration_ms integer, pair_no integer, vs_system boolean, is_mine boolean, available_at timestamp with time zone, is_system boolean, votes integer, my_vote boolean, votable boolean, votes_left integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
  c_battles constant int := 5;
  v_last uuid;
  v_ref_isrc text;
  pl_song uuid[];
  pl_pair int[];
  pl_by uuid[];
  pl_avail timestamptz[];
  v_max_pair int;
  o_song uuid[] := '{}';
  o_pair int[] := '{}';
  o_sys boolean[] := '{}';
  o_vs boolean[] := '{}';
  o_by uuid[] := '{}';
  o_avail timestamptz[] := '{}';
  v_exclude text[] := '{}';
  v_k int;
  v_h int[];
  i int;
  v_a_src uuid;
  v_a_song uuid;
  v_b_src uuid;
  v_a_by uuid;
  v_a_isrc text;
  v_a_track text;
  v_left int := 0;
begin
  if not exists (select 1 from arenas a where a.id = p_arena_id and a.state in ('waiting', 'active')) then
    return;
  end if;
  -- What pull_next_battle_songs will see: the latest battle and the ref
  select b.id into v_last from battles b where b.arena_id = p_arena_id order by b.created_at desc limit 1;
  select s.isrc into v_ref_isrc from songs s where s.id = matchmaking_ref_song(p_arena_id);

  select coalesce(array_agg(p.song_id order by p.pos), '{}'), coalesce(array_agg(p.pair_no order by p.pos), '{}'),
         coalesce(array_agg(p.proposed_by order by p.pos), '{}'), coalesce(array_agg(p.available_at order by p.pos), '{}')
  into pl_song, pl_pair, pl_by, pl_avail
  from matchmaking_plan(p_arena_id) p;
  select max(x) into v_max_pair from unnest(pl_pair) x;

  for v_k in 1..greatest(coalesce(v_max_pair, 0), c_battles) loop
    v_h := '{}';
    for i in 1..coalesce(cardinality(pl_song), 0) loop
      if pl_pair[i] = v_k then v_h := v_h || i; end if;
    end loop;

    if cardinality(v_h) = 2 then
      foreach i in array v_h loop
        o_song := o_song || pl_song[i]; o_pair := o_pair || v_k; o_sys := o_sys || false;
        o_vs := o_vs || false; o_by := o_by || pl_by[i]; o_avail := o_avail || null::timestamptz;
      end loop;
    elsif cardinality(v_h) = 1 then
      i := v_h[1];
      select s.spotify_track_id, s.isrc into v_a_track, v_a_isrc from songs s where s.id = pl_song[i];
      v_b_src := null;
      if v_k <= c_battles then
        select fc.src_song_id into v_b_src
        from fallback_candidate(p_arena_id, v_exclude || v_a_track, v_last, pl_by[i], v_a_isrc, v_ref_isrc, true) fc;
      end if;
      o_song := o_song || pl_song[i]; o_pair := o_pair || v_k; o_sys := o_sys || false;
      o_vs := o_vs || (v_b_src is not null); o_by := o_by || pl_by[i]; o_avail := o_avail || null::timestamptz;
      if v_b_src is not null then
        o_song := o_song || v_b_src; o_pair := o_pair || v_k; o_sys := o_sys || true;
        o_vs := o_vs || false; o_by := o_by || null::uuid; o_avail := o_avail || null::timestamptz;
        v_exclude := v_exclude || (select s.spotify_track_id from songs s where s.id = v_b_src);
      end if;
    else
      -- No human song left for this battle: system vs system
      exit when v_k > c_battles;
      v_a_src := null; v_a_song := null; v_b_src := null;
      select fc.src_song_id, fc.song_id into v_a_src, v_a_song
      from fallback_candidate(p_arena_id, v_exclude, v_last, null, null, v_ref_isrc, false) fc;
      exit when v_a_src is null;
      select s.spotify_track_id, s.isrc into v_a_track, v_a_isrc from songs s where s.id = v_a_src;
      v_a_by := case when v_a_song is not null then song_original_proposer(p_arena_id, v_a_song) end;
      select fc.src_song_id into v_b_src
      from fallback_candidate(p_arena_id, v_exclude || v_a_track, v_last, v_a_by, v_a_isrc, v_ref_isrc, true) fc;
      exit when v_b_src is null;
      o_song := o_song || v_a_src || v_b_src; o_pair := o_pair || v_k || v_k;
      o_sys := o_sys || true || true; o_vs := o_vs || false || false;
      o_by := o_by || null::uuid || null::uuid; o_avail := o_avail || null::timestamptz || null::timestamptz;
      v_exclude := v_exclude || v_a_track || (select s.spotify_track_id from songs s where s.id = v_b_src);
    end if;
  end loop;

  -- Can't sound yet (60-min rule): last
  for i in 1..coalesce(cardinality(pl_song), 0) loop
    if pl_pair[i] is null then
      o_song := o_song || pl_song[i]; o_pair := o_pair || null::int; o_sys := o_sys || false;
      o_vs := o_vs || false; o_by := o_by || pl_by[i]; o_avail := o_avail || pl_avail[i];
    end if;
  end loop;

  if p_viewer is not null then
    select greatest(0, m.list_vote_limit - (select count(*) from queue_backers k
                                            where k.arena_id = p_arena_id and k.user_id = p_viewer and k.source = 'list'))
    into v_left from matchmaking_config m where m.id = 1;
  end if;

  return query
  select u.ord::int, s.id, s.spotify_track_id, s.title, s.artist, s.artwork_url, s.duration_ms, u.pair_no,
         u.vs, not u.sys and p_viewer is not null and u.pby is not distinct from p_viewer, u.avail, u.sys,
         -- Proposing carries the proposer's one vote, in this list only
         (case when u.pby is not null then 1 else 0 end
          + (select count(*) from queue_backers k
             where k.arena_id = p_arena_id and k.song_id = s.id and k.user_id is distinct from u.pby))::int,
         p_viewer is not null and exists (select 1 from queue_backers k
                                          where k.arena_id = p_arena_id and k.song_id = s.id and k.user_id = p_viewer),
         -- Not their own proposal, nor a member-profile song of another arena
         p_viewer is not null and s.arena_id = p_arena_id and u.pby is distinct from p_viewer,
         v_left
  from unnest(o_song, o_pair, o_sys, o_vs, o_by, o_avail) with ordinality as u(song_id, pair_no, sys, vs, pby, avail, ord)
  join songs s on s.id = u.song_id
  order by u.ord;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.arena_pi_ranking(p_arena_id uuid, p_viewer uuid)
 RETURNS TABLE(place bigint, display_name text, pi integer, is_me boolean, is_host boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

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
$function$
;

CREATE OR REPLACE FUNCTION public.arena_playback_state(p_arena_id uuid, p_viewer uuid)
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
$function$
;

CREATE OR REPLACE FUNCTION public.arena_sound_plan(p_arena_id uuid)
 RETURNS TABLE(idx integer, song_id uuid, track_uri text, duration_ms integer, planned_start timestamp with time zone, battle_id uuid, after_gap boolean, added boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.arena_style_songs(p_arena_id uuid)
 RETURNS TABLE(isrc text, w real)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with c as (select style_half_life_minutes from system_song_config where id = 1),
  heard as (
    select s.isrc, coalesce(a.warmup_started_at, a.created_at) as at
    from arenas a join songs s on s.id = a.warmup_song_id
    where a.id = p_arena_id
    union all
    select s.isrc, q.created_at
    from queues q join songs s on s.id = q.song_id
    where q.arena_id = p_arena_id and q.proposed_by is not null
    union all
    select s.isrc, h.proposed_at
    from proposal_history h join songs s on s.id = h.song_id
    where h.arena_id = p_arena_id and h.proposed_by is not null and h.kind = 'proposal'  -- Step 14
    union all
    select s.isrc, pq.created_at
    from playlist_queue pq join songs s on s.id = pq.winner_song_id
    where pq.arena_id = p_arena_id
  )
  select h.isrc,
         sum(power(0.5, greatest(0, extract(epoch from now() - h.at)) / 60.0 / c.style_half_life_minutes))::real
  from heard h, c
  where h.isrc is not null
  group by h.isrc;
$function$
;

CREATE OR REPLACE FUNCTION public.autoplay_lead_in(p_arena_id uuid, p_track_uri text, p_track_started_at timestamp with time zone, p_track_ends_at timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.award_pi(p_user uuid, p_arena uuid, p_battle uuid, p_song uuid, p_reason text, p_delta integer)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  insert into pi_ledger (user_id, arena_id, battle_id, song_id, reason, delta)
  select p_user, p_arena, p_battle, p_song, p_reason, p_delta
  where p_user is not null and p_delta <> 0
    and exists (select 1 from auth.users where id = p_user)
  on conflict on constraint pi_ledger_event_unique do nothing;
$function$
;

CREATE OR REPLACE FUNCTION public.back_proposal(p_arena_id uuid, p_song_id uuid, p_source text DEFAULT 'duplicate'::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_participant uuid;
  v_track text;
  v_battle battles;
  v_song uuid;
  v_vote votes;
  v_rows int;
  v_limit int;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if p_source is null or p_source not in ('duplicate', 'list') then
    raise exception 'bad source' using errcode = '22023';
  end if;
  select p.id into v_participant
  from participants p join arenas a on a.id = p.arena_id
  where p.arena_id = p_arena_id and p.identity_anchor_id = v_uid
    and a.state in ('waiting', 'active');
  if v_participant is null then
    raise exception 'not a member of an open arena' using errcode = '42501';
  end if;
  select spotify_track_id into v_track from songs where id = p_song_id and arena_id = p_arena_id;
  if v_track is null then
    raise exception 'song not in this arena' using errcode = '22023';
  end if;

  perform lock_arena_queue(p_arena_id);
  -- Proposing or voting is an action, whatever the answer
  perform touch_participant_activity(p_arena_id, v_uid);
  -- Two separate limits (user, 2026-11-06)
  select case p_source when 'list' then list_vote_limit else duplicate_limit end
  into v_limit from matchmaking_config where id = 1;

  -- Queued: a pre-assigned vote for its battle, not a new entry
  if exists (select 1 from queues where arena_id = p_arena_id and song_id = p_song_id) then
    if exists (select 1 from queues where arena_id = p_arena_id and song_id = p_song_id and proposed_by = v_uid) then
      return 'own_proposal';
    end if;
    if exists (select 1 from queue_backers where arena_id = p_arena_id and song_id = p_song_id and user_id = v_uid) then
      return 'already_backed';
    end if;
    -- The list's button: only the next 10 (a duplicate proposal: any queued song)
    if p_source = 'list' and not exists (select 1 from queues where arena_id = p_arena_id and song_id = p_song_id
                                         and queue_type = 'active') then
      return 'not_in_next_up';
    end if;
    if (select count(*) from queue_backers where arena_id = p_arena_id and user_id = v_uid and source = p_source) >= v_limit then
      return case p_source when 'list' then 'votes_full' else 'backing_full' end;
    end if;
    insert into queue_backers (arena_id, song_id, user_id, source) values (p_arena_id, p_song_id, v_uid, p_source);
    -- A list vote is one tap, not a proposal: its signal is the vote, at the battle's end
    if p_source = 'duplicate' then
      perform record_affinity_signal(v_uid, p_song_id, 'proposal', p_arena_id);
    end if;
    return 'backed';
  end if;

  -- Fighting now: vote for it at once (same rule as a like)
  select b.* into v_battle
  from battles b join songs s on s.id in (b.song_a_id, b.song_b_id)
  where b.arena_id = p_arena_id and b.state in ('pending', 'active', 'closing')
    and s.spotify_track_id = v_track
  order by b.created_at desc
  limit 1;
  if not found then
    -- A system song of Next up: the vote promotes it (fallback_candidate step 0)
    if p_source = 'list' and system_song_votable(p_arena_id, p_song_id) then
      if exists (select 1 from queue_backers where arena_id = p_arena_id and song_id = p_song_id and user_id = v_uid) then
        return 'already_backed';
      end if;
      if (select count(*) from queue_backers where arena_id = p_arena_id and user_id = v_uid and source = 'list') >= v_limit then
        return 'votes_full';
      end if;
      insert into queue_backers (arena_id, song_id, user_id, source) values (p_arena_id, p_song_id, v_uid, 'list');
      return 'backed';
    end if;
    return 'not_queued';
  end if;
  select s.id into v_song from songs s
  where s.id in (v_battle.song_a_id, v_battle.song_b_id) and s.spotify_track_id = v_track
  limit 1;

  select * into v_vote from votes
  where battle_id = v_battle.id and participant_id = v_participant and status = 'active';
  if found then
    return case when v_vote.song_id = v_song then 'already_voted' else 'in_battle' end;
  end if;
  if cast_vote_if_none(p_arena_id, v_song, v_participant) is distinct from v_battle.id then
    return 'in_battle';
  end if;

  -- Step 15: a duplicate of someone else's proposal fighting now (a backing
  -- of it that wasn't cast at the start, e.g. both songs backed, is now)
  update proposal_history set vote_applied = true
  where battle_id = v_battle.id and song_id = v_song and kind = 'backing' and proposed_by = v_uid;
  get diagnostics v_rows = row_count;
  if v_rows = 0 and exists (select 1 from proposal_history h
                            where h.battle_id = v_battle.id and h.song_id = v_song
                              and h.kind = 'proposal' and h.proposed_by <> v_uid) then
    insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome, battle_id, kind, vote_applied, backing_source)
    values (p_arena_id, v_song, v_uid, now(), 'battled', v_battle.id, 'backing', true, p_source);
  end if;
  return 'voted';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.battle_over_entry(p_arena_id uuid, p_entry_battle_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

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
$function$
;

CREATE OR REPLACE FUNCTION public.begin_playback_check(p_arena_id uuid, p_min_ms integer)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with claimed as (
    update arena_playback
    set checked_at = now()
    where arena_id = p_arena_id
      and (checked_at is null or checked_at < now() - p_min_ms * interval '1 millisecond')
    returning 1
  )
  select exists (select 1 from claimed);
$function$
;

CREATE OR REPLACE FUNCTION public.calculate_lockin_vote_totals(p_battle_id uuid)
 RETURNS TABLE(votes_a double precision, votes_b double precision, is_tie boolean)
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_song_a uuid;
    v_song_b uuid;
BEGIN

    SELECT song_a_id, song_b_id
    INTO v_song_a, v_song_b
    FROM battles
    WHERE id = p_battle_id;

    RETURN QUERY
    SELECT
        COALESCE(
            (SUM(weight) FILTER (
                WHERE song_id = v_song_a
                  AND vote_type IN ('regular','passive')
                  AND status = 'active'
            ))::double precision,
            0::double precision
        ),

        COALESCE(
            (SUM(weight) FILTER (
                WHERE song_id = v_song_b
                  AND vote_type IN ('regular','passive')
                  AND status = 'active'
            ))::double precision,
            0::double precision
        ),

        COALESCE(
            SUM(weight) FILTER (
                WHERE song_id = v_song_a
                  AND vote_type IN ('regular','passive')
                  AND status = 'active'
            ),
            0
        )
        =
        COALESCE(
            SUM(weight) FILTER (
                WHERE song_id = v_song_b
                  AND vote_type IN ('regular','passive')
                  AND status = 'active'
            ),
            0
        )

    FROM votes
    WHERE battle_id = p_battle_id;

END;
$function$
;

CREATE OR REPLACE FUNCTION public.can_read_warmup_audio(p_object_name text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
    from arenas a
    join songs s on s.id = a.warmup_song_id
    where a.host_id = auth.uid()
      and a.state = 'active'
      and s.audio_storage_path = p_object_name
  );
$function$
;

CREATE OR REPLACE FUNCTION public.cast_passive_votes(p_battle_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_count int;
begin
  insert into votes (battle_id, song_id, participant_id, identity_anchor_id, vote_type, weight, status)
  select p_battle_id, c.song_id, c.participant_id, c.identity_anchor_id, 'passive', c.weight, 'active'
  from passive_vote_candidates(p_battle_id, false) c
  on conflict do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.cast_vote_if_none(p_arena_id uuid, p_song_id uuid, p_participant uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_battle battles;
  v_rows int;
begin
  select b.* into v_battle
  from battles b join arenas a on a.id = b.arena_id
  where b.arena_id = p_arena_id and b.state = 'active' and b.lockin_at is null
    and not b.sudden_death_active and a.state = 'active' and a.paused_at is null
    and p_song_id in (b.song_a_id, b.song_b_id)
  order by b.created_at desc
  limit 1;
  if not found or exists (select 1 from votes v where v.battle_id = v_battle.id
                          and v.participant_id = p_participant and v.status = 'active') then
    return null;
  end if;

  insert into votes (battle_id, song_id, participant_id, vote_type, status)
  values (v_battle.id, p_song_id, p_participant, 'regular', 'active')
  on conflict (battle_id, participant_id) do update
    set song_id = excluded.song_id, status = 'active', updated_at = now()
    where votes.status = 'cancelled' and votes.vote_type = 'regular';
  get diagnostics v_rows = row_count;
  return case when v_rows > 0 then v_battle.id end;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.claim_playlist_appends(p_arena_id uuid)
 RETURNS TABLE(id uuid, seq bigint, spotify_track_id text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update playlist_queue pq
  set added_to_playlist_at = now()
  where pq.arena_id = p_arena_id
    and pq.added_to_playlist_at is null
    and exists (select 1 from arena_playback pb where pb.arena_id = p_arena_id and pb.playlist_id is not null)
  returning pq.id, pq.seq, pq.spotify_track_id;
$function$
;

CREATE OR REPLACE FUNCTION public.clear_reserve_on_arena_end()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  delete from arena_library_contributors where arena_id = new.id;
  perform drop_reserve_rows(new.id);
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.clear_vote_preassigned()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if not old.preassigned and not new.preassigned then
    return new;
  end if;
  new.preassigned := old.preassigned
    and new.song_id = old.song_id and new.status = old.status and new.vote_type = old.vote_type;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.close_open_battles(p_arena_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_cancelled integer;
begin
  -- Already decided at lock-in: complete it, keep its result
  update battles
  set state = 'completed', ended_at = coalesce(ended_at, now()), updated_at = now()
  where arena_id = p_arena_id and state = 'closing' and resolution_type is not null;

  -- Undecided (pending, active, or Sudden Death in progress)
  update battles
  set state = 'completed',
      resolution_type = 'cancelled',
      winner_song_id = null,
      sudden_death_active = false,
      ended_at = now(),
      updated_at = now()
  where arena_id = p_arena_id and state in ('pending', 'active', 'closing');

  get diagnostics v_cancelled = row_count;
  return v_cancelled;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.correct_track_duration(p_arena_id uuid, p_track_uri text, p_duration_ms integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.create_arena_spotify(p_host_id uuid, p_name text, p_mood text, p_track jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  insert into songs (arena_id, source, spotify_track_id, title, artist, duration_ms, artwork_url, status, role, moods, isrc)
  values (
    v_arena_id, 'spotify', p_track->>'spotify_track_id', p_track->>'title', p_track->>'artist',
    (p_track->>'duration_ms')::int, p_track->>'artwork_url', 'active', 'warmup', array[p_mood],
    normalize_isrc(p_track->>'isrc')
  )
  returning id into v_warmup_id;

  update arenas set warmup_song_id = v_warmup_id where id = v_arena_id;

  perform ensure_mock_songs_for_arena(v_arena_id);
  perform record_affinity_signal(p_host_id, v_warmup_id, 'proposal', v_arena_id);

  return v_arena_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_merge_ticket()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_ticket text;
begin
  if v_uid is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) is not true then
    raise exception 'only an anonymous session can be merged into an account';
  end if;
  delete from account_merge_tickets where anon_user_id = v_uid or expires_at < now();
  v_ticket := encode(gen_random_bytes(32), 'hex');
  insert into account_merge_tickets (ticket, anon_user_id) values (v_ticket, v_uid);
  return v_ticket;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.create_next_battle(p_arena_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- Step 17: the matchmaking log row of this pair
  update matchmaking_log set battle_id = v_id
  where id = nullif(current_setting('mf.matchmaking_log', true), '')::uuid;

  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.delete_song_if_unused(p_song_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  delete from songs s
  where s.id = p_song_id
    and s.role = 'competitor'
    and not exists (select 1 from arena_song_reserve r where r.song_id = s.id)
    and not exists (select 1 from queues q where q.song_id = s.id)
    and not exists (select 1 from queue_backers k where k.song_id = s.id)
    and not exists (select 1 from battles b where s.id in (b.song_a_id, b.song_b_id, b.winner_song_id))
    and not exists (select 1 from playlist_queue pq where pq.winner_song_id = s.id)
    and not exists (select 1 from proposal_history h where h.song_id = s.id)
    and not exists (select 1 from song_likes l where l.song_id = s.id)
    and not exists (select 1 from arenas a where a.warmup_song_id = s.id);
$function$
;

CREATE OR REPLACE FUNCTION public.drop_queue_backers(p_arena_id uuid, p_song_ids uuid[], p_outcome text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with gone as (
    delete from queue_backers
    where arena_id = p_arena_id and song_id = any (coalesce(p_song_ids, '{}'))
    returning *
  )
  insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome, kind, backing_source)
  select arena_id, song_id, user_id, created_at, p_outcome, 'backing', source from gone;
$function$
;

CREATE OR REPLACE FUNCTION public.drop_reserve_rows(p_arena_id uuid, p_contributor uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_song uuid;
begin
  for v_song in
    delete from arena_song_reserve
    where arena_id = p_arena_id and (p_contributor is null or contributed_by = p_contributor)
    returning song_id
  loop
    -- Their votes come back (a queued song keeps its own)
    if not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = v_song) then
      perform drop_queue_backers(p_arena_id, array[v_song], 'purged');
    end if;
    perform delete_song_if_unused(v_song);
  end loop;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.end_arena(p_arena_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_arena arenas%rowtype;
begin
  select * into v_arena from arenas where id = p_arena_id for update;

  if not found then
    raise exception 'arena not found' using errcode = 'P0002';
  end if;
  if v_arena.host_id is distinct from auth.uid() then
    raise exception 'only the host can end the arena' using errcode = '42501';
  end if;

  if v_arena.state = 'finished' then
    return 'finished';
  end if;
  if v_arena.state not in ('waiting', 'active') then
    raise exception 'arena is %', v_arena.state using errcode = '22023';
  end if;

  perform finish_arena(p_arena_id);

  return 'finished';
end;
$function$
;

CREATE OR REPLACE FUNCTION public.enforce_battle_arena_active()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from arenas where id = new.arena_id and state = 'active') then
    raise exception 'battles can only be created in an active arena' using errcode = '23514';
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.ensure_mock_songs_for_arena(p_arena_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
begin
  -- Mock Song A
  insert into songs (
    arena_id,
    source,
    spotify_track_id,
    title,
    artist,
    duration_ms,
    status
  )
  select
    p_arena_id,
    'mock',
    'mock:A',
    'Mock Song A',
    'Mock Artist',
    180000,
    'active'
  where not exists (
    select 1
    from songs
    where arena_id = p_arena_id
      and source = 'mock'
      and spotify_track_id = 'mock:A'
  );

  -- Mock Song B
  insert into songs (
    arena_id,
    source,
    spotify_track_id,
    title,
    artist,
    duration_ms,
    status
  )
  select
    p_arena_id,
    'mock',
    'mock:B',
    'Mock Song B',
    'Mock Artist',
    180000,
    'active'
  where not exists (
    select 1
    from songs
    where arena_id = p_arena_id
      and source = 'mock'
      and spotify_track_id = 'mock:B'
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.enter_arena(p_arena_id uuid)
 RETURNS SETOF participants
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_arena arenas%rowtype;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;

  select * into v_arena from arenas where id = p_arena_id;
  if not found then
    raise exception 'arena not found' using errcode = 'P0002';
  end if;

  if v_arena.state not in ('waiting', 'active') then
    return query
      select * from participants
      where arena_id = p_arena_id and identity_anchor_id = v_uid;
    if not found then
      raise exception 'arena is %', v_arena.state using errcode = '42501';
    end if;
    return;
  end if;

  return query
    insert into participants (arena_id, identity_anchor_id, is_host, joined_at, last_active_at, last_seen_at)
    values (p_arena_id, v_uid, v_arena.host_id = v_uid, now(), now(), now())
    on conflict (arena_id, identity_anchor_id) do update
      set left_at = null,
          last_active_at = now(),
          last_seen_at = now(),
          disconnected_at = null,
          updated_at = now()
    returning *;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.expire_stale_arenas(p_waiting_idle interval DEFAULT '06:00:00'::interval, p_active_idle interval DEFAULT '02:00:00'::interval)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_expired integer;
  v_finished integer := 0;
  r record;
begin
  update arenas a
  set state = 'expired', updated_at = now()
  where a.state = 'waiting'
    and arena_last_activity(a.id) < now() - p_waiting_idle;
  get diagnostics v_expired = row_count;

  for r in
    select a.id from arenas a
    where a.state = 'active'
      and a.id <> library_arena_id()
      and arena_last_activity(a.id) < now() - p_active_idle
  loop
    perform finish_arena(r.id);
    v_finished := v_finished + 1;
  end loop;

  return v_expired + v_finished;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.fallback_candidate(p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid DEFAULT NULL::uuid, p_partner_isrc text DEFAULT NULL::text, p_ref_isrc text DEFAULT NULL::text, p_has_partner boolean DEFAULT false)
 RETURNS TABLE(song_id uuid, src_song_id uuid, step text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
  v_song uuid;
  v_src uuid;
  v_track text;
  v_bucket real;
  v_partner public.song_feature := song_features(p_partner_isrc);
  v_ref public.song_feature := song_features(p_ref_isrc);
  v_seed text := coalesce(p_last_battle::text, '');
begin
  -- 0. system songs voted from Next up: most votes first, then the first voted
  select s.id into v_song
  from (select k.song_id as sid, count(*) as n, min(k.created_at) as first_at
        from queue_backers k
        where k.arena_id = p_arena_id and k.source = 'list'
        group by k.song_id) v
  join songs s on s.id = v.sid
  where system_song_votable(p_arena_id, s.id)
    and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
    and not exists (select 1 from battles lb where lb.id = p_last_battle and s.id in (lb.song_a_id, lb.song_b_id))
    and (p_avoid_proposer is null
         or not exists (select 1 from proposal_history h
                        where h.arena_id = p_arena_id and h.song_id = s.id
                          and h.kind = 'proposal' and h.proposed_by = p_avoid_proposer))
  order by v.n desc, v.first_at, md5(s.id::text || v_seed)
  limit 1;
  if v_song is not null then
    return query select v_song, v_song, 'voted'::text;
    return;
  end if;

  -- 1. revancha (not one of the other song's proposer)
  v_song := pick_rematch_song(p_arena_id, p_exclude, p_last_battle, p_avoid_proposer, v_partner, v_ref, p_has_partner);
  if v_song is not null then
    return query select v_song, v_song, 'rematch'::text;
    return;
  end if;

  -- 2-3. reserve: libraries, then the arena's (and related) artists
  select fit_bucket into v_bucket from system_song_config where id = 1;
  select s.id into v_song
  from arena_song_reserve r join songs s on s.id = r.song_id
  where r.arena_id = p_arena_id
    and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
    and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = s.id)
    and not track_sounded_in_arena(p_arena_id, s.spotify_track_id, s.isrc)
    and not track_fought_in_arena(p_arena_id, s.spotify_track_id)
  order by r.source = 'arena_artist',
           floor(matchmaking_song_score(song_features(s.isrc), v_partner, v_ref, p_has_partner) / v_bucket) desc,
           r.fit is null, floor(r.fit / v_bucket) desc,
           r.taste desc nulls last, md5(s.id::text || v_seed)
  limit 1;
  if v_song is not null then
    return query select v_song, v_song, 'reserve'::text;
    return;
  end if;

  -- 3b. present members' own MF profiles
  select m.src_id, m.spotify_track_id into v_src, v_track
  from member_profile_candidate(p_arena_id, p_exclude, p_avoid_proposer, v_partner, v_ref, p_has_partner, v_seed) m;
  if v_src is not null then
    select s.id into v_song
    from songs s
    where s.arena_id = p_arena_id and s.source = 'spotify' and s.spotify_track_id = v_track and s.role = 'competitor';
    if v_song is null or exists (select 1 from songs s where s.id = v_song and s.status = 'active') then
      return query select v_song, coalesce(v_song, v_src), 'member'::text;
    end if;
    -- An inactive row of that track here: no pick (as before)
    return;
  end if;

  -- 4. proposed here, left the queue without fighting
  select s.id into v_song
  from proposal_history h join songs s on s.id = h.song_id
  where h.arena_id = p_arena_id
    and h.outcome in ('purged', 'withdrawn')
    and h.kind = 'proposal'
    and (p_avoid_proposer is null or h.proposed_by is distinct from p_avoid_proposer)
    and s.status = 'active'
    and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
    and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = s.id)
    and not exists (select 1 from battles b where b.arena_id = p_arena_id and s.id in (b.song_a_id, b.song_b_id))
    and not track_sounded_in_arena(p_arena_id, s.spotify_track_id, s.isrc)
  order by floor(matchmaking_song_score(song_features(s.isrc), v_partner, v_ref, p_has_partner) / v_bucket) desc,
           md5(s.id::text || v_seed)
  limit 1;
  if v_song is not null then
    return query select v_song, v_song, 'purged'::text;
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.fill_song_like_fields()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_participant_id uuid;
begin
  if auth.uid() is null then
    raise exception 'auth.uid() is required to like a song';
  end if;

  select id into v_participant_id
  from participants
  where identity_anchor_id = auth.uid()
    and arena_id = new.arena_id;

  if v_participant_id is null then
    raise exception 'no participant found for this user in this arena';
  end if;

  new.participant_id := v_participant_id;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.fill_vote_fields()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF NEW.vote_type = 'passive' THEN
    IF auth.uid() IS NOT NULL THEN
      RAISE EXCEPTION 'passive votes are system-only';
    END IF;
    NEW.preassigned := false;
  ELSIF NEW.preassigned AND current_setting('mf.preassigning', true) = 'on' THEN
    -- Step 14: cast by apply_preassigned_votes for the backer, whose
    -- identity it sets (auth.uid() is the cron's or the host's at Start)
    NULL;
  ELSE
    NEW.preassigned := false;

    -- Debe existir usuario autenticado
    IF auth.uid() IS NULL THEN
      RAISE EXCEPTION 'auth.uid() is required to vote';
    END IF;

    -- Identity SIEMPRE viene del backend
    NEW.identity_anchor_id := auth.uid();
  END IF;

  -- Derivar arena_id desde battle
  SELECT arena_id
  INTO NEW.arena_id
  FROM public.battles
  WHERE id = NEW.battle_id;

  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.finish_arena(p_arena_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update arenas
  set state = 'finished', ended_at = now(), updated_at = now(),
      paused_at = null, pause_reason = null
  where id = p_arena_id;

  perform close_open_battles(p_arena_id);

  delete from arena_playback where arena_id = p_arena_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.fit_battle_to_track(p_arena_id uuid, p_track_ends_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.forget_host_spotify(p_host_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.generate_arena_code()
 RETURNS text
 LANGUAGE sql
AS $function$
  select upper(
    substr(
      replace(gen_random_uuid()::text, '-', ''),
      1,
      6
    )
  );
$function$
;

CREATE OR REPLACE FUNCTION public.get_arena_next_up(p_arena_id uuid)
 RETURNS TABLE(pos integer, song_id uuid, spotify_track_id text, title text, artist text, artwork_url text, duration_ms integer, pair_no integer, vs_system boolean, is_mine boolean, available_at timestamp with time zone, is_system boolean, votes integer, my_vote boolean, votable boolean, votes_left integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from arena_next_up(p_arena_id, auth.uid())
  where exists (select 1 from participants pa where pa.arena_id = p_arena_id and pa.identity_anchor_id = auth.uid());
$function$
;

CREATE OR REPLACE FUNCTION public.get_arena_pi_leaderboard(p_arena_id uuid)
 RETURNS TABLE(place bigint, display_name text, pi integer, is_me boolean, is_host boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.get_arena_playback(p_arena_id uuid)
 RETURNS TABLE(paused_at timestamp with time zone, pause_reason text, is_playing boolean, expected_until timestamp with time zone, checked_at timestamp with time zone, device_name text, playlist_url text, player_context text, now_playing_kind text, now_playing_title text, now_playing_artist text, now_playing_artwork_url text, now_playing_spotify_track_id text, next_title text, next_artist text, control_mode text, manual_change_at timestamp with time zone, unplayable_title text, unplayable_artist text, now_playing_song_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select * from arena_playback_state(p_arena_id, auth.uid())
  where exists (select 1 from arenas a where a.id = p_arena_id
                and (a.host_id = auth.uid()
                  or exists (select 1 from participants p where p.arena_id = a.id and p.identity_anchor_id = auth.uid())));
$function$
;

CREATE OR REPLACE FUNCTION public.get_arena_presence(p_arena_id uuid)
 RETURNS TABLE(my_state text, active_count integer, passive_count integer, inactive_count integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not exists (select 1 from participants where arena_id = p_arena_id and identity_anchor_id = auth.uid())
     and not exists (select 1 from arenas where id = p_arena_id and host_id = auth.uid()) then
    raise exception 'not a member of this arena' using errcode = '42501';
  end if;

  return query
    select
      max(pp.state) filter (where pp.identity_anchor_id = auth.uid()),
      (count(*) filter (where pp.state = 'active'))::int,
      (count(*) filter (where pp.state = 'passive'))::int,
      (count(*) filter (where pp.state = 'inactive'))::int
    from participant_presence pp
    where pp.arena_id = p_arena_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_arena_queue_summary(p_arena_id uuid)
 RETURNS TABLE(human_queued integer, waiting_for_songs boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    (select count(*)::int from queues q where q.arena_id = a.id and q.proposed_by is not null),
    a.state = 'active'
      and not exists (select 1 from battles b where b.arena_id = a.id and b.state in ('pending', 'active', 'closing'))
  from arenas a
  where a.id = p_arena_id
    and exists (select 1 from participants p where p.arena_id = a.id and p.identity_anchor_id = auth.uid());
$function$
;

CREATE OR REPLACE FUNCTION public.get_arena_warmup(p_arena_id uuid)
 RETURNS TABLE(song_id uuid, title text, artist text, duration_ms integer, started_at timestamp with time zone, spotify_track_id text, artwork_url text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select s.id, s.title, s.artist, s.duration_ms, a.warmup_started_at,
         case when s.source = 'spotify' then s.spotify_track_id end, s.artwork_url
  from arenas a
  join songs s on s.id = a.warmup_song_id
  where a.id = p_arena_id
    and (a.host_id = auth.uid()
      or exists (
        select 1 from participants p
        where p.arena_id = a.id and p.identity_anchor_id = auth.uid()));
$function$
;

CREATE OR REPLACE FUNCTION public.get_current_arena()
 RETURNS TABLE(arena_id uuid, arena_code text, name text, state text, is_host boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select a.id, a.arena_code, a.name, a.state, (a.host_id = auth.uid())
  from participants p
  join arenas a on a.id = p.arena_id
  where p.identity_anchor_id = auth.uid()
    and p.left_at is null
    and a.state in ('waiting', 'active')
  order by p.joined_at desc
  limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_passive_vote(p_battle_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c passive_vote_config;
  b battles;
  p participants;
  v_vote votes;
  v_sa real;
  v_sb real;
begin
  select * into b from battles where id = p_battle_id;
  if not found or b.sudden_death_started_at is not null then
    return null;
  end if;
  select * into p from participants
  where arena_id = b.arena_id and identity_anchor_id = auth.uid()
  order by joined_at desc limit 1;
  if not found then
    return null;
  end if;

  select * into v_vote from votes where battle_id = b.id and participant_id = p.id limit 1;
  if found then
    return case when v_vote.vote_type = 'passive' and v_vote.status = 'active' then v_vote.song_id end;
  end if;

  if b.state <> 'active' or p.left_at is not null
     or exists (select 1 from arenas a where a.id = b.arena_id and (a.state <> 'active' or a.paused_at is not null)) then
    return null;
  end if;

  select * into c from passive_vote_config where id = 1;
  v_sa := coalesce(affinity_score(auth.uid(), (select isrc from songs where id = b.song_a_id), b.arena_id), 0);
  v_sb := coalesce(affinity_score(auth.uid(), (select isrc from songs where id = b.song_b_id), b.arena_id), 0);
  if greatest(v_sa, v_sb) < c.min_score or v_sa = v_sb then
    return null;
  end if;
  return case when v_sa > v_sb then b.song_a_id else b.song_b_id end;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_past_arenas(p_limit integer DEFAULT 20)
 RETURNS TABLE(arena_id uuid, arena_code text, name text, ended_at timestamp with time zone, players bigint, my_pi integer, my_place bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select a.id, a.arena_code, a.name, coalesce(a.ended_at, a.updated_at),
         (select count(*) from get_arena_pi_leaderboard(a.id)),
         (select lb.pi from get_arena_pi_leaderboard(a.id) lb where lb.is_me limit 1),
         (select lb.place from get_arena_pi_leaderboard(a.id) lb where lb.is_me limit 1)
  from arenas a
  where a.state in ('finished', 'expired')
    and auth.uid() is not null
    and exists (select 1 from participants p where p.arena_id = a.id and p.identity_anchor_id = auth.uid())
  order by coalesce(a.ended_at, a.updated_at) desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_pi(p_arena_id uuid)
 RETURNS TABLE(arena_pi integer, total_pi integer, recent jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select greatest(0, coalesce((select sum(l.delta) from pi_ledger l
                               where l.user_id = auth.uid() and l.arena_id = p_arena_id), 0))::int,
         greatest(0, coalesce((select sum(l.delta) from pi_ledger l where l.user_id = auth.uid()), 0))::int,
         coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'reason', x.reason, 'delta', x.delta,
                                                       'battle_id', x.battle_id, 'created_at', x.created_at)
                                    order by x.id desc)
                   from (select l.id, l.reason, l.delta, l.battle_id, l.created_at
                         from pi_ledger l
                         where l.user_id = auth.uid() and l.arena_id = p_arena_id
                         order by l.id desc limit 10) x), '[]'::jsonb)
  where auth.uid() is not null;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_profile()
 RETURNS TABLE(nickname text, is_generated boolean, country text, suggested_country text, is_account boolean, total_pi integer, month_pi integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select mf_display_name(u.id),
         (select p.nickname from user_profiles p where p.user_id = u.id) is null,
         (select p.country from user_profiles p where p.user_id = u.id),
         (select s.country from streaming_accounts s where s.host_id = u.id limit 1),
         not u.is_anonymous,
         greatest(0, coalesce((select sum(l.delta) from pi_ledger l where l.user_id = u.id), 0))::int,
         greatest(0, coalesce((select sum(l.delta) from pi_ledger l
                               where l.user_id = u.id
                                 and l.created_at >= date_trunc('month', now() at time zone 'utc') at time zone 'utc'), 0))::int
  from auth.users u
  where u.id = auth.uid();
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_proposals(p_arena_id uuid)
 RETURNS TABLE(queue_id uuid, song_id uuid, spotify_track_id text, title text, artist text, artwork_url text, status text, place bigint, battles_left integer, at timestamp with time zone, kind text, vote_applied boolean, backing_source text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with r as (select * from queue_ranked(p_arena_id))
  select x.queue_id, x.song_id, x.spotify_track_id, x.title, x.artist, x.artwork_url, x.status, x.place,
         x.battles_left, x.at, x.kind, x.vote_applied, x.backing_source
  from (
    select case when r.proposed_by = auth.uid() then r.id end as queue_id,
           s.id as song_id, s.spotify_track_id, s.title, s.artist, s.artwork_url,
           case r.queue_type when 'active' then 'next' else 'waiting' end as status,
           r.rank_in_list as place,
           case when r.queue_type = 'waiting' then 20 - r.battles_waited end as battles_left,
           coalesce(qb.created_at, r.created_at) as at,
           case when qb.user_id is null then 'proposal' else 'backing' end as kind,
           null::boolean as vote_applied, qb.source as backing_source,
           0 as grp, r.global_rank as k
    from r
    join songs s on s.id = r.song_id
    left join queue_backers qb on qb.arena_id = p_arena_id and qb.song_id = r.song_id and qb.user_id = auth.uid()
    where auth.uid() is not null and (r.proposed_by = auth.uid() or qb.user_id is not null)
    union all
    -- Votes for system songs (never in queues): place NULL
    select null, s.id, s.spotify_track_id, s.title, s.artist, s.artwork_url, 'next', null, null,
           k.created_at, 'backing', null, k.source, 0, 9223372036854775807
    from queue_backers k
    join songs s on s.id = k.song_id
    where k.arena_id = p_arena_id and k.user_id = auth.uid() and auth.uid() is not null
      and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = k.song_id)
    union all
    select null, s.id, s.spotify_track_id, s.title, s.artist, s.artwork_url,
           case
             when h.outcome <> 'battled' then h.outcome
             when b.resolution_type = 'cancelled' then 'cancelled'
             when b.resolution_type = 'draw' then 'draw'
             when b.winner_song_id = h.song_id then 'won'
             when b.winner_song_id is not null then 'lost'
             else 'competing'
           end,
           null, null, h.ended_at, h.kind, h.vote_applied, h.backing_source,
           1, -extract(epoch from h.ended_at)::bigint
    from proposal_history h
    join songs s on s.id = h.song_id
    left join battles b on b.id = h.battle_id
    where h.arena_id = p_arena_id and h.proposed_by = auth.uid() and auth.uid() is not null
  ) x
  order by x.grp, x.k;
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_song_likes(p_arena_id uuid)
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select l.song_id from song_likes l join participants p on p.id = l.participant_id
  where l.arena_id = p_arena_id and p.identity_anchor_id = auth.uid();
$function$
;

CREATE OR REPLACE FUNCTION public.get_my_streaming_connection()
 RETURNS TABLE(provider text, display_name text, premium_status text, preferred_device_id text, preferred_device_name text, connected_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select provider, display_name, premium_status, preferred_device_id,
         preferred_device_name, connected_at
  from public.streaming_accounts
  where host_id = auth.uid();
$function$
;

CREATE OR REPLACE FUNCTION public.get_pi_leaderboard(p_scope text, p_period text, p_country text DEFAULT NULL::text, p_limit integer DEFAULT 50)
 RETURNS TABLE(place bigint, display_name text, country text, pi integer, is_me boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_country text := upper(nullif(btrim(coalesce(p_country, '')), ''));
  v_since timestamptz := case when p_period = 'month'
                              then date_trunc('month', now() at time zone 'utc') at time zone 'utc' end;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  if v_uid is null or p_scope not in ('world', 'country') or p_period not in ('month', 'all') then
    return;
  end if;
  if p_scope = 'country' then
    v_country := coalesce(v_country, (select up.country from user_profiles up where up.user_id = v_uid));
    if v_country is null then
      return;
    end if;
  end if;

  return query
    with totals as (
      select l.user_id, greatest(0, sum(l.delta))::int as pi
      from pi_ledger l
      join auth.users u on u.id = l.user_id and not u.is_anonymous
      left join user_profiles up on up.user_id = l.user_id
      where (v_since is null or l.created_at >= v_since)
        and (p_scope = 'world' or up.country = v_country)
      group by l.user_id
    ),
    ranked as (
      select t.user_id, t.pi, rank() over (order by t.pi desc) as place,
             row_number() over (order by t.pi desc, t.user_id) as rn
      from totals t
      where t.pi > 0
    )
    select r.place, mf_display_name(r.user_id),
           (select up.country from user_profiles up where up.user_id = r.user_id),
           r.pi, r.user_id = v_uid
    from ranked r
    where r.rn <= v_limit or r.user_id = v_uid
    order by r.rn;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.get_stage_view(p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
      'vote_token', v_battle.vote_token,
      'a', (select jsonb_build_object('proposer', x.proposer, 'pi', x.pi, 'backers', x.backers)
            from stage_view_song_credit(v_arena.id, v_battle.id, v_battle.song_a_id) x),
      'b', (select jsonb_build_object('proposer', x.proposer, 'pi', x.pi, 'backers', x.backers)
            from stage_view_song_credit(v_arena.id, v_battle.id, v_battle.song_b_id) x)) end,
    'next_up', case when v_open then
      coalesce((select jsonb_agg(jsonb_build_object(
                  'pos', n.pos, 'song_id', n.song_id, 'spotify_track_id', n.spotify_track_id,
                  'title', n.title, 'artist', n.artist, 'artwork_url', n.artwork_url,
                  'duration_ms', n.duration_ms, 'pair_no', n.pair_no, 'vs_system', n.vs_system,
                  'is_mine', false, 'available_at', n.available_at,
                  'is_system', n.is_system, 'votes', n.votes, 'my_vote', false,
                  'votable', false, 'votes_left', 0) order by n.pos)
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
$function$
;

CREATE OR REPLACE FUNCTION public.guard_participant_presence()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  if current_user in ('anon', 'authenticated') then
    if tg_op = 'INSERT' then
      -- a client insert is an entry into the arena
      new.joined_at := now();
      new.last_active_at := now();
      new.last_seen_at := now();
      new.disconnected_at := null;
    else
      new.joined_at := old.joined_at;
      new.last_active_at := old.last_active_at;
      new.last_seen_at := old.last_seen_at;
      new.disconnected_at := old.disconnected_at;
      new.arena_id := old.arena_id;
      new.identity_anchor_id := old.identity_anchor_id;
      new.created_at := old.created_at;
    end if;
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.leave_arena(p_arena_id uuid)
 RETURNS void
 LANGUAGE sql
 SET search_path TO 'public'
AS $function$
  update participants
  set left_at = now()
  where arena_id = p_arena_id
    and identity_anchor_id = auth.uid();
$function$
;

CREATE OR REPLACE FUNCTION public.library_arena_id()
 RETURNS uuid
 LANGUAGE sql
 IMMUTABLE
AS $function$ select 'c8d99d16-4dad-498f-88ad-8a21fe15d341'::uuid $function$
;

CREATE OR REPLACE FUNCTION public.link_battle_proposals()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update proposal_history
  set battle_id = new.id
  where arena_id = new.arena_id
    and outcome = 'battled'
    and battle_id is null
    and song_id in (new.song_a_id, new.song_b_id);
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.lock_arena_queue(p_arena_id uuid)
 RETURNS void
 LANGUAGE sql
 SET search_path TO 'public'
AS $function$
  select pg_advisory_xact_lock(hashtextextended('queues:' || p_arena_id::text, 0));
$function$
;

CREATE OR REPLACE FUNCTION public.log_playback_event(p_arena_id uuid, p_kind text, p_detail jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  insert into playback_events (arena_id, kind, detail) values (p_arena_id, p_kind, coalesce(p_detail, '{}'::jsonb));
  delete from playback_events where at < now() - interval '7 days';
$function$
;

CREATE OR REPLACE FUNCTION public.mark_like_saved_to_spotify(p_user uuid, p_arena_id uuid, p_song_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update song_likes l set added_to_spotify_at = now()
  from participants p
  where p.id = l.participant_id and p.identity_anchor_id = p_user
    and l.arena_id = p_arena_id and l.song_id = p_song_id;
$function$
;

CREATE OR REPLACE FUNCTION public.mark_playlist_appended(p_arena_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update playlist_queue set added_to_playlist_at = now()
  where arena_id = p_arena_id and added_to_playlist_at is null;
$function$
;

CREATE OR REPLACE FUNCTION public.matchmaking_plan(p_arena_id uuid)
 RETURNS TABLE(pos integer, queue_id uuid, song_id uuid, proposed_by uuid, pair_no integer, turn integer, skips integer, score real, continuity real, forced boolean, available_at timestamp with time zone, votes integer)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m matchmaking_config;
  v_ref public.song_feature;
  v_ids uuid[];
  v_songs uuid[];
  v_props uuid[];
  v_skips int[];
  v_skips0 int[];  -- real counts (v_skips also counts the plan's virtual skips)
  v_feats public.song_feature[];
  v_cont real[] := '{}';
  v_taste real[] := '{}';
  v_pair real[] := '{}';
  v_votes int[];    -- pre-assigned votes of the list + duplicates
  v_max_votes int;
  v_used boolean[] := '{}';
  v_n int;
  v_left int;
  v_pos int := 0;
  v_pair_no int := 0;
  v_forced int;
  v_best real;
  v_bi int;
  v_bj int;
  v_sc real;
  v_span real;
  i int;
  j int;
begin
  select * into m from matchmaking_config where id = 1;
  v_ref := song_features((select s.isrc from songs s where s.id = matchmaking_ref_song(p_arena_id)));

  -- Candidates in the fair order (queue_ranked: humans first, turns per person, FIFO)
  select array_agg(x.id order by x.global_rank), array_agg(x.song_id order by x.global_rank),
         array_agg(x.proposed_by order by x.global_rank), array_agg(x.times_skipped order by x.global_rank),
         array_agg(song_features(x.isrc) order by x.global_rank),
         array_agg(x.backers order by x.global_rank)
  into v_ids, v_songs, v_props, v_skips, v_feats, v_votes
  from (
    select r.id, r.song_id, r.proposed_by, r.global_rank, q.times_skipped, s.isrc,
           (select count(*)::int from queue_backers k
            where k.arena_id = p_arena_id and k.song_id = r.song_id
              and k.user_id is distinct from r.proposed_by) as backers
    from queue_ranked(p_arena_id) r
    join queues q on q.id = r.id
    join songs s on s.id = r.song_id
    where r.queue_type = 'active'
      and track_available_at(p_arena_id, s.spotify_track_id) is null
  ) x;
  v_n := coalesce(cardinality(v_ids), 0);
  v_skips0 := v_skips;
  v_span := greatest(v_n - 1, 1);
  v_max_votes := greatest(coalesce((select max(x) from unnest(v_votes) x), 0), 1);

  for i in 1..v_n loop
    v_cont[i] := coalesce(song_compat(v_feats[i], v_ref), m.neutral_compat);
    v_taste[i] := case when m.taste_weight > 0
                       then coalesce(presence_taste(p_arena_id, v_feats[i].isrc), m.neutral_compat)
                       else 0 end;
    v_used[i] := false;
    for j in 1..v_n loop
      if j > i then
        v_pair[(i - 1) * v_n + j] := coalesce(song_compat(v_feats[i], v_feats[j]), m.neutral_compat);
      end if;
    end loop;
  end loop;

  v_left := v_n;
  while v_left > 0 loop
    v_pair_no := v_pair_no + 1;
    -- The best turn already passed over max_skips times must fight now
    v_forced := null;
    for i in 1..v_n loop
      if not v_used[i] and v_skips[i] >= m.max_skips then
        v_forced := i;
        exit;
      end if;
    end loop;

    v_best := null; v_bi := null; v_bj := null;
    for i in 1..v_n loop
      continue when v_used[i];
      for j in (i + 1)..v_n loop
        continue when v_used[j];
        -- Two songs of the same proposer never face each other
        continue when v_props[i] is not null and v_props[i] = v_props[j];
        continue when v_forced is not null and v_forced not in (i, j);
        v_sc := m.continuity_weight * (v_cont[i] + v_cont[j]) / 2
              + m.pair_weight * v_pair[(i - 1) * v_n + j]
              + m.taste_weight * (v_taste[i] + v_taste[j]) / 2
              + m.votes_weight * (v_votes[i] + v_votes[j]) / (2.0 * v_max_votes)
              - m.turn_weight * ((i - 1) + (j - 1)) / (2 * v_span);
        -- Ties: the better turns (loop order)
        if v_best is null or v_sc > v_best + 1e-6 then
          v_best := v_sc; v_bi := i; v_bj := j;
        end if;
      end loop;
    end loop;

    if v_bi is null then
      -- No partner of another proposer left: one song, against a system song
      for i in 1..v_n loop
        continue when v_used[i];
        continue when v_forced is not null and v_forced <> i;
        v_sc := m.continuity_weight * v_cont[i] + m.taste_weight * v_taste[i]
              + m.votes_weight * v_votes[i] / (1.0 * v_max_votes)
              - m.turn_weight * (i - 1) / v_span;
        if v_best is null or v_sc > v_best + 1e-6 then
          v_best := v_sc; v_bi := i;
        end if;
      end loop;
    end if;

    -- Emit (A = better turn), then count the virtual skips
    foreach i in array array_remove(array[v_bi, v_bj], null) loop
      v_pos := v_pos + 1;
      v_used[i] := true;
      v_left := v_left - 1;
      pos := v_pos; queue_id := v_ids[i]; song_id := v_songs[i]; proposed_by := v_props[i];
      pair_no := v_pair_no; turn := i; skips := v_skips0[i]; score := v_best;
      continuity := v_cont[i]; forced := coalesce(v_forced = i, false); available_at := null;
      votes := v_votes[i];
      return next;
    end loop;
    for i in 1..greatest(v_bi, coalesce(v_bj, 0)) - 1 loop
      if not v_used[i] then
        v_skips[i] := v_skips[i] + 1;
      end if;
    end loop;
  end loop;

  -- Can't sound yet (60-min rule): last, in the fair order
  return query
  select (v_pos + row_number() over (order by r.global_rank))::int, r.id, r.song_id, r.proposed_by, null::int,
         null::int, q.times_skipped, null::real, null::real, false,
         track_available_at(p_arena_id, s.spotify_track_id),
         (select count(*)::int from queue_backers k
          where k.arena_id = p_arena_id and k.song_id = r.song_id
            and k.user_id is distinct from r.proposed_by)
  from queue_ranked(p_arena_id) r
  join queues q on q.id = r.id
  join songs s on s.id = r.song_id
  where r.queue_type = 'active'
    and track_available_at(p_arena_id, s.spotify_track_id) is not null
  order by r.global_rank;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.matchmaking_ref_song(p_arena_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    (select pq.winner_song_id from playlist_queue pq
     where pq.arena_id = p_arena_id and pq.unplayable_at is null
     order by pq.seq desc limit 1),
    (select a.warmup_song_id from arenas a where a.id = p_arena_id and a.warmup_unplayable_at is null));
$function$
;

CREATE OR REPLACE FUNCTION public.matchmaking_song_score(p_song song_feature, p_partner song_feature, p_ref song_feature, p_has_partner boolean)
 RETURNS real
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  m matchmaking_config;
begin
  select * into m from matchmaking_config where id = 1;
  if not p_has_partner then
    return coalesce(song_compat(p_song, p_ref), m.neutral_compat);
  end if;
  return (m.continuity_weight * coalesce(song_compat(p_song, p_ref), m.neutral_compat)
        + m.pair_weight * coalesce(song_compat(p_song, p_partner), m.neutral_compat))
       / nullif(m.continuity_weight + m.pair_weight, 0);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.mb_enrich_begin(p_seconds integer DEFAULT 55)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with got as (
    update mb_enrich_state
    set running_until = now() + make_interval(secs => p_seconds)
    where id = 1 and (running_until is null or running_until < now())
    returning 1
  )
  select exists (select 1 from got);
$function$
;

CREATE OR REPLACE FUNCTION public.mb_enrich_end()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update mb_enrich_state set running_until = null where id = 1;
$function$
;

CREATE OR REPLACE FUNCTION public.mb_fail(p_kind text, p_key text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_kind = 'recording' then
    update recordings
    set attempts = attempts + 1,
        status = case when attempts + 1 >= 6 then 'failed' else 'error' end,
        next_attempt_at = now() + make_interval(mins => power(2, attempts + 1)::int)
    where isrc = p_key;
  elsif p_kind = 'artist' then
    update mb_artists
    set attempts = attempts + 1,
        status = case when attempts + 1 >= 6 then 'failed' else 'error' end,
        next_attempt_at = now() + make_interval(mins => power(2, attempts + 1)::int)
    where mbid = p_key::uuid;
  elsif p_kind in ('search', 'lb_tags') then
    update recordings
    set aux_attempts = aux_attempts + 1,
        aux_step = case when aux_attempts + 1 >= 6 then 'failed' else aux_step end,
        aux_next_at = now() + make_interval(mins => power(2, aux_attempts + 1)::int)
    where isrc = p_key;
  elsif p_kind = 'lb_similar' then
    update mb_artists
    set aux_attempts = aux_attempts + 1,
        aux_step = case when aux_attempts + 1 >= 6 then 'failed' else aux_step end,
        aux_next_at = now() + make_interval(mins => power(2, aux_attempts + 1)::int)
    where mbid = p_key::uuid;
  end if;
  -- 'genres': retried in an hour (mb_next_work)
end;
$function$
;

CREATE OR REPLACE FUNCTION public.mb_has_work()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from recordings where status in ('pending', 'error') and next_attempt_at <= now())
      or exists (select 1 from mb_artists where status in ('pending', 'error') and next_attempt_at <= now())
      or exists (select 1 from mb_enrich_state where id = 1
                 and (genres_loaded_at is null or genres_loaded_at < now() - interval '30 days'))
      or exists (select 1 from recordings where aux_step in ('search', 'lb_tags') and aux_next_at <= now())
      or exists (select 1 from mb_artists where aux_step = 'lb_similar' and aux_next_at <= now());
$function$
;

CREATE OR REPLACE FUNCTION public.mb_next_work(p_lb_only boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_key text;
  v_mbid uuid;
  v_title text;
  v_artist text;
begin
  if not p_lb_only then
  select isrc into v_key from recordings
  where status in ('pending', 'error') and next_attempt_at <= now()
  order by created_at
  limit 1
  for update skip locked;
  if found then
    update recordings set next_attempt_at = now() + interval '5 minutes' where isrc = v_key;
    return jsonb_build_object('kind', 'recording', 'key', v_key);
  end if;

  select mbid::text into v_key from mb_artists
  where status in ('pending', 'error') and next_attempt_at <= now()
  order by created_at
  limit 1
  for update skip locked;
  if found then
    update mb_artists set next_attempt_at = now() + interval '5 minutes' where mbid = v_key::uuid;
    return jsonb_build_object('kind', 'artist', 'key', v_key);
  end if;

  if exists (select 1 from mb_enrich_state where id = 1
             and (genres_loaded_at is null or genres_loaded_at < now() - interval '30 days')) then
    -- Retried in 10 minutes if it fails
    update mb_enrich_state set genres_loaded_at = now() - interval '30 days' + interval '10 minutes'
    where id = 1;
    return jsonb_build_object('kind', 'genres', 'key', 'all');
  end if;

  -- Search: needs a title + artist (the song's own metadata, used only as
  -- the search key; only MBIDs are kept)
  select r.isrc, s.title, split_part(s.artist, ', ', 1) into v_key, v_title, v_artist
  from recordings r
  join lateral (select title, artist from songs where songs.isrc = r.isrc and title is not null and artist is not null
                order by created_at desc limit 1) s on true
  where r.aux_step = 'search' and r.aux_next_at <= now()
  order by r.created_at
  limit 1
  for update of r skip locked;
  if found then
    update recordings set aux_next_at = now() + interval '5 minutes' where isrc = v_key;
    return jsonb_build_object('kind', 'search', 'key', v_key, 'title', v_title, 'artist', v_artist);
  end if;
  -- Search pending without any song left to name it
  update recordings r set aux_step = 'done'
  where r.aux_step = 'search' and r.aux_next_at <= now()
    and not exists (select 1 from songs s where s.isrc = r.isrc and s.title is not null and s.artist is not null);
  end if;

  select isrc, mbid into v_key, v_mbid from recordings
  where aux_step = 'lb_tags' and aux_next_at <= now() and mbid is not null
    and exists (select 1 from mb_genres)  -- the tags are filtered by the genre list
  order by created_at
  limit 1
  for update skip locked;
  if found then
    update recordings set aux_next_at = now() + interval '5 minutes' where isrc = v_key;
    return jsonb_build_object('kind', 'lb_tags', 'key', v_key, 'mbid', v_mbid);
  end if;

  select mbid::text into v_key from mb_artists
  where aux_step = 'lb_similar' and aux_next_at <= now()
  order by created_at
  limit 1
  for update skip locked;
  if found then
    update mb_artists set aux_next_at = now() + interval '5 minutes' where mbid = v_key::uuid;
    return jsonb_build_object('kind', 'lb_similar', 'key', v_key);
  end if;

  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.mb_save_artist(p_mbid uuid, p_result jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_result is null then
    update mb_artists set status = 'not_found', looked_up_at = now(), attempts = attempts + 1, aux_step = 'done'
    where mbid = p_mbid;
    return;
  end if;

  update mb_artists
  set name = p_result->>'name',
      tags = array(select distinct lower(t) from jsonb_array_elements_text(coalesce(p_result->'tags', '[]')) t),
      related_mbids = array(select distinct r::uuid from jsonb_array_elements_text(coalesce(p_result->'related_mbids', '[]')) r),
      status = 'found',
      looked_up_at = now(),
      attempts = attempts + 1,
      aux_step = 'lb_similar',
      aux_attempts = 0,
      aux_next_at = now()
  where mbid = p_mbid;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.mb_save_genres(p_names text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if cardinality(coalesce(p_names, '{}')) > 0 then
    insert into mb_genres (name)
    select distinct lower(btrim(n)) from unnest(p_names) n where btrim(n) <> ''
    on conflict do nothing;
  end if;
  update mb_enrich_state set genres_loaded_at = now() where id = 1;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.mb_save_lb_similar(p_mbid uuid, p_similar uuid[])
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update mb_artists
  set lb_similar = array(select distinct x from unnest(coalesce(p_similar, '{}')) x where x <> p_mbid),
      aux_step = 'done'
  where mbid = p_mbid;
$function$
;

CREATE OR REPLACE FUNCTION public.mb_save_lb_tags(p_isrc text, p_tags text[])
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update recordings
  set lb_tags = array(select distinct lower(t) from unnest(coalesce(p_tags, '{}')) t
                      where exists (select 1 from mb_genres g where g.name = lower(t))),
      aux_step = 'done'
  where isrc = p_isrc;
$function$
;

CREATE OR REPLACE FUNCTION public.mb_save_recording(p_isrc text, p_result jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_artists uuid[];
begin
  if p_result is null then
    -- Step 17: then a search by title + artist
    update recordings set status = 'not_found', looked_up_at = now(), attempts = attempts + 1,
                          aux_step = 'search', aux_attempts = 0, aux_next_at = now()
    where isrc = p_isrc;
    return;
  end if;

  select coalesce(array_agg(distinct a::uuid), '{}') into v_artists
  from jsonb_array_elements_text(coalesce(p_result->'artist_mbids', '[]')) a;

  update recordings
  set mbid = (p_result->>'mbid')::uuid,
      artist_mbids = v_artists,
      tags = array(select distinct lower(t) from jsonb_array_elements_text(coalesce(p_result->'tags', '[]')) t),
      status = 'found',
      match_source = 'isrc',
      looked_up_at = now(),
      attempts = attempts + 1,
      aux_step = case when p_result->>'mbid' is not null then 'lb_tags' else 'done' end,
      aux_attempts = 0,
      aux_next_at = now()
  where isrc = p_isrc;

  insert into mb_artists (mbid) select unnest(v_artists) on conflict do nothing;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.mb_save_search(p_isrc text, p_result jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_artists uuid[];
begin
  select coalesce(array_agg(distinct a::uuid), '{}') into v_artists
  from jsonb_array_elements_text(coalesce(p_result->'artist_mbids', '[]')) a;

  if p_result is null or cardinality(v_artists) = 0 then
    update recordings set aux_step = 'done' where isrc = p_isrc;
    return;
  end if;

  update recordings
  set mbid = (p_result->>'mbid')::uuid,
      artist_mbids = v_artists,
      tags = array(select distinct lower(t) from jsonb_array_elements_text(coalesce(p_result->'tags', '[]')) t),
      status = 'found',
      match_source = coalesce(p_result->>'source', 'search'),
      looked_up_at = now(),
      aux_step = case when p_result->>'mbid' is not null then 'lb_tags' else 'done' end,
      aux_attempts = 0,
      aux_next_at = now()
  where isrc = p_isrc;

  insert into mb_artists (mbid) select unnest(v_artists) on conflict do nothing;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.member_profile_candidate(p_arena_id uuid, p_exclude text[], p_avoid_proposer uuid, p_partner song_feature, p_ref song_feature, p_has_partner boolean, p_seed text)
 RETURNS TABLE(src_id uuid, spotify_track_id text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
  v_members uuid[];
  v_isrcs text[];
  v_ws real[];
  v_bucket real;
begin
  select array_agg(distinct pp.identity_anchor_id) into v_members
  from participant_presence pp
  join auth.users u on u.id = pp.identity_anchor_id and not u.is_anonymous
  where pp.arena_id = p_arena_id and pp.state in ('active', 'passive');
  if v_members is null then
    return;
  end if;

  select coalesce(array_agg(st.isrc), '{}'), coalesce(array_agg(st.w), '{}') into v_isrcs, v_ws
  from arena_style_songs(p_arena_id) st;
  select fit_bucket into v_bucket from system_song_config where id = 1;

  return query
  select c.src_id, c.spotify_track_id
  from (
    select distinct on (sig.isrc) sig.isrc, src.id as src_id, src.spotify_track_id
    from affinity_signals sig
    join songs src on src.isrc = sig.isrc and src.source = 'spotify' and src.role = 'competitor'
    where sig.user_id = any (v_members)
      and sig.arena_id is distinct from p_arena_id
    order by sig.isrc, src.created_at desc
  ) c
  where not (c.spotify_track_id = any (coalesce(p_exclude, '{}')))
    and not track_sounded_in_arena(p_arena_id, c.spotify_track_id, c.isrc)
    and not track_fought_in_arena(p_arena_id, c.spotify_track_id)
    and not exists (select 1 from queues q join songs qs on qs.id = q.song_id
                    where q.arena_id = p_arena_id and qs.spotify_track_id = c.spotify_track_id)
    and not exists (select 1 from battles b join songs bs on bs.id in (b.song_a_id, b.song_b_id)
                    where b.arena_id = p_arena_id
                      and (b.state <> 'completed'
                           or b.id = (select lb.id from battles lb where lb.arena_id = p_arena_id
                                      order by lb.created_at desc limit 1))
                      and bs.spotify_track_id = c.spotify_track_id)
    and (p_avoid_proposer is null
         or not exists (select 1 from songs ms join proposal_history h on h.song_id = ms.id
                        where ms.arena_id = p_arena_id and ms.spotify_track_id = c.spotify_track_id
                          and h.arena_id = p_arena_id and h.kind = 'proposal'
                          and h.proposed_by = p_avoid_proposer))
  order by floor(matchmaking_song_score(song_features(c.isrc), p_partner, p_ref, p_has_partner) / v_bucket) desc,
           floor(case when cardinality(v_isrcs) > 0 then song_set_score(v_isrcs, v_ws, c.isrc) end / v_bucket)
             desc nulls last,
           presence_taste(p_arena_id, c.isrc) desc nulls last,
           md5(c.isrc || p_seed)
  limit 1;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.merge_anonymous_user(p_from uuid, p_to uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
  v_to_participant uuid;
  v_moved int := 0;
  v_fused int := 0;
begin
  if p_from = p_to then
    raise exception 'same user';
  end if;
  if not exists (select 1 from auth.users where id = p_from and is_anonymous) then
    raise exception 'source is not an anonymous user';
  end if;
  if not exists (select 1 from auth.users where id = p_to and not is_anonymous) then
    raise exception 'target is not an account';
  end if;

  -- Hosting
  update arenas set host_id = p_to where host_id = p_from;
  update arena_playback set host_id = p_to where host_id = p_from;

  for r in select * from participants where identity_anchor_id = p_from loop
    select id into v_to_participant
    from participants where arena_id = r.arena_id and identity_anchor_id = p_to;

    if v_to_participant is null then
      update participants
      set identity_anchor_id = p_to,
          is_host = exists (select 1 from arenas a where a.id = r.arena_id and a.host_id = p_to)
      where id = r.id;
      v_moved := v_moved + 1;
    else
      -- Votes: one row per participant and battle; keep the most recent
      delete from votes v
      using votes w
      where v.battle_id = w.battle_id
        and ((v.participant_id = r.id and w.participant_id = v_to_participant and w.updated_at >= v.updated_at)
          or (v.participant_id = v_to_participant and w.participant_id = r.id and w.updated_at > v.updated_at));
      update votes set participant_id = v_to_participant where participant_id = r.id;

      delete from song_likes l
      where l.participant_id = r.id
        and exists (select 1 from song_likes k
                    where k.participant_id = v_to_participant and k.arena_id = l.arena_id and k.song_id = l.song_id);
      update song_likes set participant_id = v_to_participant where participant_id = r.id;

      delete from battle_presence_snapshots s
      where s.participant_id = r.id
        and exists (select 1 from battle_presence_snapshots k
                    where k.participant_id = v_to_participant and k.battle_id = s.battle_id);
      update battle_presence_snapshots set participant_id = v_to_participant where participant_id = r.id;

      update participants p
      set joined_at = least(p.joined_at, r.joined_at),
          last_active_at = greatest(p.last_active_at, r.last_active_at),
          last_seen_at = greatest(p.last_seen_at, r.last_seen_at),
          -- Still in the arena if either side was
          left_at = case when p.left_at is null or r.left_at is null then null
                         else greatest(p.left_at, r.left_at) end,
          disconnected_at = case when p.disconnected_at is null or r.disconnected_at is null then null
                                 else greatest(p.disconnected_at, r.disconnected_at) end,
          is_host = exists (select 1 from arenas a where a.id = r.arena_id and a.host_id = p_to)
      where p.id = v_to_participant;

      delete from participants where id = r.id;
      v_fused := v_fused + 1;
    end if;
  end loop;

  update votes set identity_anchor_id = p_to where identity_anchor_id = p_from;
  update battle_presence_snapshots set identity_anchor_id = p_to where identity_anchor_id = p_from;
  update queues set proposed_by = p_to where proposed_by = p_from;
  update proposal_history set proposed_by = p_to where proposed_by = p_from;

  -- Step 14: backings (one per song; none for a song the account proposed)
  delete from queue_backers a
  using queue_backers b
  where a.user_id = p_from and b.user_id = p_to and a.arena_id = b.arena_id and a.song_id = b.song_id;
  update queue_backers set user_id = p_to where user_id = p_from;
  delete from queue_backers k
  using queues q
  where k.user_id = p_to and q.arena_id = k.arena_id and q.song_id = k.song_id and q.proposed_by = p_to;

  -- Step 8: the anonymous in-arena profile becomes part of the account's
  delete from affinity_signals a
  using affinity_signals b
  where a.user_id = p_from and b.user_id = p_to
    and a.kind = b.kind and a.isrc = b.isrc and a.arena_id is not distinct from b.arena_id;
  update affinity_signals set user_id = p_to where user_id = p_from;

  -- Step 15: PI (same event on both sides = counted once), nickname/country
  -- only if the account has none, purged arenas' standings combined
  delete from pi_ledger a
  using pi_ledger b
  where a.user_id = p_from and b.user_id = p_to
    and a.battle_id is not distinct from b.battle_id
    and a.song_id is not distinct from b.song_id
    and a.reason = b.reason;
  update pi_ledger set user_id = p_to where user_id = p_from;

  if exists (select 1 from user_profiles where user_id = p_to) then
    update user_profiles t
    set nickname = coalesce(t.nickname, f.nickname),
        country = coalesce(t.country, f.country),
        updated_at = now()
    from user_profiles f
    where t.user_id = p_to and f.user_id = p_from;
    delete from user_profiles where user_id = p_from;
  else
    update user_profiles set user_id = p_to where user_id = p_from;
  end if;

  update arena_pi_standings t
  set pi = t.pi + f.pi
  from arena_pi_standings f
  where t.user_id = p_to and f.user_id = p_from and f.arena_id = t.arena_id;
  delete from arena_pi_standings f
  where f.user_id = p_from
    and exists (select 1 from arena_pi_standings t where t.user_id = p_to and t.arena_id = f.arena_id);
  update arena_pi_standings set user_id = p_to where user_id = p_from;

  delete from spotify_oauth_states where user_id = p_from;
  delete from account_merge_tickets where anon_user_id = p_from;

  return jsonb_build_object('arenas_moved', v_moved, 'arenas_fused', v_fused);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.mf_display_name(p_user uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce((select nickname from user_profiles where user_id = p_user), mf_generated_nickname(p_user));
$function$
;

CREATE OR REPLACE FUNCTION public.mf_generated_nickname(p_user uuid)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  with h as (select md5(p_user::text) as m),
  w as (
    select array['Neon','Electric','Cosmic','Golden','Turbo','Velvet','Midnight','Sonic','Crimson','Lunar',
                 'Atomic','Funky','Mystic','Solar','Wild','Silver','Hyper','Groovy','Retro','Thunder',
                 'Shadow','Crystal','Blazing','Stellar','Rocket','Jazzy','Laser','Mighty','Lucky','Royal',
                 'Pixel','Rebel'] as adj,
           array['Falcon','Tiger','Panda','Comet','Wolf','Fox','Phoenix','Dragon','Shark','Lynx',
                 'Raven','Cobra','Otter','Koala','Jaguar','Mantis','Orca','Bison','Gecko','Hawk',
                 'Lion','Owl','Puma','Rhino','Yak','Zebra','Badger','Beetle','Dolphin','Moose',
                 'Parrot','Viper'] as noun
  )
  select w.adj[1 + ('x' || substr(h.m, 1, 6))::bit(24)::int % 32] || ' ' ||
         w.noun[1 + ('x' || substr(h.m, 7, 6))::bit(24)::int % 32] || ' ' ||
         (('x' || substr(h.m, 13, 6))::bit(24)::int % 100)::text
  from h, w;
$function$
;

CREATE OR REPLACE FUNCTION public.normalize_isrc(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case when upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) ~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$'
              then upper(regexp_replace(p, '[^A-Za-z0-9]', '', 'g')) end;
$function$
;

CREATE OR REPLACE FUNCTION public.nudge_on_battle_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform nudge_spotify_host(new.arena_id);
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.nudge_on_playlist_insert()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform nudge_spotify_host(x.arena_id) from (select distinct arena_id from new_rows) x;
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.nudge_spotify_host(p_arena_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.passive_vote_candidates(p_battle_id uuid, p_live boolean DEFAULT false)
 RETURNS TABLE(participant_id uuid, identity_anchor_id uuid, song_id uuid, weight real)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
declare
  c passive_vote_config;
  b battles;
  v_isrc_a text;
  v_isrc_b text;
  v_present int;
  v_passive int;
  v_base real;
  v_active real;
  v_total real;
  v_factor real := 1;
  r record;
  v_sa real;
  v_sb real;
  v_best real;
  v_parts uuid[] := '{}';
  v_anchors uuid[] := '{}';
  v_songs uuid[] := '{}';
  v_weights real[] := '{}';
  v_e_pids uuid[];
  v_e_anchors uuid[];
  v_e_states text[];
begin
  select * into c from passive_vote_config where id = 1;
  select * into b from battles where id = p_battle_id;
  if not found then
    return;
  end if;
  select isrc into v_isrc_a from songs where id = b.song_a_id;
  select isrc into v_isrc_b from songs where id = b.song_b_id;

  -- Everyone still in the arena: their presence state now (live preview) or
  -- frozen at lock-in, filtered by "not gone" (left / closed the app)
  select coalesce(array_agg(x.pid), '{}'), coalesce(array_agg(x.anchor), '{}'), coalesce(array_agg(x.state), '{}')
  into v_e_pids, v_e_anchors, v_e_states
  from (
    select pp.participant_id as pid, pp.identity_anchor_id as anchor, pp.state
    from participant_presence pp where p_live and pp.arena_id = b.arena_id
    union all
    select s.participant_id, s.identity_anchor_id, s.state
    from battle_presence_snapshots s where not p_live and s.battle_id = b.id
  ) x
  join participants p on p.id = x.pid
  where p.left_at is null
    and not (p.disconnected_at is not null and (p.last_seen_at is null or p.disconnected_at >= p.last_seen_at));

  v_present := cardinality(v_e_pids);
  select count(*) into v_passive from unnest(v_e_states) st where st <> 'active';
  v_base := case when v_present > 0 and v_passive >= c.boost_passive_ratio * v_present
                 then c.boosted_value else c.base_value end;

  for r in
    select e.pid, e.anchor from unnest(v_e_pids, v_e_anchors) as e(pid, anchor)
    -- No votes row at all: a cancelled vote means the user abstained
    where not exists (select 1 from votes v where v.battle_id = b.id and v.participant_id = e.pid)
  loop
    v_sa := coalesce(affinity_score(r.anchor, v_isrc_a, b.arena_id), 0);
    v_sb := coalesce(affinity_score(r.anchor, v_isrc_b, b.arena_id), 0);
    v_best := greatest(v_sa, v_sb);
    continue when v_best < c.min_score or v_sa = v_sb;
    v_parts := v_parts || r.pid;
    v_anchors := v_anchors || r.anchor;
    v_songs := v_songs || case when v_sa > v_sb then b.song_a_id else b.song_b_id end;
    v_weights := v_weights || (v_base + (v_best - c.min_score) / (1 - c.min_score) * c.value_span)::real;
  end loop;

  if cardinality(v_parts) = 0 then
    return;
  end if;

  -- k cap against the active points; no cap when nobody voted
  select coalesce(sum(v.weight), 0) into v_active
  from votes v where v.battle_id = b.id and v.status = 'active' and v.vote_type = 'regular';
  select sum(w) into v_total from unnest(v_weights) w;
  if v_active > 0 and v_total > c.k_cap * v_active then
    v_factor := c.k_cap * v_active / v_total;
  end if;

  return query
  select u.p, u.a, u.s, trunc((u.w * v_factor)::numeric, 3)::real
  from unnest(v_parts, v_anchors, v_songs, v_weights) as u(p, a, s, w);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pause_arena(p_arena_id uuid, p_reason text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update arenas
  set paused_at = now(), pause_reason = p_reason, updated_at = now()
  where id = p_arena_id and state = 'active' and paused_at is null;
$function$
;

CREATE OR REPLACE FUNCTION public.pi_on_battle_completed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c pi_config;
  v_sd boolean := new.sudden_death_started_at is not null;
  v_songs uuid[];
  v_reason text;
  v_base integer;
  r record;
begin
  if new.resolution_type is null or new.resolution_type not in ('normal', 'sudden_death', 'draw') then
    return null;  -- cancelled: nothing (battle_entry stays)
  end if;
  select * into c from pi_config where id;

  if new.resolution_type = 'draw' then
    v_songs := array[new.song_a_id, new.song_b_id];
    v_reason := 'tie';
    v_base := c.tie;
  else
    if new.winner_song_id is null then
      return null;
    end if;
    v_songs := array[new.winner_song_id];
    v_reason := 'win';
    v_base := c.win;
  end if;

  -- Original proposers (system songs have none), whether or not they voted,
  -- when someone else voted in this battle
  for r in
    select distinct h.proposed_by, h.song_id
    from proposal_history h
    where h.battle_id = new.id and h.kind = 'proposal' and h.outcome = 'battled'
      and h.proposed_by is not null and h.song_id = any (v_songs)
      and exists (select 1 from votes o
                  where o.battle_id = new.id and o.status = 'active' and o.vote_type <> 'passive'
                    and o.identity_anchor_id <> h.proposed_by)
  loop
    perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, v_reason, v_base);
    if v_sd then
      perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, 'sudden_death_bonus', c.sudden_death_bonus);
    end if;
  end loop;

  -- Backers: pre-assigned at the start, still their counted vote at the end,
  -- and someone else voted too. Duplicate proposals only: a list vote gives
  -- influence, not PI (user, 2026-11-06)
  for r in
    select distinct h.proposed_by, h.song_id
    from proposal_history h
    where h.battle_id = new.id and h.kind = 'backing' and h.vote_preassigned
      and coalesce(h.backing_source, 'duplicate') = 'duplicate'
      and h.proposed_by is not null and h.song_id = any (v_songs)
      and exists (select 1 from votes v
                  where v.battle_id = new.id and v.identity_anchor_id = h.proposed_by
                    and v.song_id = h.song_id and v.status = 'active' and v.vote_type <> 'passive'
                    and (new.sudden_death_started_at is null or v.vote_type = 'sudden_death'))
      and exists (select 1 from votes o
                  where o.battle_id = new.id and o.status = 'active' and o.vote_type <> 'passive'
                    and o.identity_anchor_id <> h.proposed_by)
  loop
    perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, 'duplicate_half',
                     round((v_base + case when v_sd then c.sudden_death_bonus else 0 end) * c.backing_share)::integer);
  end loop;

  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pi_on_battle_created()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c pi_config;
  v_started timestamptz;
  r record;
begin
  select * into c from pi_config where id;
  -- Alone (or almost): no +1
  if (select count(distinct pp.identity_anchor_id) from participant_presence pp
      where pp.arena_id = new.arena_id and pp.state in ('active', 'passive')) < c.entry_min_present then
    return null;
  end if;
  select started_at into v_started from arenas where id = new.arena_id;

  for r in
    select distinct h.proposed_by, h.song_id
    from proposal_history h
    where h.battle_id = new.id and h.kind = 'proposal' and h.outcome = 'battled' and h.proposed_by is not null
      -- proposed after Start, not in the lobby
      and v_started is not null and h.proposed_at >= v_started
  loop
    perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, 'battle_entry', c.battle_entry);
  end loop;
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pick_fallback_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid DEFAULT NULL::uuid, p_partner_isrc text DEFAULT NULL::text, p_ref_isrc text DEFAULT NULL::text, p_has_partner boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c record;
  v_song uuid;
begin
  select * into c
  from fallback_candidate(p_arena_id, p_exclude, p_last_battle, p_avoid_proposer, p_partner_isrc, p_ref_isrc, p_has_partner);
  if c.src_song_id is null then
    return null;
  end if;
  if c.song_id is not null then
    return c.song_id;
  end if;
  insert into songs (arena_id, source, spotify_track_id, title, artist, duration_ms, status, artwork_url, isrc)
  select p_arena_id, 'spotify', s.spotify_track_id, s.title, s.artist, s.duration_ms, 'active', s.artwork_url, s.isrc
  from songs s where s.id = c.src_song_id
  returning id into v_song;
  return v_song;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.pick_rematch_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid DEFAULT NULL::uuid, p_partner song_feature DEFAULT NULL::song_feature, p_ref song_feature DEFAULT NULL::song_feature, p_has_partner boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select x.id from (
    select s.id, s.isrc, max(b.created_at) as last_fought
    from songs s
    join battles b on b.arena_id = p_arena_id
                  and b.state = 'completed'
                  and b.resolution_type in ('normal', 'sudden_death', 'fit')
                  and s.id in (b.song_a_id, b.song_b_id)
                  and s.id <> b.winner_song_id
    where s.arena_id = p_arena_id
      and s.role = 'competitor'
      and s.status = 'active'
      and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
      and not exists (select 1 from battles lb where lb.id = p_last_battle and s.id in (lb.song_a_id, lb.song_b_id))
      and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = s.id)
      and not track_sounded_in_arena(p_arena_id, s.spotify_track_id, s.isrc)
      -- Only once (2026-10-30)
      and (select count(*) from battles b2
           where b2.arena_id = p_arena_id and s.id in (b2.song_a_id, b2.song_b_id)
             and b2.resolution_type is distinct from 'cancelled') < 2
      and (p_avoid_proposer is null
           or not exists (select 1 from proposal_history h
                          where h.arena_id = p_arena_id and h.song_id = s.id
                            and h.kind = 'proposal' and h.proposed_by = p_avoid_proposer))
    group by s.id, s.isrc
  ) x
  order by floor(matchmaking_song_score(song_features(x.isrc), p_partner, p_ref, p_has_partner)
                 / (select fit_bucket from system_song_config where id = 1)) desc,
           x.last_fought, md5(x.id::text || coalesce(p_last_battle::text, ''))
  limit 1;
$function$
;

CREATE OR REPLACE FUNCTION public.prepare_reserve(p_arena_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c system_song_config;
  v_host uuid;
  v_gone uuid;
  v_pool record;
  v_worst uuid;
  v_song uuid;
begin
  select * into c from system_song_config where id = 1;
  select host_id into v_host from arenas where id = p_arena_id;

  perform release_dead_system_votes(p_arena_id);

  -- Guests no longer lending: left, not a member, host now, or no Spotify
  for v_gone in
    select lc.user_id from arena_library_contributors lc
    where lc.arena_id = p_arena_id
      and (lc.user_id = v_host
           or not exists (select 1 from participants p
                          where p.arena_id = p_arena_id and p.identity_anchor_id = lc.user_id and p.left_at is null)
           or not exists (select 1 from streaming_accounts sa where sa.host_id = lc.user_id))
  loop
    perform set_library_contribution(p_arena_id, v_gone, false);
  end loop;
  -- Rows of a guest whose switch is gone (e.g. account deleted mid-way)
  for v_gone in
    select distinct r.contributed_by from arena_song_reserve r
    where r.arena_id = p_arena_id and r.contributed_by is not null
      and not exists (select 1 from arena_library_contributors lc
                      where lc.arena_id = p_arena_id and lc.user_id = r.contributed_by)
  loop
    perform drop_reserve_rows(p_arena_id, v_gone);
  end loop;

  -- Step 20: a song that already sounded here never comes back as a system song
  for v_song in
    delete from arena_song_reserve r
    using songs s
    where r.arena_id = p_arena_id and s.id = r.song_id
      and (track_sounded_in_arena(p_arena_id, s.spotify_track_id, s.isrc)
           or track_fought_in_arena(p_arena_id, s.spotify_track_id))
    returning r.song_id
  loop
    perform delete_song_if_unused(v_song);
  end loop;

  perform score_arena_reserve(p_arena_id);

  -- Rotation of full library pools: the worst old song makes room for a new one
  for v_pool in
    select r.source, r.contributed_by
    from arena_song_reserve r
    where r.arena_id = p_arena_id and r.source in ('host_library', 'guest_library')
    group by r.source, r.contributed_by
    having count(*) >= case when r.source = 'host_library' then c.host_library_pool else c.guest_library_pool end
       and max(r.created_at) < now() - make_interval(mins => c.rotate_every_minutes)
  loop
    select r.id into v_worst
    from arena_song_reserve r
    where r.arena_id = p_arena_id and r.source = v_pool.source
      and r.contributed_by is not distinct from v_pool.contributed_by
      and r.created_at < now() - make_interval(mins => c.rotate_min_age_minutes)
      -- A song people voted for stays
      and not exists (select 1 from queue_backers k where k.arena_id = r.arena_id and k.song_id = r.song_id)
    order by r.fit is not null, floor(r.fit / c.fit_bucket), r.taste nulls first, r.created_at
    limit 1;
    if v_worst is not null then
      delete from arena_song_reserve where id = v_worst returning song_id into v_song;
      perform delete_song_if_unused(v_song);
    end if;
  end loop;

  return jsonb_build_object(
    'host_library', greatest(0, c.host_library_pool - (select count(*) from arena_song_reserve where arena_id = p_arena_id and source = 'host_library')),
    'arena_artist', greatest(0, c.arena_artist_pool - (select count(*) from arena_song_reserve where arena_id = p_arena_id and source = 'arena_artist')),
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
    ), '[]'::jsonb),
    -- Step 20: the arena's related artists (MusicBrainz relations +
    -- ListenBrainz similar artists of its style songs' artists), also searched
    'related_artists', coalesce((
      select jsonb_agg(x.name) from (
        select distinct ra.name
        from arena_style_songs(p_arena_id) st
        join recordings rc on rc.isrc = st.isrc
        join mb_artists aa on aa.mbid = any (rc.artist_mbids)
        join mb_artists ra on ra.mbid = any (coalesce(aa.related_mbids, '{}') || coalesce(aa.lb_similar, '{}'))
        where ra.name is not null and not (ra.mbid = any (rc.artist_mbids))
        limit 40
      ) x
    ), '[]'::jsonb),
    'guests', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', lc.user_id, 'need', g.need))
      from arena_library_contributors lc
      cross join lateral (
        select greatest(0, c.guest_library_pool - (select count(*) from arena_song_reserve r
                                                   where r.arena_id = p_arena_id and r.contributed_by = lc.user_id)) as need
      ) g
      where lc.arena_id = p_arena_id and g.need > 0
    ), '[]'::jsonb)
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.presence_disconnect()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update participants
  set disconnected_at = now()
  where id = (
    select p.id from participants p
    join arenas a on a.id = p.arena_id
    where p.identity_anchor_id = auth.uid()
      and p.left_at is null
      and a.state in ('waiting', 'active')
    order by p.joined_at desc
    limit 1);
$function$
;

CREATE OR REPLACE FUNCTION public.presence_heartbeat()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update participants
  set last_seen_at = now(),
      disconnected_at = null
  where id = (
    select p.id from participants p
    join arenas a on a.id = p.arena_id
    where p.identity_anchor_id = auth.uid()
      and p.left_at is null
      and a.state in ('waiting', 'active')
    order by p.joined_at desc
    limit 1);
$function$
;

CREATE OR REPLACE FUNCTION public.presence_state(p_last_active_at timestamp with time zone, p_last_seen_at timestamp with time zone, p_disconnected_at timestamp with time zone, p_left_at timestamp with time zone, p_arena_state text, p_at timestamp with time zone DEFAULT now())
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case
    when p_arena_state is distinct from 'waiting' and p_arena_state is distinct from 'active'
      then 'inactive'
    when p_left_at is not null then 'inactive'
    -- connection: heartbeat grace and explicit disconnect
    when p_last_seen_at is null or p_last_seen_at < p_at - interval '10 minutes' then 'inactive'
    when p_disconnected_at is not null and p_disconnected_at >= p_last_seen_at then 'inactive'
    -- activity window
    when p_last_active_at >= p_at - interval '5 minutes' then 'active'
    else 'passive'
  end;
$function$
;

CREATE OR REPLACE FUNCTION public.presence_taste(p_arena_id uuid, p_isrc text)
 RETURNS real
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select avg(x.score)::real
  from (
    select affinity_score(pp.identity_anchor_id, p_isrc, p_arena_id) as score
    from participant_presence pp
    where pp.arena_id = p_arena_id and pp.state in ('active', 'passive')
  ) x
  where x.score is not null;
$function$
;

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

        -- Step 20 (user decision 2026-11-01): nobody voted, not even
        -- passively -> no Sudden Death and no draw: the song that fits the
        -- arena best wins (arena_fit_winner)
        if not exists (select 1 from votes where battle_id = v_battle.id and status = 'active') then
            v_winner := arena_fit_winner(v_battle.id);

            insert into playlist_queue (arena_id, battle_id, winner_song_id, spotify_track_id, song_duration_ms, created_at)
            select v_battle.arena_id, v_battle.id, s.id, s.spotify_track_id, s.duration_ms, v_now
            from songs s where s.id = v_winner;

            update battles
            set state = 'closing',
                lockin_at = v_lockin_at,
                winner_song_id = v_winner,
                resolution_type = 'fit'
            where id = v_battle.id;

            return;
        end if;

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
$function$
;

CREATE OR REPLACE FUNCTION public.pull_next_battle_songs(p_arena_id uuid)
 RETURNS TABLE(song_a uuid, song_b uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_last uuid;
  v_ref uuid;
  v_ref_isrc text;
  v_plan jsonb;
  v_a_row uuid;
  v_a_song uuid;
  v_a_by uuid;
  v_a_track text;
  v_a_isrc text;
  v_b_row uuid;
  v_b_song uuid;
  v_b_track text;
  v_forced boolean := false;
  v_b_forced boolean;
  v_score real;
  v_max_turn int;
  v_log uuid;
  v_ref_f public.song_feature;
  v_a_f public.song_feature;
  v_b_f public.song_feature;
  v_purged uuid[];
begin
  perform lock_arena_queue(p_arena_id);

  -- Votes for a system song that can no longer fight go back to their owners
  perform release_dead_system_votes(p_arena_id);

  select id into v_last from battles where arena_id = p_arena_id order by created_at desc limit 1;

  perform refill_active_queue(p_arena_id);

  -- Step 17: the best pair of the next 10 (matchmaking_plan pair 1)
  v_ref := matchmaking_ref_song(p_arena_id);
  select isrc into v_ref_isrc from songs where id = v_ref;
  select coalesce(jsonb_agg(to_jsonb(p) order by p.pos), '[]') into v_plan from matchmaking_plan(p_arena_id) p;

  select (e->>'queue_id')::uuid, (e->>'song_id')::uuid, (e->>'proposed_by')::uuid,
         coalesce((e->>'forced')::boolean, false), (e->>'score')::real
  into v_a_row, v_a_song, v_a_by, v_forced, v_score
  from jsonb_array_elements(v_plan) e where (e->>'pair_no')::int = 1 order by (e->>'pos')::int limit 1;

  select (e->>'queue_id')::uuid, (e->>'song_id')::uuid, coalesce((e->>'forced')::boolean, false)
  into v_b_row, v_b_song, v_b_forced
  from jsonb_array_elements(v_plan) e where (e->>'pair_no')::int = 1 order by (e->>'pos')::int offset 1 limit 1;
  v_forced := coalesce(v_forced, false) or coalesce(v_b_forced, false);

  select spotify_track_id, isrc into v_a_track, v_a_isrc from songs where id = v_a_song;
  select spotify_track_id into v_b_track from songs where id = v_b_song;

  -- Missing slots: revancha -> host's source -> arena artists -> member
  -- profiles -> purged/withdrawn, never a song originally proposed by the
  -- other slot's proposer; compatible with the other song and the ref
  if v_a_song is null then
    v_a_song := pick_fallback_song(p_arena_id, array_remove(array[v_b_track], null), v_last,
                                   null, null, v_ref_isrc, false);
    select spotify_track_id, isrc into v_a_track, v_a_isrc from songs where id = v_a_song;
    v_a_by := song_original_proposer(p_arena_id, v_a_song);
  end if;
  if v_b_song is null then
    v_b_song := pick_fallback_song(p_arena_id, array_remove(array[v_a_track], null), v_last, v_a_by,
                                   v_a_isrc, v_ref_isrc, v_a_song is not null);
  end if;

  -- No pair: nothing changes, the arena waits
  if v_a_song is null or v_b_song is null then
    return;
  end if;

  -- Skips: songs of the next 10 with a better turn than a picked one
  select max((e->>'turn')::int) into v_max_turn
  from jsonb_array_elements(v_plan) e where (e->>'queue_id')::uuid in (v_a_row, v_b_row);
  if v_max_turn is not null then
    update queues set times_skipped = times_skipped + 1, updated_at = now()
    where id in (select (e->>'queue_id')::uuid from jsonb_array_elements(v_plan) e
                 where (e->>'turn')::int < v_max_turn)
      and id not in (v_a_row, v_b_row);
  end if;

  -- Log (Block_4 §10); create_next_battle links the battle
  v_ref_f := song_features(v_ref_isrc);
  v_a_f := song_features(v_a_isrc);
  v_b_f := song_features((select isrc from songs where id = v_b_song));
  insert into matchmaking_log (arena_id, ref_song_id, song_a_id, song_b_id, a_source, b_source, forced, score,
                               components, candidates)
  values (p_arena_id, v_ref, v_a_song, v_b_song,
          case when v_a_row is null then 'system' else 'queue' end,
          case when v_b_row is null then 'system' else 'queue' end,
          v_forced, v_score,
          -- NULL = unknown (counted as neutral_compat)
          jsonb_build_object('a_ref', song_compat(v_a_f, v_ref_f), 'b_ref', song_compat(v_b_f, v_ref_f),
                             'a_b', song_compat(v_a_f, v_b_f)),
          v_plan)
  returning id into v_log;
  perform set_config('mf.matchmaking_log', v_log::text, true);
  delete from matchmaking_log
  where created_at < now() - make_interval(days => (select log_retention_days from matchmaking_config where id = 1));

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
  ), hist as (
    insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome)
    select arena_id, song_id, proposed_by, created_at, 'purged'
    from purged where proposed_by is not null
  )
  select array_agg(song_id) into v_purged from purged;

  -- Step 14: their backings go with them
  perform drop_queue_backers(p_arena_id, v_purged, 'purged');

  perform refill_active_queue(p_arena_id);

  return query select v_a_song, v_b_song;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.purge_old_arena_votes(p_retention interval DEFAULT '30 days'::interval)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_count integer := 0;
  r record;
begin
  for r in
    select id from arenas
    where state in ('finished', 'expired')
      and votes_purged_at is null
      and coalesce(ended_at, updated_at) < now() - p_retention
  loop
    update battles b
    set final_votes_a = c.va, final_votes_b = c.vb,
        final_passive_a = c.pa, final_passive_b = c.pb
    from (
      select b2.id,
        count(v.id) filter (where v.song_id = b2.song_a_id and v.status = 'active' and v.vote_type <> 'passive'
          and (b2.sudden_death_started_at is null or v.vote_type = 'sudden_death'))::int as va,
        count(v.id) filter (where v.song_id = b2.song_b_id and v.status = 'active' and v.vote_type <> 'passive'
          and (b2.sudden_death_started_at is null or v.vote_type = 'sudden_death'))::int as vb,
        coalesce(sum(v.weight) filter (where v.song_id = b2.song_a_id and v.status = 'active' and v.vote_type = 'passive'), 0)::real as pa,
        coalesce(sum(v.weight) filter (where v.song_id = b2.song_b_id and v.status = 'active' and v.vote_type = 'passive'), 0)::real as pb
      from battles b2
      left join votes v on v.battle_id = b2.id
      where b2.arena_id = r.id
      group by b2.id
    ) c
    where b.id = c.id;

    delete from votes v using battles b
    where v.battle_id = b.id and b.arena_id = r.id;

    delete from battle_presence_snapshots where arena_id = r.id;
    delete from proposal_history where arena_id = r.id;
    delete from queue_backers where arena_id = r.id;  -- Step 14

    -- Anonymous users' in-arena profile goes with the votes; accounts keep theirs
    delete from affinity_signals s
    using auth.users u
    where s.arena_id = r.id and u.id = s.user_id and u.is_anonymous;

    -- Step 15: the arena's final ranking stays; anonymous PI rows go
    delete from arena_pi_standings where arena_id = r.id;
    insert into arena_pi_standings (arena_id, user_id, display_name, pi)
    select r.id, x.uid, mf_display_name(x.uid), x.pi
    from (
      select p.identity_anchor_id as uid,
             greatest(0, coalesce((select sum(l.delta) from pi_ledger l
                                   where l.arena_id = r.id and l.user_id = p.identity_anchor_id), 0))::int as pi
      from participants p
      where p.arena_id = r.id
        and exists (select 1 from auth.users u where u.id = p.identity_anchor_id)
      group by p.identity_anchor_id
    ) x;
    delete from pi_ledger l
    using auth.users u
    where l.arena_id = r.id and u.id = l.user_id and u.is_anonymous;

    update arenas set votes_purged_at = now() where id = r.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.queue_ranked(p_arena_id uuid)
 RETURNS TABLE(id uuid, song_id uuid, proposed_by uuid, queue_type text, battles_waited integer, created_at timestamp with time zone, rank_in_list bigint, global_rank bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with battled as (
    select h.proposed_by, count(*) as n
    from proposal_history h
    where h.arena_id = p_arena_id and h.outcome = 'battled' and h.kind = 'proposal'  -- Step 14
    group by h.proposed_by
  ),
  q as (
    select q.*, q.proposed_by is null as is_system,
           coalesce(b.n, 0) + row_number() over (partition by q.proposed_by order by q.created_at, q.id) as turn
    from queues q
    left join battled b on b.proposed_by = q.proposed_by
    where q.arena_id = p_arena_id
  )
  select q.id, q.song_id, q.proposed_by, q.queue_type, q.battles_waited, q.created_at,
         row_number() over (partition by q.queue_type order by q.is_system, q.turn, q.created_at, q.id),
         row_number() over (order by q.queue_type = 'waiting', q.is_system, q.turn, q.created_at, q.id)
  from q;
$function$
;

CREATE OR REPLACE FUNCTION public.queue_recording_lookup()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.isrc is not null then
    insert into recordings (isrc) values (new.isrc) on conflict do nothing;
  end if;
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_affinity_signal(p_user uuid, p_song uuid, p_kind text, p_arena uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_isrc text;
  v_weight real;
begin
  select isrc into v_isrc from songs where id = p_song;
  if v_isrc is null or p_user is null or not exists (select 1 from auth.users where id = p_user) then
    return;
  end if;
  select case p_kind when 'like' then weight_like when 'proposal' then weight_proposal else weight_vote end
  into v_weight from passive_vote_config where id = 1;

  insert into affinity_signals (user_id, isrc, kind, arena_id, weight)
  values (p_user, v_isrc, p_kind, p_arena, v_weight)
  on conflict on constraint affinity_signals_unique
  do update set created_at = now(), weight = excluded.weight;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_privacy_consent(p_version text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null or coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'sign in first';
  end if;
  insert into privacy_consents (user_id, policy_version)
  values (auth.uid(), left(p_version, 20))
  on conflict (user_id) do update set policy_version = excluded.policy_version, accepted_at = now();
end;
$function$
;

CREATE OR REPLACE FUNCTION public.refill_active_queue(p_arena_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_free integer;
begin
  select 10 - count(*) into v_free from queues where arena_id = p_arena_id and queue_type = 'active';
  if v_free <= 0 then
    return;
  end if;

  update queues
  set queue_type = 'active', updated_at = now()
  where id in (
    select r.id from queue_ranked(p_arena_id) r
    where r.queue_type = 'waiting'
    order by r.rank_in_list
    limit v_free
  );
end;
$function$
;

CREATE OR REPLACE FUNCTION public.reject_warmup_song()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if tg_table_name = 'queues' then
    if exists (select 1 from songs where id = new.song_id and role = 'warmup') then
      raise exception 'the warm-up song cannot be queued' using errcode = '23514';
    end if;
  else
    if exists (
      select 1 from songs
      where id in (new.song_a_id, new.song_b_id, new.winner_song_id)
        and role = 'warmup'
    ) then
      raise exception 'the warm-up song cannot compete' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.release_dead_system_votes(p_arena_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_songs uuid[];
begin
  select array_agg(distinct k.song_id) into v_songs
  from queue_backers k
  where k.arena_id = p_arena_id and k.source = 'list'
    and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = k.song_id)
    and not system_song_votable(p_arena_id, k.song_id);
  if v_songs is not null then
    perform drop_queue_backers(p_arena_id, v_songs, 'purged');
  end if;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.release_playlist_appends(p_ids uuid[])
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update playlist_queue set added_to_playlist_at = null where id = any (p_ids);
$function$
;

CREATE OR REPLACE FUNCTION public.resolve_vote_token(p_token text, p_side text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b battles;
  a arenas;
  v_song uuid;
begin
  if auth.uid() is null or p_side is null or lower(p_side) not in ('a', 'b') then
    return jsonb_build_object('status', 'invalid');
  end if;
  select * into b from battles where vote_token = p_token;
  if b.id is null then
    return jsonb_build_object('status', 'invalid');
  end if;
  select * into a from arenas where id = b.arena_id;
  if a.id is null or a.state = 'expired' then
    return jsonb_build_object('status', 'invalid');
  end if;
  v_song := case lower(p_side) when 'a' then b.song_a_id else b.song_b_id end;

  return jsonb_build_object(
    'status', case
      when a.state <> 'active' then 'finished'
      when b.state = 'completed' then 'over'
      when a.paused_at is not null then 'paused'
      when b.sudden_death_active then 'sudden_death'
      when b.lockin_at is not null then 'locked'
      else 'open' end,
    'arena_id', a.id,
    'arena_code', a.arena_code,
    'battle_id', b.id,
    'song_id', v_song,
    'title', (select s.title from songs s where s.id = v_song));
end;
$function$
;

CREATE OR REPLACE FUNCTION public.resume_arena(p_arena_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.score_arena_reserve(p_arena_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_isrcs text[];
  v_ws real[];
begin
  select coalesce(array_agg(isrc), '{}'), coalesce(array_agg(w), '{}') into v_isrcs, v_ws
  from arena_style_songs(p_arena_id);

  update arena_song_reserve r
  set fit = case when cardinality(v_isrcs) > 0 then song_set_score(v_isrcs, v_ws, s.isrc) end,
      taste = presence_taste(p_arena_id, s.isrc),
      scored_at = now()
  from songs s
  where s.id = r.song_id and r.arena_id = p_arena_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_arena_control_mode(p_arena_id uuid, p_mode text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  perform log_playback_event(p_arena_id, 'control_mode', jsonb_build_object('mode', p_mode));
  return p_mode;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.set_library_contribution(p_arena_id uuid, p_user_id uuid, p_enabled boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if p_enabled then
    insert into arena_library_contributors (arena_id, user_id) values (p_arena_id, p_user_id)
    on conflict do nothing;
  else
    delete from arena_library_contributors where arena_id = p_arena_id and user_id = p_user_id;
    perform drop_reserve_rows(p_arena_id, p_user_id);
  end if;
  return p_enabled;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.shift_open_battle(p_battle_id uuid, p_shift interval, p_warmup boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.signal_on_battle_completed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  r record;
begin
  for r in
    select v.identity_anchor_id, v.song_id
    from votes v
    where v.battle_id = new.id and v.status = 'active' and v.vote_type <> 'passive'
  loop
    perform record_affinity_signal(r.identity_anchor_id, r.song_id, 'vote', new.arena_id);
  end loop;
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.signal_on_proposal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.proposed_by is not null then
    perform record_affinity_signal(new.proposed_by, new.song_id, 'proposal', new.arena_id);
  end if;
  return null;
end;
$function$
;

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
$function$
;

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
$function$
;

CREATE OR REPLACE FUNCTION public.snapshot_battle_presence(p_battle_id uuid, p_arena_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  insert into battle_presence_snapshots (battle_id, participant_id, arena_id, identity_anchor_id, state, last_active_at)
  select p_battle_id, pp.participant_id, pp.arena_id, pp.identity_anchor_id, pp.state, pp.last_active_at
  from participant_presence pp
  where pp.arena_id = p_arena_id
  on conflict (battle_id, participant_id) do nothing;
$function$
;

CREATE OR REPLACE FUNCTION public.snapshot_presence_at_lockin()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform snapshot_battle_presence(new.id, new.arena_id);
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.song_compat(a song_feature, b song_feature)
 RETURNS real
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c passive_vote_config;
  v_score real := 0;
  v_overlap int;
begin
  if a is null or b is null or a.artists is null or b.artists is null then
    return null;
  end if;
  select * into c from passive_vote_config where id = 1;

  if a.isrc = b.isrc then
    return c.score_same_song;
  end if;
  if a.artists && b.artists then
    return c.score_same_artist;
  end if;
  if a.artists && b.neighbours or b.artists && a.neighbours then
    v_score := c.score_related_artist;
  end if;

  if cardinality(a.tags) > 0 and cardinality(b.tags) > 0 then
    select count(*) into v_overlap from unnest(a.tags) t where t = any (b.tags);
    -- At least 3 in the denominator: one shared tag is weak evidence
    v_score := greatest(v_score,
      least(c.score_tags_cap, v_overlap::real / greatest(least(cardinality(a.tags), cardinality(b.tags)), 3)));
  elsif v_score = 0 then
    -- No genres to compare and no artist link: unknown, not incompatible
    -- (a known artist without genres scored 0 against everything, 2026-10-30)
    return null;
  end if;
  return v_score;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.song_features(p_isrc text)
 RETURNS song_feature
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select row(
    r.isrc,
    r.artist_mbids,
    coalesce((select array_agg(distinct x)
              from mb_artists a, unnest(a.related_mbids || a.lb_similar) x
              where a.mbid = any (r.artist_mbids) and a.status = 'found'), '{}'),
    -- MusicBrainz genres only: folksonomy ("billboard hot 100", "5+ wochen",
    -- "boastful") made false matches (2026-10-30)
    coalesce((select array_agg(distinct t)
              from (select unnest(r.tags || r.lb_tags) t
                    union
                    select unnest(a.tags) from mb_artists a
                    where a.mbid = any (r.artist_mbids) and a.status = 'found') x
              where exists (select 1 from mb_genres g where g.name = x.t)
                 or not exists (select 1 from mb_genres)), '{}')
  )::song_feature
  from recordings r
  where r.isrc = p_isrc and r.status = 'found' and cardinality(r.artist_mbids) > 0;
$function$
;

CREATE OR REPLACE FUNCTION public.song_original_proposer(p_arena_id uuid, p_song_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    (select q.proposed_by from queues q
     where q.arena_id = p_arena_id and q.song_id = p_song_id and q.proposed_by is not null
     limit 1),
    (select h.proposed_by from proposal_history h
     where h.arena_id = p_arena_id and h.song_id = p_song_id and h.kind = 'proposal' and h.proposed_by is not null
     order by h.ended_at desc nulls last
     limit 1));
$function$
;

CREATE OR REPLACE FUNCTION public.song_set_score(p_isrcs text[], p_ws real[], p_isrc text)
 RETURNS real
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  c passive_vote_config;
  v_target recordings;
  v_target_related uuid[];
  v_target_tags text[];
  v_user_tags text[];
  v_overlap int;
  v_score real := 0;
begin
  if p_isrc is null then
    return null;
  end if;
  select * into c from passive_vote_config where id = 1;

  -- Same song
  if p_isrc = any (p_isrcs) then
    return c.score_same_song;
  end if;

  select * into v_target from recordings where isrc = p_isrc and status = 'found';
  if not found then
    return null;
  end if;

  -- Same artist
  if exists (select 1 from recordings r
             where r.isrc = any (p_isrcs) and r.status = 'found' and r.artist_mbids && v_target.artist_mbids) then
    return c.score_same_artist;
  end if;

  -- MusicBrainz-related artist (either direction)
  select coalesce(array_agg(distinct x), '{}') into v_target_related
  from mb_artists a, unnest(a.related_mbids) x
  where a.mbid = any (v_target.artist_mbids) and a.status = 'found';

  if exists (
    select 1 from recordings r
    where r.isrc = any (p_isrcs) and r.status = 'found'
      and (r.artist_mbids && v_target_related
           or exists (select 1 from mb_artists a where a.mbid = any (r.artist_mbids) and a.status = 'found'
                      and a.related_mbids && v_target.artist_mbids))
  ) then
    v_score := c.score_related_artist;
  end if;

  -- Genres/tags: share of the song's tags among the set's top tags
  select coalesce(array_agg(distinct t), '{}') into v_target_tags
  from (
    select unnest(v_target.tags) t
    union
    select unnest(a.tags) from mb_artists a where a.mbid = any (v_target.artist_mbids) and a.status = 'found'
  ) x;

  if cardinality(v_target_tags) > 0 then
    with sig as (
      select u.isrc, u.w from unnest(p_isrcs, p_ws) as u(isrc, w)
    ), weighted as (
      select sig.w, unnest(r.tags) as tag
      from sig join recordings r on r.isrc = sig.isrc and r.status = 'found'
      union all
      select sig.w, unnest(a.tags)
      from sig join recordings r on r.isrc = sig.isrc and r.status = 'found'
      join mb_artists a on a.mbid = any (r.artist_mbids) and a.status = 'found'
    )
    select coalesce(array_agg(tag), '{}') into v_user_tags
    from (select tag from weighted group by tag order by sum(w) desc, tag limit c.top_tags) top;

    select count(*) into v_overlap from unnest(v_target_tags) t where t = any (v_user_tags);
    -- At least 3 in the denominator: one shared tag is weak evidence
    v_score := greatest(v_score,
      least(c.score_tags_cap, v_overlap::real / greatest(cardinality(v_target_tags), 3)));
  end if;

  return v_score;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.stage_view_song_credit(p_arena_id uuid, p_battle_id uuid, p_song_id uuid)
 RETURNS TABLE(proposer text, pi integer, backers integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.stamp_queue_proposer()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
begin
  new.proposed_by := auth.uid();
  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.start_arena_battles(p_arena_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$
;

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
$function$
;

CREATE OR REPLACE FUNCTION public.system_song_votable(p_arena_id uuid, p_song_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from songs s
    where s.id = p_song_id and s.arena_id = p_arena_id
      and s.role = 'competitor' and s.status = 'active'
      and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = s.id)
      and not track_sounded_in_arena(p_arena_id, s.spotify_track_id, s.isrc)
      -- Never fought here, or lost once (the one revancha)
      and (select count(*) from battles f
           where f.arena_id = p_arena_id and s.id in (f.song_a_id, f.song_b_id)
             and f.resolution_type is distinct from 'cancelled') <= 1
      and not exists (select 1 from battles f
                      where f.arena_id = p_arena_id and s.id in (f.song_a_id, f.song_b_id)
                        and f.resolution_type is distinct from 'cancelled'
                        and not (f.state = 'completed' and f.resolution_type in ('normal', 'sudden_death', 'fit')
                                 and f.winner_song_id is distinct from s.id))
  );
$function$
;

CREATE OR REPLACE FUNCTION public.toggle_song_like(p_arena_id uuid, p_song_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_participant uuid;
  v_found boolean;
  v_added timestamptz;
  v_voted boolean := false;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  select p.id into v_participant
  from participants p join arenas a on a.id = p.arena_id
  where p.arena_id = p_arena_id and p.identity_anchor_id = v_uid
    and p.left_at is null and a.state in ('waiting', 'active');
  if v_participant is null then
    raise exception 'not a member of an open arena' using errcode = '42501';
  end if;
  if not exists (select 1 from songs where id = p_song_id and arena_id = p_arena_id) then
    raise exception 'song not in this arena' using errcode = '22023';
  end if;

  -- A like is an action in the arena (v3.2: any action -> ACTIVO)
  perform touch_participant_activity(p_arena_id, v_uid);

  delete from song_likes where participant_id = v_participant and song_id = p_song_id
  returning true, added_to_spotify_at into v_found, v_added;
  if v_found then
    delete from affinity_signals s
    using songs so
    where so.id = p_song_id and s.user_id = v_uid and s.kind = 'like'
      and s.isrc = so.isrc and s.arena_id = p_arena_id;
    -- Unliking never touches the vote
    return jsonb_build_object('liked', false, 'voted', false, 'remove_from_spotify', v_added is not null);
  end if;

  insert into song_likes (arena_id, song_id, participant_id) values (p_arena_id, p_song_id, v_participant);
  perform record_affinity_signal(v_uid, p_song_id, 'like', p_arena_id);

  -- No active vote in the open battle with this song: the like votes for it
  v_voted := cast_vote_if_none(p_arena_id, p_song_id, v_participant) is not null;

  return jsonb_build_object('liked', true, 'voted', v_voted, 'remove_from_spotify', false);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.touch_activity_on_arena_start()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is not null and new.host_id = auth.uid() then
    perform touch_participant_activity(new.id, auth.uid());
  end if;
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.touch_activity_on_proposal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.proposed_by is not null then
    perform touch_participant_activity(new.arena_id, new.proposed_by);
  end if;
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.touch_activity_on_vote()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if new.vote_type = 'passive' then
    return null;
  end if;
  if auth.uid() is not null and new.identity_anchor_id = auth.uid() then
    perform touch_participant_activity(new.arena_id, auth.uid());
  elsif tg_op = 'INSERT' and new.preassigned then
    update participants
    set last_active_at = now(), updated_at = now()
    where arena_id = new.arena_id and identity_anchor_id = new.identity_anchor_id;
  end if;
  return null;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.touch_participant_activity(p_arena_id uuid, p_uid uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  update participants
  set last_active_at = now(),
      last_seen_at = now(),
      disconnected_at = null,
      updated_at = now()
  where arena_id = p_arena_id
    and identity_anchor_id = p_uid;
$function$
;

CREATE OR REPLACE FUNCTION public.track_available_at(p_arena_id uuid, p_track text)
 RETURNS timestamp with time zone
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when t.last_sounded > now() - interval '60 minutes'
              then t.last_sounded + interval '60 minutes' end
  from (
    select greatest(
      (select max(pq.created_at) from playlist_queue pq
        where pq.arena_id = p_arena_id and pq.spotify_track_id = p_track),
      (select a.warmup_started_at from arenas a join songs w on w.id = a.warmup_song_id
        where a.id = p_arena_id and w.spotify_track_id = p_track)
    ) as last_sounded
  ) t;
$function$
;

CREATE OR REPLACE FUNCTION public.track_fought_in_arena(p_arena_id uuid, p_track text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from battles b
                 join songs s on s.id in (b.song_a_id, b.song_b_id)
                 where b.arena_id = p_arena_id and s.spotify_track_id = p_track);
$function$
;

CREATE OR REPLACE FUNCTION public.track_sounded_in_arena(p_arena_id uuid, p_track text, p_isrc text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (select 1 from playlist_queue pq where pq.arena_id = p_arena_id and pq.spotify_track_id = p_track)
      or exists (select 1 from arenas a join songs w on w.id = a.warmup_song_id
                 where a.id = p_arena_id
                   and (w.spotify_track_id = p_track or (p_isrc is not null and w.isrc = p_isrc)))
      or (p_isrc is not null
          and exists (select 1 from playlist_queue pq join songs s on s.id = pq.winner_song_id
                      where pq.arena_id = p_arena_id and s.isrc = p_isrc));
$function$
;

CREATE OR REPLACE FUNCTION public.update_my_profile(p_nickname text, p_country text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_nick text := nullif(regexp_replace(btrim(coalesce(p_nickname, '')), '\s+', ' ', 'g'), '');
  v_country text := nullif(upper(btrim(coalesce(p_country, ''))), '');
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  if v_nick is not null and (char_length(v_nick) not between 2 and 20 or v_nick ~ '[[:cntrl:]]') then
    raise exception 'invalid_nickname' using errcode = 'P0001';
  end if;
  if v_country is not null and v_country !~ '^[A-Z]{2}$' then
    raise exception 'invalid_country' using errcode = 'P0001';
  end if;

  insert into user_profiles (user_id, nickname, country)
  values (v_uid, v_nick, v_country)
  on conflict (user_id) do update
    set nickname = excluded.nickname, country = excluded.country, updated_at = now();
end;
$function$
;

CREATE OR REPLACE FUNCTION public.upsert_spotify_song(p_arena_id uuid, p_track jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_id uuid;
begin
  insert into songs (arena_id, source, spotify_track_id, title, artist, duration_ms, artwork_url, status, role, isrc)
  values (
    p_arena_id, 'spotify', p_track->>'spotify_track_id', p_track->>'title', p_track->>'artist',
    (p_track->>'duration_ms')::int, p_track->>'artwork_url', 'active', 'competitor',
    normalize_isrc(p_track->>'isrc')
  )
  on conflict (arena_id, source, spotify_track_id, role)
  do update set title = excluded.title, artist = excluded.artist,
                duration_ms = excluded.duration_ms, artwork_url = excluded.artwork_url,
                isrc = coalesce(excluded.isrc, songs.isrc),
                updated_at = now()
  returning id into v_id;
  return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.validate_queue_proposal()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_arena arenas%rowtype;
  v_track text;
  v_until timestamptz;
  v_active integer;
  v_waiting integer;
begin
  perform lock_arena_queue(new.arena_id);

  new.position := 0;
  new.priority := 1;
  new.battles_waited := 0;
  new.times_skipped := 0;  -- Step 17
  new.created_at := now();
  new.updated_at := now();

  select * into v_arena from arenas where id = new.arena_id;
  select spotify_track_id into v_track from songs where id = new.song_id;

  -- Already queued: same unique violation the frontend reads as "already in the queue"
  if exists (select 1 from queues where arena_id = new.arena_id and song_id = new.song_id) then
    raise exception 'duplicate key value violates unique constraint "queues_arena_song_unique"'
      using errcode = '23505';
  end if;

  if exists (
    select 1 from battles b join songs s on s.id in (b.song_a_id, b.song_b_id)
    where b.arena_id = new.arena_id
      and b.state in ('pending', 'active', 'closing')
      and s.spotify_track_id = v_track
  ) then
    raise exception 'in_battle' using errcode = 'P0001';
  end if;

  -- Lobby: the warm-up is about to sound
  if v_arena.warmup_started_at is null
     and exists (select 1 from songs w where w.id = v_arena.warmup_song_id and w.spotify_track_id = v_track) then
    raise exception 'is_warmup' using errcode = 'P0001';
  end if;

  v_until := track_available_at(new.arena_id, v_track);
  if v_until is not null then
    raise exception 'recently_played' using errcode = 'P0001',
      hint = to_char(v_until at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"');
  end if;

  if new.proposed_by is not null
     and (select count(*) from queues where arena_id = new.arena_id and proposed_by = new.proposed_by) >= 5 then
    raise exception 'proposer_queue_full' using errcode = 'P0001';
  end if;

  select count(*) filter (where queue_type = 'active'), count(*) filter (where queue_type = 'waiting')
  into v_active, v_waiting
  from queues where arena_id = new.arena_id;

  if v_active < 10 then
    new.queue_type := 'active';
  elsif v_waiting < 50 then
    new.queue_type := 'waiting';
  else
    raise exception 'queue_full' using errcode = 'P0001';
  end if;

  return new;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.wake_spotify_host()
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with due as (
    update arena_playback set wake_at = null
    where wake_at is not null and wake_at <= now()
    returning arena_id
  )
  select nudge_spotify_host(due.arena_id) from due;
$function$
;

CREATE OR REPLACE FUNCTION public.withdraw_backing(p_arena_id uuid, p_song_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_rows int;
begin
  if auth.uid() is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from arenas where id = p_arena_id and state in ('waiting', 'active')) then
    raise exception 'arena_closed' using errcode = '55000';
  end if;

  perform lock_arena_queue(p_arena_id);

  -- Under the lock: its battle may have just started (then it is a vote)
  with gone as (
    delete from queue_backers
    where arena_id = p_arena_id and song_id = p_song_id and user_id = auth.uid()
    returning *
  )
  insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome, kind, backing_source)
  select arena_id, song_id, user_id, created_at, 'removed', 'backing', source from gone;
  get diagnostics v_rows = row_count;
  if v_rows = 0 then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  perform touch_participant_activity(p_arena_id, auth.uid());
end;
$function$
;

CREATE OR REPLACE FUNCTION public.withdraw_proposal(p_queue_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_arena_id uuid;
  v_row queues%rowtype;
begin
  select arena_id into v_arena_id from queues where id = p_queue_id and proposed_by = auth.uid();
  if v_arena_id is null or auth.uid() is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from arenas where id = v_arena_id and state in ('waiting', 'active')) then
    raise exception 'arena_closed' using errcode = '55000';
  end if;

  perform lock_arena_queue(v_arena_id);

  -- Re-read under the lock: it may have just entered a battle
  delete from queues where id = p_queue_id and proposed_by = auth.uid()
  returning * into v_row;
  if v_row.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;

  insert into proposal_history (arena_id, song_id, proposed_by, proposed_at, outcome)
  values (v_row.arena_id, v_row.song_id, v_row.proposed_by, v_row.created_at, 'withdrawn');

  -- Step 14: its backings go with it
  perform drop_queue_backers(v_row.arena_id, array[v_row.song_id], 'withdrawn');

  perform refill_active_queue(v_arena_id);
  perform touch_participant_activity(v_arena_id, auth.uid());
end;
$function$
;
