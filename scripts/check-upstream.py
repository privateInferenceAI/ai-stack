#!/usr/bin/env python3
"""check-upstream.py — Lane 1 of the tech watch: pinned-component version/security watch.

Reads scripts/upstream-watch.json (hand-maintained record of what we have pinned)
and checks each upstream GitHub repo for newer releases and security-relevant
release notes. Prints a markdown report; exits 1 when any component needs action
(so the weekly GitHub Action files an issue only when there's something to say).

Track policies (per component, in the manifest):
  - "version":       flag when latest MAJOR.MINOR > ours (patch drift is FYI only)
  - "security-only": flag only when release notes since ours_date look
                     security-relevant (for digest-pinned-from-floating-tag images
                     where we don't know an exact version — llama.cpp, litellm,
                     n8n, mailpit)

MAINTENANCE: when you bump a pin (new image digest), update ours / ours_version /
ours_date in upstream-watch.json in the same commit.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST = REPO_ROOT / "scripts" / "upstream-watch.json"
TOKEN = os.environ.get("GITHUB_TOKEN", "")

# Strong security signals only — plain "security" appears in routine release notes
# constantly and would flag every component every week.
SECURITY_RE = re.compile(
    r"cve-|ghsa-|security (fix|patch|advis|update|release)|vulnerab", re.IGNORECASE
)
PRERELEASE_RE = re.compile(r"rc|beta|alpha|dev|pre", re.IGNORECASE)


def gh(path: str):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "ai-stack-upstream-watch"}
    if TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    req = urllib.request.Request(f"https://api.github.com{path}", headers=headers)
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.load(r)


def releases(repo: str, tag_regex: str = ""):
    """Release list; falls back to tags for repos that don't use GitHub Releases.
    tag_regex (optional) filters to relevant tag families (e.g. REL_16_* for postgres)."""
    rels = gh(f"/repos/{repo}/releases?per_page=20")
    if rels:
        out = [{"tag": r.get("tag_name", ""), "name": r.get("name") or "",
                "date": r.get("published_at", ""), "body": (r.get("body") or "")[:4000]} for r in rels]
    else:
        tags = gh(f"/repos/{repo}/tags?per_page=100")
        out = [{"tag": t.get("name", ""), "name": "", "date": "", "body": ""} for t in tags]
    if tag_regex:
        rx = re.compile(tag_regex)
        out = [r for r in out if rx.search(r["tag"])]
    return out


def major_minor(v: str):
    m = re.search(r"(\d+)\.(\d+)", v or "")
    return (int(m.group(1)), int(m.group(2))) if m else None


def main() -> int:
    comps = json.loads(MANIFEST.read_text())
    rows, actions = [], 0
    for c in comps:
        ours_disp, latest_disp, newer, note, action = c["ours"], "?", "", "", ""
        try:
            rels = releases(c["repo"], c.get("tag_regex", ""))
        except Exception as e:
            rows.append((c["service"], c["repo"], ours_disp, "ERROR", "", f"fetch failed: {e}", "review"))
            actions += 1
            continue
        if not rels:
            rows.append((c["service"], c["repo"], ours_disp, "none found", "", "no releases/tags", ""))
            continue
        stable = [r for r in rels if not PRERELEASE_RE.search(r["tag"])]
        latest = (stable or rels)[0]
        latest_disp = f"{latest['tag']} ({latest['date'][:10] or 'date n/a'})"
        sec_hits = []
        for r in rels:
            m = SECURITY_RE.search(f"{r['name']}\n{r['body']}")
            if m:
                line = next((ln.strip() for ln in f"{r['name']}\n{r['body']}".splitlines()
                             if SECURITY_RE.search(ln)), "")[:140]
                sec_hits.append((r["tag"], line))
        newer_count = 0
        if c.get("ours_date"):
            newer_count = sum(1 for r in rels if r["date"] and r["date"] > c["ours_date"])
        newer = f"{newer_count} newer" if newer_count else "—"
        if sec_hits:
            action = "🔴 SECURITY — review " + ", ".join(t for t, _ in sec_hits[:3])
        elif c["track"] == "version" and c.get("ours_version"):
            om, lm = major_minor(c["ours_version"]), major_minor(latest["tag"])
            if om and lm and lm > om:
                action = "🟡 bump candidate"
        note = "; ".join(f"{t}: {ln}" for t, ln in sec_hits[:2]) if sec_hits else ""
        rows.append((c["service"], c["repo"], ours_disp, latest_disp, newer, note, action))
        if action:
            actions += 1

    today = datetime.now(timezone.utc).date().isoformat()
    print(f"## Upstream watch — {today}\n")
    print("| Component | Repo | Ours | Latest upstream | Newer | Security scan | Action |")
    print("|---|---|---|---|---|---|---|")
    for svc, repo, ours, latest, newer, note, action in rows:
        print(f"| {svc} | {repo} | {ours} | {latest} | {newer} | {note or 'clean'} | {action or 'ok'} |")
    print("\n_Lane 1 of the tech watch (scripts/check-upstream.py). "
          "Bump pins deliberately: re-pull, record new digest + version in scripts/upstream-watch.json, "
          "run the eval set, merge._")
    print(f"\n{actions} component(s) need action" if actions else "\nAll components current / no security flags")
    return 1 if actions else 0


if __name__ == "__main__":
    sys.exit(main())
