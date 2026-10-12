#!/usr/bin/env python3
# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Give the gallery screenshots their names.

`xcresulttool export attachments` writes each screenshot under a generated file name and lists
the names in manifest.json. This copies each one to `<out>/<attachment name>.png` (for example
`02-today-light.png`), the names Design/review-* use.

    python3 scripts/gallery-names.py build/gallery build/gallery-named
"""

from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path

# "02-today-light_0_6F2C….png": the attachment name, then an index and an id that Xcode adds.
SUFFIX = re.compile(r"_\d+_[0-9A-Fa-f-]{8,}(?=\.\w+$)")
SAFE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def readable(name: str) -> str:
    return SUFFIX.sub("", name)


def main(source: Path, out: Path) -> int:
    manifest = json.loads((source / "manifest.json").read_text())
    out.mkdir(parents=True, exist_ok=True)
    written: set[str] = set()
    for test in manifest:
        for attachment in test.get("attachments", []):
            exported = attachment.get("exportedFileName")
            name = readable(attachment.get("suggestedHumanReadableName") or "")
            if not exported or not name.endswith(".png") or not SAFE.match(name):
                continue
            if name in written:
                print(f"two screenshots are called {name}", file=sys.stderr)
                return 1
            shutil.copyfile(source / exported, out / name)
            written.add(name)
    if not written:
        print("no screenshots in the manifest", file=sys.stderr)
        return 1
    for name in sorted(written):
        print(name)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    sys.exit(main(Path(sys.argv[1]), Path(sys.argv[2])))
