#!/usr/bin/env python3
"""check-doc-sync.py — the doc/script drift guard.

The build guides embed full copies of repo files. Those copies must be
BYTE-EXACT mirrors of the real files — this script verifies that, and can
also regenerate the embedded copies from the real files.

Recognized embedding styles:
  A) docs/scripted-build.md appendix: a '### <name>.sh — …' heading followed by
     a ```bash fenced block holding the whole script.
  B) docs/manual-build.md: 'cat > /opt/ai-stack/<path> << 'EOF'' heredoc blocks.

Usage:
    python3 scripts/check-doc-sync.py           # check only; exit 1 on drift
    python3 scripts/check-doc-sync.py --write   # rewrite embedded copies from the real files

Run after editing either side (real file or embedded copy). The --write mode is
the fastest way to re-sync: edit the REAL file, then regenerate the embedded copy.

NOT caught (by design): prose and sample-output drift — expected outputs,
settings-page names, troubleshooting tables. Those aren't files; review them
by eye when editing.
"""

from __future__ import annotations

import difflib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

DOCS = {
    "appendix": REPO / "docs" / "scripted-build.md",
    "heredoc": REPO / "docs" / "manual-build.md",
}

OPT_PREFIX = "/opt/ai-stack/"


def extract_appendix_scripts(lines: list[str]):
    """Style A blocks -> (name, heading_lineno, content_start_idx, content_end_idx)."""
    blocks = []
    i = 0
    while i < len(lines):
        m = re.match(r"^### (\S+\.sh)\b", lines[i])
        if m:
            name, start = m.group(1), i + 1
            j = i + 1
            while j < len(lines) and not lines[j].startswith("```bash"):
                j += 1
            if j >= len(lines):
                print(f"WARNING: line {start}: '{name}' heading has no ```bash block")
                i += 1
                continue
            k = j + 1
            while k < len(lines) and not lines[k].startswith("```"):
                k += 1
            blocks.append((name, start, j + 1, k))
            i = k
        i += 1
    return blocks


def extract_heredocs(lines: list[str]):
    """Style B blocks -> (path, start_lineno, content_start_idx, content_end_idx)."""
    blocks = []
    i = 0
    while i < len(lines):
        m = re.match(r"^cat > (\S+) << 'EOF'\s*$", lines[i])
        if m:
            path, start = m.group(1), i + 1
            j = i + 1
            while j < len(lines) and lines[j] != "EOF":
                j += 1
            blocks.append((path, start, i + 1, j))
            i = j
        i += 1
    return blocks


def repo_rel(box_path: str) -> str | None:
    if not box_path.startswith(OPT_PREFIX):
        return None
    return box_path[len(OPT_PREFIX):]


def collect():
    """Yield (doc, doc_lines, start_lineno, content_start, content_end, repo_rel, embedded)."""
    for kind, doc in DOCS.items():
        lines = doc.read_text().splitlines()
        if kind == "appendix":
            for name, start, cs, ce in extract_appendix_scripts(lines):
                yield doc, lines, start, cs, ce, name, lines[cs:ce]
        else:
            for box_path, start, cs, ce in extract_heredocs(lines):
                rel = repo_rel(box_path)
                if rel is None:
                    print(f"SKIP     {box_path}  ({doc.name}:{start}) — not under {OPT_PREFIX}")
                    continue
                yield doc, lines, start, cs, ce, rel, lines[cs:ce]


def check() -> int:
    failures = checked = 0
    for doc, _lines, start, _cs, _ce, rel, embedded in collect():
        real_file = REPO / rel
        if not real_file.is_file():
            print(f"MISSING  {doc.name}:{start}  ->  repo has no {rel}")
            failures += 1
            continue
        real = real_file.read_text().splitlines()
        if real == embedded:
            print(f"OK       {rel}  ({doc.name}:{start})")
            checked += 1
            continue
        failures += 1
        print(f"DRIFT    {rel}  ({doc.name}:{start})")
        diff = list(
            difflib.unified_diff(
                real,
                embedded,
                fromfile=f"repo/{rel}",
                tofile=f"{doc.name}:{start} (embedded)",
                lineterm="",
                n=2,
            )
        )
        for line in diff[:80]:
            print(f"         {line}")
        if len(diff) > 80:
            print(f"         ... ({len(diff) - 80} more diff lines)")
    print(f"\n{checked} byte-exact, {failures} drifting/missing")
    return 1 if failures else 0


def write() -> int:
    per_doc: dict = {}
    for doc, lines, start, cs, ce, rel, _embedded in collect():
        real_file = REPO / rel
        if not real_file.is_file():
            print(f"MISSING  {doc.name}:{start}  ->  repo has no {rel}; skipped")
            continue
        per_doc.setdefault(doc, {"lines": lines, "edits": []})
        per_doc[doc]["edits"].append((cs, ce, rel, doc.name))
    total = 0
    for doc, payload in per_doc.items():
        lines = payload["lines"]
        # splice from the bottom up so earlier indices stay valid
        for cs, ce, rel, docname in sorted(payload["edits"], reverse=True):
            real = (REPO / rel).read_text().splitlines()
            if lines[cs:ce] != real:
                print(f"SYNCED   {rel}  ->  {docname}")
                total += 1
            lines[cs:ce] = real
        doc.write_text("\n".join(lines) + "\n")
    print(f"\n{total} embedded blocks rewritten")
    return 0


if __name__ == "__main__":
    if "--write" in sys.argv[1:]:
        sys.exit(write())
    sys.exit(check())
