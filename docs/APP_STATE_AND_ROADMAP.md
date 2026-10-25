# App State & Roadmap — Ground Truth (2026-10-25)

## Why this doc exists, and what it supersedes

Everything in `docs/DB_REBUILD_PLAN.md` was written *before* we had live database
access — it's reconstruction from frontend code, spec docs, and Lovable's own
guesswork, carefully tagged `[VERIFIED]`/`[CORROBORATED]`/`[SPECULATIVE]`. The
project has since been unpaused and I've read the real schema, every real RPC
function's source, every real RLS policy, and the real list of deployed Edge
Functions directly.

**Most of `DB_REBUILD_PLAN.md` is now resolved or moot.** We are *not* rebuilding
from scratch — the real schema, business logic, and most of the real app data
(1,615 battles, 137 votes, 102 arenas — all intact) survived. The 7GB bloat was
never battle spam; it was `cron.job_run_details` (pg_cron's own execution log)
accumulating for 8 months from a 1-second-interval job nobody ever pruned. That's
already been purged. Treat `DB_REBUILD_PLAN.md` as historical — kept for the
reasoning trail, not as current guidance. This document is the current one.

Everything below is read directly from the live database/CLI — not reconstructed —
unless explicitly marked otherwise.

---

## 1. How the app actually works today

### 1.1 Two parallel battle-lifecycle implementations — only one is live

There are **two separate, non-overlapping implementations** of the battle state
machine in the database. This wasn't visible from the frontend or docs at all.

**A. The legacy pathway (SQL functions exist, nothing schedules them):**
`end_battle` → `resolve_lockin_and_activate_sd` → `resolve_battle_after_sudden_death`
→ `finalize_battle` → `finalize_and_enqueue_battle`, orchestrated by
`orchestrate_battle_closure`, meant to be invoked by `run_battle_closure_job` /
`run_battle_finalizer_job`. The Edge Function `battle-finalizer-cron` in this repo
calls `run_battle_finalizer_job` via RPC — but **nothing schedules that Edge
Function**. `pg_net` is installed but no `cron.job` entry calls it via HTTP. This
entire pathway is dead code today, confirmed by checking every `cron.job` row.

**B. The live pathway — `process_battle_lifecycle(arena_id)`:**
This is the only thing actually running, via the `battle_lifecycle_job` pg_cron
job (every 1 second, for any `arenas.state='active'` arena with a battle in
`pending/active/closing`). It's a self-contained reimplementation, not a caller of
the functions in (A). Its logic:

1. `pending → active`: sets `started_at = now()`.
2. `active → closing` at lock-in (`started_at + duration_ms − 15000ms`): tallies
   `vote_type IN ('regular','passive')` votes via `calculate_lockin_vote_totals`.
   If tied → `sudden_death_active = true`. If not tied → inserts the winner into
   `playlist_queue` and sets `resolution_type = 'normal'`.
3. `closing → completed` at full duration end: if Sudden Death was active, tallies
   `vote_type = 'sudden_death'` votes only. Clear winner → inserts into
   `playlist_queue`, `resolution_type = 'sudden_death'`. Tied again → inserts
   **both** songs into `playlist_queue`, `resolution_type = 'draw'`.
4. **Then, unconditionally**: computes `v_next_duration = SUM(song_duration_ms)`
   over everything just inserted into `playlist_queue` for this battle, and
   **inserts a new `battles` row with `state='pending'`, the exact same
   `song_a_id`/`song_b_id` as the battle that just finished**, and
   `duration_ms = v_next_duration`.

**This is the real mechanism behind what we'd been calling `is_special_battle`.**
That column doesn't exist anywhere in the real schema (see §2.1) — it isn't a flag
at all. A "special," longer battle is just an ordinary row whose `duration_ms`
happens to be large because the previous round was a draw (two songs queued,
durations summed) instead of a clean win (one song queued). No new table or
column was ever needed for the duration/combined-playback part of what Sergio
described.

**But this also reveals a real gap, confirmed by the code, not inferred:** the
auto-chained next battle **always reuses the same two songs** — there is no
branch anywhere in `process_battle_lifecycle` that ever introduces a new
candidate song. Sergio described voting during a round as deciding what plays in
the *next* round (implying fresh candidates each time); what's actually
implemented is the same two songs battling indefinitely, forever, with no
mechanism to ever bring in a third song. The `queues` table (see §2.1) exists
with exactly the shape needed for song rotation (`waiting_50`/`active_10` lists,
matching the old spec docs' "lista primaria (10) / cola secundaria (50)"
language) — but **no function anywhere reads from or writes to `queues`**. It's
scaffolding for a feature that was never connected.

This also resolves why 8 months of a 1-second cron only produced 1,615 battles,
not millions: `process_battle_lifecycle`'s first query filters to
`arenas.state='active' AND EXISTS (... battles in pending/active/closing)` — most
of those 16.6M ticks were cheap no-ops because no arena qualified. The job ran
constantly; it just mostly had nothing to do. The bloat was 100% logging
overhead, not real work.

### 1.2 Vote weighting is partially wired server-side, invisible from the frontend

`votes.weight` (real column, `real`, default `1`) exists and is summed (not just
counted) by every vote-tallying function. `calculate_lockin_vote_totals` filters
on `vote_type IN ('regular','passive')` — **a `'passive'` vote type is expected
and summed by the SQL, but nothing in the frontend ever writes a `'passive'`
vote.** This is a real, partial implementation of the "passive affinity" concept
CLAUDE.md flags as unresolved pending Sergio — the read side exists in SQL
already; only the write side (something actually inserting weighted passive
votes) is missing. Worth bringing to Sergio specifically framed this way: it's
not a green-field decision, it's finishing something half-built.

### 1.3 Identity enforcement happens via a trigger, not via what the frontend sends

`trg_fill_vote_fields` (BEFORE INSERT on `votes`) unconditionally overwrites
`NEW.identity_anchor_id := auth.uid()` and derives `NEW.arena_id` from the battle
row — regardless of what the client sent. `src/integrations/supabase/votes.ts`
passes `identityAnchorId`/`arenaId` explicitly on insert; those values are
silently discarded. Not a bug — this is good server-side enforcement — but worth
knowing the frontend's explicit values are inert noise, not load-bearing.

### 1.4 Edge Functions: only one of four is actually live

| Function | Status | Notes |
|---|---|---|
| `create-battle` | **Live** | Called from `ArenaLobbyScreen.tsx`. Version 7 — iterated on substantially. |
| `battle-finalizer-cron` | Dead | In this repo. Nothing schedules it (see §1.1). |
| `battle-ended` | Dead | **Not in this repo before today** — pulled into `supabase/functions/battle-ended/`. Version 11 (heavily iterated, clearly was load-bearing once). Explicitly a read-only "notifier" per its own code comments (`PROHIBIDO: Escribir en DB, Decidir ganadores, Cerrar battles, Contar votos`) — matches `CLAUDE.md`'s description of `useBattleEndedTrigger.ts` as a deliberate no-op stub; this Edge Function is what that stub used to call before being retired. Never invoked anywhere in current `src/`. |
| `battle-lockin` | Dead | **Not in this repo before today** — pulled into `supabase/functions/battle-lockin/`. Version 3. Same pattern: passive notifier, never invoked anywhere in current `src/`. |

### 1.5 Real schema — full column list

**`arenas`**: `id`, `host_id`, `name`, `state`, `mood` (default `'NULL'::text` —
see bug list), `started_at`, `ended_at`, `created_at`, `updated_at`, `arena_code`
(default `generate_arena_code()`).

**`battles`**: `id`, `arena_id`, `song_a_id` (default a placeholder UUID, no FK —
see bug list), `song_b_id` (same), `state` (default `'pending'`), `winner_song_id`
(FK → `songs.id`), `started_at`, `ended_at`, `created_at`, `updated_at`,
`duration_ms` (default `45000`), `lockin_at`, `sudden_death_active` (default
`false`), `post_battle_processed_at`, `enqueue_done` (default `false`),
`resolution_type`, `sudden_death_started_at`. **No `is_special_battle`, no
`had_sudden_death`** — both were real fields the frontend's `BattleData`
interface (`battleClosureOrchestrator.ts`) selects, and both don't exist (see
§2.2 — this is a live bug, not a documentation gap).

