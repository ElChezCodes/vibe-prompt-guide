-- ===========================================================================
-- Fair play (user decisions 2026-10-29, follow-ups to step 15):
--
-- 1. The passive-profile layer (host_profile_songs_2026-10-29.sql) uses every
--    present member's own Music Fighter profile, not only the host's: songs
--    that present members with an account (participant_presence active or
--    passive, same rule as step 13's taste) voted, proposed or liked in OTHER
--    arenas, mapped by ISRC to a Spotify track MF already knows, ranked by
--    fit with the arena, then the present members' taste (presence_taste),
--    then random. Still a passive system song: never queued, can't be backed,
--    no PI. Same exclusions as before (A's track, queued/fighting, the battle
--    that just ended, recently played, tracks A's proposer actively proposed
--    here). Replaces pick_host_profile_song.
--
-- 2. Win/draw/Sudden Death/backing PI only when at least
--    pi_config.min_voters (2) different people cast an explicit vote in the
--    battle (votes status 'active', not passive; pre-assigned votes count).
--    Stops a lone user farming PI by voting their own songs against system
--    songs. The +1 for reaching a battle is unchanged.
-- ===========================================================================

drop function if exists public.pick_host_profile_song(uuid, text[], uuid);

create or replace function public.pick_member_profile_song(p_arena_id uuid, p_exclude text[],
                                                         p_avoid_proposer uuid default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_members uuid[];
  v_isrcs text[];
  v_ws real[];
  v_bucket real;
  v_src uuid;
  v_track text;
  v_song uuid;
begin
  -- Present members with an account (same "present" as step 13's taste)
  select array_agg(distinct pp.identity_anchor_id) into v_members
  from participant_presence pp
  join auth.users u on u.id = pp.identity_anchor_id and not u.is_anonymous
  where pp.arena_id = p_arena_id and pp.state in ('active', 'passive');
  if v_members is null then
    return null;
  end if;

  select coalesce(array_agg(isrc), '{}'), coalesce(array_agg(w), '{}') into v_isrcs, v_ws
  from arena_style_songs(p_arena_id);
  select fit_bucket into v_bucket from system_song_config where id = 1;

  select c.src_id, c.spotify_track_id into v_src, v_track
  from (
    -- one known Spotify track per ISRC of the members' signals elsewhere
    select distinct on (sig.isrc) sig.isrc, src.id as src_id, src.spotify_track_id
    from affinity_signals sig
    join songs src on src.isrc = sig.isrc and src.source = 'spotify' and src.role = 'competitor'
    where sig.user_id = any (v_members)
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
           presence_taste(p_arena_id, c.isrc) desc nulls last,
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
revoke all on function public.pick_member_profile_song(uuid, text[], uuid) from public, anon, authenticated;

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

  -- 3b. present members' own MF profiles (their signals in other arenas)
  v_song := pick_member_profile_song(p_arena_id, p_exclude, p_avoid_proposer);
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

-- ---------------------------------------------------------------------------
-- 2. Minimum explicit voters for win/draw/SD/backing PI
-- ---------------------------------------------------------------------------
alter table public.pi_config add column if not exists min_voters integer not null default 2;

-- Win / draw / Sudden Death bonus / half to backers, when the battle completes
create or replace function public.pi_on_battle_completed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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

  -- Fair play: at least min_voters different people voted explicitly
  if (select count(distinct v.identity_anchor_id) from votes v
      where v.battle_id = new.id and v.status = 'active' and v.vote_type <> 'passive') < c.min_voters then
    return null;
  end if;

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

  -- Original proposers (system songs have none)
  for r in
    select distinct h.proposed_by, h.song_id
    from proposal_history h
    where h.battle_id = new.id and h.kind = 'proposal' and h.outcome = 'battled'
      and h.proposed_by is not null and h.song_id = any (v_songs)
  loop
    perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, v_reason, v_base);
    if v_sd then
      perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, 'sudden_death_bonus', c.sudden_death_bonus);
    end if;
  end loop;

  -- Backers: pre-assigned at the start and still their counted vote at the end
  for r in
    select distinct h.proposed_by, h.song_id
    from proposal_history h
    where h.battle_id = new.id and h.kind = 'backing' and h.vote_preassigned
      and h.proposed_by is not null and h.song_id = any (v_songs)
      and exists (select 1 from votes v
                  where v.battle_id = new.id and v.identity_anchor_id = h.proposed_by
                    and v.song_id = h.song_id and v.status = 'active' and v.vote_type <> 'passive'
                    and (new.sudden_death_started_at is null or v.vote_type = 'sudden_death'))
  loop
    perform award_pi(r.proposed_by, new.arena_id, new.id, r.song_id, 'duplicate_half',
                     round((v_base + case when v_sd then c.sudden_death_bonus else 0 end) * c.backing_share)::integer);
  end loop;

  return null;
end;
$$;

