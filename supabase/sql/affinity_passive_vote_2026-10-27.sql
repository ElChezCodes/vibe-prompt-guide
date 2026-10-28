-- ===========================================================================
-- Roadmap steps 8 + 9 (2026-10-27): own affinity profile + passive vote.
--
-- Step 8 (user decisions 2026-10-27):
--   * Signals are only what the user does in Music Fighter: explicit votes
--     (recorded when the battle completes), active proposals (and the host's
--     warm-up pick) and manual "likes" (song_likes, reconnected; the old
--     3-like auto-queue trigger is dropped).
--   * Spotify <-> open data bridge = ISRC. songs.isrc is read from Spotify's
--     external_ids by spotify-host; everything the profile/model uses is keyed
--     by ISRC and comes from MusicBrainz (recordings, mb_artists), never from
--     Spotify names/ids/artwork (Developer Policy III.13/III.14).
--   * MusicBrainz lookups run in the background: the musicbrainz-enrich Edge
--     Function, called every minute by pg_cron while there is work, <= 1 req/s.
--   * Retention: an account's signals persist until the account is deleted
--     (FK cascade) and lose weight with age (half-life in passive_vote_config);
--     an anonymous user's signals only score inside the arena they came from
--     and are deleted with that arena's 30-day vote purge. Merging an
--     anonymous user into an account moves them (they become persistent).
--   * Engine v0 = explainable rules (affinity_score): same song 1.0, same
--     artist 0.9, MusicBrainz-related artist 0.75, genre/tag coverage of the
--     song by the user's top tags (capped 0.85). Needs min_signals songs.
--
-- Step 9 (rules decided by the user 2026-10-27):
--   * Eligible: PASIVO in the lock-in battle_presence_snapshots, no votes row
--     for the battle (cancelled = abstained), enough signals. One passive vote
--     per participant, for the song with the higher score, only if >= 0.7;
--     equal scores = no vote.
--   * Value scaled 0.4 (score 0.7) -> 0.5 (score 1.0); 0.5 -> 0.6 when >= 75 %
--     of present (ACTIVO+PASIVO) users are PASIVO.
--   * Cap: total passive <= k (1.25) x active points, scaled down
--     proportionally; no cap when there are 0 active votes. ("Never reverse a
--     clear win" from Paso_1 §8 was NOT adopted.)
--   * Frozen until 30 s before lock-in, ramps over them (display only, live
--     presence); the votes cast at lock-in from the snapshot are what count.
--     0 in Sudden Death (the SD tally only counts sudden_death votes).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. ISRC on the Spotify-side songs rows
-- ---------------------------------------------------------------------------
alter table public.songs add column if not exists isrc text;
create index if not exists songs_isrc_idx on public.songs (isrc) where isrc is not null;

create or replace function public.normalize_isrc(p text)
returns text
language sql
immutable
as $$
  select case when upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) ~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$'
              then upper(regexp_replace(p, '[^A-Za-z0-9]', '', 'g')) end;
$$;

