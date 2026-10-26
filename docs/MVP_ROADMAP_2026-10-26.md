# Music Fighter — MVP Roadmap (grounded re-read, 2026-10-26)

**This supersedes the roadmap/next-steps section of `docs/APP_STATE_AND_ROADMAP.md`.**
That file's architecture findings (real schema, real RLS, dead code, bugs found) are
still accurate and not replaced — only its "what's needed" roadmap section is
superseded by this document, which is grounded in a full fresh re-read of every
MVP spec document rather than the earlier session's partial/remembered reads.

**Every item below traces to a specific document.** Nothing here is an invented
"best practice" or an engineering nice-to-have not actually written in the specs —
that was explicitly the thing to stop doing.

Version authority (already established, restated for citation purposes):
`v3.2 > v3.0 > v2.6 > v2.0 > v1.0` for the `MVP/` lineage. The `Dev/PRD/` document
(v1.2x) declares itself `STATUS: DEFINITIVO — FUENTE ÚNICA DE VERDAD` (single
source of truth) and is the most structurally rigorous document found — treated as
highest authority for *feature scope* (what's in/out), with the `MVP/` v3.2
lineage and `Dev/Backend/` Blocks 1-5 as highest authority for *exact mechanics*
(formulas, thresholds, timings), since the PRD is scope-level and doesn't restate
every formula. `Dev/MVP/Paso 1-6` are process documents (design closure, UX
closure, technical closure, pilot, hardening, final decision) — cited for
process/criteria, not mechanics. The Spotify API docs explicitly state they
describe capabilities, not a roadmap — cited only as evidence for *why* a
mechanic exists, never as a roadmap source themselves.

---

## Doc conflict found — resolved by user decision, 2026-10-26

**PI (Prestige Influence) / ranking / gamification** appears as a core feature in
`v3.2`, `v3.0` §7, and `Backend_Block_1_Model.txt` (`USER_STATS`,
`USER_ACHIEVEMENT` entities) — but the PRD, which declares itself the single
source of truth, lists **"Rankings, perfiles sociales"** explicitly under
**§3 NON-GOALS**. **Resolved: the user has decided PI and Jukebox Boost are
intended features of the final product, overriding the PRD's non-goal framing.**
Both are now real roadmap items (see §C, §E below) rather than excluded.
**Comments/moderation** was part of the same flagged conflict but wasn't
addressed by this decision — still treated as excluded/undecided pending a
separate call.

Both open questions this raised are now resolved, 2026-10-26:

1. **Jukebox Boost payment stays deferred.** The non-payment mechanic (1 purchase
   per battle, non-cancelable, counts as 1.0 PB) is in scope to build now; the
   real-money payment integration specifically still waits for its own separate
   planning session, per the user's confirmation.
2. **PI displays inline, no dedicated Ranking screen.** PI shows next to the
   user's icon/profile/name wherever participant identity already appears in
   the UI (Battle Room, Stage View) — this respects `Paso_2`'s closed linear
   flow (no Profile/Ranking screens) rather than conflicting with it.

---

## Full roadmap by subsystem

Status key: **Done** (built and verified this session or earlier) / **Partial**
(schema and/or some logic exists, materially incomplete) / **Not started**.

### A. Arena lifecycle & lifecycle states
- Real states `waiting → active → finished` (+ technical `expired`) —
  *Backend_Block_2 §1*. **Done (step 1, 2026-10-26)** — see
  `supabase/sql/arena_state_model_2026-10-26.sql`; legacy `inactive` rows
  mapped to `expired`.
- `Arena.mood` field, set at creation, used for UX/system-proposal sourcing, never
  changes battle rules — *Backend_Block_2 §2*. **Done for UX (step 1)** —
  required at creation, shown in Lobby/Battle Room/Stage View; system-proposal
  sourcing use waits on step 13.
- **Warm-up song**: Host-selected, never competes/votes/scores/queues —
  *Backend_Block_2 §3, Backend_Block_3 §1*. **Done (step 2, 2026-10-26)** —
  with a user decision overriding *Backend_Block_2 §4 / Backend_Block_4 §2*:
  silent lobby; it starts on Start Battles and keeps playing as the first song
  of the session, battle 1 lasting its duration. See
  `supabase/sql/warmup_song_2026-10-26.sql`. Real audio via the host's browser
  (curated MP3s) until Spotify; post-warm-up playback is step 18.
- Battle states `init → normal → final_30s → sudden_death → finished` —
  *Backend_Block_2 §5, Paso_3 §3.2*. **Partial** — real implementation uses
  `pending/active/closing/completed`; conceptually close but `final_30s` isn't a
  distinct sub-state (folded into the lock-in-offset calculation), and `init`'s
  "3·2·1·FIGHT!" (*Paso_2 §6.2, Paso_3 §3.2*) isn't a tracked state at all.

### B. User presence & states
- ACTIVO / PASIVO / INACTIVO, 5-minute activity window, transition rules
  (including the "re-entering between battles starts next battle as ACTIVO" edge
  case) — *PRD §5, Paso_1_Definitivo §3, v3.2 §1.2, Backend docs reference it
  throughout*. **Not started** — `participants.last_active_at` exists as a
  column; nothing computes or transitions a state anywhere.

### C. Voting
- Active voting (1 vote/user/battle, last-vote-counts, toggle/switch) — *PRD
  §6.6, v3.2 §Votación, Decision Log*. **Done.**
- Passive voting: Spotify-affinity-similarity score
  (`0.4·artist + 0.3·genre + 0.3·audio_features`), ≥0.7 → +0.4 PB (+0.5 if
  ≥75% present users are passive), frozen until final 30s then ramps in, k=1.25
  aggregate cap, zero during Sudden Death — *v3.2 §"Cálculo de voto pasivo",
  Paso_1_Definitivo §6-8, PRD §6.6*. **Not started** functionally — schema
  anticipates it (`votes.vote_type = 'passive'`, already summed by
  `calculate_lockin_vote_totals`), nothing computes or writes it. Depends on D
  (participant streaming connection) existing first.
- Sudden Death (active votes only, PB_passive = 0) — *v3.2, v3.0 §6.3,
  Paso_1_Definitivo §6.4*. **Done.**
- Draw → both songs to playlist A-then-B — *v3.2 §Empates* (supersedes v3.0's
  PI-then-random tiebreak, already noted in CLAUDE.md). **Done.**
- Jukebox Boost: purchasable, non-cancelable, always-counts 1.0-point vote, 1
  purchase per battle per user, no cap on battles — *v3.2 §4-5, v3.0 §5*. **Not
  started.** Mechanic is in scope to build; the real-money payment integration
  specifically is deferred to its own planning session (user-confirmed
  2026-10-26).
- Prestige Influence (PI): awarded for proposing a winning song (full PI to
  original proposer, half to duplicate proposers), bonus PI for winning via
  Sudden Death, −5 PI for a first moderation infraction; tracked per-user via
  `USER_STATS`/`pi_logs`-equivalent — *v3.2 §PI, v3.0 §7, Backend_Block_1
  §10-11*. **Not started.** Displays inline next to the user's icon/profile/
  name wherever identity already appears in the UI (user-confirmed
  2026-10-26) — no dedicated Ranking screen, so this doesn't conflict with
  `Paso_2`'s closed linear flow after all.

### D. Streaming integration
- Host streaming connection (1:1 with Host, play/pause/switch-track/set-device
  only, no user control, no scrubbing/volume) — *Backend_Block_1 §2,
  Backend_Block_4 §1*. **Partial** — `streaming_accounts`/`ConnectStreamingScreen`
  schema+UI exist, OAuth is fully mocked.
- Participant streaming connection (OAuth for top tracks/artists/genres/
  audio-feature averages, to drive passive voting and passive proposals) —
  *v3.2 §"Integración musical del usuario", PRD §6.2, Spotify docs §4*. **Not
  started** — no schema, no flow at all. This is the single biggest blocker for
  C (passive voting) and the system-proposal half of E.
- "Playback Provider" abstraction (`getStatus/play/queue/skip/onProgress`,
  swappable implementation for legal/licensing reasons) — *v3.2 §Playback real,
  Backend_Block_4 §1*. **Not started.**
- Real playback: winner auto-plays, next battle starts when previous winner
  starts playing, progress-synced timers, auto-append winners to a local
  playlist — *v3.2 §Flujos clave, v3.0 §10, Backend_Block_3 §9,
  Backend_Block_4 §9*. **Not started** — `playlist_queue` has the right shape,
  nothing calls a real playback API.

### E. Song proposals & queue
- Active/human proposal (1 per user per battle, high priority, never displaced
  by system) — *Backend_Block_3 §3, PRD §6.3*. **Done** (`ProposeSongModal` →
  real `songs`/`queues`, this session).
- Passive/system proposal (auto-generated when pools aren't full AND no pending
  human proposals, sourced from aggregate passive-user affinity + mood + venue
  history, always low priority, never displaces human) — *Backend_Block_3 §4,
  Backend_Block_4 §3-4, PRD §8*. **Not started** — depends on D (participant
  affinity) and A (mood actually being used) and a venue-history concept that
  doesn't exist in any form yet.
- Duplicate proposal → auto-assigned pre-vote (not a new queue entry) — *v3.0
  §3.5, Backend_Block_3, PRD §6.3*. **Not started** — current behavior treats a
  duplicate as a silent no-op, not an auto-vote.
- Queue structure: `active_10` (max 10) / `waiting_50` (max 50, FIFO),
  human-priority-first fill — *Backend_Block_1 §7, Backend_Block_4 §3, v3.2
  §2.2*. **Partial** — this session built real `waiting`/`active` promotion by
  priority; the explicit 50-cap, FIFO-within-waiting, and human>system priority
  distinction (moot until system proposals exist) aren't enforced.
- Purge: a song with no promotion to active_10 after 20 battles is dropped —
  *v3.2 §2.2, v3.0 §3.4*. **Not started.**
- No-repeat-within-60-minutes — *v3.2 §Propuestas y colas, v3.0 §3.7, PRD
  (implicit via continuity)*. **Not started.**
- PI award on proposal outcome (full PI to original proposer of a winning song,
  half PI to duplicate proposers) — *v3.2 §PI, v3.0 §3.5/§7*. **Not started**,
  included per the 2026-10-26 decision above — depends on PI tracking existing
  (see §C) and real proposal/duplicate handling above being built first.

### F. Battle pair selection / matchmaking
- Pairs drawn only from `active_10`, matched by popularity tier, BPM/energy
  range, genre compatibility; next pair must be compatible with the current
  winner (BPM ±5-8, similar/ascending energy, compatible genre) for session
  continuity — *Backend_Block_4 §7-8, PRD §9*. **Not started** — current
  `pull_next_battle_songs` pulls top-2-by-priority only, no compatibility logic
  at all.

### G. Identity, security, persistence
- `identity_anchor_id` (anti-double-vote, survives auth-state changes) —
  *Backend_Block_5 §1*. **Done.**
- Role permissions (Host can't start battles manually, can't decide pairings,
  can't control results; users can't control music or Arena state) —
  *Backend_Block_5 §2*. **Done** this session (the RLS fix removing
  any-participant `battles.state` write access enforces exactly this).
- Token encryption at rest, TLS in transit, "E2EE lógico" (votes
  encrypted/anonymized) — *Backend_Block_5 §4*. **Partial** — TLS is
  Supabase-infra-level (reasonable to assume done), token encryption at rest not
  independently verified, vote-level encryption not implemented (relies on
  DB-level RLS, not field encryption).
- Arena TTL / archival of abandoned arenas — *Backend_Block_5 §6*. **Not
  started** (102 stale "Test Arena" rows from the cron incident are exactly the
  kind of thing this rule would have prevented from piling up).

### H. Host arena-management flows
- Pause/resume Arena, choose initial song if no previous winner exists,
  configure excluded genres (Host cannot veto specific songs, isn't notified of
  ties) — *v3.0 §9, v3.2 §Administrador, Backend_Block_2*. **Not started**
  beyond create/view.

### I. Stage View & UX conformance
- Real-data Stage View wiring — already scoped in the prior roadmap doc as
  unblocked. **Not started** (confirmed still true — `StageViewScreen.tsx` is
  hardcoded).
- Tension bar exact behavior (50/50 start, interpolated not instant, micro-
  oscillation, percentages pinned to the divider), battle-card exit/win
  animation sequence, status-overlay timing — *Paso_2 §5-7*. **Partial** —
  current components implement a version of this; not verified against the
  exact spec'd behavior/timings in this re-read.

### J. Validation & closure (process, not code)
- Real-venue pilot (1 local, 10-30 people, 60-120 min, specific GO/NO-GO
  criteria) — *Paso_4*. **Not started.**
- Hardening pass (no new features, only fix what the pilot surfaced) —
  *Paso_5*. **Not started**, can't start before J's pilot runs.
- MVP closure decision (scale / iterate / discard) — *Paso_6*. **Not
  started**, final gate.

---

## Proposed engineering additions (judgment call, not spec-sourced — 2026-10-26)

Requested explicitly by the user, given the product's actual nature: a
gamification layer, real in-app purchases, shipping to phone/tablet/desktop.
Flagged clearly as additions, not documented requirements:

1. **Payment/App Store compliance boundary.** If Music Fighter ever ships as a
   native app through Apple's App Store or Google Play (not just responsive
   web), Jukebox Boost's payment *must* go through that platform's own in-app
   purchase API for a digital good bought inside the app — bypassing it (e.g.
   a web checkout link) risks app rejection or removal. This is a real
   constraint on item 11 below, not a style preference — worth deciding now
   whether distribution stays web/PWA (simpler, direct Stripe-style payment
   works) or goes native through app stores (forces platform IAP).
