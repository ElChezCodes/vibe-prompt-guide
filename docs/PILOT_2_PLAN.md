# Pilot 2 plan

**Goal:** a party where everyone has enough own-affinity signals, so the data can
inform the collective mind, which is designed **after** this pilot and not here.

Numbers come from `scripts/export_pilot_aggregates.py` on a restored copy of the
database. Anything marked *inference* is a reading of those numbers, not a measurement.

## 1. What pilot 1 shows

### Passive votes: signals are necessary, not sufficient
The rule (`passive_vote_config`, live): at least `min_signals` = 3 **distinct songs**
(ISRCs), then a score of at least `min_score` = 0.7 for one of the two songs, no tie.

- **Correction to the checkpoint:** 4 of 9 people reached 3 songs, not 3. All four cast
  passive votes (72 in total), but the fourth got there with 5 battles left.
- **Late:** nobody had 3 songs before battle 1. Two got there within an hour of joining,
  two after about 3 hours. No song was proposed in the lobby.
- **The other five:** 3 people did nothing that signals, 2 stopped at 2 songs.
- **What counts:** a proposal or duplicate at once, a like at once, an explicit vote when
  its battle ends. A list vote counts only as that vote. Passive votes never count.
- **Anonymous users:** all 9 were anonymous. They score only with signals from the same
  arena, so ending an arena and opening another resets everyone. It cost nothing in
  pilot 1 (one song among all nine), but it rules out a two-arena party.
- **Likes:** 0 in the whole pilot, although they work without Spotify and take one tap.

Every person in every battle, without an explicit vote (replay at each lock-in; it
reproduces the real 72 passive votes exactly):

| Outcome | Rows | Share |
|---|---:|---:|
| Under 3 songs | 391 | 61.2 % |
| 3+ songs, score under 0.7 | 168 | 26.3 % |
| Tie | 8 | 1.3 % |
| Passive vote | 72 | 11.3 % |

With 3+ songs, a person gets a passive vote in only 29 % of battles, rising with
their song count:

| Songs when the battle locks | Rows | Passive votes | Rate | People |
|---|---:|---:|---:|---:|
| 3-5 | 120 | 17 | 14 % | 4 |
| 6-13 | 85 | 33 | 39 % | 2 |
| 14+ | 43 | 22 | 51 % | 1 |

*Inference:* the same few people sit in each row, so this is a hint, not a law.

**Why so low:** among people with 3+ songs, every score of 0.7 or more was 0.9 (same
artist) or 1.0 (same song). No score came from a related artist (0.75) or from genres
(cap 0.85), so a passive vote today means "you already touched this artist".
MusicBrainz isn't the limit: 88 of the 93 songs that fought were found.

**The thresholds aren't the lever:** replaying the rule with other numbers barely
moves it, so they stay frozen for this pilot.

| `min_signals` | `min_score` | Passive votes | Battles |
|---:|---:|---:|---:|
| 3 | 0.7 (real) | 72 | 55 |
| 3 | 0.5 | 78 | 55 |
| 1 | 0.7 | 81 | 60 |
| 1 | 0.5 | 87 | 60 |

### Could passive votes be trusted?
Unknown: the sample is too small. Where a person voted by hand and the rule would also
have picked a song, it agreed on 7 of 9 when a song was already in their signals, and
on 0 of 8 when neither was, from 2 people. Measuring this properly is the main
reason to run pilot 2.

### 94 system vs system battles
Simple arithmetic: 115 battles have 230 song slots, and only 23 songs were proposed,
so humans filled 10 % of them. The queue was almost always empty: the median wait from
proposal to battle was 5.2 minutes, and 13 of the 23 songs came in two single hours.
The rest of the time the arena ran on the host's source, as designed (0 waits for songs).

### 1.15 people present at lock-in
That number measures **awake screens, not people**. ACTIVO or PASIVO needs an action in
5 minutes or a heartbeat in 10, and a locked phone sends none. The snapshot held 6.73
people on average, 82.9 % of them INACTIVO; 38 battles had nobody ACTIVO or PASIVO.
It peaked at 2.7 in the busiest hour, the one with the most proposals and votes. The arena also ran 12.5 h,
well past any collective attention. *Inference:* a shorter party with a reason to
look at the phone moves this; a wake lock wouldn't add data worth the battery.

This doesn't limit passive votes: they also reach people whose phone is simply locked.

### Reading pilot 1 against pilot 2
Rules changed after pilot 1, so these comparisons aren't like for like:
- **Sudden Death:** of the 37, 32 had no active vote and would now be resolved by fit
  with no Sudden Death (step 20), which leaves 5.
- **Explicit votes:** now include pre-assigned ones. List and QR votes didn't exist.

## 2. The party

**Format:** one arena, 2.5 h of battles, about 25 battles (353 s each on average), for
**12 people joined**, 8 at the very least. One person plays **MC** with this script, ideally
not the host, who has the music to look after.

*Inference on the numbers:* 25 battles have 50 slots. 12 people × 3 songs in the lobby
fill the first 18 battles, and 2 more each at the one-hour mark cover the rest.

