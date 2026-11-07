# Local copy of the production database

To rehearse SQL before it touches production. Everything here is procedure: the
dumps hold people's data and **never enter this public repo**.

## Dump
Into a folder outside the repo (`umask 077`):

```sh
npx supabase db dump --remote --role-only -f roles.sql
npx supabase db dump --remote -f schema.sql
npx supabase db dump --remote --schema auth,storage -f schema_auth_storage.sql
npx supabase db dump --remote --data-only --use-copy -f data.sql
```

Takes about 5 minutes and only reads. Do it with no arena running.

## Restore
`scripts/restore_local_copy.sh <dump_dir>` builds the `mf-restore-test` container,
in about 20 s. One error in `schema_auth_storage` is expected: a storage policy that
needs a public function, which the script applies at the end.

- **No network** (`--network none`): `pg_net` and cron can't reach production. Keep it so.
- **Cron jobs** are loaded but disabled, from the checkpoint snapshot.
- **It only runs in this container.** The script drops the image's default privileges
  before loading. Without that, `anon` gets EXECUTE on 209 internal functions
  that production denies, because a dump only revokes relative to Postgres's defaults.
  **Never restore into production without solving this**, and compare the ACLs after.

## Verified on 2026-11-06
Against production, item by item: 148 functions, 2 views, 371 columns, 120 constraints,
72 indexes, 28 policies, 23 triggers, RLS on 36 tables, 726 table and 409 function
privileges: 0 differences. 69 tables with 70,867 rows: identical.
`auth.schema_migrations` and `storage.migrations` are left out by the dump.
Smoke test as `authenticated`: the view reads, a client insert into `battles` is refused.

## What a dump doesn't hold
- Vault secrets (`spotify_watch_secret`) and Edge secrets: in Supabase only.
- Files in Storage: only their rows, not the objects.
- Cron jobs: in `supabase/snapshots/2026-11-06-checkpoint/10_cron.sql`.
- Auth settings and email templates: dashboard. Edge Functions: this repo.

## Retention
A dump with individual votes falls under `/privacy`: delete or replace it before
those votes' 30 days end. The 2026-11-06 dump must be gone before **2026-12-01**.
