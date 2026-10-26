-- Fix broken ownership checks on votes RLS policies, 2026-10-26
--
-- Both votes_update_before_lockin and votes_upgrade_to_sudden_death compared
-- votes.participant_id directly to auth.uid(). Verified against real data
-- (137 real votes, 216 real participants): participant_id (= participants.id,
-- a separately gen_random_uuid()'d value) NEVER equals identity_anchor_id/
-- auth.uid() for any real row. So this comparison can never be true for anyone.
--
-- votes_upgrade_to_sudden_death had this bug from before any of this session's
-- changes -- pre-existing, not something we introduced. Nobody has ever been
-- able to upgrade a regular vote to sudden_death via this policy.
--
-- votes_update_before_lockin got this exact (broken) pattern added during this
-- session's earlier RLS-hardening pass, to close a missing-ownership-check gap.
-- That fix was verified by reading the policy *text* against the intended
-- pattern, but not verified against real data -- so it went live as a
-- regression: it closed the "any user can touch any vote" hole, but replaced
-- it with "no user, including the vote's own owner, can touch their vote at
-- all" (the qual/with_check could never be true). Caught only because a
-- separately-run background task doing unrelated work (the song-rotation
-- build) independently noticed the same underlying participant_id/auth.uid()
-- mismatch while deliberately avoiding copying this pattern for song_likes.
--
-- Fix: resolve ownership via a real relational lookup (participants.id ->
-- participants.identity_anchor_id = auth.uid()) instead of a direct column
-- comparison -- the same pattern song_likes' RLS already uses correctly.

drop policy if exists votes_update_before_lockin on votes;
create policy votes_update_before_lockin on votes
  for update
  using (
    exists (select 1 from participants p where p.id = votes.participant_id and p.identity_anchor_id = auth.uid())
    and exists (select 1 from battles b where b.id = votes.battle_id and b.lockin_at is null)
  )
  with check (
    exists (select 1 from participants p where p.id = votes.participant_id and p.identity_anchor_id = auth.uid())
    and status = any (array['active', 'cancelled'])
  );

drop policy if exists votes_upgrade_to_sudden_death on votes;
create policy votes_upgrade_to_sudden_death on votes
  for update
  using (
    exists (select 1 from participants p where p.id = votes.participant_id and p.identity_anchor_id = auth.uid())
    and vote_type = 'regular'
  )
  with check (
    exists (select 1 from participants p where p.id = votes.participant_id and p.identity_anchor_id = auth.uid())
    and vote_type = 'sudden_death'
    and exists (select 1 from battles where battles.id = votes.battle_id and battles.sudden_death_active = true)
  );
