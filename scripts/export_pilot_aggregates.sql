-- Aggregates of one arena, for pilot analysis. One read-only SELECT, one JSON value.
-- Run through scripts/export_pilot_aggregates.py, which fills in the arena code.
--
-- Nothing per person leaves this query: no ids, nicknames, arena name, or per-person
-- sequences. people_by_* are distributions only. The funnel, grid and agreement
-- sections replay the passive vote rules at each lock-in with the signals that
-- existed then; they need votes, snapshots and signals, which the 30-day purge deletes.

with
arena as (
  select a.* from arenas a where a.arena_code = '__ARENA_CODE__'
),
cfg as (select * from passive_vote_config where id = 1),

bat as (
  select b.*, row_number() over (order by b.started_at, b.created_at)::int as n,
         sa.title a_title, sa.artist a_artist, sa.isrc a_isrc,
         sb.title b_title, sb.artist b_artist, sb.isrc b_isrc,
         (select min(b2.started_at) from battles b2 where b2.arena_id = b.arena_id) as first_start
  from battles b
  join arena a on a.id = b.arena_id
  join songs sa on sa.id = b.song_a_id
  join songs sb on sb.id = b.song_b_id
),
vot as (
  select v.*, b.n, b.started_at b_start, b.sudden_death_started_at b_sd,
         b.song_a_id, b.song_b_id
  from votes v join bat b on b.id = v.battle_id
),
per_battle as (
  select b.id,
    count(v.id) filter (where v.song_id = b.song_a_id and v.status = 'active' and v.vote_type <> 'passive')::int explicit_a,
    count(v.id) filter (where v.song_id = b.song_b_id and v.status = 'active' and v.vote_type <> 'passive')::int explicit_b,
    -- The tally that decides: once Sudden Death starts, only its votes count
    count(v.id) filter (where v.song_id = b.song_a_id and v.status = 'active' and v.vote_type <> 'passive'
      and (b.sudden_death_started_at is null or v.vote_type = 'sudden_death'))::int final_a,
    count(v.id) filter (where v.song_id = b.song_b_id and v.status = 'active' and v.vote_type <> 'passive'
      and (b.sudden_death_started_at is null or v.vote_type = 'sudden_death'))::int final_b,
    count(v.id) filter (where v.status <> 'active' and v.vote_type <> 'passive')::int cancelled,
    coalesce(sum(v.weight) filter (where v.song_id = b.song_a_id and v.vote_type = 'passive' and v.status = 'active'), 0)::numeric(8,3) passive_a,
    coalesce(sum(v.weight) filter (where v.song_id = b.song_b_id and v.vote_type = 'passive' and v.status = 'active'), 0)::numeric(8,3) passive_b,
    count(v.id) filter (where v.vote_type = 'passive' and v.status = 'active')::int passive_voters,
    round(avg(extract(epoch from v.created_at - b.started_at)) filter (where v.vote_type <> 'passive'))::int avg_vote_s
  from bat b left join votes v on v.battle_id = b.id
  group by b.id
),
per_presence as (
  select s.battle_id,
    count(*) filter (where s.state = 'active')::int present_active,
    count(*) filter (where s.state = 'passive')::int present_passive,
    count(*) filter (where s.state = 'inactive')::int present_inactive
  from battle_presence_snapshots s join arena a on a.id = s.arena_id
  group by s.battle_id
),
human as (
  select ph.battle_id, ph.song_id, ph.proposed_at
  from proposal_history ph join arena a on a.id = ph.arena_id
  where ph.kind = 'proposal' and ph.battle_id is not null
),
battles_json as (
  select b.n, b.started_at, b.duration_ms,
    extract(epoch from b.started_at - b.first_start)::int start_s,
    pb.*, coalesce(pp.present_active, 0) present_active, coalesce(pp.present_passive, 0) present_passive,
    coalesce(pp.present_inactive, 0) present_inactive,
    exists (select 1 from human h where h.battle_id = b.id and h.song_id = b.song_a_id) a_human,
    exists (select 1 from human h where h.battle_id = b.id and h.song_id = b.song_b_id) b_human,
    b.state, b.resolution_type, b.soundtrack, b.sudden_death_started_at is not null had_sd,
    case b.winner_song_id when b.song_a_id then 'A' when b.song_b_id then 'B' end winner,
    b.a_title, b.a_artist, b.a_isrc, b.b_title, b.b_artist, b.b_isrc
  from bat b
  join per_battle pb on pb.id = b.id
  left join per_presence pp on pp.battle_id = b.id
),

