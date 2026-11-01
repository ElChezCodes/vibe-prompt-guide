-- Step 20: fixes after the pilot (2026-10-31, arena "Cumple del Manu",
-- 20c1c77b-576d-465d-8d40-0f79fee94b5a). User decisions 2026-11-01.
--
-- 1. Repeated songs. Two causes found in the pilot's data:
--    a) playback: Spotify plays a playlist "at a track" from that track's
--       FIRST occurrence; winners repeat in the arena playlist (152 entries,
--       88 distinct), so a Resume / put-back went back hours and Spotify went
--       on with old songs. Fixed in spotify-host (plays the plan's position).
--    b) system songs: the reserve took songs of the host's playlist again as
--       soon as the 60-min rule allowed it ("Calentita" won 6 times). User
--       decision: a song that already SOUNDED in the arena (a winner, either
--       song of a draw, the warm-up; same track or same ISRC) never comes back
--       as a system song (reserve, revancha, member profiles, purged/
--       withdrawn); human proposals keep the 60-min rule. The sources go
--       deeper so the arena doesn't run out (spotify-host: 3 random pages of
--       the host's source; arena artists + their MusicBrainz/ListenBrainz
--       related artists, searched past the first page).
-- 2. A battle nobody voted in, not even passively (32 of 115 in the pilot):
--    no Sudden Death/draw; the song that fits the arena best wins
--    (resolution_type 'fit'); tie or unknown fit -> the more compatible with
--    what has just sounded (matchmaking's ref); still tied -> random.
--    Passive votes were rare because 6 of the 9 (anonymous) participants had
--    < 3 songs of their own in the arena (min_signals): no profile, no passive
--    vote. User decision: kept as is.
-- 3. "Next up to fight" also shows the system songs that would fill the next
--    5 battles (is_system). The system picks are now deterministic for a
--    given state (md5 of song + last battle instead of random()), and the
--    preview runs the same candidate function as the real pick, so the next
--    battle's system song shown is the one picked unless the state changes.

-- ---------------------------------------------------------------------------
-- 1b. Sounded songs never come back as system songs
create or replace function public.track_sounded_in_arena(p_arena_id uuid, p_track text, p_isrc text default null)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (select 1 from playlist_queue pq where pq.arena_id = p_arena_id and pq.spotify_track_id = p_track)
      or exists (select 1 from arenas a join songs w on w.id = a.warmup_song_id
                 where a.id = p_arena_id
                   and (w.spotify_track_id = p_track or (p_isrc is not null and w.isrc = p_isrc)))
      or (p_isrc is not null
          and exists (select 1 from playlist_queue pq join songs s on s.id = pq.winner_song_id
                      where pq.arena_id = p_arena_id and s.isrc = p_isrc));
$$;
revoke all on function public.track_sounded_in_arena(uuid, text, text) from public, anon, authenticated;

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

-- Revancha: also 'fit' losers; never a song that sounded; deterministic
create or replace function public.pick_rematch_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid default null::uuid, p_partner song_feature default null::song_feature, p_ref song_feature default null::song_feature, p_has_partner boolean default false)
returns uuid
language sql
stable
security definer
set search_path to 'public'
as $function$
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
$function$;
revoke all on function public.pick_rematch_song(uuid, text[], uuid, uuid, song_feature, song_feature, boolean) from public, anon, authenticated;

-- Present members' own MF profiles: the candidate only (no insert), so the
-- Next up preview can run it too
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
revoke all on function public.member_profile_candidate(uuid, text[], uuid, song_feature, song_feature, boolean, text) from public, anon, authenticated;

-- The fallback chain as a read-only candidate: song_id = this arena's song
-- (NULL for a member-profile track not copied here yet), src_song_id = the
-- songs row to show/copy, step = which link of the chain
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
revoke all on function public.fallback_candidate(uuid, text[], uuid, uuid, text, text, boolean) from public, anon, authenticated;

-- The real pick: the candidate, copying a member-profile track into the arena
create or replace function public.pick_fallback_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid default null::uuid, p_partner_isrc text default null::text, p_ref_isrc text default null::text, p_has_partner boolean default false)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
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
$function$;

drop function if exists public.pick_member_profile_song(uuid, text[], uuid, song_feature, song_feature, boolean);

-- ---------------------------------------------------------------------------
-- 2. Nobody voted: the song that fits the arena best wins
alter table public.battles drop constraint battles_resolution_type_check;
alter table public.battles add constraint battles_resolution_type_check
  check (resolution_type = any (array['normal', 'sudden_death', 'draw', 'cancelled', 'fit']));

create or replace function public.arena_fit_winner(p_battle_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
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
$function$;
revoke all on function public.arena_fit_winner(uuid) from public, anon, authenticated;


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
$function$;


-- ---------------------------------------------------------------------------
-- 3. Next up: the human plan (step 17) + the system songs that would fill the
-- next 5 battles, from the same fallback_candidate the real pick runs (the
-- next battle's exact for the current state; later ones are a forecast)
drop function if exists public.get_arena_next_up(uuid);
drop function if exists public.arena_next_up(uuid, uuid);

create function public.arena_next_up(p_arena_id uuid, p_viewer uuid)
returns table(pos integer, song_id uuid, spotify_track_id text, title text, artist text, artwork_url text, duration_ms integer, pair_no integer, vs_system boolean, is_mine boolean, available_at timestamp with time zone, is_system boolean)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
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

  return query
  select u.ord::int, s.id, s.spotify_track_id, s.title, s.artist, s.artwork_url, s.duration_ms, u.pair_no,
         u.vs, not u.sys and p_viewer is not null and u.pby is not distinct from p_viewer, u.avail, u.sys
  from unnest(o_song, o_pair, o_sys, o_vs, o_by, o_avail) with ordinality as u(song_id, pair_no, sys, vs, pby, avail, ord)
  join songs s on s.id = u.song_id
  order by u.ord;
end;
$function$;
revoke all on function public.arena_next_up(uuid, uuid) from public, anon, authenticated;
grant execute on function public.arena_next_up(uuid, uuid) to service_role;

create function public.get_arena_next_up(p_arena_id uuid)
returns table(pos integer, song_id uuid, spotify_track_id text, title text, artist text, artwork_url text, duration_ms integer, pair_no integer, vs_system boolean, is_mine boolean, available_at timestamp with time zone, is_system boolean)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select * from arena_next_up(p_arena_id, auth.uid())
  where exists (select 1 from participants pa where pa.arena_id = p_arena_id and pa.identity_anchor_id = auth.uid());
$function$;
revoke all on function public.get_arena_next_up(uuid) from public, anon;
grant execute on function public.get_arena_next_up(uuid) to authenticated, service_role;

-- Stage View: is_system in next_up
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
                  'is_system', n.is_system) order by n.pos)
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
$function$;

-- prepare_reserve: prune sounded songs, related artists
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
      and track_sounded_in_arena(p_arena_id, s.spotify_track_id, s.isrc)
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
