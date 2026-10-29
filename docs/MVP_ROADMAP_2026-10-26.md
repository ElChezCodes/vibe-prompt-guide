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

## Change of focus — user decision 2026-10-27 (Spotify Developer Policy)

After reviewing Spotify's Developer Policy (III.10 no business/venue use,
III.13 no listener profiling from Spotify data, IV.2 no monetisation;
dev-mode apps limited to 5 users, extended quota only for organisations
with 250k MAU; audio-features/recommendations closed to new apps since
2024-11-27; Feb-2026 dev-mode changes removed `popularity` from tracks/
artists and `product` from `GET /me`), the product is re-scoped. **This
overrides every spec document where they disagree:**

1. **Private gatherings among friends** (a dinner at home), **not bars or
   venues.** Framed as gamified music selection for a private group.
2. **Music Fighter never plays audio.** It curates a playlist it creates in
   real time in the **host's Spotify Premium account** (host must be
   Premium); playback happens in the host's own Spotify app, on their own
   device. The warm-up is the **first track of that playlist** (user
   decision 2026-10-27, built in step 6/18; the browser MP3 warm-up of step 2
   stays only as a provisional stand-in until then).
3. **Participants never connect Spotify.** Affinity and passive voting will
   be computed from **Music Fighter's own data**. Steps 7, 8, 9 and 13 are
   **to be redefined** (marked below, not redesigned here).
4. **Jukebox Boost and all payments are excluded for now** (steps 10-11).

**Spec parts made obsolete by this** (kept in the docs for history, not
deleted, but no longer requirements):
- *Venue / "local" framing everywhere*: v4 §8.1 "reproductor real del
  local", §10.2 playlist name "Music Fight + Nombre del Local" and "Stage
  View se autentica con la cuenta del local", §11.1 "cuenta del local",
  §11.4 venue-responsibility TOS note, §2.4/§12 "no volver a sonar en el
  local"; PRD §6.2 "Activa [Servicio] en el local", §19 "Local acepta
  repetir"; Paso_4 real-venue pilot (1 local, 10-30 people).
- *GPS / geofencing*: v4 §16.3 (GPS as auxiliary validation, 30 m geofence).
  QR/PIN only.