-- Replay of passive_vote_candidates: everyone in the snapshot and not gone
eligible as (
  select b.id bid, b.n, b.lockin_at, b.song_a_id, b.song_b_id, b.a_isrc, b.b_isrc,
         s.participant_id pid, s.identity_anchor_id uid, u.is_anonymous anon,
         (select v.vote_type from votes v where v.battle_id = b.id and v.participant_id = s.participant_id
          order by (v.vote_type = 'passive') limit 1) vtype,
         (select v.song_id from votes v where v.battle_id = b.id and v.participant_id = s.participant_id
          and v.status = 'active' and v.vote_type <> 'passive' limit 1) voted_song
  from bat b
  join battle_presence_snapshots s on s.battle_id = b.id
  join participants p on p.id = s.participant_id
  left join auth.users u on u.id = s.identity_anchor_id
  where p.left_at is null
    and not (p.disconnected_at is not null and (p.last_seen_at is null or p.disconnected_at >= p.last_seen_at))
),
replay as materialized (
  select e.*, coalesce(cardinality(sg.isrcs), 0) nsig,
         (sg.isrcs @> array[e.a_isrc] or sg.isrcs @> array[e.b_isrc]) known_song,
         case when sg.isrcs is not null then coalesce(song_set_score(sg.isrcs, sg.ws, e.a_isrc), 0) end sa,
         case when sg.isrcs is not null then coalesce(song_set_score(sg.isrcs, sg.ws, e.b_isrc), 0) end sb
  from eligible e
  left join lateral (
    select array_agg(i) isrcs, array_agg(w) ws
    from (
      select x.isrc i,
             sum(x.weight * power(0.5, extract(epoch from e.lockin_at - x.created_at) / 86400.0
                                        / (select half_life_days from cfg)))::real w
      from affinity_signals x
      where x.user_id = e.uid
        and x.created_at < e.lockin_at
        and (not coalesce(e.anon, true) or x.arena_id = (select id from arena))
      group by x.isrc
    ) y
  ) sg on true
),
no_explicit as (
  select r.*, greatest(r.sa, r.sb) top from replay r where r.vtype is null or r.vtype = 'passive'
),
with_pick as (
  select r.*, greatest(r.sa, r.sb) top,
         case when r.sa > r.sb then r.song_a_id when r.sb > r.sa then r.song_b_id end pick
  from replay r where r.voted_song is not null
),

people as (
  select p.id pid, p.identity_anchor_id uid, p.joined_at, u.is_anonymous anon
  from participants p join arena a on a.id = p.arena_id
  left join auth.users u on u.id = p.identity_anchor_id
),
person_songs as (
  select pe.uid, pe.joined_at, count(distinct s.isrc)::int songs,
         (select min(t) from (
            select min(s2.created_at) t from affinity_signals s2
            where s2.user_id = pe.uid and s2.arena_id = (select id from arena)
            group by s2.isrc order by 1 offset 2 limit 1) z) at_3
  from people pe
  left join affinity_signals s on s.user_id = pe.uid and s.arena_id = (select id from arena)
  group by pe.uid, pe.joined_at
),
person_votes as (
  select pe.uid, count(v.id)::int n
  from people pe left join vot v on v.participant_id = pe.pid and v.vote_type <> 'passive'
  group by pe.uid
),
person_props as (
  select ph.proposed_by, count(*)::int n
  from proposal_history ph join arena a on a.id = ph.arena_id
  where ph.kind = 'proposal' group by 1
),
hourly as (
  select floor(extract(epoch from b.started_at - (select min(started_at) from battles_json)) / 3600)::int h,
    count(*)::int battles,
    round(avg(b.present_active + b.present_passive), 2) present_avg,
    sum(b.explicit_a + b.explicit_b)::int explicit,
    sum(b.passive_voters)::int passive,
    sum(b.a_human::int + b.b_human::int)::int human_slots
  from battles_json b group by 1
),
fought as (
  select distinct unnest(array[b.a_isrc, b.b_isrc]) isrc from bat b
)