| When | Who | What |
|---|---|---|
| 2 days before | Organiser | Message guests: bring a charged phone, think of 5 songs by different artists. No app, no Spotify, no account. Include the privacy note (section 5). |
| 1 day before | Organiser | Publish → Update in Lovable. Dry run with 2 phones. Add any Spotify users to the dashboard (below). No SQL changes from now on. |
| T−45 min | Host | Connect Spotify, create the arena (warm-up), open the Stage View on the TV. Check that the big join QR scans from across the room. |
| T−45 to T | Each guest | Scan the TV with the phone's **camera**, join, propose **3 songs by 3 different artists**. MC walks the room until everyone has done it. |
| T | Host | Start battles once about 70 % have joined and 20+ songs are queued. |
| T to T+60 | Everyone | Vote every battle, on the phone or by QR. MC names the moment: "new battle, vote". Tap the heart on anything you like. |
| T+60 | MC | "Everyone: 2 more songs, and use your 3 votes in Next up." |
| T+60 to T+150 | Everyone | Free play. MC refills when "The queue is running low" appears. |
| T+150 | Host | **End Arena**, final ranking on the TV. Don't leave it running. |
| Closing | MC | Offer an account to whoever wants to keep their profile (Profile, email + code): same browser, signals kept. Optional and no effect on the results. |
| Next day | Organiser | Two questions, by voice or chat: did the automatic vote sound like you? did you notice it? Keep only the totals. |
| Within 7 days | Coordinator | Export (section 4). |

**Rules for the day**
- **One arena only**, for the reason above. If the host's phone fails, resume the same arena.
- **One browser per person:** a QR opened by a scanner app or an in-app view makes a new
  anonymous person with no signals. Say "use the camera", and watch `people` against
  the head count.
- **Nothing risky on production** from the day before, and no SQL during the party.

