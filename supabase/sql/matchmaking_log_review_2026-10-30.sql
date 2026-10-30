-- ===========================================================================
-- Step 17 follow-up after reading matchmaking_log of the first in-app test
-- (2026-10-30, 15 battles):
-- 1. song_features keeps MusicBrainz genres only: recording/artist
--    folksonomy tags ("billboard hot 100", "5+ wochen", "boastful") made
--    false matches.
-- 2. song_compat: no genres to compare and no artist link = unknown (NULL,
--    neutral), not 0. A song whose MusicBrainz artist has no genres or
--    relations (e.g. found by the artist search) scored 0 against
--    everything, worse than a song MusicBrainz doesn't know.
-- 3. matchmaking_log.components: the picked pair's compatibilities (a_ref,
--    b_ref, a_b), also for system songs (score was NULL for them), and the
--    plan reports real skip counts, not the simulation's.
-- ===========================================================================

alter table public.matchmaking_log add column if not exists components jsonb;

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
$$;

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
  elsif v_score = 0 then
    -- No genres to compare and no artist link: unknown, not incompatible
    -- (a known artist without genres scored 0 against everything, 2026-10-30)
    return null;
  end if;
  return v_score;
end;
$$;

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
  v_skips0 int[];  -- real counts (v_skips also counts the plan's virtual skips)
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
  v_skips0 := v_skips;
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
      pair_no := v_pair_no; turn := i; skips := v_skips0[i]; score := v_best;
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
  v_ref_f public.song_feature;
  v_a_f public.song_feature;
  v_b_f public.song_feature;
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
$$;
