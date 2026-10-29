-- ===========================================================================
-- Roadmap step 13 (2026-10-28): system songs that fit the arena.
--
-- User decisions 2026-10-28:
--   * Scope: the fallback reserve (step 12b) is ranked by how well each song
--     fits the arena, using Music Fighter's own open data (MusicBrainz via
--     ISRC, step 8), and guests may lend their Spotify Liked Songs to it.
--   * Fit = the arena's style as the base, the taste of the people present to
--     break ties:
--       fit   = song_set_score of the song against the arena's songs (warm-up,
--               human proposals, winners; recent ones weigh more) - the same
--               rules as affinity_score: same song, same artist,
--               MusicBrainz-related artist, tag coverage
--       taste = average affinity_score of the present (ACTIVO/PASIVO) users
--               who have one
--     Order inside a tier: songs with MusicBrainz data first, fit in buckets
--     of fit_bucket (higher first), then taste, then random. Songs without
--     MusicBrainz data (~40 %) stay behind, in random order as before.
--   * Guests: a per-arena switch, off by default, can be turned off any time;
--     only while they are in the arena (leaving, disconnecting Spotify or the
--     arena ending drops it, with their songs). Anonymous: the song enters as
--     a system song; nobody sees whose library it came from. Only Liked
--     Songs, read live with their token and the host's country as market.
--   * When: unchanged - only when human proposals can't make a pair. Chain:
--     revancha -> reserve from libraries (host's source + guests', ranked by
--     fit) -> search by the arena's artists (ranked by fit) -> purged/withdrawn
--     -> the arena waits for songs.
--
-- Spotify policy: library songs are candidates to play, never a signal
-- (nothing goes to affinity_signals, no profile of the library's owner).
-- What is stored is only the small reserve (songs rows the battle chain
-- needs, Spotify can't be called from SQL) plus which guest lent each one,
-- service-only, deleted when the song is not picked (rotation, switch off,
-- arena end). Songs that fought stay: they are arena content.
--
-- spotify-host keeps the reserve: prepare_reserve (prune, rotate, score,
-- needs) on Start and every watch tick, then add_reserve_songs.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Schema
-- ---------------------------------------------------------------------------
alter table public.arena_song_reserve add column if not exists fit real;
alter table public.arena_song_reserve add column if not exists taste real;
alter table public.arena_song_reserve add column if not exists scored_at timestamptz;
-- The guest who lent it (guest_library only)
alter table public.arena_song_reserve
  add column if not exists contributed_by uuid references auth.users (id) on delete cascade;

alter table public.arena_song_reserve drop constraint if exists arena_song_reserve_source_check;
alter table public.arena_song_reserve add constraint arena_song_reserve_source_check
  check (source in ('host_library', 'guest_library', 'arena_artist'));

-- Guests who lend their Liked Songs to one arena. Service-only.
create table if not exists public.arena_library_contributors (
  arena_id uuid not null references public.arenas (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (arena_id, user_id)
);
alter table public.arena_library_contributors enable row level security;
revoke all on public.arena_library_contributors from anon, authenticated;

-- One row; changing a rule is an UPDATE
create table if not exists public.system_song_config (
  id int primary key default 1 check (id = 1),
  -- The arena's style follows the party: a song counts half after this
  style_half_life_minutes int not null default 60,
  -- Fits within one bucket are ties, decided by the taste of the present
  fit_bucket real not null default 0.1,
  -- Reserve sizes
  host_library_pool int not null default 8,
  guest_library_pool int not null default 4,
  arena_artist_pool int not null default 3,
  -- Rotation of a full library pool: its worst song older than
  -- rotate_min_age_minutes is replaced, at most once per rotate_every_minutes
  rotate_every_minutes int not null default 5,
  rotate_min_age_minutes int not null default 10
);
insert into public.system_song_config (id) values (1) on conflict do nothing;
alter table public.system_song_config enable row level security;
revoke all on public.system_song_config from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Scores
-- ---------------------------------------------------------------------------

-- The rules of affinity_score against any weighted set of songs (ISRCs).
-- NULL = MusicBrainz has nothing on p_isrc (and it isn't in the set).
create or replace function public.song_set_score(p_isrcs text[], p_ws real[], p_isrc text)
returns real
language plpgsql
stable
security definer
set search_path = public
as $$
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
$$;
revoke all on function public.song_set_score(text[], real[], text) from public, anon, authenticated;

-- Affinity v0 (step 8), now on song_set_score: same rules, same results
-- (a song MusicBrainz doesn't know scores 0 for a user, as before)
create or replace function public.affinity_score(p_user uuid, p_isrc text, p_arena uuid)
returns real
language plpgsql
stable
security definer
set search_path = public
as $$
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
$$;
revoke all on function public.affinity_score(uuid, text, uuid) from public, anon, authenticated;

-- The arena's style: its warm-up, human proposals (queued or past) and
-- winners, each weighing less with age (style_half_life_minutes)
create or replace function public.arena_style_songs(p_arena_id uuid)
returns table (isrc text, w real)
language sql
stable
security definer
set search_path = public
as $$
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
    where h.arena_id = p_arena_id and h.proposed_by is not null
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
$$;
revoke all on function public.arena_style_songs(uuid) from public, anon, authenticated;

-- Average affinity of the present (ACTIVO/PASIVO) users who have one
create or replace function public.presence_taste(p_arena_id uuid, p_isrc text)
returns real
language sql
stable
security definer
set search_path = public
as $$
  select avg(x.score)::real
  from (
    select affinity_score(pp.identity_anchor_id, p_isrc, p_arena_id) as score
    from participant_presence pp
    where pp.arena_id = p_arena_id and pp.state in ('active', 'passive')
  ) x
  where x.score is not null;
$$;
revoke all on function public.presence_taste(uuid, text) from public, anon, authenticated;

create or replace function public.score_arena_reserve(p_arena_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
$$;
revoke all on function public.score_arena_reserve(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Reserve upkeep (service-only)
-- ---------------------------------------------------------------------------

-- A songs row only the reserve knew about (never queued, fought, liked...)
create or replace function public.delete_song_if_unused(p_song_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  delete from songs s
  where s.id = p_song_id
    and s.role = 'competitor'
    and not exists (select 1 from arena_song_reserve r where r.song_id = s.id)
    and not exists (select 1 from queues q where q.song_id = s.id)
    and not exists (select 1 from battles b where s.id in (b.song_a_id, b.song_b_id, b.winner_song_id))
    and not exists (select 1 from playlist_queue pq where pq.winner_song_id = s.id)
    and not exists (select 1 from proposal_history h where h.song_id = s.id)
    and not exists (select 1 from song_likes l where l.song_id = s.id)
    and not exists (select 1 from arenas a where a.warmup_song_id = s.id);
$$;
revoke all on function public.delete_song_if_unused(uuid) from public, anon, authenticated;

-- Drops reserve rows (all of the arena, or one guest's) and their unused songs
create or replace function public.drop_reserve_rows(p_arena_id uuid, p_contributor uuid default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_song uuid;
begin
  for v_song in
    delete from arena_song_reserve
    where arena_id = p_arena_id and (p_contributor is null or contributed_by = p_contributor)
    returning song_id
  loop
    perform delete_song_if_unused(v_song);
  end loop;
end;
$$;
revoke all on function public.drop_reserve_rows(uuid, uuid) from public, anon, authenticated;

-- The guest's switch (spotify-host checks membership and their Spotify)
create or replace function public.set_library_contribution(p_arena_id uuid, p_user_id uuid, p_enabled boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
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
$$;
revoke all on function public.set_library_contribution(uuid, uuid, boolean) from public, anon, authenticated;

-- Prune, rotate and score the reserve, then say what's missing:
-- {host_library, arena_artist, source, artists, guests: [{user_id, need}]}
create or replace function public.prepare_reserve(p_arena_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
$$;
revoke all on function public.prepare_reserve(uuid) from public, anon, authenticated;

drop function if exists public.reserve_needs(uuid);

-- Adds up to p_limit of p_tracks ({spotify_track_id,title,artist,duration_ms,
-- artwork_url,isrc}) that may fight now: not the warm-up, not sounded in 60
-- min, not queued, not fighting, not already reserved. Returns how many.
-- p_contributor: the guest who lent them (guest_library).
drop function if exists public.add_reserve_songs(uuid, text, jsonb, integer);
create or replace function public.add_reserve_songs(
  p_arena_id uuid, p_source text, p_tracks jsonb, p_limit integer, p_contributor uuid default null)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
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
      or track_available_at(p_arena_id, v_id) is not null
      or exists (select 1 from arenas a join songs w on w.id = a.warmup_song_id
                 where a.id = p_arena_id and w.spotify_track_id = v_id)
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
$$;
revoke execute on function public.add_reserve_songs(uuid, text, jsonb, integer, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. Picks: libraries ranked by fit, then the arena's artists ranked by fit
-- ---------------------------------------------------------------------------
create or replace function public.pick_fallback_song(p_arena_id uuid, p_exclude text[], p_last_battle uuid)
returns uuid
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
  v_song uuid;
  v_bucket real;
begin
  -- 1. revancha
  v_song := pick_rematch_song(p_arena_id, p_exclude, p_last_battle);
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

  -- 4. proposed here, left the queue without fighting
  select s.id into v_song
  from proposal_history h join songs s on s.id = h.song_id
  where h.arena_id = p_arena_id
    and h.outcome in ('purged', 'withdrawn')
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
revoke execute on function public.pick_fallback_song(uuid, text[], uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. An arena that ends keeps no reserve and no lent libraries
-- ---------------------------------------------------------------------------
create or replace function public.clear_reserve_on_arena_end()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from arena_library_contributors where arena_id = new.id;
  perform drop_reserve_rows(new.id);
  return null;
end;
$$;

drop trigger if exists trg_arenas_clear_reserve on public.arenas;
create trigger trg_arenas_clear_reserve
after update of state on public.arenas
for each row
when (new.state in ('finished', 'expired') and old.state is distinct from new.state)
execute function public.clear_reserve_on_arena_end();

-- Reserves left by arenas that already ended
do $$
declare
  v_arena uuid;
begin
  for v_arena in
    select distinct r.arena_id from arena_song_reserve r join arenas a on a.id = r.arena_id
    where a.state in ('finished', 'expired')
  loop
    perform drop_reserve_rows(v_arena);
  end loop;
end;
$$;
