#!/usr/bin/env python3
"""Exports one arena's aggregates, outside this public repo, before the 30-day purge.

  scripts/export_pilot_aggregates.py <ARENA_CODE> --label pilot-2

Reads the mf-restore-test copy, so take a fresh dump and restore it first
(docs/LOCAL_DB_COPY.md). It can't run against production: the replay needs
song_set_score, which the CLI's read-only role rightly can't execute. Keep it so.

The file goes to ~/projects/music-fighter-docs/pilots/ and holds no people, ids,
nicknames or arena name. Nothing is written anywhere else.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys
from datetime import date

SQL = pathlib.Path(__file__).resolve().parent / "export_pilot_aggregates.sql"
OUT_DIR = pathlib.Path.home() / "projects" / "music-fighter-docs" / "pilots"
PSQL = ["docker", "exec", "-i", "-u", "postgres", "mf-restore-test",
        "psql", "-U", "postgres", "-d", "postgres", "-At", "-v", "ON_ERROR_STOP=1"]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("arena_code")
    ap.add_argument("--label", required=True, help="file name prefix, e.g. pilot-2")
    args = ap.parse_args()

    code = args.arena_code.upper()
    if not re.fullmatch(r"[0-9A-F]{6}", code):
        sys.exit("arena code: 6 hex characters")
    if not re.fullmatch(r"[a-z0-9-]{1,40}", args.label):
        sys.exit("label: lowercase letters, digits and dashes")

    sql = SQL.read_text().replace("__ARENA_CODE__", code)
    r = subprocess.run(PSQL, input=sql, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"psql failed: {r.stderr[:2000]}")
    data = json.loads(r.stdout) if r.stdout.strip() else None
    if not data or not data.get("battles"):
        sys.exit("no such arena, or no battles")
    if data.get("purged"):
        sys.exit("this arena's votes were already purged: the export would be wrong, nothing written")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = OUT_DIR / f"{args.label}-aggregate-{date.today().isoformat()}.json"
    path.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    path.chmod(0o600)

    check = data["passive_replay_check"]
    print(path)
    print(f"battles {len(data['battles'])}, passive replay {check['replayed']} vs real {check['real']}")
    if check["replayed"] != check["real"]:
        print("WARNING: the replay doesn't match the real passive votes; don't trust the funnel or the grid")


if __name__ == "__main__":
    main()
