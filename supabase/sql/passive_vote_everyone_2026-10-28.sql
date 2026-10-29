-- Step 9 rule change (user decisions 2026-10-28, after the in-app test where
-- only PASIVO users voted passively): every participant present in the arena
-- who hasn't voted gets a passive vote, not only PASIVO ones.
--
-- * Eligible at lock-in: in the arena and not gone — never left ("Leave
--   arena") and didn't close the app (presence_disconnect after their last
--   heartbeat). ACTIVO, PASIVO and INACTIVO only for lack of heartbeat (locked
--   phone, app minimised, no signal) all count. No votes row at all, as
--   before: a cancelled vote means they abstained.
-- * Unchanged: a clear preference is needed (>= 0.7 and above the other song,
--   at least 3 songs in the profile), weights 0.4-0.5 (0.5-0.6 when >= 75 % of
--   the eligible are not ACTIVO), k cap 1.25 x the active votes unless there
--   are none, 30 s ramp on the tension bar, none in Sudden Death.
-- * Each user sees their own passive vote from the start of the battle (a
--   softer glow on the card, get_my_passive_vote); voting any song replaces
--   it (the same song too: then it is their active vote, and tapping it again
--   cancels it = abstain). It is cast for real at lock-in.

create or replace function public.passive_vote_candidates(p_battle_id uuid, p_live boolean default false)
returns table(participant_id uuid, identity_anchor_id uuid, song_id uuid, weight real)
language plpgsql
stable
security definer
set search_path to 'public'
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
$$;

-- The caller's own passive vote in a battle, for the Battle Room glow: the
-- one cast at lock-in (until Sudden Death, where it doesn't count), or before
-- lock-in the song Music Fighter would vote for them (same rules as above,
-- without the k cap: only which song). NULL = none.
create or replace function public.get_my_passive_vote(p_battle_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path to 'public'
as $$
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
$$;

revoke all on function public.get_my_passive_vote(uuid) from public, anon;
grant execute on function public.get_my_passive_vote(uuid) to authenticated;