2. **Idempotent, auditable PI ledger.** Award PI through an append-only log
   with a replay-safe uniqueness constraint (e.g. one row per
   `battle_id + user_id + reason`), so a retried event never double-awards —
   the same idempotency pattern already used elsewhere in this codebase
   (`ensure_mock_songs_for_arena`'s existence check), just extended to PI.
3. **Shared anti-abuse boundary.** PI and Jukebox both affect competitive
   outcomes and real money — route both through the existing
   `identity_anchor_id` anti-double-vote mechanism rather than letting either
   subsystem bypass it with its own identity check.
4. **Explicit cross-platform QA gate.** Target platforms are phone (iOS/
   Android)/tablet/desktop (Win/Mac); today's delivery is pure responsive web.
   Add a concrete breakpoint/device test matrix (small phone portrait, tablet,
   desktop widescreen, at minimum) as a gate before the pilot stage.
5. **Server-side receipt verification.** Never grant Jukebox's vote weight on
   a client-reported "purchase succeeded" — verify the payment provider's
   webhook/receipt server-side first. Standard practice for any real-money
   feature, worth stating explicitly given this is the project's first one.

#1 and #4 are folded into the 20-item list below since they're closer to hard
requirements than optional nice-to-haves; #2, #3, #5 are noted as
implementation guidance on the relevant items rather than separate stages.

---

## The 20 build stages, dependency-ordered

Regenerated from the 10 above — denser subsystems split into coherent halves,
nothing added that wasn't already in the 10 except the two resolved decisions
(PI display, Jukebox payment split) and the two near-mandatory engineering
additions (#1, #4 above), each marked where it lands.

1. **Real Arena state model** — `waiting/active/finished/expired`, `mood`
   persisted and actually read. **Done 2026-10-26** — incl. auto-finish of
   abandoned active arenas (2h idle), cancelled in-flight battles, and
   Block 5 §6 vote retention (30 days). Two-device check passed in-app
   (guest join, waiting overlay, guest voting/proposals, live "finished").
2. **Warm-up song system** — Host selects it (mood-based suggestions), never
   competes/votes/scores/queues. **Done 2026-10-26**, per the user's
   definition (overrides Block 2 §4): silent lobby, starts on Start Battles,
   is the first song of the session and sets battle 1's duration. Battle 1
   also falls back to mood-matched library songs instead of "Mock Song A/B"
   when nothing was proposed in the lobby.
3. **Presence tracking infrastructure** — real writes to `last_active_at` on
   every qualifying action (vote, proposal, entering Arena).
4. **Presence state transitions** — ACTIVO/PASIVO/INACTIVO computed from #3,
   including the "re-enters between battles → starts next as ACTIVO" edge case.
5. **Host Spotify OAuth** — PKCE flow, encrypted token storage/refresh, device
   selection.
6. **Playback Provider abstraction** — `getStatus/play/queue/skip/onProgress`
   interface plus the Spotify implementation. Kept swappable per the docs'
   own licensing rationale, not an invented abstraction.
7. **Participant Spotify OAuth** — separate scope from #5 (`user-top-read`
   etc.), the prerequisite for both #9 and #12.
8. **Participant affinity profile sync** — top tracks/artists/genres/
   audio-feature averages, recalculated on the spec's cadence.
9. **Passive voting engine** — the affinity-similarity formula, k=1.25 cap,
   30-second freeze/ramp, zero during Sudden Death. Depends on #4 and #8.
   Only participants with no `votes` row for the battle get a passive vote:
   voting and then cancelling means abstaining, not "didn't vote"
   (user decision, 2026-10-26).
10. **Jukebox Boost mechanic** — the vote behavior only (1 purchase per battle,
    non-cancelable, counts as 1.0 PB). Apply the shared anti-abuse boundary
    (engineering addition #3) here.
11. **Jukebox Boost payment integration** — *deferred*, not scheduled; waits
    for its own planning session (user-confirmed). When it is scheduled, the
    App Store/Play Store compliance boundary (engineering addition #1) and
    server-side receipt verification (addition #5) apply directly to this item
    — decide web/PWA vs. native distribution before building it, since that
    choice determines which payment path is even legal to use.
12. **Queue rule enforcement** — explicit `active_10`/`waiting_50` caps, FIFO
    within waiting, 60-minute no-repeat, 20-battle purge, human>system
    priority.
13. **Passive/system auto-proposal generation** — sourced from aggregate
    passive-user affinity + `mood` + venue history, always lower priority than
    human proposals. Depends on #1, #8, and a venue-history concept that
    doesn't exist yet in any form.
14. **Duplicate-proposal auto-vote** — a repeat proposal becomes a pre-assigned
    vote instead of a new queue entry.
15. **PI award logic** — full/half PI on proposal wins, Sudden Death bonus,
    −5 PI on a first infraction. Use an idempotent, auditable ledger
    (engineering addition #2) so a retried event never double-awards.
16. **PI display in the UI** — inline next to the user's icon/profile/name
    wherever identity already appears (Battle Room, Stage View) — no dedicated
    Ranking screen, resolved 2026-10-26.
17. **Battle pair selection / matchmaking** — popularity/BPM/energy/genre
    compatibility, continuity with the previous winner. Needs #12 and #13 (a
    real, populated queue) to select from.
18. **Real playback wiring end-to-end** — winner auto-plays, battle starts when
    the previous winner starts, synced timers, playlist auto-append. Depends
    on #6 and #17 — this is where "what wins, plays" actually becomes true.
19. **Stage View, remaining host flows, and UX/cross-platform conformance** —
    real-data Stage View, pause/resume Arena, excluded genres, initial-song
    selection, exact tension-bar/overlay timing, and the phone/tablet/desktop
    breakpoint QA gate (engineering addition #4). Depends on #18 for real data
    to display.
20. **Pilot validation, hardening, closure** — the real-venue pilot, fix-only
    hardening pass, GO/NO-GO/iterate/discard decision. Depends on everything
    above being functionally real first.