create or replace function public.upsert_spotify_song(p_arena_id uuid, p_track jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- ---------------------------------------------------------------------------
-- 2. Open-data catalog (MusicBrainz, keyed by ISRC / MBID). Service-only.
-- ---------------------------------------------------------------------------
create table if not exists public.recordings (
  isrc text primary key,
  mbid uuid,
  artist_mbids uuid[] not null default '{}',
  -- MusicBrainz genres (else top tags) of the recording, lowercase
  tags text[] not null default '{}',
  status text not null default 'pending'
    check (status in ('pending', 'found', 'not_found', 'error', 'failed')),
  attempts int not null default 0,
  next_attempt_at timestamptz not null default now(),
  looked_up_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.recordings enable row level security;
revoke all on public.recordings from anon, authenticated;

create table if not exists public.mb_artists (
  mbid uuid primary key,
  name text,
  tags text[] not null default '{}',
  -- MusicBrainz artist-artist relations (members, collaborations, ...)
  related_mbids uuid[] not null default '{}',
  status text not null default 'pending'
    check (status in ('pending', 'found', 'not_found', 'error', 'failed')),
  attempts int not null default 0,
  next_attempt_at timestamptz not null default now(),
  looked_up_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.mb_artists enable row level security;
revoke all on public.mb_artists from anon, authenticated;

-- Single run lease so overlapping cron calls never exceed MusicBrainz's 1 req/s
create table if not exists public.mb_enrich_state (
  id int primary key default 1 check (id = 1),
  running_until timestamptz
);
insert into public.mb_enrich_state (id) values (1) on conflict do nothing;
alter table public.mb_enrich_state enable row level security;
revoke all on public.mb_enrich_state from anon, authenticated;

-- Every song with an ISRC gets its recording queued for lookup
create or replace function public.queue_recording_lookup()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.isrc is not null then
    insert into recordings (isrc) values (new.isrc) on conflict do nothing;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_songs_queue_recording on public.songs;
create trigger trg_songs_queue_recording
after insert or update of isrc on public.songs
for each row execute function public.queue_recording_lookup();

create or replace function public.mb_has_work()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from recordings where status in ('pending', 'error') and next_attempt_at <= now())
      or exists (select 1 from mb_artists where status in ('pending', 'error') and next_attempt_at <= now());
$$;

create or replace function public.mb_enrich_begin(p_seconds int default 55)
returns boolean
language sql
security definer
set search_path = public
as $$
  with got as (
    update mb_enrich_state
    set running_until = now() + make_interval(secs => p_seconds)
    where id = 1 and (running_until is null or running_until < now())
    returning 1
  )
  select exists (select 1 from got);
$$;

create or replace function public.mb_enrich_end()
returns void
language sql
security definer
set search_path = public
as $$
  update mb_enrich_state set running_until = null where id = 1;
$$;

-- Next lookup: recordings first (they discover the artists). The row is
-- leased for 5 min so a crashed run doesn't block it forever.
create or replace function public.mb_next_work()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
begin
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

  return null;
end;
$$;

-- p_result null = MusicBrainz doesn't know this ISRC
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
    update recordings set status = 'not_found', looked_up_at = now(), attempts = attempts + 1
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
      looked_up_at = now(),
      attempts = attempts + 1
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
    update mb_artists set status = 'not_found', looked_up_at = now(), attempts = attempts + 1
    where mbid = p_mbid;
    return;
  end if;

  update mb_artists
  set name = p_result->>'name',
      tags = array(select distinct lower(t) from jsonb_array_elements_text(coalesce(p_result->'tags', '[]')) t),
      related_mbids = array(select distinct r::uuid from jsonb_array_elements_text(coalesce(p_result->'related_mbids', '[]')) r),
      status = 'found',
      looked_up_at = now(),
      attempts = attempts + 1
  where mbid = p_mbid;
end;
$$;

-- Transient failure: back off 2^attempts minutes, give up after 6 tries
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
  else
    update mb_artists
    set attempts = attempts + 1,
        status = case when attempts + 1 >= 6 then 'failed' else 'error' end,
        next_attempt_at = now() + make_interval(mins => power(2, attempts + 1)::int)
    where mbid = p_key::uuid;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Affinity signals (step 8). Keyed by user + ISRC; no battle/vote link, so
--    they survive the 30-day vote purge for accounts. Service-only.
-- ---------------------------------------------------------------------------
create table if not exists public.affinity_signals (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  isrc text not null,
  kind text not null check (kind in ('vote', 'proposal', 'like')),
  -- Where it happened: the scope of an anonymous user's in-arena profile
  arena_id uuid references public.arenas (id) on delete set null,
  weight real not null,
  created_at timestamptz not null default now(),
  constraint affinity_signals_unique unique nulls not distinct (user_id, kind, isrc, arena_id)
);
create index if not exists affinity_signals_user_idx on public.affinity_signals (user_id);
create index if not exists affinity_signals_arena_idx on public.affinity_signals (arena_id);
alter table public.affinity_signals enable row level security;
revoke all on public.affinity_signals from anon, authenticated;

-- v0 parameters, one row; changing a rule is an UPDATE (e.g. k after Sergio)
create table if not exists public.passive_vote_config (
  id int primary key default 1 check (id = 1),
  min_score real not null default 0.7,
  base_value real not null default 0.4,
  boosted_value real not null default 0.5,
  value_span real not null default 0.1,
  boost_passive_ratio real not null default 0.75,
  k_cap real not null default 1.25,
  ramp_seconds int not null default 30,
  min_signals int not null default 3,
  half_life_days int not null default 365,
  top_tags int not null default 10,
  score_same_song real not null default 1.0,
  score_same_artist real not null default 0.9,
  score_related_artist real not null default 0.75,
  score_tags_cap real not null default 0.85,
  weight_like real not null default 1.0,
  weight_proposal real not null default 1.0,
  weight_vote real not null default 0.5
);
insert into public.passive_vote_config (id) values (1) on conflict do nothing;
alter table public.passive_vote_config enable row level security;
revoke all on public.passive_vote_config from anon, authenticated;

create or replace function public.record_affinity_signal(p_user uuid, p_song uuid, p_kind text, p_arena uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
$$;
revoke all on function public.record_affinity_signal(uuid, uuid, text, uuid) from public, anon, authenticated;

-- Proposals (human ones: proposed_by is stamped from auth.uid())
create or replace function public.signal_on_proposal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.proposed_by is not null then
    perform record_affinity_signal(new.proposed_by, new.song_id, 'proposal', new.arena_id);
  end if;
  return null;
end;
$$;

drop trigger if exists trg_queues_affinity_signal on public.queues;
create trigger trg_queues_affinity_signal
after insert on public.queues
for each row execute function public.signal_on_proposal();

-- Explicit votes, once the battle is over (the final pick counts, toggled-off
-- votes don't; passive votes are never a signal)
create or replace function public.signal_on_battle_completed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

drop trigger if exists trg_battles_affinity_signals on public.battles;
create trigger trg_battles_affinity_signals
after update of state on public.battles
for each row
when (new.state = 'completed' and old.state is distinct from 'completed')
execute function public.signal_on_battle_completed();

-- The host's warm-up pick counts as a proposal
create or replace function public.create_arena_spotify(p_host_id uuid, p_name text, p_mood text, p_track jsonb)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- ---------------------------------------------------------------------------
-- 4. "Like" reconnected as a manual signal (not the 3-like auto-queue)
-- ---------------------------------------------------------------------------
drop trigger if exists trg_promote_liked_song_to_queue on public.song_likes;
drop function if exists public.promote_liked_song_to_queue();

-- Writes only through toggle_song_like
drop policy if exists song_likes_insert_self on public.song_likes;
drop policy if exists song_likes_delete_self on public.song_likes;
revoke insert, update, delete on public.song_likes from anon, authenticated;

create or replace function public.toggle_song_like(p_arena_id uuid, p_song_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_participant uuid;
  v_deleted int;
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

  delete from song_likes where participant_id = v_participant and song_id = p_song_id;
  get diagnostics v_deleted = row_count;
  if v_deleted > 0 then
    delete from affinity_signals s
    using songs so
    where so.id = p_song_id and s.user_id = v_uid and s.kind = 'like'
      and s.isrc = so.isrc and s.arena_id = p_arena_id;
    return false;
  end if;

  insert into song_likes (arena_id, song_id, participant_id) values (p_arena_id, p_song_id, v_participant);
  perform record_affinity_signal(v_uid, p_song_id, 'like', p_arena_id);
  return true;
end;
$$;
revoke all on function public.toggle_song_like(uuid, uuid) from public, anon;
grant execute on function public.toggle_song_like(uuid, uuid) to authenticated;

-- fill_song_like_fields needs auth.uid(); toggle_song_like passes participant_id itself
drop trigger if exists trg_fill_song_like_fields on public.song_likes;

create or replace function public.get_my_song_likes(p_arena_id uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select l.song_id from song_likes l join participants p on p.id = l.participant_id
  where l.arena_id = p_arena_id and p.identity_anchor_id = auth.uid();
$$;
revoke all on function public.get_my_song_likes(uuid) from public, anon;
grant execute on function public.get_my_song_likes(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Affinity score v0 (step 8). Scope: account = all its signals (decayed);
--    anonymous = only what it did in p_arena. NULL = not enough signals.
--    Usable by step 13 (system proposals) as well.
-- ---------------------------------------------------------------------------
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
  v_target recordings;
  v_target_related uuid[];
  v_target_tags text[];
  v_user_tags text[];
  v_overlap int;
  v_score real := 0;
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

  -- Same song
  if p_isrc = any (v_isrcs) then
    return c.score_same_song;
  end if;

  select * into v_target from recordings where isrc = p_isrc and status = 'found';
  if not found then
    return 0;
  end if;

  -- Same artist
  if exists (select 1 from recordings r
             where r.isrc = any (v_isrcs) and r.status = 'found' and r.artist_mbids && v_target.artist_mbids) then
    return c.score_same_artist;
  end if;

  -- MusicBrainz-related artist (either direction)
  select coalesce(array_agg(distinct x), '{}') into v_target_related
  from mb_artists a, unnest(a.related_mbids) x
  where a.mbid = any (v_target.artist_mbids) and a.status = 'found';

  if exists (
    select 1 from recordings r
    where r.isrc = any (v_isrcs) and r.status = 'found'
      and (r.artist_mbids && v_target_related
           or exists (select 1 from mb_artists a where a.mbid = any (r.artist_mbids) and a.status = 'found'
                      and a.related_mbids && v_target.artist_mbids))
  ) then
    v_score := c.score_related_artist;
  end if;

  -- Genres/tags: share of the song's tags among the user's top tags
  select coalesce(array_agg(distinct t), '{}') into v_target_tags
  from (
    select unnest(v_target.tags) t
    union
    select unnest(a.tags) from mb_artists a where a.mbid = any (v_target.artist_mbids) and a.status = 'found'
  ) x;

  if cardinality(v_target_tags) > 0 then
    with sig as (
      select u.isrc, u.w from unnest(v_isrcs, v_ws) as u(isrc, w)
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
revoke all on function public.affinity_score(uuid, text, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Passive votes (step 9)
-- ---------------------------------------------------------------------------
-- Snapshot taken explicitly at lock-in, before the passive votes are cast
-- (the lockin_at trigger stays as a backstop; conflicts are ignored)
create or replace function public.snapshot_battle_presence(p_battle_id uuid, p_arena_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  insert into battle_presence_snapshots (battle_id, participant_id, arena_id, identity_anchor_id, state, last_active_at)
  select p_battle_id, pp.participant_id, pp.arena_id, pp.identity_anchor_id, pp.state, pp.last_active_at
  from participant_presence pp
  where pp.arena_id = p_arena_id
  on conflict (battle_id, participant_id) do nothing;
$$;
revoke all on function public.snapshot_battle_presence(uuid, uuid) from public, anon, authenticated;

create or replace function public.snapshot_presence_at_lockin()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform snapshot_battle_presence(new.id, new.arena_id);
  return null;
end;
$$;

-- Who would get a passive vote and its weight (cap applied).
-- p_live = false: the lock-in snapshot (what counts); true: live presence
-- (only for the final-30-s preview on the tension bar).
create or replace function public.passive_vote_candidates(p_battle_id uuid, p_live boolean default false)
returns table (participant_id uuid, identity_anchor_id uuid, song_id uuid, weight real)
language plpgsql
stable
security definer
set search_path = public
as $$
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
begin
  select * into c from passive_vote_config where id = 1;
  select * into b from battles where id = p_battle_id;
  if not found then
    return;
  end if;
  select isrc into v_isrc_a from songs where id = b.song_a_id;
  select isrc into v_isrc_b from songs where id = b.song_b_id;

  select count(*) filter (where x.state in ('active', 'passive')), count(*) filter (where x.state = 'passive')
  into v_present, v_passive
  from (
    select pp.state from participant_presence pp where p_live and pp.arena_id = b.arena_id
    union all
    select s.state from battle_presence_snapshots s where not p_live and s.battle_id = b.id
  ) x;
  v_base := case when v_present > 0 and v_passive >= c.boost_passive_ratio * v_present
                 then c.boosted_value else c.base_value end;

  for r in
    select x.pid, x.anchor from (
      select pp.participant_id as pid, pp.identity_anchor_id as anchor, pp.state
      from participant_presence pp where p_live and pp.arena_id = b.arena_id
      union all
      select s.participant_id, s.identity_anchor_id, s.state
      from battle_presence_snapshots s where not p_live and s.battle_id = b.id
    ) x
    where x.state = 'passive'
      -- No votes row at all: a cancelled vote means the user abstained
      and not exists (select 1 from votes v where v.battle_id = b.id and v.participant_id = x.pid)
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
$$;
revoke all on function public.passive_vote_candidates(uuid, boolean) from public, anon, authenticated;

create or replace function public.cast_passive_votes(p_battle_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
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
$$;
revoke all on function public.cast_passive_votes(uuid) from public, anon, authenticated;

-- Passive votes are written by the system only (no auth.uid()); clients
-- can't insert them anyway (no insert policy for vote_type 'passive')
create or replace function public.fill_vote_fields()
returns trigger
language plpgsql
as $$
BEGIN
  IF NEW.vote_type = 'passive' THEN
    IF auth.uid() IS NOT NULL THEN
      RAISE EXCEPTION 'passive votes are system-only';
    END IF;
  ELSE
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
$$;

-- Passive points of a battle for display: the real passive votes once locked
-- in (0 in Sudden Death), the live preview ramping over the 30 s before
-- lock-in, 0 before that.
create or replace function public.battle_passive_tally(p_battle_id uuid)
returns table (passive_a real, passive_b real)
language plpgsql
stable
security definer
set search_path = public
as $$
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
  v_lockin := b.started_at + ((b.duration_ms - 15000) * interval '1 millisecond');
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
$$;
revoke all on function public.battle_passive_tally(uuid) from public;
grant execute on function public.battle_passive_tally(uuid) to anon, authenticated;

-- votes_a/b = explicit votes (count); passive_a/b = passive points
create or replace view public.arena_live_state as
select g.*, t.passive_a, t.passive_b
from (
  SELECT b.id AS battle_id,
    b.arena_id,
    b.state AS status,
    b.started_at,
    b.duration_ms,
    b.lockin_at,
    b.resolution_type,
    b.winner_song_id,
    b.created_at AS battle_created_at,
    sa.id AS song_a_id,
    sa.title AS song_a_title,
    sa.artist AS song_a_artist,
    sa.source AS song_a_source,
    sa.spotify_track_id AS song_a_spotify_track_id,
    sa.duration_ms AS song_a_duration_ms,
    sb.id AS song_b_id,
    sb.title AS song_b_title,
    sb.artist AS song_b_artist,
    sb.source AS song_b_source,
    sb.spotify_track_id AS song_b_spotify_track_id,
    sb.duration_ms AS song_b_duration_ms,
    count(v.id) FILTER (WHERE v.song_id = sa.id AND v.status = 'active' AND v.vote_type <> 'passive'
      AND (b.sudden_death_started_at IS NULL OR v.vote_type = 'sudden_death')) AS votes_a,
    count(v.id) FILTER (WHERE v.song_id = sb.id AND v.status = 'active' AND v.vote_type <> 'passive'
      AND (b.sudden_death_started_at IS NULL OR v.vote_type = 'sudden_death')) AS votes_b,
    b.sudden_death_active,
    sa.artwork_url AS song_a_artwork_url,
    sb.artwork_url AS song_b_artwork_url
  FROM battles b
    JOIN songs sa ON sa.id = b.song_a_id
    JOIN songs sb ON sb.id = b.song_b_id
    LEFT JOIN votes v ON v.battle_id = b.id
  WHERE b.state = ANY (ARRAY['pending', 'active', 'closing', 'completed'])
  GROUP BY b.id, sa.id, sb.id
) g
cross join lateral public.battle_passive_tally(g.battle_id) t;

-- ---------------------------------------------------------------------------
-- 7. Lock-in: snapshot -> passive votes -> totals (regular + passive)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.process_battle_lifecycle(p_arena_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_battle RECORD;
    v_now timestamptz := now();
    v_lockin_at timestamptz;
    v_end_at timestamptz;

    v_votes RECORD;
    v_winner uuid;
BEGIN

    -- 1️⃣ Obtener battle viva y lockearla
    SELECT *
    INTO v_battle
    FROM battles
    WHERE arena_id = p_arena_id
      AND state IN ('pending','active','closing')
    ORDER BY created_at
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    -- 2️⃣ pending → active
    IF v_battle.state = 'pending' THEN
        UPDATE battles
        SET state = 'active',
            started_at = v_now
        WHERE id = v_battle.id;
        RETURN;
    END IF;

    -- Calcular tiempos deterministas
    v_lockin_at :=
        v_battle.started_at
        + ((v_battle.duration_ms - 15000) * interval '1 millisecond');

    v_end_at :=
        v_battle.started_at
        + (v_battle.duration_ms * interval '1 millisecond');

    -- 3️⃣ ACTIVE → CLOSING (LOCK-IN)
    IF v_battle.state = 'active'
       AND v_now >= v_lockin_at
    THEN

        -- Step 9: presence frozen at lock-in, then the passive votes from it
        PERFORM snapshot_battle_presence(v_battle.id, v_battle.arena_id);
        PERFORM cast_passive_votes(v_battle.id);

        SELECT *
        INTO v_votes
        FROM calculate_lockin_vote_totals(v_battle.id);

        IF v_votes.is_tie = false THEN

            v_winner := CASE
                WHEN v_votes.votes_a > v_votes.votes_b THEN v_battle.song_a_id
                ELSE v_battle.song_b_id
            END;

            INSERT INTO playlist_queue (
                arena_id,
                battle_id,
                winner_song_id,
                spotify_track_id,
                song_duration_ms,
                created_at
            )
            SELECT
                v_battle.arena_id,
                v_battle.id,
                s.id,
                s.spotify_track_id,
                s.duration_ms,
                v_now
            FROM songs s
            WHERE s.id = v_winner;

            UPDATE battles
            SET state = 'closing',
                lockin_at = v_lockin_at,
                winner_song_id = v_winner,
                resolution_type = 'normal'
            WHERE id = v_battle.id;

        ELSE
            UPDATE battles
            SET state = 'closing',
                lockin_at = v_lockin_at,
                sudden_death_active = true,
                sudden_death_started_at = v_lockin_at
            WHERE id = v_battle.id;
        END IF;

        RETURN;
    END IF;

    -- 4️⃣ END OF BATTLE
    IF v_battle.state = 'closing'
       AND v_now >= v_end_at
    THEN

        -- Releer estado real antes de resolver
        SELECT *
        INTO v_battle
        FROM battles
        WHERE id = v_battle.id
        FOR UPDATE;

        -- Resolver Sudden Death si estaba activo
        IF v_battle.sudden_death_active = true THEN

            SELECT
                COALESCE(SUM(weight) FILTER (
                    WHERE song_id = v_battle.song_a_id
                    AND vote_type = 'sudden_death'
                    AND status = 'active'
                ),0) AS votes_a,
                COALESCE(SUM(weight) FILTER (
                    WHERE song_id = v_battle.song_b_id
                    AND vote_type = 'sudden_death'
                    AND status = 'active'
                ),0) AS votes_b
            INTO v_votes
            FROM votes
            WHERE battle_id = v_battle.id;

            IF v_votes.votes_a <> v_votes.votes_b THEN

                v_winner := CASE
                    WHEN v_votes.votes_a > v_votes.votes_b THEN v_battle.song_a_id
                    ELSE v_battle.song_b_id
                END;

                INSERT INTO playlist_queue (
                    arena_id,
                    battle_id,
                    winner_song_id,
                    spotify_track_id,
                    song_duration_ms,
                    created_at
                )
                SELECT
                    v_battle.arena_id,
                    v_battle.id,
                    s.id,
                    s.spotify_track_id,
                    s.duration_ms,
                    v_now
                FROM songs s
                WHERE s.id = v_winner;

                UPDATE battles
                SET winner_song_id = v_winner,
                    resolution_type = 'sudden_death',
                    sudden_death_active = false
                WHERE id = v_battle.id;

            ELSE
                -- SD empate real (0-0 o X-X) → DRAW
                INSERT INTO playlist_queue (
                    arena_id,
                    battle_id,
                    winner_song_id,
                    spotify_track_id,
                    song_duration_ms,
                    created_at
                )
                SELECT
                    v_battle.arena_id,
                    v_battle.id,
                    s.id,
                    s.spotify_track_id,
                    s.duration_ms,
                    v_now
                FROM songs s
                WHERE s.id IN (v_battle.song_a_id, v_battle.song_b_id);

                UPDATE battles
                SET resolution_type = 'draw',
                    sudden_death_active = false
                WHERE id = v_battle.id;
            END IF;
        END IF;

        -- Garantizar resolución antes de completar
        SELECT resolution_type
        INTO v_votes
        FROM battles
        WHERE id = v_battle.id;

        IF v_votes.resolution_type IS NULL THEN
            RETURN; -- no completar si no hay resolución válida
        END IF;

        -- Cierre final
        UPDATE battles
        SET state = 'completed',
            ended_at = v_end_at,
            enqueue_done = true
        WHERE id = v_battle.id;

        -- Next battle from the queue chain (step 12b); no pair = the arena
        -- waits and battle_lifecycle_job retries via create_next_battle
        PERFORM create_next_battle(v_battle.arena_id);

        RETURN;
    END IF;

END;
$function$;

-- ---------------------------------------------------------------------------
-- 8. Retention (Block 5 §6) and account merge
-- ---------------------------------------------------------------------------
alter table public.battles add column if not exists final_passive_a real;
alter table public.battles add column if not exists final_passive_b real;

create or replace function public.purge_old_arena_votes(p_retention interval default '30 days'::interval)
returns integer
language plpgsql
security definer
set search_path = public
as $$
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

    -- Anonymous users' in-arena profile goes with the votes; accounts keep theirs
    delete from affinity_signals s
    using auth.users u
    where s.arena_id = r.id and u.id = s.user_id and u.is_anonymous;

    update arenas set votes_purged_at = now() where id = r.id;
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

create or replace function public.merge_anonymous_user(p_from uuid, p_to uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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

  -- Step 8: the anonymous in-arena profile becomes part of the account's
  delete from affinity_signals a
  using affinity_signals b
  where a.user_id = p_from and b.user_id = p_to
    and a.kind = b.kind and a.isrc = b.isrc and a.arena_id is not distinct from b.arena_id;
  update affinity_signals set user_id = p_to where user_id = p_from;

  delete from spotify_oauth_states where user_id = p_from;
  delete from account_merge_tickets where anon_user_id = p_from;

  return jsonb_build_object('arenas_moved', v_moved, 'arenas_fused', v_fused);
end;
$$;
revoke all on function public.merge_anonymous_user(uuid, uuid) from public, anon, authenticated;
grant execute on function public.merge_anonymous_user(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 9. Service-only grants for the enrichment RPCs + the cron job
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array[
    'normalize_isrc(text)', 'mb_has_work()', 'mb_enrich_begin(int)', 'mb_enrich_end()', 'mb_next_work()',
    'mb_save_recording(text, jsonb)', 'mb_save_artist(uuid, jsonb)', 'mb_fail(text, text)'
  ] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
grant execute on function public.normalize_isrc(text) to anon, authenticated;

select cron.unschedule('musicbrainz_enrich_job')
where exists (select 1 from cron.job where jobname = 'musicbrainz_enrich_job');

select cron.schedule(
  'musicbrainz_enrich_job',
  '* * * * *',
  $cmd$
  select net.http_post(
    url := 'https://uuxzjroikbzwaszpgiks.supabase.co/functions/v1/musicbrainz-enrich',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-watch-secret', coalesce((select decrypted_secret from vault.decrypted_secrets where name = 'spotify_watch_secret'), '')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 58000
  )
  where public.mb_has_work();
  $cmd$
);