**`songs`**: `id`, `arena_id` (NOT NULL — songs are scoped **per arena**, not a
global catalog), `source`, `spotify_track_id`, `title`, `artist`, `duration_ms`,
`energy`, `bpm`, `valence`, `popularity` (real audio-feature columns, matching
the ML affinity feature set doc), `status`, `created_at`, `updated_at`. No
audio-file/storage column — confirms self-hosted mp3 playback was never part of
the schema; needed new for Sergio's curated-songs phase.

**`votes`**: `id`, `arena_id`, `battle_id`, `song_id`, `participant_id`,
`identity_anchor_id`, `vote_type` (default `'regular'`), `weight` (default `1`),
`created_at`, `updated_at`, `status` (default `'active'`).

**`participants`**: `id`, `arena_id`, `identity_anchor_id`, `user_id` (nullable,
separate from `identity_anchor_id`), `display_name` (default `''`), `avatar_url`,
`is_host` (default `false`), `joined_at`, `last_active_at`, `created_at`,
`updated_at`. `last_active_at` existing is notable — real schema support for the
activity-state tracking the spec docs describe, unused by the frontend today.

**`hosts`**: `id`, `display_name`, `email`, `created_at`, `updated_at`.
**Completely new — not referenced anywhere in the frontend code**, which assumes
`arenas.host_id` points straight at `auth.users`. No FK constraint exists tying
`arenas.host_id` to either `hosts.id` or `auth.users.id`, so this can't be
resolved from the schema alone — needs Sergio.

