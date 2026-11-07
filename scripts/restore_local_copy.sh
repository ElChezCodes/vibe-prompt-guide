#!/usr/bin/env bash
# Restores a production dump into a throwaway local Postgres, to rehearse SQL.
# No data here: the dump lives outside this public repo. See docs/LOCAL_DB_COPY.md.
#   scripts/restore_local_copy.sh <dump_dir>
# The container has NO network, so pg_net and cron can never reach production.
# Open a shell with:
#   docker exec -it mf-restore-test bash -c \
#     'PGPASSWORD=$POSTGRES_PASSWORD psql -h 127.0.0.1 -U supabase_admin -d postgres'
set -euo pipefail
DUMP="${1:?dump dir}"; NAME=mf-restore-test
IMAGE=public.ecr.aws/supabase/postgres:17.6.1.071
SNAP="$(cd "$(dirname "$0")/.." && pwd)/supabase/snapshots/2026-11-06-checkpoint"
LOGS="$DUMP/restore-logs"; umask 077; mkdir -p "$LOGS"
psql_c() { docker exec -i "$NAME" bash -c \
  "PGPASSWORD=\$POSTGRES_PASSWORD psql -h 127.0.0.1 -U supabase_admin -d postgres -q -v ON_ERROR_STOP=$1"; }

docker rm -f "$NAME" >/dev/null 2>&1 || true
PW=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
docker run -d --name "$NAME" --network none -e POSTGRES_PASSWORD="$PW" "$IMAGE" >/dev/null
for _ in $(seq 1 90); do
  echo 'select 1' | psql_c 1 >/dev/null 2>&1 && break; sleep 2
done

# The image grants new objects in public to anon/authenticated by default, and a
# dump only revokes relative to Postgres's own default: restored as it comes, anon
# would get EXECUTE on internal functions production denies. Drop those defaults
# first; schema.sql re-creates production's own at its end.
psql_c 1 >/dev/null <<'SQL'
drop schema if exists auth cascade;
drop schema if exists storage cascade;
do $$
declare r text; t text; o text;
begin
  foreach r in array array['postgres','supabase_admin'] loop
    foreach o in array array['tables','functions','sequences'] loop
      foreach t in array array['postgres','anon','authenticated','service_role'] loop
        execute format('alter default privileges for role %I in schema public revoke all on %s from %I', r, o, t);
      end loop;
    end loop;
  end loop;
end $$;
SQL

for f in roles schema_auth_storage schema data; do
  psql_c 0 < "$DUMP/$f.sql" > "$LOGS/$f.log" 2>&1
  echo "$f: $(grep -c ERROR "$LOGS/$f.log" || true) errors"
done

# A storage policy needs a public function, which loads after it.
python3 - "$DUMP/schema_auth_storage.sql" <<'PY' | psql_c 1
import re, sys
for m in re.finditer(r'CREATE POLICY[^;]*can_read_warmup_audio[^;]*;', open(sys.argv[1]).read()):
    print(m.group(0))
PY

# Jobs exist for inspection but never run.
{ echo 'begin;'; cat "$SNAP/10_cron.sql"; echo 'update cron.job set active = false; commit;'; } | psql_c 1 >/dev/null
echo restored