- *Venue music history* as an affinity/proposal source: Backend_Block_3 §4,
  CLAUDE.md three-tier model, step 13. (Block_4 §4 "historial musical del
  Host" is also Spotify-derived and falls under point 3.)
- *Participant Spotify integration*: v4 §11.2-11.3 (`user-top-read`, top
  tracks/artists, `audio-features`, `audio-analysis`), v3.2 "Integración
  musical del usuario", PRD §6.2 participant side, Spotify docs §4, the
  `0.4·artist + 0.3·genre + 0.3·audio-features` passive-vote formula and the
  k=1.25 affinity cap discussion, v4 §17.1 "Perfil: conectar/desconectar
  Spotify; ver afinidad" for participants.
- *Spotify-derived matching data*: Backend_Block_4 §5-8 audio features and
  "Spotify popularity" tiers (endpoint closed / field removed) — affects
  step 17, see there.
- *PRD §6.2 "No necesitas cuenta Premium 😉"*: the host must be Premium.
- *Jukebox Boost / payments*: v3.2 §4-5, v3.0 §5, engineering additions
  #1, #3, #5 below (dormant while payments are excluded).
- *Stage View "for the venue"*: it stays as a shared screen (TV at the
  party), read-only; it does not authenticate with any account or control
  playback (v4 §10.1 "control de playback desde Stage View", §17.2
  "controles de playback, selector de dispositivo" → the host's phone does
  that, via MF's backend).

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
  throughout*. **Done** — activity writes (step 3) and server-computed states
  with a per-battle lock-in snapshot (step 4).

### C. Voting
- Active voting (1 vote/user/battle, last-vote-counts, toggle/switch) — *PRD
  §6.6, v3.2 §Votación, Decision Log*. **Done.**
- **To be redefined (2026-10-27): passive voting will use Music Fighter's own
  data, not Spotify; the mechanics below are the superseded spec version.**
  Passive voting: Spotify-affinity-similarity score
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
- **Excluded for now (2026-10-27).** Jukebox Boost: purchasable, non-cancelable, always-counts 1.0-point vote, 1
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
  Backend_Block_4 §1*. **Done (step 5, 2026-10-27)** — real Spotify OAuth
  (PKCE), encrypted tokens, backend refresh, Premium check, device choice,
  disconnect. Host-level and reusable across arenas.
- ~~Participant streaming connection~~ — **dropped (2026-10-27)**:
  participants never connect Spotify (policy III.13). Passive voting and
  passive proposals get their data from Music Fighter itself (to be
  redefined, steps 7-9, 13).
- "Playback Provider" abstraction (`getStatus/play/queue/skip/onProgress`,
  swappable implementation for legal/licensing reasons) — *v3.2 §Playback real,
  Backend_Block_4 §1*. **Done (step 6, 2026-10-27)** — Spotify implementation,
  arena playlist + warm-up on the host's device, pause/resume watcher.
- Real playback: winner auto-plays, next battle starts when previous winner
  starts playing, progress-synced timers, auto-append winners to the arena's
  playlist in the host's Spotify account (not a "local" playlist, 2026-10-27) — *v3.2 §Flujos clave, v3.0 §10, Backend_Block_3 §9,
  Backend_Block_4 §9*. **Built and verified in-app 2026-10-28 (step 18).**

### E. Song proposals & queue
- Active/human proposal (1 per user per battle, high priority, never displaced
  by system) — *Backend_Block_3 §3, PRD §6.3*. **Done** (`ProposeSongModal` →
  real `songs`/`queues`, this session).
- **To be redefined (2026-10-27): own-data affinity, no venue history.**
  Passive/system proposal (auto-generated when pools aren't full AND no pending
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
  at all. **Affected by 2026-10-27:** Spotify no longer provides
  popularity (removed Feb 2026) or audio features/BPM/energy (closed to new
  apps) — the inputs need another source before this step.

### G. Identity, security, persistence
- `identity_anchor_id` (anti-double-vote, survives auth-state changes) —
  *Backend_Block_5 §1*. **Done.**
- Role permissions (Host can't start battles manually, can't decide pairings,
  can't control results; users can't control music or Arena state) —
  *Backend_Block_5 §2*. **Done** this session (the RLS fix removing
  any-participant `battles.state` write access enforces exactly this).
- Token encryption at rest, TLS in transit, "E2EE lógico" (votes
  encrypted/anonymized) — *Backend_Block_5 §4*. **Partial** — TLS is
  Supabase-infra-level (reasonable to assume done), streaming tokens encrypted
  at rest since step 5 (AES-256-GCM, key in Edge secrets), vote-level encryption not implemented (relies on
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
- Pilot (**a private gathering, not a venue, since 2026-10-27**; the
  original spec: 1 local, 10-30 people, 60-120 min, specific GO/NO-GO
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
2b. **Functional in-app navigation** — added by user decision 2026-10-26,
    pulled ahead of #19. **Done 2026-10-26**, verified in-app (host + guest checklist).
    User decision: Paso_2 §3's closed flow ("no back/menus") applies only
    inside the Battle Room; the rest is an app shell with a bottom tab bar
    (Home · Propose · Arena · Ranking · Profile), Ranking/Profile as
    placeholders. Arena in the URL (`/a/:code/...`), `/join/:code` + real QR,
    Lobby → Connect/Stage, End Arena in Lobby and Battle Room, "← App" out of
    the battle without leaving the arena, explicit "Leave arena"
    (`participants.left_at`), backend-owned current arena, propose song both
    in-battle and on its own screen sharing `queues.proposed_by`. Visual
    design is done by the user in Lovable from a handoff prompt.
3. **Presence tracking infrastructure** — real writes to `last_active_at` on
   every qualifying action (vote, proposal, entering Arena).
   **Done 2026-10-26** (`supabase/sql/presence_tracking_2026-10-26.sql`).
   Server-side only: `enter_arena` RPC (every Battle Room / host Lobby entry,
   incl. reloads and returning from other tabs), AFTER triggers on votes
   (cast/switch/toggle-off; never passive) and queues (proposals), and the
   host's Start battles. A guard trigger pins `last_active_at`/`joined_at` for
   client roles. User decisions: host counts like everyone + Start counts;
   toggling off counts; heartbeat is NOT activity (v4 §1.3).
   Verified in-app by the user 2026-10-26.
4. **Presence state transitions** — ACTIVO/PASIVO/INACTIVO computed from #3,
   including the "re-enters between battles → starts next as ACTIVO" edge case.
   **Done 2026-10-26** (`supabase/sql/presence_states_2026-10-26.sql`).
   Computed on the fly (`presence_state` / `participant_presence`), 5-min
   activity window; connection = 30 s heartbeat (`last_seen_at`, not activity)
   with a 10-min grace for locked phones, immediate INACTIVO on tab close
   (`pagehide`) or Leave arena. Frozen per battle at lock-in in
   `battle_presence_snapshots`, which is what #9 and the 0.4/0.5 PB ratio read.
   User decisions: no music account needed to be PASIVO (#9 checks it);
   a PASIVO user's active vote stays active and tapping again re-activates
   them (no RLS lock). Open for #9: 75 % "pasivos" (v3.2/v4) vs "inactivos"
   (Paso_1/PRD).
5. **Host Spotify OAuth** — PKCE flow, encrypted token storage/refresh, device
   selection. **Done 2026-10-27** (`supabase/sql/spotify_host_connection_2026-10-27.sql`,
   Edge Function `spotify-host`). User decisions: tokens AES-256-GCM-encrypted
   in the Edge Function with the key in Edge secrets (app-level encryption,
   key outside the DB); one connection per host user, reused by all their
   arenas; the host picks a preferred device (transfer with `play:false`,
   which is also the Premium check — `GET /me` no longer returns `product`);
   a missing device only warns. Scopes: `user-read-playback-state`,
   `user-modify-playback-state`, `playlist-modify-private` (public and
   currently-playing dropped as unneeded). Disconnect deletes every stored
   Spotify datum. No arena pause / Start gating yet (warm-up still plays in
   the browser).
6. **Playback Provider abstraction** — **Done 2026-10-27.** `getStatus/play/queue/skip/onProgress`
   interface plus the Spotify implementation. Kept swappable per the docs'
   own licensing rationale, not an invented abstraction.
   Agreed for this step (user decisions 2026-10-27): the arena's playlist is
   created **at Start**, **private**, named "Music Fighter · <arena name> ·
   dd/mm/aa"; the **warm-up is its first track** and starts playing on the
   host's chosen device — so the warm-up is picked from Spotify search (the
   curated library's `spotify_track_id`s are placeholder UUIDs, not real
   Spotify ids) and the host must connect Spotify before creating an arena;
   `useArenaWarmup`'s browser MP3 is removed. Device lost / host disconnected
   → pause the arena (PRD §17), and Start requires a connected Premium host
   with an available device. Disconnecting must also clear any per-arena
   Spotify data added here (playlist ids).
   **Also in this step (user decision 2026-10-27): Spotify search for song
   proposals.** Today `search_songs` only searches the curated library; every
   proposed song must become a real Spotify track, like the warm-up. Guests
   don't connect Spotify, so the search runs server-side (Edge Function) with
   the arena host's token — same piece as the warm-up search; max 10 results
   per query (Feb 2026); results shown with artwork, Spotify logo and link
   back (Design Guidelines). Before building it, check the Developer Policy
   on using the host's token to serve searches to their guests.
   **Done 2026-10-27** (`supabase/sql/spotify_playback_2026-10-27.sql`,
   `supabase/functions/spotify-host/playback.ts`). Policy check: nothing in
   the Developer Policy/Terms forbids host-token catalog search for guests
   (catalog metadata isn't personal data, token never leaves the server,
   private non-commercial use); Spotify is moving away from Client
   Credentials for metadata, so the host token is the stable path. User
   decisions this step: warm-up = free Spotify search (no mood suggestions);
   pause = frozen battle clock, votes closed, proposals open, **automatic
   resume**; pause triggers (while music is expected) = no usable device for
   2 checks (~30 s, another of the host's devices is adopted), host paused
   Spotify, or playing outside the arena playlist; disconnect = immediate
   pause; battle 1 keeps the curated-library fallback (fake track ids) until
   steps 12/18. Step 18 must: extend `arena_playback.expected_until` to the
   winners, `queue` winners into the playlist (incl. both songs of a draw,
   A then B), re-add them in `ensureSession` when a reconnect recreates the
   playlist, and generalise `sync_arena_clock` (today it re-anchors only
   battle 1 on the warm-up's real Spotify progress) to the winner playing
   during each battle. Fixes after the user's test (2026-10-27): battle
   cards show Spotify artwork + "Open Spotify"; the battle timer freezes
   while paused and follows the song (`spotify_clock_sync_2026-10-27.sql`);
   search/track calls don't send `market=from_token` (needs
   `user-read-private`).
7. **TO BE REDEFINED (2026-10-27)** — was "Participant Spotify OAuth".
   Participants no longer connect Spotify *for affinity/passive voting*.
   Since step 5 any user can connect Spotify from Profile, but only to host
   their own arenas. **New use requested by the user 2026-10-27 (not built):**
   a guest who has connected their own Spotify can use it **in someone else's
   arena only to propose songs** — picking from their own playlists and
   searching with their own account (falling back to the host's token, step
   6, when they aren't connected). Never for taste profiling, affinity or
   passive votes (policy III.13). Needs `playlist-read-private` (re-consent)
   and each user in the dashboard's User Management while in dev mode (5
   users max). **Built in this step 7** (user decision 2026-10-27), after
   step 6's host-token search exists.
   **Done 2026-10-27** (Edge Function `spotify-host` only, no SQL). User
   decisions: "My playlists" = Liked Songs + owned/collaborative playlists
   (Feb 2026: only those can be opened; adds `user-library-read` besides
   `playlist-read-private`); search with the guest's own account by default,
   silent fallback to the host's, plus a visible "My Spotify / Host's
   Spotify" switch; soft re-consent (old connections keep working, Profile
   and "My playlists" offer "Reconnect Spotify"). Policy check: reading the
   user's own playlists to show them back to that user only is within
   Developer Terms V.4 ("displaying it back to the user"); minimum scopes
   (I.1.1/V.3); nothing stored (IV.3.1); not used for profiling (III.13).
   The "1 proposal per user per battle" cap is still step 12. Verified
   in-app by the user 2026-10-27; search and modal no longer reset after
   proposing (user request).
7b. **Optional Music Fighter accounts** (new, user decision 2026-10-27;
   prerequisite of 8). Entering an arena stays anonymous; anyone who wants a
   persistent profile signs in (email magic link or Google) and Supabase
   links the identity to the existing anonymous user, so `auth.uid()` and the
   history are kept. Needs a privacy policy + consent + account deletion (a
   taste profile is personal data). The anonymous session is per origin/device,
   so without an account the profile is per browser.
   **Built 2026-10-27** (`supabase/sql/accounts_2026-10-27.sql`, spotify-host
   `merge_anonymous`/`delete_account`, Profile "Your account", `/privacy`).
   User decisions: email + 6-digit code only (Google later); signing into an
   existing account from an anonymous device **merges** that device's data
   into the account; privacy contact email pending from the user. Pending
   owner config: Auth URL/OTP/templates and custom SMTP (Gmail app password
   recommended, or Brevo).
8. **Own affinity profile — BUILT 2026-10-27 together with step 9** (`supabase/sql/affinity_passive_vote_2026-10-27.sql`, Edge Function `musicbrainz-enrich`; details in CLAUDE.md "Own affinity & passive vote"). Build decisions 2026-10-27: account signals persist until account deletion with a 1-year half-life; anonymous guests get an in-arena-only profile (purged with the votes, merged into an account if they sign in) and keep proposing through the host's Spotify without connecting their own; ISRC→MusicBrainz in its own Edge Function + per-minute cron at ≤ 1 req/s; k=1.25 kept as decided (configurable), Paso_1 §8 "never reverse a clear win" not adopted.
   Original definition:
   (user decision: no code in the step-8 chat; "define 8, build with 9").
   Replaces "Participant affinity profile sync" (Spotify top tracks/genres/
   audio features). User decisions 2026-10-27:
   - **Persistent per-user profile in a Music Fighter account** (Shazam-like:
     MF's own catalog identity and own signals), not per arena.
   - **Signals: only what the user does in MF** — explicit votes, active
     proposals and likes (`song_likes`, to be reconnected as a manual "like"
     signal). Never Spotify listening data (top items, saved tracks,
     playlists read in step 7, plays/skips).
   - **Spotify ↔ MF bridge = ISRC.** Spotify is used only for catalog search
     and playback; the track's ISRC (`external_ids`, removed Feb 2026,
     restored Mar 2026) maps it to MusicBrainz (recording/artist MBIDs, CC0).
     Song features come from **open datasets** keyed by ISRC/MBID
     (MusicBrainz relations/tags, AcousticBrainz, MSD, FMA, Last.fm — see
     `MLM/Datasets_IA.pdf`), never from Spotify metadata. The profile and any
     model never see Spotify names/ids/artwork (Developer Policy III.13 no
     user profiling from Spotify Content, III.14 no ML on Spotify Content).
     Documented grey zone: the ISRC itself is read from a Spotify response;
     confirm with Spotify/legal before any growth beyond private use.
   - **Engine: v0 rules first, own model later.** v0 = explainable score
     (same artist / MusicBrainz-related artists / open tags overlap with what
     the user voted, proposed, liked), works with few users; an own model
     (pre-trained on open datasets with decaying influence, then MF data, per
     `Datasets_IA.pdf`) only when MF has enough data. The old
     `Affinity_Music_Model_Feature_Set_v1.csv` / `setup_spotify_ml.ps1`
     (Spotify audio features, skips, device, location) are obsolete.
   - Known limits: AcousticBrainz stopped collecting in 2022 and MSD ends in
     2011 (recent songs have no audio features → fall back to artist/tags);
     MusicBrainz tags and Last.fm/MSD are non-commercial/research licences
     (fine while payments are excluded, a blocker for monetisation);
     MusicBrainz API is 1 req/s (cache per ISRC).
   - **Open for the build (ask then):** profile retention vs the 30-day vote
     purge (the profile must aggregate signals before votes are purged);
     whether a guest without an account gets an in-arena-only profile;
     where the ISRC→MBID lookup runs (Edge Function + cache table);
     check the affinity rules with Sergio (CLAUDE.md), together with step 9's
     k=1.25 and "≥75 % pasivos vs inactivos".
9. **BUILT 2026-10-27 together with step 8** (rules below, score = step 8's v0).
   Superseded note: the Spotify-similarity formula below
   is superseded by step 8's own-data score (built together with it); the
   rest (lock-in snapshot, no-row rule) still stands.
   **Passive voting engine** — the affinity-similarity formula, k=1.25 cap,
   30-second freeze/ramp, zero during Sudden Death. Depends on #4 and #8.
   Only participants with no `votes` row for the battle get a passive vote:
   voting and then cancelling means abstaining, not "didn't vote"
   (user decision, 2026-10-26).
   **Rules decided by the user 2026-10-27** (resolve the doc conflicts that
   CLAUDE.md said to check with Sergio; build together with step 8):
   - Eligible: **PASIVO** in the lock-in `battle_presence_snapshots`, no
     `votes` row, and enough own-data signals (account → persistent step-8
     profile; anonymous → what they did in that arena). No signals = no vote.
     INACTIVO never gets one.
   - Value: only if affinity score ≥ 0.7; **scaled linearly** 0.4 PB at 0.7 →
     0.5 PB at 1.0; when **≥75 % of present users are PASIVOS** (v4 wording,
     not "inactivos") the base rises: 0.5 at 0.7 → 0.6 at 1.0.
   - Timing: frozen until the final 30 s, ramps linearly over them (visible
     on the tension bar), the value at lock-in is what counts; **0 during
     Sudden Death**.
   - Cap: PB_passive_total ≤ **1.25 × PB_active_total**; **with 0 active votes
     the cap doesn't apply** (passive votes decide instead of a forced tie).
10. **EXCLUDED FOR NOW (2026-10-27).** **Jukebox Boost mechanic** — the vote behavior only (1 purchase per battle,
    non-cancelable, counts as 1.0 PB). Apply the shared anti-abuse boundary
    (engineering addition #3) here.
11. **EXCLUDED FOR NOW (2026-10-27)**, with all payments. **Jukebox Boost
    payment integration** — *deferred*, not scheduled; waits
    for its own planning session (user-confirmed). When it is scheduled, the
    App Store/Play Store compliance boundary (engineering addition #1) and
    server-side receipt verification (addition #5) apply directly to this item
    — decide web/PWA vs. native distribution before building it, since that
    choice determines which payment path is even legal to use.
12. **Queue rule enforcement** — explicit `active_10`/`waiting_50` caps, FIFO
    within waiting, 60-minute no-repeat, 20-battle purge, human>system
    priority.
    User decision 2026-10-26: a user may keep **several** songs in their
    queue list, but each battle takes **at most 1 per proposer** ("1 active
    proposal per user per battle"). Today `pull_next_battle_songs` takes the
    top 2 regardless of proposer, so one user's two songs can face each other
    (confirmed by rollback test) — fix here; also decide what fills slot B
    when only one user has proposals.
    **Done 2026-10-27** (`supabase/sql/queue_rules_2026-10-27.sql`, details in
    CLAUDE.md). User decisions: slot B chain = another proposer → the same
    proposer's next song → a previous loser of the arena ("revancha") →
    curated library (last resort until #13); order = turns per person (FIFO
    within a turn, the next 10 never demote); max 5 queued per person;
    "Your proposals" = queue state/place + history + withdraw. Spec as
    written: 10 + 50, "full" notice, purge after 20 battles waiting, no song
    within 60 min of sounding (winners, draw A+B, warm-up).
    **12b, same day (user decisions):** curated library retired from Music
    Fighter (test data only). After the revancha the chain continues with the
    host's backup music chosen at creation (Liked Songs or one of their own
    playlists), then catalog search by the arena's artists / the warm-up's
    artist (host token), then purged/withdrawn proposals; if still nothing the
    arena waits ("Waiting for songs") and the next battle is created as soon
    as a pair exists. Spotify radio/autoplay rejected: no API to start it,
    recommendations and Spotify's algorithmic playlists closed to new apps,
    and autoplay plays outside the arena playlist (`off_playlist`). Low-queue
    notice at < 4 human proposals.
13. **TO BE REDEFINED (2026-10-27)** — sources change: own-data affinity
    instead of Spotify, and no venue history (private gatherings). Candidate
    source proposed by the user 2026-10-27 (step-12 chat): fill empty slots
    with a song from the **host's or a user's Spotify Liked Songs** that fits
    the arena (mood/style of the songs playing or proposed) — only with the
    library owner's explicit consent (step-7 decision: a guest's library is
    otherwise only for their own proposals), matching computed from MF's own
    data (step 8), not Spotify metadata (III.13/III.14; no audio features),
    and pre-fetched by `spotify-host` (the battle cycle is SQL). The host's
    part of this (their chosen Liked Songs/playlist, no matching) was built in
    step 12b; what remains here is matching and guests' libraries. Original:
    **Passive/system auto-proposal generation** — sourced from aggregate
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
    real, populated queue) to select from. Its Spotify inputs (popularity,
    BPM/energy) are no longer available (see §F); needs another source.
18. **Real playback wiring end-to-end** — winner auto-plays, battle starts when
    the previous winner starts, synced timers, playlist auto-append (winners
    appended to the arena's private playlist after the warm-up; no
    crossfade/mixing, policy III.7). Depends
    on #6 and #17 — this is where "what wins, plays" actually becomes true.
    **Built 2026-10-28, ahead of #13 (user decision 2026-10-28)**
    (`supabase/sql/real_playback_2026-10-28.sql`, `spotify-host` `nudge`;
    details in CLAUDE.md "Real playback"). User decisions: winners appended
    when decided (lock-in; Sudden Death 10 s from lock-in, resolved at end − 5 s;
    draw A then B), pushed at once via pg_net; no pair → Spotify Autoplay may
    fill, a late battle lasts what is left of the playing song if ≥ 60 s
    (Autoplay tracks too), else 60 s, then MF plays the winner; manual changes
    inside the playlist are put back by MF and the host is asked whether to
    take manual control (then skips are followed, v4 §8.3, skipping past the
    end = immediate lock-in, anything else = off_playlist); pause/other
    playlist keep the step-6 pause; arena end lets the playlist play out.
    Matchmaking (#17) is not needed for this; #13 system songs enter through
    the same queue/`pull_next_battle_songs` path and stay compatible.
    In-app test 2026-10-28: winners appended < 1 s, Sudden Death + draws
    (A then B) and manual control OK. Found: a winner greyed out in the
    host's country made MF put it back in a loop. User decisions 2026-10-28:
    it counts as skipped (battle shortened by its length, last song = lock-in
    now, no pause/prompt) and songs are checked against the host's Spotify
    country when proposing (new `user-read-private` scope, soft re-consent):
    `supabase/sql/unplayable_tracks_2026-10-28.sql`. Still to test: a late
    battle over Autoplay, the unplayable skip.
    Later the same day (found in-app: relinked versions of songs, Autoplay
    radio reported as the playlist, a Sudden Death winner appended ~1 s
    before the end): relinked tracks are matched (ISRC, Spotify relinking,
    title/artist/length), Autoplay is told apart from hand-made changes, and
    user decisions: lock-in at end − 25 s, Sudden Death 15 s until end − 10 s,
    drift corrected from 1 s, and a radio track that started is never cut
    (it lengthens the battle, the winner follows it):
    `supabase/sql/radio_lead_in_2026-10-28.sql`. NowPlaying: instant answer,
    "Back to automatic" asks first. Radio lead-in follows the radio track
    really playing; Spotify's own song lengths replace the stored ones
    (`radio_follow_2026-10-28.sql`, `real_lengths_2026-10-28.sql`).
    **Verified in-app by the user 2026-10-28** (new timings, Sudden Death
    and draws, auto/manual control and its buttons, radio lead-in then the
    winner within ~0.4 s). Left to check when they happen (user decision
    2026-10-28): a late battle over Autoplay (never occurred yet), a song
    unplayable in the host's country skipped during an arena, and the greyed
    out search result (e.g. "Twice"); `real length` corrections in the
    spotify-host logs (none needed in the last test).
19. (Stage View is the party's shared screen, not a venue display, since
    2026-10-27.) **Stage View, remaining host flows, and UX/cross-platform conformance** —
    real-data Stage View, pause/resume Arena, excluded genres, initial-song
    selection, exact tension-bar/overlay timing, and the phone/tablet/desktop
    breakpoint QA gate (engineering addition #4). Depends on #18 for real data
    to display.
    **Technical cleanup (added 2026-10-28, user decision):** remove the
    phase-desync debug logging (`[BattleTimer Debug]`, `[DerivedPhase Debug]`,
    `[Realtime Debug]`, `[StageView Render]`, …, see `.lovable/plan.md`), drop
    the vestigial `identity_anchors` table and the no-op `useBattleEndedTrigger`
    stub (check nothing imports/references them first), and fix the 3
    pre-existing lint errors (empty interfaces in `src/components/ui/command.tsx`
    and `textarea.tsx`, `require()` in `tailwind.config.ts`).
20. **Pilot validation, hardening, closure** — the pilot (a private
    gathering since 2026-10-27, not a venue), fix-only
    hardening pass, GO/NO-GO/iterate/discard decision. Depends on everything
    above being functionally real first.
