#!/usr/bin/env python3
# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Fail when the repository mentions anything on the maintainer's private denylist.

The denylist is a repository secret (PRIVACY_DENYLIST): one entry per line, matched without
regard to case. A line starting with `re:` is a regular expression; blank lines and lines
starting with `#` are skipped. Typical entries: real names, a homelab domain, hostnames,
an Apple team id, real trip places and dates.

    PRIVACY_DENYLIST="$(cat my-list)" python3 scripts/privacy-scan.py            # the working tree
    PRIVACY_DENYLIST=… python3 scripts/privacy-scan.py --commits BASE..HEAD       # plus every commit in the range

With --commits, each commit's message and every line it adds are checked too, so a term that
was added and then removed in a later commit is still caught (the merge would keep it in history).
PR_TITLE and PR_BODY, when set, are checked as well.

The output never contains an entry or the text it matched (CI logs of a public repository
are public): only where it was found and the entry's number in the list.
Without the secret (forks, or not set up yet) it notes that and passes.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys


def load() -> list[re.Pattern[str]]:
    patterns = []
    for raw in os.environ.get("PRIVACY_DENYLIST", "").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("re:"):
            patterns.append(re.compile(line[3:].strip(), re.IGNORECASE))
        else:
            patterns.append(re.compile(re.escape(line), re.IGNORECASE))
    return patterns


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True, errors="replace").stdout


class Scanner:
    def __init__(self, patterns: list[re.Pattern[str]]) -> None:
        self.patterns = patterns
        self.found = 0

    def check(self, text: str, where: str, file: str | None = None, line: int | None = None) -> None:
        for number, pattern in enumerate(self.patterns, start=1):
            if pattern.search(text):
                self.found += 1
                location = f"file={file},line={line}" if file else ""
                print(f"::error {location}::{where} matches denylist entry {number}", flush=True)

    def tree(self) -> None:
        for path in git("ls-files", "-z").split("\0"):
            if not path:
                continue
            self.check(path, f"the file name {path}")
            try:
                with open(path, encoding="utf-8") as handle:
                    for number, text in enumerate(handle, start=1):
                        self.check(text, f"{path}:{number}", path, number)
            except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
                continue  # binary files (screenshots are synthetic by rule), submodules, deleted files

    def commits(self, revisions: str) -> None:
        for sha in git("rev-list", "--no-merges", revisions).split():
            short = sha[:7]
            self.check(git("log", "-1", "--format=%B", sha), f"the message of commit {short}")
            path = None
            for text in git("show", "--format=", "--no-color", "--unified=0", sha).splitlines():
                if text.startswith("+++ "):
                    path = text[6:] if text.startswith("+++ b/") else None
                elif text.startswith("+") and path:
                    self.check(text[1:], f"a line added to {path} in commit {short}")


def main() -> int:
    patterns = load()
    if not patterns:
        print("::notice::PRIVACY_DENYLIST is not set (a fork, or not set up yet): skipping the privacy scan.")
        return 0
    scanner = Scanner(patterns)
    scanner.tree()
    if "--commits" in sys.argv:
        scanner.commits(sys.argv[sys.argv.index("--commits") + 1])
    for name in ("PR_TITLE", "PR_BODY"):
        if os.environ.get(name):
            scanner.check(os.environ[name], f"the pull request {name[3:].lower()}")
    print(f"{len(patterns)} denylist entries checked; {scanner.found} matches.")
    return 1 if scanner.found else 0


if __name__ == "__main__":
    sys.exit(main())
