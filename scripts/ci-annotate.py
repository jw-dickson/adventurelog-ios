#!/usr/bin/env python3
# AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.
"""Turn Swift compiler errors and test failures in a build log into GitHub annotations.

    make test-packages 2>&1 | tee build/packages.log
    python3 scripts/ci-annotate.py build/packages.log

GitHub shows at most 10 error annotations per step, so the most useful come first: compiler
errors, then test failures, de-duplicated.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMPILER = re.compile(r"^(?P<path>/[^:\s]+\.swift):(?P<line>\d+):(?P<col>\d+): (?P<level>error|warning): (?P<msg>.+)$")
# Swift Testing: "✘ Test foo() recorded an issue at File.swift:12:5: Expectation failed: …"
TESTING = re.compile(r"recorded an issue at (?P<file>[\w./-]+\.swift):(?P<line>\d+):(?P<col>\d+): (?P<msg>.+)$")
# XCTest: "/path/File.swift:12: error: -[Suite test] : XCTAssertTrue failed"
XCTEST = re.compile(r"^(?P<path>/[^:\s]+\.swift):(?P<line>\d+): error: (?P<msg>.+)$")


def rel(path: str) -> str:
    """Make a path relative to GITHUB_WORKSPACE, a known source directory, or ROOT."""
    workspace = os.environ.get("GITHUB_WORKSPACE")
    if workspace and path.startswith(workspace.rstrip("/") + "/"):
        return os.path.relpath(path, workspace)
    for anchor in ("/Packages/", "/AppUITests/", "/App/"):
        if anchor in path:
            return anchor[1:] + path.split(anchor, 1)[1]
    return os.path.relpath(path, ROOT) if path.startswith("/") else path


def find(file_name: str) -> str:
    """Find the first matching basename under ROOT outside build directories.

    Return its repository-relative path, or the original name if no match is found.
    """
    for base, _, files in os.walk(ROOT):
        if ".build" in base or "/build" in base:
            continue
        if os.path.basename(file_name) in files:
            return os.path.relpath(os.path.join(base, os.path.basename(file_name)), ROOT)
    return file_name


def escape(text: str) -> str:
    """Escape percent signs and line breaks for GitHub workflow command data."""
    return text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def main() -> int:
    """Print deduplicated annotations for the log in argv[1], optionally with a --tail.

    Emit at most 30 combined error/failure annotations and 10 warnings. Return 0
    even if errors are found or the log is absent; file access errors propagate.
    """
    if len(sys.argv) < 2 or not os.path.exists(sys.argv[1]):
        return 0
    errors, failures, warnings, seen = [], [], [], set()
    for raw in open(sys.argv[1], errors="replace"):
        line = raw.rstrip("\n")
        m = COMPILER.match(line) or XCTEST.match(line)
        if m:
            level = m.groupdict().get("level", "error")
            key = (m["path"], m["line"], m["msg"])
            if key in seen:
                continue
            seen.add(key)
            entry = f"::{level} file={rel(m['path'])},line={m['line']}::{escape(m['msg'])}"
            (errors if level == "error" else warnings).append(entry)
            continue
        m = TESTING.search(line)
        if m:
            key = (m["file"], m["line"], m["msg"])
            if key in seen:
                continue
            seen.add(key)
            failures.append(f"::error file={find(m['file'])},line={m['line']}::{escape(m['msg'])}")
    for entry in (errors + failures)[:30] + warnings[:10]:
        print(entry)
    if "--tail" in sys.argv:
        # Anything the patterns missed (linker errors, crashes, new test-output formats).
        lines = [l.rstrip("\n") for l in open(sys.argv[1], errors="replace")]
        interesting = [l for l in lines if re.search(r"error|✘|failed|Fatal|crash", l, re.I)]
        tail = (interesting[-40:] if interesting else []) + ["----- last lines -----"] + lines[-30:]
        print(f"::error title=Log tail::{escape(chr(10).join(tail))[:60000]}")
    print(f"Annotated {len(errors)} compiler errors, {len(failures)} test failures, {len(warnings)} warnings.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
