-- Vote UPDATE integrity: SD votes immutable, vote edits must match the phase,
-- 2026-10-26 (apply after sudden_death_voting_2026-10-26.sql)
--
-- Found by the rollback smoke test right after Sudden Death voting started
-- working. Permissive policies OR together -- both their USING and their WITH
-- CHECK, independently of which policy matched the row -- so:
--   - votes_block_update_sd (permissive, with_check false) never blocked
--     anything: its USING made SD rows updatable, and
--     votes_upgrade_to_sudden_death's WITH CHECK accepted any new SD row.
--     A cast SD vote could be switched to the other song.
--   - a regular vote could still be switched after lock-in: matched by
--     votes_upgrade_to_sudden_death's USING (owner + regular), passed by
--     votes_update_before_lockin's WITH CHECK (owner + valid status).
-- Restrictive policies AND with everything, so they're the right tool for
-- invariants.

begin;

drop policy if exists votes_block_update_sd on votes;

-- "sudden_death votes are final once cast". Explicit WITH CHECK (true): an
-- UPDATE policy without one reuses USING for the new row, which would block
-- the legitimate regular -> sudden_death upgrade. (Applied live as
-- create + alter policy; this file shows the final definition.)
create policy votes_sd_immutable on votes
  as restrictive for update
  using (vote_type <> 'sudden_death')
  with check (true);

-- The edited row's vote_type must match the battle phase: regular votes
-- only before lock-in; a row can only become sudden_death while Sudden Death
-- is active (the one-time upgrade; ownership is checked by the permissive
-- policies). Without the phase check on sudden_death, the OR with
-- votes_update_before_lockin let a regular vote "upgrade" during the active
-- phase or a normal (non-tie) closing.
create policy votes_update_matches_phase on votes
  as restrictive for update
  with check (exists (
    select 1 from battles b
    where b.id = votes.battle_id
      and ((votes.vote_type = 'regular' and b.lockin_at is null)
        or (votes.vote_type = 'sudden_death' and b.sudden_death_active = true))));

commit;
