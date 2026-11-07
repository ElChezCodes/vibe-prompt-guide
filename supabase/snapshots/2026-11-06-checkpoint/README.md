# Live database snapshot, 2026-11-06 checkpoint

What lives only in the Supabase project, copied so a mistake can be undone:
every Claude fork shares one production database. Generated with catalog
queries (`supabase db dump` needs Docker, which wasn't reachable from WSL).

| File | Contents | Count |
|---|---|---|
| `01_types.sql` | Composite types | 1 |
| `02_tables.sql` | Tables, defaults, RLS on | 36 |
| `03_constraints_indexes.sql` | Constraints, foreign keys, indexes | 151 |
| `04_views.sql` | Views | 2 |
| `05_functions.sql` | Functions | 148 |
| `06_triggers.sql` | Triggers on `public` | 23 |
| `07_policies.sql` | RLS policies | 28 |
| `08_grants.sql` | Table and function grants | 60 + 148 |
| `09_rule_numbers.sql` | `passive_vote_config`, `matchmaking_config`, `pi_config`, `system_song_config` | 4 rows |
| `10_cron.sql` | pg_cron jobs | 6 |

**Not included, on purpose:** user data and secrets. This repo is public: never
commit a data dump here. Tokens stay in Edge secrets and Vault; their names are in
CLAUDE.md (`SPOTIFY_*`, Vault `spotify_watch_secret`). Dashboard settings (Auth
URLs, OTP, templates, SMTP) aren't in the database either.

**Verified:** counts match the live catalog; no JWTs, tokens or personal emails;
`05_functions.sql` loaded whole inside a transaction that rolled back, with the
functions' fingerprint unchanged and no cron failures. The deployed Edge Functions
were identical to `supabase/functions/` on the same day. **Not verified:** a full
restore into an empty database (tables, triggers and policies weren't run:
that would lock live tables). Docker + a local Supabase would allow it.

**To undo one function:** copy its definition from `05_functions.sql` into a new
file in `supabase/sql/`, apply it and verify as usual. To restore everything, in
order: extensions, then files 01 to 10.
