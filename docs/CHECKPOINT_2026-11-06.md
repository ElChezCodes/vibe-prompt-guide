# Project checkpoint, 2026-11-06

**State:** the engine works and pilot 1 was a **GO**. Baseline for what follows:
`main` at this document's commit, plus `supabase/snapshots/2026-11-06-checkpoint/`.

## What exists
Real-time arenas, song battles on the host's Spotify playlist, matchmaking, passive
votes, PI and leaderboards, Stage View, optional email accounts (custom Gmail SMTP
tested 2026-11-06). New on 2026-11-06: votes from the Next up list, QR votes on the
Stage View, Spotify's full logo as the link back, the new Home notes. Details:
CLAUDE.md. History: `docs/MVP_ROADMAP_2026-10-26.md`, step 20.

## Pilot 1 in numbers (2026-10-31, 12.5 h)
- 115 battles, 0 waits for songs; ~30 people, 9 joined.
- 4 of 9 ever voted (2 cast 11+ votes); explicit votes in 35/115 battles; 32 with no
  vote at all, not even passive; 37 Sudden Deaths, all 0-0.
- 5 people proposed 23 songs, one of them 14. 94/115 battles were system vs system.
- Passive votes need 3 songs with signals: only 3 of 9 reached it.
- At lock-in, 1.15 people on average were ACTIVO or PASIVO (max 5).
- Aggregates by battle, on the user's PC, not in this public repo:
  `~/projects/music-fighter-docs/pilots/pilot-1-2026-10-31-aggregate.json`.

## Dates
- **2026-12-01 14:00 UTC:** pilot 1's individual votes are purged (30 days,
  promised in `/privacy`), and its `matchmaking_log` around then. Battle totals stay.
  Anonymous per-person sequences weren't exported: that would go beyond the policy's
  wording, so it needs the user's decision before that date.
- Same 30-day clock for pilot 2: export aggregates within it.

## To test (Publish → Update in Lovable first)
None of this has been tested on real phones yet; the QR vote is the main risk.
- **Stage View:** no name + mood line, no "Scan to vote"; white Spotify logo links to
  the song on cards, Now Playing, Next up; Now Playing has its QR; fits a real TV.
- **Battle Room:** the card's logo opens the song without voting; cards stay level;
  a tap enlarges Now Playing's QR and another phone can scan it.
- **List votes:** 3 votes then the button disables; removing one gives it back; own
  song shows 1 vote + "Your pick", no button; duplicates still work with 0 left; the
  most voted rises to the next battle; a voted system song goes first among system
  songs.
- **In battle:** "Your pre-assigned vote" can be changed; not cast if you left; the
  vote comes back when the battle starts; no PI for a list vote.
- **QR:** a new phone joins and votes; same QR doesn't cancel; the other QR switches;
  next battle with MF open keeps the same account (iPhone and Android); hidden at
  lock-in and pause, back in Sudden Death; an old QR doesn't vote; distance on a TV.
- **Home:** three notes left in blue, flagged note right in pink, leaning.

## Pending
- Spotify's 5-user limit (dev mode). It matters for pilot 2.
- Spotify brand review, before leaving dev mode: white logo vs green on a black
  patch; small green icons on navy (10 places); icons 12-14 px vs the 21 px minimum;
  logo as link back not confirmed by the guidelines.
- Security, low priority: **this repo is public**, worth weighing private. `anon` and
  `authenticated` still hold TRUNCATE, TRIGGER, REFERENCES and MAINTAIN on tables
  (Supabase's defaults); PostgREST can't reach them, but revoking is cleaner.

## How we work from here
Claude forks work by area **inside this same repo**. Everyone shares `main`, one
production database, one Spotify app and one published Lovable app, so:
- A coordinator chat launches the forks, relays their questions and integrates.
- One fork at a time applies SQL. No two forks touch the same function or file;
  read live definitions, not old `.sql` files, and verify with rollback tests.
- Forks commit in their own worktree; the coordinator merges to `main` and pushes.
- Nothing risky on production during a real party or a live arena.
- No secrets in chats or commits; no user data in this repo.

**Areas:** (1) visuals with PixelLab, including the Home notes; (2) an organized
pilot 2 where people build more passive affinity, to get data. The **collective
mind** is designed only after pilot 2.
