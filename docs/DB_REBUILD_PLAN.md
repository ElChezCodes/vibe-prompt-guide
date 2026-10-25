# Database Rebuild Plan — Draft for Sergio's Review

## Why this exists

The Supabase project backing this app (`uuxzjroikbzwaszpgiks`) is paused and its database
has grown to 7.0 GB — past what the free plan will restore without upgrading. We've decided
**not** to pay to restore it during development, and support isn't an option we're waiting on.
No SQL, migrations, or schema dump exist anywhere outside that paused database — not in this
repo, not in the docs folder, not with Sergio. So we're rebuilding the schema and backend logic
from scratch in a new Supabase project, reconstructed from what the frontend code assumes plus
the spec docs.

**Nothing below has been run anywhere.** This is a draft to review and correct before we
provision anything. Every item is tagged with how confident we actually are:

- **[VERIFIED]** — read directly from working frontend code (a `.select()`, an interface, a
  constant) in this repo. As close to ground truth as we can get without the real database.
- **[CORROBORATED]** — Lovable's AI independently reconstructed the same detail from the same
  codebase (it could not connect to the live DB either — its answer said so explicitly). Two
  independent reconstructions agreeing is reassuring, but it's still not a live schema read.
- **[SPECULATIVE]** — invented to be plausible (by Lovable, by me, or by both) to fill a gap
  neither of us can actually see. Treat as a strawman, not a fact. These are the items that most
  need Sergio's correction before we write real SQL.

Business rules (lifecycle states, Sudden Death, draw resolution, vote types) are already
documented in `CLAUDE.md` and aren't repeated here except where they bear directly on a schema
decision.

---

## 0. CRITICAL — chained/pipelined voting model (new understanding, 2026-10-25, NOT yet fully confirmed)

Per Sergio: **voting during a battle decides what plays in the *next* round, not what's audible
right now.** At any moment, what's actually playing through the venue's speakers is the
*previous* round's winner, while the *current* battle's `song_a`/`song_b` are two candidates
competing to become the *next* thing queued. Voting is always one step ahead of playback.

**Implications this reframes** (flagged, not yet confirmed with Sergio):
- `winner_song_id` is likely not just a historical record — it's the real signal for "play this
  song next." `useArenaFlow`'s current no-op placeholder needs to become a real playback trigger,
  timed for when the currently-audible song ends.
- A normal battle's `duration_ms` is probably not an arbitrary fixed voting window — it likely
  needs to match the length of whatever song is *currently playing* (the previous round's
  winner), so the vote resolves exactly as that song ends.
- **This walks back part of the same-row/new-row reasoning below.** That recommendation assumed
  a special battle's `song_a_id`/`song_b_id` were the same two drawn songs, revoted on live. If
  voting is always for the *next* round, a special battle's `song_a_id`/`song_b_id` are more
  likely a *fresh* pair of candidates for the round after the drawn songs finish — not the drawn
  songs themselves. Open question with no answer yet: **where does the system record which two
  songs are actually playing during the special battle's extended window**, if not in that row's
  own `song_a_id`/`song_b_id`? A separate field we haven't accounted for, or a lookup to the prior
  completed battle?
- Recursion is confirmed possible: **a special battle can itself end in another tie, triggering
  another special battle.** (Confirmed by Sergio, 2026-10-25.)

**This needs a precise answer from Sergio before any of §1/§2 below is implemented**, specifically:
1. Does *every* battle row's `song_a_id`/`song_b_id` always mean "candidates for the next round,"
   never "what's currently audible"?
2. What determines "what's currently playing" during a round's voting window — is it simply "the
   previous round's resolved winner" (derivable by looking at the prior completed battle, no new
   column needed), or is there a dedicated "now playing" field/table we haven't found?
3. For a special (draw) battle specifically: do its `song_a_id`/`song_b_id` hold the *next*
   candidates (per the chained model), with the two drawn songs' *playback* tracked separately —
   or do they hold the two drawn songs themselves, with the *next* candidates tracked somewhere
   else? These are different schemas and we need to know which before writing migration SQL.
4. Does `winner_song_id` really function as "cue this for playback next," confirming the pipeline
   theory?

---

## 1. Tables

### `arenas` — [VERIFIED]
Source: `src/integrations/supabase/arenas.ts` (`Arena` interface, `resolveArenaByCode`,
`createArena`), `src/screens/ArenaLobbyScreen.tsx`.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `name` | text | |
| `state` | text | |
| `mood` | text | Column exists and is typed on the frontend; **never read or rendered anywhere in `src/`**. Likely meant to drive arena-background art (per the visual design docs) but unimplemented. |
| `host_id` | uuid | nullable, references the auth user |
| `arena_code` | text | looked up via `resolveArenaByCode`; must be unique |
| `created_at` | timestamptz | |

