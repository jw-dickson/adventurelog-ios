# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Copies a SQLite store into another store, usually Postgres (#20):

    python -m companion.migrate /data/companion.sqlite postgresql://user:pass@host:5432/companion

Stop the companion first. Rows already in the target are left as they are, so running it twice is
harmless. Phones would register again by themselves, but photo matches, the record of each sidecar
written (which undo needs) and what the flight-status provider billed would start over without it.
"""

from __future__ import annotations

import sqlite3
import sys

from .store import Store

# Parents before children, for the foreign keys. Leases aren't copied: they only matter while a
# companion runs.
TABLES = [
    "devices",
    "activities",
    "refused_keys",
    "photo_trips",
    "photo_assets",
    "photo_sidecars",
    "flight_status",
    "flight_units",
]


def copy(source: str, target: str) -> dict[str, int]:
    """Copies every row of `source` (a SQLite file) into `target` (a path or URL). Returns how many
    rows each table had."""
    old = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
    old.row_factory = sqlite3.Row
    present = {row["name"] for row in old.execute("select name from sqlite_master where type = 'table'")}
    new = Store(target)
    counts: dict[str, int] = {}
    try:
        with new._db() as db:
            for table in TABLES:
                if table not in present:
                    continue
                rows = old.execute(f"select * from {table}").fetchall()
                for row in rows:
                    columns = row.keys()
                    db.run(
                        f"insert into {table} ({', '.join(columns)}) values ({', '.join('?' for _ in columns)})"
                        " on conflict do nothing",
                        tuple(row),
                    )
                counts[table] = len(rows)
    finally:
        new.close()
        old.close()
    return counts


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    for table, count in copy(argv[0], argv[1]).items():
        print(f"{table}: {count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
