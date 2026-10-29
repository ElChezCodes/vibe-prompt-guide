-- ===========================================================================
-- Step 17: battle pair selection / matchmaking (user decisions 2026-10-29).
-- Specs: Backend_Block_4 §6-8 (session coherence, comparable songs, DJ-like
-- continuity with the winner), §10 (logs), PRD v1.2x §9 (pool of 10, oldest
-- first, never force a repetition), v4 §2.3 / v2.6 §7.3 (queue ranking).
--
-- 1. Data (no Spotify data in the model, policy III.13/III.14): MusicBrainz
--    + ListenBrainz open data, fetched once per song by musicbrainz-enrich:
--    - ISRC not in MusicBrainz -> MusicBrainz search by title + first artist
--      (recording, else exact artist name); only MBIDs are kept
--      (recordings.match_source)
--    - ListenBrainz similar artists (listening sessions) -> mb_artists.lb_similar
--    - ListenBrainz recording/release-group tags, kept only when they are
--      MusicBrainz genres (mb_genres) -> recordings.lb_tags
--    No BPM/energy/popularity (no open source alive; popularity not wanted).
-- 2. Compatibility (song_compat): same artist 0.9 / related or similar artist
--    0.75 / shared genres (cap 0.85), the step-8 constants; NULL = unknown,
--    counted as matchmaking_config.neutral_compat.
-- 3. Pair = the best pair among the next 10 (queues 'active') that may sound:
--      continuity_weight · (compat(A, ref) + compat(B, ref)) / 2
--    + pair_weight · compat(A, B)
--    + taste_weight · present users' affinity (presence_taste)
--    − turn_weight · how far behind in the fair order (turns per person) both are
--    ref = the last arena song decided to sound (last playlist_queue entry by
--    seq: the winner, B of a draw; else the warm-up). A song with a better
--    turn passed over max_skips (3) times must fight in the next battle
--    (queues.times_skipped). Two songs of the same proposer never face each
--    other; no pair of humans -> the best one fights a system song.
--    Compatibility only orders, never blocks (human-first).
-- 4. System songs (revancha, reserve, member profiles, purged/withdrawn):
--    same chain, inside each step the most compatible with the human song
--    fighting and the ref first, then fit with the arena.
-- 5. Transparency: matchmaking_log (service-only, 30 days) and
--    get_arena_next_up (members): the next 10 in the order they would fight.
-- Nothing here touches timing or playback.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Open data
-- ---------------------------------------------------------------------------

alter table public.recordings add column if not exists match_source text not null default 'isrc';
alter table public.recordings add column if not exists lb_tags text[] not null default '{}';
-- Secondary lookups, one at a time per row: 'search' (ISRC not found) or
-- 'lb_tags' (found with a recording MBID), then 'done' | 'failed'
alter table public.recordings add column if not exists aux_step text;
alter table public.recordings add column if not exists aux_attempts integer not null default 0;
alter table public.recordings add column if not exists aux_next_at timestamptz not null default now();

alter table public.mb_artists add column if not exists lb_similar uuid[] not null default '{}';
-- 'lb_similar', then 'done' | 'failed'
alter table public.mb_artists add column if not exists aux_step text;
alter table public.mb_artists add column if not exists aux_attempts integer not null default 0;
alter table public.mb_artists add column if not exists aux_next_at timestamptz not null default now();

create index if not exists recordings_aux_idx on public.recordings (aux_next_at) where aux_step in ('search', 'lb_tags');
create index if not exists mb_artists_aux_idx on public.mb_artists (aux_next_at) where aux_step = 'lb_similar';

-- MusicBrainz's genre list (GET /genre/all?fmt=txt), refreshed monthly
create table if not exists public.mb_genres (
  name text primary key
);
alter table public.mb_genres enable row level security;
revoke all on public.mb_genres from anon, authenticated;

alter table public.mb_enrich_state add column if not exists genres_loaded_at timestamptz;

-- Backfill what is already known
update public.recordings set aux_step = 'lb_tags'
where status = 'found' and mbid is not null and aux_step is null;
update public.recordings set aux_step = 'search'
where status = 'not_found' and aux_step is null;
update public.mb_artists set aux_step = 'lb_similar'
where status = 'found' and aux_step is null;

