-- ===========================================================================
-- System songs from the host's own Music Fighter profile (user decision
-- 2026-10-29, follow-up to no_self_battles_2026-10-29.sql).
--
-- When the reserve is empty (host's backup source empty/unreadable and the
-- arena-artist search found nothing), a lone proposer used to make the arena
-- wait. Now a new step after the reserve picks a song from the host's own
-- affinity profile: songs the host voted, proposed or liked in OTHER arenas
-- (affinity_signals, MF's own data, step 8), mapped by ISRC to a Spotify
-- track already known to Music Fighter, ranked by fit with this arena
-- (song_set_score vs arena_style_songs, same buckets as the reserve), then
-- random. Accounts only: anonymous hosts' signals only live inside their
-- arena. It is a passive (system) song: never in queues, no proposal_history
-- row, so no PI, no backings, and it can face anyone except as below.
--
-- Same rules as the other system songs: not A's track, not queued,
-- fighting or in the battle that just ended, may sound now
-- (track_available_at: 60 min after sounding), and
-- never a track that A's proposer actively proposed in this arena.
-- Chain: revancha -> reserve -> host's MF profile -> purged/withdrawn ->
-- the arena waits.
-- ===========================================================================

create or replace function public.pick_host_profile_song(p_arena_id uuid, p_exclude text[],
                                                         p_avoid_proposer uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host uuid;
  v_isrcs text[];
  v_ws real[];
  v_bucket real;
  v_src uuid;
  v_track text;
  v_song uuid;
begin
  select a.host_id into v_host
  from arenas a join auth.users u on u.id = a.host_id and not u.is_anonymous
  where a.id = p_arena_id;
  if v_host is null then
    return null;
  end if;

  select coalesce(array_agg(isrc), '{}'), coalesce(array_agg(w), '{}') into v_isrcs, v_ws
  from arena_style_songs(p_arena_id);
  select fit_bucket into v_bucket from system_song_config where id = 1;

  select c.src_id, c.spotify_track_id into v_src, v_track
  from (
    -- one known Spotify track per ISRC of the host's signals elsewhere
    select distinct on (sig.isrc) sig.isrc, src.id as src_id, src.spotify_track_id
    from affinity_signals sig
    join songs src on src.isrc = sig.isrc and src.source = 'spotify' and src.role = 'competitor'
    where sig.user_id = v_host
      and sig.arena_id is distinct from p_arena_id
    order by sig.isrc, src.created_at desc
  ) c
  where not (c.spotify_track_id = any (coalesce(p_exclude, '{}')))
    and track_available_at(p_arena_id, c.spotify_track_id) is null
    and not exists (select 1 from queues q join songs qs on qs.id = q.song_id
                    where q.arena_id = p_arena_id and qs.spotify_track_id = c.spotify_track_id)
    -- not fighting now, nor in the battle that just ended (no immediate rematch)
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
  order by floor(case when cardinality(v_isrcs) > 0 then song_set_score(v_isrcs, v_ws, c.isrc) end / v_bucket)
             desc nulls last,
           random()
  limit 1;
  if v_src is null then
    return null;
  end if;

  -- This arena's own songs row for that track (reused if it already exists)
  select id into v_song
  from songs
  where arena_id = p_arena_id and source = 'spotify' and spotify_track_id = v_track and role = 'competitor';
  if v_song is null then
    insert into songs (arena_id, source, spotify_track_id, title, artist, duration_ms, status, artwork_url, isrc)
    select p_arena_id, 'spotify', s.spotify_track_id, s.title, s.artist, s.duration_ms, 'active', s.artwork_url, s.isrc
    from songs s where s.id = v_src
    returning id into v_song;
  elsif exists (select 1 from songs where id = v_song and status <> 'active') then
    return null;
  end if;
  return v_song;
end;
$$;
revoke all on function public.pick_host_profile_song(uuid, text[], uuid) from public, anon, authenticated;

create or replace function public.pick_fallback_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid,
                                                     p_avoid_proposer uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_song uuid;
  v_bucket real;
begin
  -- 1. revancha (not one of the other song's proposer)
  v_song := pick_rematch_song(p_arena_id, p_exclude, p_last_battle, p_avoid_proposer);
  if v_song is not null then
    return v_song;
  end if;

  -- 2-3. reserve: libraries (host's source, guests'), then the arena's
  -- artists; inside each, known fit first (buckets), taste, random
  select fit_bucket into v_bucket from system_song_config where id = 1;
  select s.id into v_song
  from arena_song_reserve r join songs s on s.id = r.song_id
  where r.arena_id = p_arena_id
    and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
    and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = s.id)
    and track_available_at(p_arena_id, s.spotify_track_id) is null
  order by r.source = 'arena_artist', r.fit is null, floor(r.fit / v_bucket) desc,
           r.taste desc nulls last, random()
  limit 1;
  if v_song is not null then
    return v_song;
  end if;

  -- 3b. the host's own MF profile (songs from their signals in other arenas)
  v_song := pick_host_profile_song(p_arena_id, p_exclude, p_avoid_proposer);
  if v_song is not null then
    return v_song;
  end if;

  -- 4. proposed here, left the queue without fighting (not by the other
  -- song's proposer)
  select s.id into v_song
  from proposal_history h join songs s on s.id = h.song_id
  where h.arena_id = p_arena_id
    and h.outcome in ('purged', 'withdrawn')
    and h.kind = 'proposal'  -- Step 14
    and (p_avoid_proposer is null or h.proposed_by is distinct from p_avoid_proposer)
    and s.status = 'active'
    and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
    and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = s.id)
    and not exists (select 1 from battles b where b.arena_id = p_arena_id and s.id in (b.song_a_id, b.song_b_id))
    and track_available_at(p_arena_id, s.spotify_track_id) is null
  order by random()
  limit 1;
  return v_song;
end;
$$;
revoke all on function public.pick_fallback_song(uuid, text[], uuid, uuid) from public, anon, authenticated;
