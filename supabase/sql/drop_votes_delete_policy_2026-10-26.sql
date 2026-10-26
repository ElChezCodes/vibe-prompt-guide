-- Remove the only DELETE policy on votes, 2026-10-26
--
-- votes_block_delete_sd (permissive, USING vote_type <> 'sudden_death') had
-- no ownership check: any authenticated user could delete anyone's regular
-- votes, including before lock-in -- enough to change a battle's winner.
--
-- Nothing legitimately deletes votes: the frontend toggles via
-- status = 'cancelled', and no Edge Function or DB function issues a DELETE
-- on votes (checked 2026-10-26). With no DELETE policy, RLS denies all client
-- deletes; service-role / SECURITY DEFINER code is unaffected.

drop policy if exists votes_block_delete_sd on votes;