select jsonb_build_object(
  'note', 'Aggregates only: no people, ids, nicknames or arena name. Individual votes are deleted after 30 days per the privacy policy; battle totals may be kept.',
  'schema', 2,
  'purged', (select votes_purged_at is not null from arena),
  'rules', (select to_jsonb(c) - 'id' from cfg c),
  'summary', jsonb_build_object(
    'battles', (select count(*) from battles_json),
    'hours', (select round(extract(epoch from max(started_at) - min(started_at)) / 3600, 2) from battles_json),
    'avg_battle_s', (select round(avg(duration_ms) / 1000) from battles_json),
    'people', (select count(*) from people),
    'anonymous', (select count(*) from people where anon),
    'accounts', (select count(*) from people where anon = false),
    'battles_with_explicit', (select count(*) from battles_json where explicit_a + explicit_b > 0),
    'battles_with_any_vote', (select count(*) from battles_json where explicit_a + explicit_b + passive_voters > 0),
    'battles_system_vs_system', (select count(*) from battles_json where not a_human and not b_human),
    'battles_human_vs_system', (select count(*) from battles_json where a_human <> b_human),
    'battles_human_vs_human', (select count(*) from battles_json where a_human and b_human),
    'explicit_votes', (select coalesce(sum(explicit_a + explicit_b), 0) from battles_json),
    'passive_votes', (select coalesce(sum(passive_voters), 0) from battles_json),
    'preassigned_votes_kept', (select count(*) from vot where preassigned and status = 'active'),
    'sudden_deaths', (select count(*) from battles_json where had_sd),
    'present_avg', (select round(avg(present_active + present_passive), 2) from battles_json),
    'snapshot_avg', (select round(avg(present_active + present_passive + present_inactive), 2) from battles_json),
    'proposals', (select coalesce(sum(n), 0) from person_props),
    'proposers', (select count(*) from person_props),
    'lobby_proposals', (select count(*) from proposal_history ph, arena a
                        where ph.arena_id = a.id and ph.kind = 'proposal' and ph.proposed_at < a.started_at),
    'proposal_wait_min_median', (select round((percentile_cont(0.5) within group (
        order by extract(epoch from b.started_at - h.proposed_at) / 60))::numeric, 1)
      from human h join bat b on b.id = h.battle_id),
    'resolutions', (select coalesce(jsonb_object_agg(k, c), '{}') from (
      select coalesce(resolution_type, 'open') k, count(*) c from battles_json group by 1) x)
  ),
  'hourly', (select coalesce(jsonb_agg(to_jsonb(x) order by x.h), '[]') from hourly x),
  'signals_by_kind', (select coalesce(jsonb_agg(x order by x.kind), '[]') from (
    select s.kind, count(*)::int n, count(distinct s.isrc)::int songs
    from affinity_signals s join arena a on a.id = s.arena_id group by s.kind) x),
  'people_by_songs_signalled', (select coalesce(jsonb_agg(x order by x.songs), '[]') from (
    select songs, count(*)::int people from person_songs group by 1) x),
  'people_by_proposals', (select coalesce(jsonb_agg(x order by x.proposals), '[]') from (
    select n proposals, count(*)::int people from person_props group by 1) x),
  'people_by_explicit_votes', (select coalesce(jsonb_agg(x order by x.bucket), '[]') from (
    select case when n = 0 then '0' when n <= 2 then '1-2' when n <= 5 then '3-5' when n <= 10 then '6-10' else '11+' end bucket,
           count(*)::int people from person_votes group by 1) x),
  'time_to_three_songs', (select coalesce(jsonb_object_agg(k, c), '{}') from (
    select case when ps.at_3 is null then 'never'
                when ps.at_3 < (select started_at from arena) then 'before_battles'
                when ps.at_3 < ps.joined_at + interval '30 min' then 'under_30_min'
                when ps.at_3 < ps.joined_at + interval '60 min' then 'under_60_min'
                else 'over_60_min' end k, count(*)::int c
    from person_songs ps group by 1) x),
  'passive_funnel', (select coalesce(jsonb_object_agg(k, c), '{}') from (
    select case when nsig < (select min_signals from cfg) then 'under_min_signals'
                when top < (select min_score from cfg) then 'score_below_min'
                when sa = sb then 'tie'
                else 'passive_vote' end k, count(*)::int c
    from no_explicit group by 1) x),
  'passive_replay_check', jsonb_build_object(
    'replayed', (select count(*) from no_explicit, cfg c where nsig >= c.min_signals and top >= c.min_score and sa <> sb),
    'real', (select coalesce(sum(passive_voters), 0) from battles_json)),
  'passive_score_levels', (select coalesce(jsonb_agg(x order by x.top), '[]') from (
    select round(top::numeric, 2) top, count(*)::int n from no_explicit, cfg c
    where nsig >= c.min_signals and top >= 0.5 group by 1) x),
  'passive_by_signal_size', (select coalesce(jsonb_agg(x order by x.size), '[]') from (
    select case when nsig < 3 then '0-2' when nsig < 6 then '3-5' when nsig < 14 then '6-13' else '14+' end size,
           count(*)::int rows, count(*) filter (where nsig >= c.min_signals and top >= c.min_score and sa <> sb)::int passive
    from no_explicit, cfg c group by 1) x),
  'passive_rule_grid', (select coalesce(jsonb_agg(x order by x.min_signals, x.min_score), '[]') from (
    select ms min_signals, sc min_score, count(*)::int votes, count(distinct n)::int battles
    from no_explicit, unnest(array[1, 2, 3, 6]) ms, unnest(array[0.5, 0.6, 0.7]) sc
    where nsig >= ms and top >= sc and sa <> sb group by 1, 2) x),
  'passive_agreement', (select coalesce(jsonb_agg(x order by x.known_song), '[]') from (
    select coalesce(known_song, false) known_song, count(*)::int n, count(*) filter (where pick = voted_song)::int agree
    from with_pick, cfg c where nsig >= c.min_signals and top >= c.min_score and sa <> sb group by 1) x),
  'backings', (select coalesce(jsonb_agg(x), '[]') from (
    select coalesce(ph.backing_source, 'duplicate') source, ph.outcome, ph.vote_applied, count(*)::int n
    from proposal_history ph join arena a on a.id = ph.arena_id
    where ph.kind = 'backing' group by 1, 2, 3) x),
  'likes', jsonb_build_object(
    'total', (select count(*) from song_likes l join arena a on a.id = l.arena_id),
    'songs', (select count(distinct l.song_id) from song_likes l join arena a on a.id = l.arena_id),
    'people', (select count(distinct l.participant_id) from song_likes l join arena a on a.id = l.arena_id)),
  'musicbrainz', (select jsonb_build_object(
      'songs', count(*), 'found', count(*) filter (where r.status = 'found'))
    from fought f left join recordings r on r.isrc = f.isrc),
  'playback_events', (select coalesce(jsonb_object_agg(k, c), '{}') from (
    select e.kind k, count(*)::int c from playback_events e join arena a on a.id = e.arena_id group by 1) x),
  'battles', (select coalesce(jsonb_agg((to_jsonb(b) - 'id' - 'started_at') order by b.n), '[]') from battles_json b),
  'matchmaking', (select coalesce(jsonb_agg(x order by x.n), '[]') from (
    select b.n, m.a_source, m.b_source, m.forced, m.score, m.components
    from matchmaking_log m join bat b on b.id = m.battle_id) x)
)::text as export;
