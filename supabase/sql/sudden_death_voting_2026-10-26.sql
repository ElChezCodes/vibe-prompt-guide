-- Make Sudden Death voting actually work + SD-only tension bar, 2026-10-26
--
-- Live data before this script: 1,077 battles entered Sudden Death, and ZERO
-- votes with vote_type = 'sudden_death' exist -- every one ended as a draw.
-- Two blockers, this script fixes the DB one (frontend fix ships alongside):
--   - only INSERT policy was votes_insert_regular_active (vote_type =
--     'regular', lockin_at IS NULL), so a participant with no prior vote
--     could never cast their Sudden Death vote. Upgrading an existing regular
--     vote (votes_upgrade_to_sudden_death) was already allowed.
--   - arena_live_state didn't expose sudden_death_active, and the frontend's
--     SD detection used resolution_type, which is only set at completion.
--
-- Rules (CLAUDE.md business rules): one immutable vote per participant;
-- a prior regular vote can be upgraded once. Already enforced and unchanged:
-- votes_unique_participant_battle (one row per participant per battle, so a
-- participant with a regular vote must upgrade rather than insert),
-- votes_block_update_sd (SD votes can't be changed), votes_require_active_arena.

begin;

create policy votes_insert_sudden_death on votes
  for insert
  with check (
    vote_type = 'sudden_death'
    and status = 'active'
    and exists (
      select 1 from participants p
      where p.id = votes.participant_id and p.identity_anchor_id = auth.uid())
    and exists (
      select 1 from battles b
      where b.id = votes.battle_id and b.sudden_death_active = true));

-- Tension bar / on-screen tallies: once a battle has entered Sudden Death,
-- count only sudden_death votes -- the same set the SD resolution in
-- process_battle_lifecycle uses. Keyed on sudden_death_started_at (set at
-- SD start, never cleared) rather than sudden_death_active (reset to false on
-- completion by battles_sd_not_completed), so the final result screen keeps
-- showing the tally that actually decided it.
-- Same columns/order as before; sudden_death_active appended at the end.
create or replace view public.arena_live_state as
select
  b.id as battle_id,
  b.arena_id,
  b.state as status,
  b.started_at,
  b.duration_ms,
  b.lockin_at,
  b.resolution_type,
  b.winner_song_id,
  b.created_at as battle_created_at,
  sa.id as song_a_id,
  sa.title as song_a_title,
  sa.artist as song_a_artist,
  sa.source as song_a_source,
  sa.spotify_track_id as song_a_spotify_track_id,
  sa.duration_ms as song_a_duration_ms,
  sb.id as song_b_id,
  sb.title as song_b_title,
  sb.artist as song_b_artist,
  sb.source as song_b_source,
  sb.spotify_track_id as song_b_spotify_track_id,
  sb.duration_ms as song_b_duration_ms,
  count(v.id) filter (
    where v.song_id = sa.id and v.status = 'active'
      and (b.sudden_death_started_at is null or v.vote_type = 'sudden_death')) as votes_a,
  count(v.id) filter (
    where v.song_id = sb.id and v.status = 'active'
      and (b.sudden_death_started_at is null or v.vote_type = 'sudden_death')) as votes_b,
  b.sudden_death_active
from battles b
  join songs sa on sa.id = b.song_a_id
  join songs sb on sb.id = b.song_b_id
  left join votes v on v.battle_id = b.id
where b.state = any (array['pending', 'active', 'closing', 'completed'])
group by b.id, sa.id, sb.id;

commit;
