-- ===========================================================================
-- 2026-11-06: votes from the Next up list + in-battle QR votes.
--
-- User decisions 2026-11-06 (no decay, no fractional weights: the formula
-- max(0, 1 - t/60) of the original notes was discarded):
--
-- Next up votes = pre-assigned votes, the mechanism of step 14 (queue_backers,
-- trg_battles_apply_preassigned), through back_proposal(.., p_source 'list'):
--   * Weight 1, cast when the song's battle starts; can be switched, cancelled
--     or upgraded in Sudden Death; not cast if the voter left the arena.
--   * Order: a strong factor of matchmaking_plan (votes_weight), never over
--     max_skips nor "two songs of one proposer never fight". Ties: the turns.
--   * Limits: 3 list votes + 5 duplicate backings, two separate counters. A
--     vote comes back when its battle starts, when the song leaves, or
--     when it is removed (withdraw_backing).
--   * Scope: the button only in the next 10 (server-checked, not_in_next_up);
--     a duplicate proposal still backs any queued song.
--   * PI: none for a list vote (backing_source); duplicates keep their half.
--   * System songs of Next up can be voted: the vote promotes them
--     (fallback_candidate step 0, most votes first, always behind humans). If
--     the song can't fight any more the vote comes back. Songs of a member's
--     profile in another arena aren't in this arena: no button.
--   * Your own proposal: proposing carries your one vote, in Next up only
--     (it shows 1 vote + "Your pick", no button, doesn't use your 3). Battles
--     don't change: no vote is cast for the proposer.
--
-- QR votes: battles.vote_token (one per battle, the rotation) + A or B in the
-- URL (/v/<token>/a). resolve_vote_token only reads; the vote goes through the
-- usual client path (RLS, applyVoteIntent) as an anonymous or account session,
-- after enter_arena (scanning = joining, a normal participant).
-- ===========================================================================

begin;

-- 1. Columns ----------------------------------------------------------------
alter table public.queue_backers
  add column if not exists source text not null default 'duplicate'
  check (source in ('duplicate', 'list'));

alter table public.proposal_history
  add column if not exists backing_source text
  check (backing_source in ('duplicate', 'list'));

alter table public.matchmaking_config
  add column if not exists votes_weight real not null default 2.0,
  add column if not exists list_vote_limit integer not null default 3,
  add column if not exists duplicate_limit integer not null default 5;

alter table public.battles add column if not exists vote_token text;
alter table public.battles alter column vote_token set default substr(md5(gen_random_uuid()::text), 1, 12);
create unique index if not exists battles_vote_token_unique on public.battles (vote_token);

-- 2. A system song that may still fight -------------------------------------
create or replace function public.system_song_votable(p_arena_id uuid, p_song_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $function$
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
$function$;

create or replace function public.release_dead_system_votes(p_arena_id uuid)
returns void
language plpgsql security definer set search_path = public
as $function$
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
$function$;

revoke all on function public.system_song_votable(uuid, uuid) from public, anon, authenticated;
revoke all on function public.release_dead_system_votes(uuid) from public, anon, authenticated;
grant execute on function public.system_song_votable(uuid, uuid) to service_role;
grant execute on function public.release_dead_system_votes(uuid) to service_role;

-- 3. Functions whose result type changes -------------------------------------
drop function public.back_proposal(uuid, uuid);
drop function public.matchmaking_plan(uuid);
drop function public.get_arena_next_up(uuid);
drop function public.arena_next_up(uuid, uuid);
drop function public.get_my_proposals(uuid);

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

-- 4. Definitions updated in place ----------------------------------------

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
$function$;

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
$function$;

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
$function$;

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
$function$;

revoke all on function public.back_proposal(uuid, uuid, text) from public, anon;
grant execute on function public.back_proposal(uuid, uuid, text) to authenticated, service_role;
revoke all on function public.matchmaking_plan(uuid) from public, anon, authenticated;
grant execute on function public.matchmaking_plan(uuid) to service_role;
revoke all on function public.arena_next_up(uuid, uuid) from public, anon, authenticated;
grant execute on function public.arena_next_up(uuid, uuid) to service_role;
revoke all on function public.get_arena_next_up(uuid) from public, anon;
grant execute on function public.get_arena_next_up(uuid) to authenticated, service_role;
revoke all on function public.get_my_proposals(uuid) from public, anon;
grant execute on function public.get_my_proposals(uuid) to authenticated, service_role;

-- 5. What a scanned QR means now (reads only; the vote is the client's, RLS) --
create or replace function public.resolve_vote_token(p_token text, p_side text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $function$
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
$function$;

revoke all on function public.resolve_vote_token(text, text) from public, anon;
grant execute on function public.resolve_vote_token(text, text) to authenticated, service_role;

commit;