create or replace function public.mb_save_recording(p_isrc text, p_result jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
$$;

create or replace function public.mb_save_artist(p_mbid uuid, p_result jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- Search result: {mbid (may be null: artist-only match), artist_mbids, tags, source}
create or replace function public.mb_save_search(p_isrc text, p_result jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- ListenBrainz tags, only MusicBrainz genres (folksonomy like "los angeles" dropped)
create or replace function public.mb_save_lb_tags(p_isrc text, p_tags text[])
returns void
language sql
security definer
set search_path = public
as $$
  update recordings
  set lb_tags = array(select distinct lower(t) from unnest(coalesce(p_tags, '{}')) t
                      where exists (select 1 from mb_genres g where g.name = lower(t))),
      aux_step = 'done'
  where isrc = p_isrc;
$$;

create or replace function public.mb_save_lb_similar(p_mbid uuid, p_similar uuid[])
returns void
language sql
security definer
set search_path = public
as $$
  update mb_artists
  set lb_similar = array(select distinct x from unnest(coalesce(p_similar, '{}')) x where x <> p_mbid),
      aux_step = 'done'
  where mbid = p_mbid;
$$;

create or replace function public.mb_save_genres(p_names text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if cardinality(coalesce(p_names, '{}')) > 0 then
    insert into mb_genres (name)
    select distinct lower(btrim(n)) from unnest(p_names) n where btrim(n) <> ''
    on conflict do nothing;
  end if;
  update mb_enrich_state set genres_loaded_at = now() where id = 1;
end;
$$;

create or replace function public.mb_has_work()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from recordings where status in ('pending', 'error') and next_attempt_at <= now())
      or exists (select 1 from mb_artists where status in ('pending', 'error') and next_attempt_at <= now())
      or exists (select 1 from mb_enrich_state where id = 1
                 and (genres_loaded_at is null or genres_loaded_at < now() - interval '30 days'))
      or exists (select 1 from recordings where aux_step in ('search', 'lb_tags') and aux_next_at <= now())
      or exists (select 1 from mb_artists where aux_step = 'lb_similar' and aux_next_at <= now());
$$;

-- Order: ISRC lookups, artists, genre list, searches, ListenBrainz tags,
-- ListenBrainz similar artists. p_lb_only: MusicBrainz is rate-limiting this
-- run, ListenBrainz work only (its own limit).
drop function if exists public.mb_next_work();
create or replace function public.mb_next_work(p_lb_only boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
$$;

create or replace function public.mb_fail(p_kind text, p_key text)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
  -- 'genres': retried in 10 minutes (mb_next_work)
end;
$$;

revoke all on function public.mb_save_search(text, jsonb) from public, anon, authenticated;
revoke all on function public.mb_save_lb_tags(text, text[]) from public, anon, authenticated;
revoke all on function public.mb_save_lb_similar(uuid, uuid[]) from public, anon, authenticated;
revoke all on function public.mb_save_genres(text[]) from public, anon, authenticated;
revoke all on function public.mb_save_recording(text, jsonb) from public, anon, authenticated;
revoke all on function public.mb_save_artist(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.mb_has_work() from public, anon, authenticated;
revoke all on function public.mb_next_work(boolean) from public, anon, authenticated;
revoke all on function public.mb_fail(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Compatibility between two songs
-- ---------------------------------------------------------------------------

do $$
begin
  if not exists (select 1 from pg_type where typname = 'song_feature' and typnamespace = 'public'::regnamespace) then
    create type public.song_feature as (isrc text, artists uuid[], neighbours uuid[], tags text[]);
  end if;
end $$;

-- What matchmaking knows of a song: MusicBrainz artists, their MusicBrainz
-- relations + ListenBrainz similar artists, genres/tags (recording,
-- ListenBrainz, artists). NULL = nothing known.
create or replace function public.song_features(p_isrc text)
returns public.song_feature
language sql
stable
security definer
set search_path = public
as $$
  select row(
    r.isrc,
    r.artist_mbids,
    coalesce((select array_agg(distinct x)
              from mb_artists a, unnest(a.related_mbids || a.lb_similar) x
              where a.mbid = any (r.artist_mbids) and a.status = 'found'), '{}'),
    coalesce((select array_agg(distinct t)
              from (select unnest(r.tags || r.lb_tags) t
                    union
                    select unnest(a.tags) from mb_artists a
                    where a.mbid = any (r.artist_mbids) and a.status = 'found') x), '{}')
  )::song_feature
  from recordings r
  where r.isrc = p_isrc and r.status = 'found' and cardinality(r.artist_mbids) > 0;
$$;

-- Symmetric, 0..1, NULL when either song is unknown. Step-8 constants.
create or replace function public.song_compat(a public.song_feature, b public.song_feature)
returns real
language plpgsql
stable
security definer
set search_path = public
as $$
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
  end if;
  return v_score;
end;
$$;

revoke all on function public.song_features(text) from public, anon, authenticated;
revoke all on function public.song_compat(public.song_feature, public.song_feature) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Configuration, skips, log
-- ---------------------------------------------------------------------------

create table if not exists public.matchmaking_config (
  id integer primary key default 1 check (id = 1),
  continuity_weight real not null default 0.6,  -- both songs with the ref (last song decided to sound)
  pair_weight real not null default 0.4,        -- A with B
  taste_weight real not null default 0.1,       -- present users' affinity
  turn_weight real not null default 0.15,       -- penalty for passing over better turns
  neutral_compat real not null default 0.35,    -- an unknown song (no MusicBrainz data)
  max_skips integer not null default 3,         -- passed over this many times -> fights next
  log_retention_days integer not null default 30
);
insert into public.matchmaking_config (id) values (1) on conflict do nothing;
alter table public.matchmaking_config enable row level security;
revoke all on public.matchmaking_config from anon, authenticated;

-- Times a song of the next 10 with a better turn was passed over
alter table public.queues add column if not exists times_skipped integer not null default 0;

create table if not exists public.matchmaking_log (
  id uuid primary key default gen_random_uuid(),
  arena_id uuid not null references public.arenas(id) on delete cascade,
  battle_id uuid references public.battles(id) on delete set null,
  created_at timestamptz not null default now(),
  ref_song_id uuid,
  song_a_id uuid,
  song_b_id uuid,
  a_source text,  -- 'queue' | 'system'
  b_source text,
  forced boolean not null default false,
  score real,
  candidates jsonb  -- the plan: queue rows, turns, skips, scores
);
create index if not exists matchmaking_log_arena_idx on public.matchmaking_log (arena_id, created_at);
create index if not exists matchmaking_log_created_idx on public.matchmaking_log (created_at);
alter table public.matchmaking_log enable row level security;
revoke all on public.matchmaking_log from anon, authenticated;

-- New proposals start without skips (client values ignored, like battles_waited)
create or replace function public.validate_queue_proposal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- ---------------------------------------------------------------------------
-- 4. The plan: the next 10 in the order they would fight
-- ---------------------------------------------------------------------------

-- The last arena song decided to sound: the last winner appended (B of a
-- draw), else the warm-up. Skipped (unplayable) songs never sounded.
create or replace function public.matchmaking_ref_song(p_arena_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select pq.winner_song_id from playlist_queue pq
     where pq.arena_id = p_arena_id and pq.unplayable_at is null
     order by pq.seq desc limit 1),
    (select a.warmup_song_id from arenas a where a.id = p_arena_id and a.warmup_unplayable_at is null));
$$;

-- Score of one song against a partner and the ref (system songs); NULL
-- features = neutral. Without a partner, continuity only.
create or replace function public.matchmaking_song_score(
  p_song public.song_feature, p_partner public.song_feature, p_ref public.song_feature, p_has_partner boolean)
returns real
language plpgsql
stable
security definer
set search_path = public
as $$
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
$$;

-- Greedy over the next 10 that may sound: best pair, then the best pair of
-- the rest, ... (the ref stays the same: later winners aren't known yet).
-- pair_no 1 = the next battle. A song without a partner of another proposer
-- fights a system song (alone in its pair_no). Songs that can't sound yet
-- (60-min rule) come last, without pair_no.
create or replace function public.matchmaking_plan(p_arena_id uuid)
returns table(pos integer, queue_id uuid, song_id uuid, proposed_by uuid, pair_no integer,
              turn integer, skips integer, score real, continuity real, forced boolean,
              available_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  m matchmaking_config;
  v_ref public.song_feature;
  v_ids uuid[];
  v_songs uuid[];
  v_props uuid[];
  v_skips int[];
  v_feats public.song_feature[];
  v_cont real[] := '{}';
  v_taste real[] := '{}';
  v_pair real[] := '{}';
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
         array_agg(song_features(x.isrc) order by x.global_rank)
  into v_ids, v_songs, v_props, v_skips, v_feats
  from (
    select r.id, r.song_id, r.proposed_by, r.global_rank, q.times_skipped, s.isrc
    from queue_ranked(p_arena_id) r
    join queues q on q.id = r.id
    join songs s on s.id = r.song_id
    where r.queue_type = 'active'
      and track_available_at(p_arena_id, s.spotify_track_id) is null
  ) x;
  v_n := coalesce(cardinality(v_ids), 0);
  v_span := greatest(v_n - 1, 1);

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
      pair_no := v_pair_no; turn := i; skips := v_skips[i]; score := v_best;
      continuity := v_cont[i]; forced := coalesce(v_forced = i, false); available_at := null;
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
         track_available_at(p_arena_id, s.spotify_track_id)
  from queue_ranked(p_arena_id) r
  join queues q on q.id = r.id
  join songs s on s.id = r.song_id
  where r.queue_type = 'active'
    and track_available_at(p_arena_id, s.spotify_track_id) is not null
  order by r.global_rank;
end;
$$;

revoke all on function public.matchmaking_ref_song(uuid) from public, anon, authenticated;
revoke all on function public.matchmaking_song_score(public.song_feature, public.song_feature, public.song_feature, boolean) from public, anon, authenticated;
revoke all on function public.matchmaking_plan(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. System songs by compatibility (same chain as before)
-- ---------------------------------------------------------------------------

drop function if exists public.pick_rematch_song(uuid, text[], uuid, uuid);
create or replace function public.pick_rematch_song(
  p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid default null,
  p_partner public.song_feature default null, p_ref public.song_feature default null, p_has_partner boolean default false)
returns uuid
language sql
security definer
set search_path = public
as $$
  select x.id from (
    select s.id, s.isrc, max(b.created_at) as last_fought
    from songs s
    join battles b on b.arena_id = p_arena_id
                  and b.state = 'completed'
                  and b.resolution_type in ('normal', 'sudden_death')
                  and s.id in (b.song_a_id, b.song_b_id)
                  and s.id <> b.winner_song_id
    where s.arena_id = p_arena_id
      and s.role = 'competitor'
      and s.status = 'active'
      and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
      and not exists (select 1 from battles lb where lb.id = p_last_battle and s.id in (lb.song_a_id, lb.song_b_id))
      and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = s.id)
      and track_available_at(p_arena_id, s.spotify_track_id) is null
      and (p_avoid_proposer is null
           or not exists (select 1 from proposal_history h
                          where h.arena_id = p_arena_id and h.song_id = s.id
                            and h.kind = 'proposal' and h.proposed_by = p_avoid_proposer))
    group by s.id, s.isrc
  ) x
  -- Step 17: the most compatible first, then the oldest loser
  order by floor(matchmaking_song_score(song_features(x.isrc), p_partner, p_ref, p_has_partner)
                 / (select fit_bucket from system_song_config where id = 1)) desc,
           x.last_fought, random()
  limit 1;
$$;

drop function if exists public.pick_member_profile_song(uuid, text[], uuid);
create or replace function public.pick_member_profile_song(
  p_arena_id uuid, p_exclude text[], p_avoid_proposer uuid default null,
  p_partner public.song_feature default null, p_ref public.song_feature default null, p_has_partner boolean default false)
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
  -- Step 17: compatible with the song it fights and the ref first, then fit
  order by floor(matchmaking_song_score(song_features(c.isrc), p_partner, p_ref, p_has_partner) / v_bucket) desc,
           floor(case when cardinality(v_isrcs) > 0 then song_set_score(v_isrcs, v_ws, c.isrc) end / v_bucket)
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

-- p_partner_isrc: the song it will fight (NULL when choosing A); p_ref_isrc:
-- the last song decided to sound
drop function if exists public.pick_fallback_song(uuid, text[], uuid, uuid);
create or replace function public.pick_fallback_song(
  p_arena_id uuid, p_exclude text[], p_last_battle uuid, p_avoid_proposer uuid default null,
  p_partner_isrc text default null, p_ref_isrc text default null, p_has_partner boolean default false)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_song uuid;
  v_bucket real;
  v_partner public.song_feature := song_features(p_partner_isrc);
  v_ref public.song_feature := song_features(p_ref_isrc);
begin
  -- 1. revancha (not one of the other song's proposer)
  v_song := pick_rematch_song(p_arena_id, p_exclude, p_last_battle, p_avoid_proposer, v_partner, v_ref, p_has_partner);
  if v_song is not null then
    return v_song;
  end if;

  -- 2-3. reserve: libraries (host's source, guests'), then the arena's
  -- artists; inside each, the most compatible with the song it fights and
  -- the ref (step 17), then fit (buckets), taste, random
  select fit_bucket into v_bucket from system_song_config where id = 1;
  select s.id into v_song
  from arena_song_reserve r join songs s on s.id = r.song_id
  where r.arena_id = p_arena_id
    and not (s.spotify_track_id = any (coalesce(p_exclude, '{}')))
    and not exists (select 1 from queues q where q.arena_id = p_arena_id and q.song_id = s.id)
    and track_available_at(p_arena_id, s.spotify_track_id) is null
  order by r.source = 'arena_artist',
           floor(matchmaking_song_score(song_features(s.isrc), v_partner, v_ref, p_has_partner) / v_bucket) desc,
           r.fit is null, floor(r.fit / v_bucket) desc,
           r.taste desc nulls last, random()
  limit 1;
  if v_song is not null then
    return v_song;
  end if;

  -- 3b. present members' own MF profiles (their signals in other arenas)
  v_song := pick_member_profile_song(p_arena_id, p_exclude, p_avoid_proposer, v_partner, v_ref, p_has_partner);
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
  order by floor(matchmaking_song_score(song_features(s.isrc), v_partner, v_ref, p_has_partner) / v_bucket) desc,
           random()
  limit 1;
  return v_song;
end;
$$;

revoke all on function public.pick_rematch_song(uuid, text[], uuid, uuid, public.song_feature, public.song_feature, boolean) from public, anon, authenticated;
revoke all on function public.pick_member_profile_song(uuid, text[], uuid, public.song_feature, public.song_feature, boolean) from public, anon, authenticated;
revoke all on function public.pick_fallback_song(uuid, text[], uuid, uuid, text, text, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Pulling the next pair
-- ---------------------------------------------------------------------------

create or replace function public.pull_next_battle_songs(p_arena_id uuid)
returns table(song_a uuid, song_b uuid)
language plpgsql
security definer
set search_path = public
as $$
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
  v_purged uuid[];
begin
  perform lock_arena_queue(p_arena_id);

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
  insert into matchmaking_log (arena_id, ref_song_id, song_a_id, song_b_id, a_source, b_source, forced, score, candidates)
  values (p_arena_id, v_ref, v_a_song, v_b_song,
          case when v_a_row is null then 'system' else 'queue' end,
          case when v_b_row is null then 'system' else 'queue' end,
          v_forced, v_score, v_plan)
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
$$;

create or replace function public.create_next_battle(p_arena_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- ---------------------------------------------------------------------------
-- 7. What members see: the next 10 in the order they would fight
-- ---------------------------------------------------------------------------

create or replace function public.get_arena_next_up(p_arena_id uuid)
returns table(pos integer, song_id uuid, spotify_track_id text, title text, artist text,
              artwork_url text, duration_ms integer, pair_no integer, vs_system boolean,
              is_mine boolean, available_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  with plan as (select * from matchmaking_plan(p_arena_id))
  select p.pos, s.id, s.spotify_track_id, s.title, s.artist, s.artwork_url, s.duration_ms, p.pair_no,
         -- Only the next battle: later lone songs may still get a partner
         p.pair_no = 1 and (select count(*) from plan o where o.pair_no = 1) = 1,
         p.proposed_by is not distinct from auth.uid(),
         p.available_at
  from plan p join songs s on s.id = p.song_id
  where exists (select 1 from arenas a where a.id = p_arena_id and a.state in ('waiting', 'active'))
    and exists (select 1 from participants pa where pa.arena_id = p_arena_id and pa.identity_anchor_id = auth.uid())
  order by p.pos;
$$;

revoke all on function public.get_arena_next_up(uuid) from public, anon;
grant execute on function public.get_arena_next_up(uuid) to authenticated;