**`playlist_queue`**: `id`, `arena_id` (FK, cascade), `battle_id` (FK, cascade),
`winner_song_id` (FK → `songs.id`, restrict), `spotify_track_id`, `created_at`,
`song_duration_ms` (default `0`). This is the real "what plays next" bridge —
genuinely wired into `process_battle_lifecycle`, not speculative at all, contrary
to `DB_REBUILD_PLAN.md`'s guess that it might be unused.

**`queues`**: `id`, `arena_id`, `song_id`, `queue_type` (default the literal
string `'waiting_50, active_10 '` — see bug list), `position`, `priority`,
`created_at`, `updated_at`. Real structure, matching the old spec's two-tier
queue concept, but **zero functions reference this table at all** — pure
unconnected scaffolding.

**`streaming_accounts`**: `id`, `host_id` (tied to a **host**, not an arena —
corrects `DB_REBUILD_PLAN.md`'s guess), `provider` (default `'spotify'`),
`provider_account_id`, `access_token`, `refresh_token`, `token_expires_at`,
`created_at`, `updated_at`.

**`arena_live_state`** (view): matches `ArenaBattleView` almost exactly, with one
notable gap — **it does not expose `sudden_death_active`** at all, even though
`battles.sudden_death_active` is real. `BattleRoomScreen`'s UI-facing phase
derivation (`getDerivedBattlePhase`) currently relies on `resolution_type`, not
`sudden_death_active`, to detect Sudden Death — which happens to work, but only
because that function reads from the view, while `battleClosureOrchestrator.ts`'s
separate read path queries `battles` directly and *does* get `sudden_death_active`.
Two genuinely different data shapes for the same concept, confirmed real, not a
misunderstanding.

### 1.6 RLS — confirmed, and there are real, serious holes

Full policy list is in git history of this session's queries; the ones that
matter:

- **`battles` has an UPDATE policy (`participants_can_update_battle_state`, and a
  duplicate `participants_can_update_battles`) that allows *any* participant in
  the arena — not just the host, not just the backend — to set
  `state ∈ {'pending','active','finished'}` directly from the client.** This
  directly violates the stated core invariant ("backend-only transitions via SQL
  RPC + cron"). Also note `'finished'` isn't even a real state value anywhere
  else in the codebase (real values are `pending/active/closing/completed`) —
  this policy references a stale/wrong state name on top of being a security
  problem.
- **`arenas` and `battles` both have wide-open "mvp"/"dev" policies**
  (`arena_insert_mvp`, `arena_select_mvp`, `allow insert battles`,
  `allow read battles`, `dev_allow_all_battles_insert`) with `qual`/`with_check
  = true` for `anon`/`public`. Postgres RLS policies are OR'd — these
  unconditionally-permissive policies make every other properly-scoped policy on
  the same table meaningless. Right now, anyone with the anon key can read every
  arena and battle, and insert arbitrary rows into both tables.
- **`votes_update_before_lockin`** has no ownership check in its `qual` at all —
  any authenticated user could update *any other participant's* vote row
  (e.g. cancel someone else's active vote) as long as the battle hasn't locked
  in. Contrast with `votes_upgrade_to_sudden_death`, which *does* correctly scope
  to `participant_id = auth.uid()` — so the pattern for doing this right already
  exists elsewhere in the same table's policy set, it's just inconsistently
  applied.
- **`votes_select_authenticated`** lets any authenticated user read every vote
  row in the database (not scoped to their own arena), exposing individual
  per-participant vote choices, not just aggregate tallies.
- Several exact-duplicate policy pairs exist (`host_can_create_own_arena` /
  `host_create_arena`, `host_can_view_own_arena` / `host_select_arena`,
  `participant_can_insert_self` / `participant_insert_self`,
  `participant_can_view_arena_participants` / `participant_select`,
  `participants_can_update_battle_state` / `participants_can_update_battles`) —
  harmless redundancy, but signals iterative edits where old policies were never
  cleaned up. Worth a pass to consolidate regardless of the security fixes.

---

## 2. Concrete bugs, prioritized

### 2.1 Critical — security / architecture-invariant violations
1. **Any participant can directly set `battles.state`** via the RLS UPDATE
   policies in §1.6. This bypasses the entire backend-authoritative state machine
   from the client. Needs the permissive policies removed/tightened before any
   real deployment.
2. **Wide-open `_mvp`/`dev_allow_all` policies on `arenas` and `battles`** nullify
   every scoped RLS policy on those tables (anyone can read/write arbitrary rows).

### 2.2 High — real functional bugs
3. **`battleClosureOrchestrator.ts`'s `fetchBattle()` selects `is_special_battle`
   and `had_sudden_death` — neither column exists in the real `battles` table.**
   This query has been failing (or has always failed) wherever it's actually
   invoked, hitting the `error || !data → return null` branch silently. Confirmed
   real, not theoretical — need to check how far this propagates (it feeds
   `isResolvedFromBattle`/`getWinnerFromBattle`, all of which are currently
   unreachable with good data as a result).
4. **No song rotation mechanism exists.** `process_battle_lifecycle` always
   reuses the same two songs for the next battle — contradicts the "voting
   decides the next round's songs" design Sergio described. `queues` table is
   unconnected scaffolding for this. Needs real design + implementation, not a
   small fix.
5. **`votes_update_before_lockin` RLS policy missing ownership check** — any user
   can cancel another participant's vote before lock-in.

### 2.3 Medium
6. **`votes_select_authenticated` exposes all individual vote rows** to any
   authenticated user, not just aggregates.
7. **`arena_live_state` view omits `sudden_death_active`**, forcing two different
   code paths (`BattleRoomScreen` via the view, `battleClosureOrchestrator.ts` via
   raw `battles`) to detect the same concept differently.
8. **The legacy `orchestrate_battle_closure`/`finalize_battle`/etc. pathway and
   three orphaned Edge Functions are dead code still present** — not urgent, but
   a maintenance liability and a confusing trap for future debugging (two
   competing "finalizer" implementations with similar names).

### 2.4 Low — cosmetic/data-hygiene bugs
9. **`arenas.mood` default is the four-character string `'NULL'`**, not a real
   SQL `NULL`. Any code doing `mood == null` checks will not match this default.
10. **`queues.queue_type` default is the literal placeholder string
    `'waiting_50, active_10 '`** (with a trailing space) — reads like
    documentation text accidentally left as a column default, not a real enum
    value.
11. **`battles.song_a_id`/`song_b_id` default to fixed placeholder UUIDs**
    (`11111111-...`, `22222222-...`) with **no FK constraint** on either column
    (only `winner_song_id` has one) — if any insert path ever relies on these
    defaults instead of explicit real song IDs, it'll silently reference
    nonexistent songs with no database-level error.
12. Duplicate RLS policies listed in §1.6 — harmless but worth consolidating.

### 2.5 Operational
13. **`battle_lifecycle_job` must not be re-enabled at a 1-second interval
    without first setting up `cron.job_run_details` retention** (a cleanup job,
    or Supabase's built-in log retention setting if available) — otherwise this
    exact bloat recurs. Both `battle_lifecycle_job` and `cron_seconds_test` are
    currently disabled (`active=false`) — `cron_seconds_test` looks like pure
    debug cruft and is a candidate for `cron.unschedule()` (full removal) rather
    than just staying paused.

---

## 3. Frontend gaps (already known from earlier conversation, restated here for one complete list)

- `ProposeSongModal.tsx` / `ActionStrip.tsx` exist but aren't mounted in
  `BattleRoomScreen`; submit is a `TODO`.
- `StageViewScreen.tsx` (`/stage` route) is fully hardcoded/mocked — separate copy
  of the presentational pieces, not wired to real data (confirmed expected/known,
  not a surprise).
- `/stage` has no `arenaId` wiring from anywhere, and no in-app navigation
  actually links to it (`ConnectStreamingScreen`'s link to `/stage` is itself
  unreachable, since nothing navigates to `/connect` either).
- `ConnectStreamingScreen.tsx` OAuth is entirely mocked (`handleConnect` just
  flips local state).
- `songs` has no audio-file/storage column for Sergio's curated mp3 phase —
  needs adding.
- `hosts` table is completely unused by the frontend, which assumes `host_id`
  points straight to `auth.users` — needs reconciling with Sergio.
- `arenas.mood` is typed on the frontend but never read/rendered anywhere.

---

## 4. Roadmap — what's needed for a complete running app

Ordered by what unblocks the most downstream work, folding in everything above:

1. **Fix the critical RLS holes (§2.1)** — remove/tighten the permissive
   `_mvp`/`dev_allow_all` policies and the any-participant `battles.state` UPDATE
   policies. This is the one item that's actually risky to leave as-is even
   during development, since it's a real open read/write hole on live data.
2. **Fix `battleClosureOrchestrator.ts`'s `fetchBattle()`** to stop selecting
   nonexistent columns (`is_special_battle`, `had_sudden_death`) — remove them or
   replace with the real mechanism (duration-sum-based, per §1.1).
3. **Decide and design song rotation** (the real gap in §2.2.4) — this needs
   Sergio: is it host-driven (via `create-battle` being re-triggered with new
   songs), participant-proposal-driven (via `ProposeSongModal`, now that Sergio
   confirmed songs will be a curated per-arena table), or `queues`-driven (wiring
   up the already-shaped-but-unused waiting/active list)? This single decision
   determines how `ProposeSongModal` actually gets wired.
4. **Seed curated songs** (already-scoped task) — now known precisely: insert
   into the real `songs` table, scoped to `arena_id` (confirmed per-arena, not
   global), add a storage/audio-file column, upload Sergio's mp3s.
5. **Wire `ProposeSongModal`** against the real `songs` table and whatever
   rotation mechanism comes out of #3.
6. **Build real playback** — `playlist_queue` already has everything needed
   (`spotify_track_id`, `song_duration_ms`); this becomes "read the next
   `playlist_queue` row for this arena and play it," initially via an `<audio>`
   tag against Sergio's mp3s, later via real Spotify playback once OAuth (#8)
   exists.
7. **Wire Stage View to real data** (already-scoped task) — read-only, now that
   schema is confirmed stable, no blockers remain for this one.
8. **Real Spotify OAuth in `ConnectStreamingScreen`** — now confirmed to belong
   to `streaming_accounts.host_id`, not per-arena.
9. **Clean up dead code** (§2.3.8, §2.4.12) — remove or clearly mark the legacy
   SQL pathway and orphaned Edge Functions, consolidate duplicate RLS policies.
   Not urgent, but cheap and reduces future confusion.
10. **Re-enable `battle_lifecycle_job` with log retention in place** (§2.5.13)
    before any sustained real usage, so this exact incident can't recur.

Still open, needs Sergio directly (not derivable from code or schema):
- The `hosts` table's real relationship to `arenas.host_id`/`auth.users`.
- Song rotation design (#3 above) — the single biggest remaining product
  decision blocking several roadmap items.
- Whether the legacy pathway (§1.1.A) and the three dead Edge Functions should be
  deleted outright or kept for reference.
