-- Found in the 1-hour test arena (d0cd5cbe-9857-49b6-afed-8f76231c6e7d,
-- 2026-11-01): "Solitude" lost twice and the host-library refill put it back
-- in the reserve (only sounded songs were skipped). A song that already
-- fought in the arena returns only as the revancha (once, 2026-10-30), never
-- as a reserve or member-profile song; prepare_reserve prunes them.

create or replace function public.track_fought_in_arena(p_arena_id uuid, p_track text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (select 1 from battles b
                 join songs s on s.id in (b.song_a_id, b.song_b_id)
                 where b.arena_id = p_arena_id and s.spotify_track_id = p_track);
$$;
revoke all on function public.track_fought_in_arena(uuid, text) from public, anon, authenticated;

create or replace function public.add_reserve_songs(p_arena_id uuid, p_source text, p_tracks jsonb, p_limit integer, p_contributor uuid default null::uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
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
$function$;

create or replace function public.member_profile_candidate(p_arena_id uuid, p_exclude text[], p_avoid_proposer uuid, p_partner song_feature, p_ref song_feature, p_has_partner boolean, p_seed text)
returns table(src_id uuid, spotify_track_id text)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
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
$function$;

create or replace function public.fallback_candidate(p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid default null::uuid, p_partner_isrc text default null::text, p_ref_isrc text default null::text, p_has_partner boolean default false)
returns table(song_id uuid, src_song_id uuid, step text)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
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
$function$;

-- prepare_reserve: prune fought songs too
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
$function$;
