-- Step 19b (2026-10-30): close the host flows (roadmap §H).
-- Backend_Block_5 §2.1: the host does NOT start battles by hand, decide
-- pairings or control results; v3.0 §9 / v4 §10.1: can't veto specific songs.
-- The audit found these holes, closed here:
--   1. `host_can_create_initial_battle` let the host INSERT battles directly
--      (any songs of the arena, any state) — e.g. while the arena waits for
--      songs, choosing the pair. Battles are created only by
--      start_arena_battles / create_next_battle (SECURITY DEFINER). The old
--      `create-battle` Edge Function (service role, host-only) is deleted too.
--   2. `votes_insert_regular_active` didn't check that `participant_id` is
--      the caller's: anyone (the host sees every participant) could cast
--      regular votes in other people's name (one per participant row), which
--      also blocked their own vote and their passive vote. Sudden Death insert
--      and every UPDATE policy already checked it.
--   3. Leftover client grants: table writes nothing uses (no policy allows
--      them today, but a future permissive policy would), the two legacy cron
--      debug tables (no RLS, writable by anon), and EXECUTE on internal
--      functions (process_battle_lifecycle runs as the cron;
--      calculate_lockin_vote_totals; ensure_mock_songs_for_arena wrote mock
--      songs into any arena).
-- Not changed (by design, user decisions): the host's End Arena / Start
-- battles, `set_arena_control_mode` (step 18 manual control re-times battles
-- with the host's Spotify skips; never picks songs or winners), the step-6
-- "Resume on Spotify".

-- 1. No direct battle writes from clients
drop policy if exists host_can_create_initial_battle on public.battles;
revoke insert, update, delete on public.battles from anon, authenticated;

-- 2. A client vote is always cast by its own participant row
drop policy if exists votes_insert_own_participant on public.votes;
create policy votes_insert_own_participant on public.votes
  as restrictive for insert to public
  with check (exists (
    select 1 from public.participants p
    where p.id = votes.participant_id
      and p.identity_anchor_id = auth.uid()
      and p.arena_id = votes.arena_id));
revoke delete on public.votes from anon, authenticated;

-- 3. Leftover grants
revoke insert, update, delete on public.arenas, public.songs, public.hosts,
  public.arena_live_state, public.participant_presence from anon, authenticated;
revoke update, delete on public.queues from anon, authenticated;
revoke delete on public.participants from anon, authenticated;

revoke all on public.cron_debug_log, public.cron_seconds_test_log from anon, authenticated;
alter table public.cron_debug_log enable row level security;
alter table public.cron_seconds_test_log enable row level security;

revoke execute on function public.process_battle_lifecycle(uuid) from public, anon, authenticated;
revoke execute on function public.calculate_lockin_vote_totals(uuid) from public, anon, authenticated;
revoke execute on function public.ensure_mock_songs_for_arena(uuid) from public, anon, authenticated;