### `identity_anchors` — [VERIFIED]
Source: `src/integrations/supabase/identityAnchors.ts`.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `created_at` | timestamptz | |

### `participants` — [VERIFIED]
Source: `src/integrations/supabase/participants.ts`.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `arena_id` | uuid | FK → `arenas.id` |
| `identity_anchor_id` | uuid | FK → `identity_anchors.id` |
| `is_host` | boolean | default `false` |
| `created_at` | timestamptz | |

`ensureParticipant` does a select-then-insert for idempotency rather than relying on a DB-level
upsert — **[SPECULATIVE]**: a unique constraint on `(arena_id, identity_anchor_id)` would be the
correct safeguard, but we don't know if one exists today.

### `battles` — [VERIFIED] with one [SPECULATIVE] field
Source: `src/hooks/useBattleOrchestrator.ts` (`ArenaBattleView`'s `MERGE_FIELDS`),
`src/lib/battleClosureOrchestrator.ts` (`BattleData`), `src/hooks/useBattleClosureOrchestrator.ts`.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `arena_id` | uuid | FK → `arenas.id` |
| `song_a_id` | uuid | FK → `songs.id` |
| `song_b_id` | uuid | FK → `songs.id` |
| `state` | text | `'pending' \| 'active' \| 'closing' \| 'completed'` |
| `started_at` | timestamptz | nullable until active |
| `duration_ms` | integer | |
| `lockin_at` | timestamptz | **[CORROBORATED]** `= started_at + duration_ms − 15000`. The 15000ms offset is independently confirmed — it matches `LOCKIN_OFFSET_MS` in `battleClosureOrchestrator.ts:211`. |
| `sudden_death_active` | boolean | default `false` |
| `had_sudden_death` | boolean | default `false` |
| `resolution_type` | text | nullable. Values include `'sudden_death'` — confirmed live in `BattleRoomScreen.tsx:47`. Lovable additionally guessed `'standard'` / `'draw'`; `'draw'` is now **[CORROBORATED]** by Sergio's explanation of `is_special_battle` below — a draw-after-Sudden-Death is a real, named outcome. Exact string value still unconfirmed. |
| `winner_song_id` | uuid | nullable, set on resolution |
| `is_special_battle` | boolean | **[VERIFIED column, CORROBORATED meaning]** — present in `BattleData` (`battleClosureOrchestrator.ts:27`), never read or branched on anywhere in the frontend, so its purpose wasn't derivable from code. Per Sergio (relayed 2026-10-25): marks a battle where **both songs from a Sudden-Death draw play back-to-back**, with `duration_ms` = the combined duration of both drawn songs — functionally a **rematch**, not a passive victory lap: Sergio confirmed voting stays fully active for the entire combined duration, which means `winner_song_id` is expected to be set for real at the end of this round (not left null). Sergio noted this path may have **never actually fired** in the real (now-paused) data — i.e. no real example row to check even with DB access. This lines up with the spec's draw rule ("ambas canciones pasan a la playlist en orden A luego B" — `MUSIC FIGHTER — MVP CONSOLIDADO (TXT) v 3.2.txt:6`, confirmed as current in `v4:95`) — **working hypothesis: `is_special_battle` may be *how* that spec rule is implemented**, i.e. the "playlist" isn't necessarily a separate queue table, it's just the next `battles` row. **Decision (2026-10-25): implement as a NEW `battles` row**, not a mutation of the original tied row — see rationale in §4. |
| `created_at` | timestamptz | |

### `votes` — [VERIFIED]
Source: `src/integrations/supabase/votes.ts`.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `battle_id` | uuid | FK → `battles.id` |
| `participant_id` | uuid | FK → `participants.id` |
| `arena_id` | uuid | FK → `arenas.id` (present on insert payloads) |
| `identity_anchor_id` | uuid | FK → `identity_anchors.id` (present on insert payloads) |
| `song_id` | uuid | |
| `status` | text | `'active' \| 'cancelled'` |
| `vote_type` | text | `'regular' \| 'sudden_death'` |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |

### `songs` — [CORROBORATED] core columns, [SPECULATIVE]/new for playback
Source: `arena_live_state` view fields (`song_a_title`, `song_a_artist`, `song_a_source`,
`song_a_spotify_track_id`, `song_a_duration_ms` in `useBattleOrchestrator.ts`) plus Lovable's
reconstruction.

| Column | Type | Notes |
|---|---|---|
| `id` | uuid | PK |
| `title` | text | **[VERIFIED]** (view exposes `song_a_title`/`song_b_title`) |
| `artist` | text | **[VERIFIED]** |
| `source` | text | **[VERIFIED]** — distinct from `spotify_track_id`, meaning non-Spotify sources were already anticipated |
| `spotify_track_id` | text | **[VERIFIED]** |
| `duration_ms` | integer | **[VERIFIED]** |
| `album_art_url` | text | **[SPECULATIVE]** (Lovable's guess only) |
| `audio_storage_path` | text | **Not in the original schema at all** — needed new, for Sergio's curated mp3 phase. Neither reconstruction surfaced an audio-file column, which lines up with `ProposeSongModal`/playback never having been wired up. This is new work, not recovery. |
| `created_at` | timestamptz | |

### `queues` / `playlist_queue` — [SPECULATIVE], unused
Named in `CLAUDE.md` as existing with "zero frontend wiring." Nothing in `src/` references
either table at all, so there's no code to reconstruct a shape from. Lovable's guess
(`id, arena_id, song_id, position, status`) is a plausible placeholder, not a reconstruction.
**Open question for Sergio: do we even need these in the rebuild yet, or can they be deferred
entirely until the queue feature is actually scoped?**

### `streaming_accounts` — [SPECULATIVE], unused
Same situation — named in `CLAUDE.md`, zero frontend references, Lovable's guessed shape
(`id, arena_id, provider, access_token, refresh_token, expires_at`) is a placeholder. Given
`ConnectStreamingScreen.tsx` is fully mocked (no real OAuth), this table has never been exercised
by any real code path. Same question: defer until OAuth work actually starts?

### View: `arena_live_state` — [VERIFIED]
Exact column list taken directly from the `ArenaBattleView` interface in
`src/hooks/useBattleOrchestrator.ts:5-34` — this is the one piece of "schema" we have 1:1 from
working code, since the frontend's `.select("*")` against this view and its consumption are both
visible. Joins current battle + both songs' metadata + live vote counts (`votes_a`, `votes_b`).

---

## 2. RPC Functions

### `create_arena(p_name text, p_host_id uuid) RETURNS uuid` — signature [VERIFIED], body [SPECULATIVE]
Call site: `src/integrations/supabase/arenas.ts:43`. We know the signature and return type
precisely (uuid, fetched back via a follow-up `select`). We do **not** know:
- The real `arena_code` generation algorithm (length, charset, collision handling) —
  **[SPECULATIVE]**, both reconstructions guessed "4-6 alphanumeric characters."
- Whether `mood` gets a default value here or elsewhere — **[SPECULATIVE]**.

### `run_battle_finalizer_job() RETURNS void` — signature [VERIFIED], body almost entirely [SPECULATIVE]
Call site: `supabase/functions/battle-finalizer-cron/index.ts:9`, invoked with no arguments via
the service role. Everything about what it actually *does* is reconstructed from `CLAUDE.md`'s
prose description and generic knowledge of how such systems are typically built — **neither
Lovable nor I have seen this function's real body.**

**The one load-bearing hypothesis in this whole document:** Lovable's reconstruction claims this
job, after resolving a `closing` battle, "immediately prepares and inserts the next battle row...
to maintain real-time flow" — with no song assignment. If that's accurate, it fully explains the
bug: one mock arena, perpetually auto-chaining blank battles, for however long the cron ran
unattended, producing the 7 GB of junk we're trying to get out from under.

**This needs Sergio's direct answer, not another reconstruction:**
- Does the finalizer really auto-create the next battle today?
- If so — was that *intentional* (keep the arena "always live" automatically) or should
  continuing to the next battle become an explicit host action instead (i.e., folded into
  `create-battle`, which the host already triggers manually via "Enter Battle")?
- Either way, the rebuilt version must pick two real songs for any battle it creates — the
  original apparently never did this anywhere.

### `create-battle` (Edge Function, not an RPC) — [VERIFIED — full source, from Sergio]
This one we actually have in full, pasted directly by Sergio earlier in this conversation. It:
inserts a `battles` row with only `arena_id` and `sudden_death_active: false` — no songs, no
`state`, no `duration_ms`, no `started_at`. Confirms independently that the manual "Enter Battle"
path has the exact same missing-songs gap as the hypothesized auto-chain path above.

**Open question tied to this, already raised once before:** should `create-battle`, once it picks
two songs, also set `state = 'active'`, `started_at`, and `duration_ms` to start the clock — or
should that remain a separate transition? Still unanswered.

---

## 3. Row-Level Security — [SPECULATIVE], entirely a strawman

None of this has been read from a real policy. It's built by reasoning backward from observed
app behavior (`isRlsError` handling in `votes.ts`, the "backend-only transitions" rule in
`CLAUDE.md`) into policies that *would* produce that behavior — not policies known to exist.

Proposed starting point, for Sergio to correct line by line:

- **`arenas`**: public/anon `SELECT` (needed for join-by-code); `INSERT` only via `create_arena`
  (service role), not directly from anon.
- **`identity_anchors`**, **`participants`**: anon `SELECT`/`INSERT` allowed — participants are
  walk-up strangers with no real account.
- **`battles`**: public `SELECT` (and included in the Realtime publication); `INSERT`/`UPDATE`
  restricted to `service_role` only — this is the mechanism that would actually enforce "frontend
  never decides battle state," not just a convention.
- **`votes`**: anon `SELECT`; `INSERT`/`UPDATE` guarded so that:
  - any write after `battles.state` leaves `'active'` is rejected (→ the `42501` the app treats
    as "locked"),
  - `vote_type = 'sudden_death'` is only insertable when `sudden_death_active = true`,
  - no update/cancel is allowed once a row has `vote_type = 'sudden_death'` (immutability).

---

## 4. Open questions for Sergio — consolidated

1. **Does `run_battle_finalizer_job` auto-create the next battle?** (Leading theory for root
   cause of the 7 GB bloat — needs a real answer, not another reconstruction.)
2. If it does — should that auto-chaining behavior continue in the rebuild, or should starting
   the next battle become an explicit host action via `create-battle` instead?
3. ~~What does `battles.is_special_battle` mean?~~ **Answered by Sergio (2026-10-25):** marks a
   combined-duration rematch battle for the two songs that drew after Sudden Death, with voting
   fully active the whole time — see table above. Follow-ups still open:
   - ~~Same row vs. new row?~~ **Decided: new row — but see §0 above, this needs re-examination.**
     The reasoning below assumed a special battle's `song_a_id`/`song_b_id` are the same two drawn
     songs being revoted on. If the chained-voting model in §0 is correct, that premise is wrong,
     and the right representation may not be "one new `battles` row" at all — it might need a
     playback reference distinct from the vote-candidate fields. Original reasoning, kept for
     reference: The original tied battle completes normally
     (`state='completed'`, `resolution_type='draw'`, `winner_song_id=null`); a fresh `battles` row
     is inserted with the same two songs, `is_special_battle=true`, and `duration_ms` = combined
     duration, running through the normal `pending→active→closing→completed` lifecycle. Rationale:
     `BattleTimer` needs a clean `started_at` for this round, vote tallying per `battle_id` stays
     unambiguous, and the orchestrator's entire "one `battle_id` = one contest" model (INSERT
     handling, `useArenaFlow`'s once-per-battleId consumption, vote-reset-on-id-change) applies
     with zero special-casing. Reusing the same row would require overwriting `started_at` mid-row
     and disambiguating old vs. new votes sharing one `battle_id` — fighting the existing design
     rather than extending it.
   - **New question this raises:** can the rematch itself end in another tie? If so, does it
     recursively trigger Sudden Death → another special battle? Unanswered — ask Sergio.
   - Is `duration_ms` literally stored as `song_a.duration_ms + song_b.duration_ms`, computed at
     creation time?
   - Confirm: has this path ever actually executed in real data, or is it untested/unexercised
     end to end?
   - Implementation note regardless of the above: `is_special_battle` isn't currently exposed on
     the `arena_live_state` view or the `ArenaBattleView` frontend interface — it'll need to be
     added to both so Stage View / Battle Room can render this round differently (e.g. no "FIGHT!"
     VS intro, since it's a rematch, not a fresh matchup).
4. What's the real `arena_code` generation algorithm?
5. **Do `queues` / `playlist_queue` need to exist in the rebuild at all**, or does
   `is_special_battle` already implement the spec's "both songs go to the playlist in A-then-B
   order" draw rule (`v3.2:6`, `v4:95`) by itself, via ordinary `battles` rows? If so, a separate
   queue table may only be needed for a *later*, different feature (host-curated upcoming-songs
   queue), not for draw resolution. Does `streaming_accounts` similarly stay deferred until OAuth
   work actually starts (nothing references it today)?
6. Should `create-battle` start the battle clock itself (`state`/`started_at`/`duration_ms`), or
   should that stay a separate backend transition?
7. Sanity-check the proposed RLS policies in §3 against actual intent — these are invented to
   match observed behavior, not read from a real policy.

## 5. Next steps (once Sergio's answered the above)

1. Finalize schema + RLS + RPC logic as real migration SQL, committed to this repo (so this
   single-point-of-failure situation can't happen again).
2. Provision a new Supabase project; apply the migration.
3. Re-point `src/integrations/supabase/client.ts` at the new project's URL/anon key.
4. Seed the curated `songs` table with Sergio's mp3s (separate task, already scoped).
5. Update `create-battle` (and the finalizer, if it's the one auto-chaining) to actually assign
   two real songs to every battle.
6. Re-test the full loop end to end before anything else gets built on top of it.