**Spotify's 5 slots.** Guests need none: search goes through the host's account. The
dashboard lists 2 users, the same 2 accounts behind the 5 stored connections, so about
3 are free (to confirm: whether the app's owner takes one).
1. Host: an existing slot, must be Premium.
2. Backup host: the second existing account, if it's Premium.
3. Up to 3 guests with big libraries, to lend their Liked Songs. It improves the songs the
   system picks but adds no signals, so skip it if it's a hassle. Add them a day before.
4. Tell everyone else **not to press Connect Spotify**: it fails with
   `spotify_user_not_allowed` and looks like a bug.

## 3. Minimal changes

**User decision, 2026-11-07: none.** The app stays as it is and the organiser explains the
goal aloud. The list below is kept as options for later.

Nothing is required to run the party: everything below only makes the script land.

| # | Priority | Change | Where | SQL | Effort |
|---|---|---|---|---|---|
| 1 | **Do** | Tell guests what to do while waiting: "Propose 3 songs by different artists" | `src/screens/BattleRoomScreen.tsx` waiting card (446-457), `StageLobby` in `src/screens/StageViewScreen.tsx` (202) | No | 30 min |
| 2 | **Should** | Show each guest their progress ("Your taste: 2 of 3 songs"), only to them | New read-only RPC `get_my_taste_progress(p_arena_id)`, counting songs as `affinity_score` does and reading `min_signals`; new wrapper in `src/integrations/supabase/`, a hook, a chip beside `PresenceChip` in `BattleRoomScreen.tsx` (491) | Yes, one read-only function | 2 h |
| 3 | Optional | Count of people with 3+ songs on the Stage View lobby | `get_stage_view`, `StageLobby` | Yes | 1 h |
| 4 | Optional | Record how a vote was cast (tap, QR, like), to measure QR use | New `votes` column, `fill_vote_fields`, `voteFromQr` and `applyVoteIntent` in `src/integrations/supabase/votes.ts` | Yes, on the vote path | 2 h + tests |

Changes 1-3 touch screens the visual fork owns, so they need a file split. Change 4 touches the
vote path right before a pilot; without it, QR use is seen only through the Next day
questions. Recommended: 1 and 2.

**Deliberately not changed:** `min_signals`, `min_score`, weights, matchmaking, presence.
Frozen rules are what make pilot 2 comparable, and the grid above shows they aren't the lever.

## 4. What to measure

All of it comes from one export, per arena:

1. Take a dump and restore it (`docs/LOCAL_DB_COPY.md`), replacing the copy.
2. `scripts/export_pilot_aggregates.py <ARENA_CODE> --label pilot-2`
3. It must print `passive replay N vs real N` with the same number twice.
4. Delete the dump when finished, and in any case within the 30 days.

It writes to `~/projects/music-fighter-docs/pilots/`, outside this repo. Run it **within
7 days** to keep the playback event counts; everything else lasts 30. It needs the copy
because the replay calls `song_set_score`, which the CLI's read-only role can't run.
Tested on pilot 1: all 115 battles and matchmaking rows match the original aggregate
field by field, and so do the people distributions, which only add a row for people with
0 songs. `explicit_a/b` keep pilot 1's meaning; `final_a/b` are the deciding tally.

Keys below are in that JSON. `no_explicit` means a person in a battle's snapshot, not
gone, with no explicit vote.

**Success: the signals (the point of this pilot)**

| Metric | Definition (export key) | Pilot 1 | Target |
|---|---|---:|---:|
| Reached 3 songs | 1 − `time_to_three_songs.never` / `summary.people` | 44 % | ≥ 80 % |
| Ready before battle 1 | `time_to_three_songs.before_battles` / `summary.people` | 0 % | ≥ 60 % |
| Reached 6 songs | `people_by_songs_signalled` with songs ≥ 6 / people | 22 % | ≥ 50 % |
| Lacking signals | `passive_funnel.under_min_signals` / all funnel rows | 61 % | ≤ 20 % |

**Success: enough data for the collective mind**

| Metric | Definition (export key) | Pilot 1 | Target |
|---|---|---:|---:|
| Comparable votes | sum of `passive_agreement[].n` | 17 | ≥ 60 |
| On songs not in the voter's signals | `n` where `known_song` is false | 8 | ≥ 20, from ≥ 6 people* |
| Battles with an explicit vote | `summary.battles_with_explicit` / battles | 30 % | ≥ 60 % |
| Battles with any vote | `summary.battles_with_any_vote` / battles | 72 % | ≥ 90 % |
| People who voted by hand | 1 − `people_by_explicit_votes` bucket 0 / people | 44 % | ≥ 75 % |

\* The export doesn't count those people, on purpose. Check it once on the copy within
the 30 days and keep only the number.

**Context: reported, no target that decides anything**

| Metric | Export key | Pilot 1 | Expected |
|---|---|---:|---:|
| System vs system | `summary.battles_system_vs_system` / battles | 82 % | ≤ 30 % |
| Songs proposed in the lobby | `summary.lobby_proposals` | 0 | ≥ 24 |
| Likes | `likes.total` | 0 | > 0 |
| Present at lock-in | `summary.present_avg` | 1.15 | ≥ 3 |
| Agreement, unknown songs | `passive_agreement` `agree / n` | 0 of 8 | no target |
| Passive rate by songs | `passive_by_signal_size` | 14-51 % | no target |
| Scores reached | `passive_score_levels` | only 0.9, 1.0 | no target |
| Rule alternatives | `passive_rule_grid` | see above | no target |
| List and duplicate votes | `backings`, `summary.preassigned_votes_kept` | none | no target |
| Playback trouble | `playback_events` (7 days) | not recorded | few |

Agreement has no target because it's the finding, not a pass mark: a low number is as
useful as a high one, if the sample is large enough.

**Verdict**
- **Ready to design the collective mind:** all four signal targets and the comparable
  votes target are met.
- **Partly:** signals met but under 60 comparable votes: design what the data
  supports and say what stays unproven.
- **Repeat:** under 60 % reach 3 songs, or a technical failure ruins the party. Fix the
  cause before anything else.

**Main risk (*inference*):** today's passive votes rely on same-artist matches, and some
system songs were found through artists already in the arena. With more human songs
by different artists, overlap may fall, and the 29 % with it, even though more people have
signals. That wouldn't be a failed pilot: it would show the genre path, which reached 0.7
zero times, is the gap to address.

## 5. Privacy

**Allowed by the current policy (version 2026-10-28), no change needed**
- Everything in the export. It's aggregate, stored outside the repo, and the policy keeps
  battle totals. Song titles aren't personal data, though among friends a title can hint at
  who chose it, which is one more reason for keeping the file private.
- Analysis of individual rows **inside** the 30 days, on the restored copy, as long as the
  copy is deleted when the window ends. The policy covers storing them for that long.

**Needs a notice before the party, no policy change**
- Tell guests it's a test and that the organisers will look at how the group voted. It's
  a courtesy among friends, not a legal step: nothing new is collected.

**Would need a policy change first, and people told before the party**
- **Per-person sequences kept beyond 30 days**, even anonymised. `/privacy` says
  "Individual votes are deleted 30 days after an arena ends". It would need new
  text and a version bump (`PrivacyScreen.tsx`, `PRIVACY_POLICY_VERSION` in `account.ts`), and
  guests can't be asked individually without an account. With 12 friends, removing ids
  doesn't anonymise anyone.
- Anything that adds a data source, such as Spotify data for taste (never: policy III.13).

**Sequences (user decision, 2026-11-07).** `/privacy` doesn't change.
- **Pilot 1:** aggregates only, as already saved. Its individual votes are purged as promised.
- **Pilot 2:** before playing, each guest accepts in writing that their data is kept for
  the pilot. Only those guests' per-person sequences are kept, outside this repo. Anyone
  who doesn't accept plays normally and counts only in the aggregates.

**Before the party:** write the one-page consent (what is kept, why, for how long, how to
ask for deletion at musicfighterapp@gmail.com) and its form, which records the guest's
nickname in the arena, the only link to the data. Then add a per-person export that
reads those nicknames. Neither exists yet, and signed forms never enter this repo.

**Deadlines**
- Pilot 2's clock starts when its arena ends; the export is due in 7 days, the copy gone by 30.
- Pilot 1's purge, the 2026-11-06 dump and the restored copy holding it: 2026-12-01.
