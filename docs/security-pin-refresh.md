# Security pin refresh — how to update Docker image digest pins

This is the manual procedure behind issue **#25** and the quarterly refresh called out in
`docs/tech-watch.md`. It updates the **digest-pinned container images** in
`docker-compose.yml` so a new build starts from patched upstream images instead of
old, potentially vulnerable ones.

> **What this is NOT:** it is not about API keys. API keys are still generated fresh by
> `genenv.sh` during each install. This is only about the *container images* themselves.

---

## Why we pin (and why we refresh)

- **Pinning by digest** (`image@sha256:...`) means Docker pulls exactly that image every
  time. A malicious or broken upstream tag cannot silently change what we deploy.
- **The downside:** pinned images do not auto-update. If upstream releases a security
  patch, our pin still points at the old image.
- **A security pin refresh** inspects upstream for a newer patched image, records its
  new digest, and updates our manifest so the next build uses it.

---

## Components that may need a refresh

Look in `docker-compose.yml`. There are two pinning styles:

1. **Direct digest pins** (must refresh for security fixes):
   - `llamacpp` — `ghcr.io/ggml-org/llama.cpp@sha256:...`
   - `litellm` — `ghcr.io/berriai/litellm@sha256:...`
   - `open-webui` — `ghcr.io/open-webui/open-webui@sha256:...`
   - `n8n` — `docker.n8n.io/n8nio/n8n@sha256:...`
   - `mailpit` — `axllent/mailpit@sha256:...`

2. **Version tags with a fallback digest comment** (refresh when the version tag itself
   changes, e.g. postgres 16.x -> 16.y, qdrant v1.11.3 -> v1.12.0):
   - `postgres:16-alpine`
   - `qdrant/qdrant:v1.11.3`
   - `ghcr.io/huggingface/text-embeddings-inference:1.6` (embeddings + reranker)

For this procedure we focus on the **direct digest pins**, because that is what issue
#25 is about. The version-tag components are bumped separately when
`scripts/check-upstream.py` flags a new MAJOR.MINOR release.

---

## Prerequisites

- A machine with Docker and `docker buildx` installed.
- Internet egress (this is one of the few times the stack intentionally reaches out).
- Optional but recommended: a GitHub token in `GITHUB_TOKEN` so
  `scripts/check-upstream.py` is not rate-limited.

---

## Step 1 — Check the current pins

### 1.1 Read the manifest

```bash
cat scripts/upstream-watch.json
```

This file is the single source of truth for what we have pinned, when we pinned it,
and what our update policy is for each component (`version` vs `security-only`).

**Why:** It tells you which components are pinned from floating tags and which are
version-locked. Security-only components are the ones that silently accumulate CVEs
because there is no version number to flag.

### 1.2 Read the compose file image lines

```bash
grep -nE "image:|freeze:|# CHANGED:" docker-compose.yml
```

You will see lines like:

```yaml
image: ghcr.io/open-webui/open-webui@sha256:6a773e5c3a246b65cbe74ce942b294292c0e5f81c138f703d111bc162f7d7c3d
```

**Why:** This confirms the exact digests currently in force. The manifest and compose
must agree; if they drift, you have found a bug to fix in the same PR.

### 1.3 Run the upstream watch script

```bash
python3 scripts/check-upstream.py
```

The script prints a markdown report. It exits `1` if any component needs action.

**Why:** It automates the security-signal search. For security-only components it
scans release notes for keywords like `CVE`, `GHSA`, `security fix/patch`, and
`vulnerability`. For version-track components it flags MAJOR.MINOR drift. This is how
we know *which* pins to refresh instead of guessing.

---

## Step 2 — Decide what to refresh

Issue #25 is a **security-driven refresh**: update every direct digest pin that has a
security patch available, regardless of whether the version number changed.

A quarterly refresh is broader: re-pull the security-only components even if no CVE
was flagged, so we capture low-noise fixes and re-record their versions properly.

For each component you will refresh, pick the upstream tag to inspect:

| Service | Pin source | Tag to inspect |
|---|---|---|
| llamacpp | `ghcr.io/ggml-org/llama.cpp` | `:server-cuda` |
| litellm | `ghcr.io/berriai/litellm` | `:main-stable` |
| open-webui | `ghcr.io/open-webui/open-webui` | `:main` or a numbered `:v0.X.Y` |
| n8n | `docker.n8n.io/n8nio/n8n` | `:latest` |
| mailpit | `axllent/mailpit` | `:latest` |

**Why:** We pinned from these tags originally. The refresh pulls the *current* image
that tag points to and records its digest.

---

## Step 3 — Fetch the new digests

For each component, run:

```bash
docker buildx imagetools inspect <registry>/<image>:<tag>
```

### Example: open-webui

```bash
docker buildx imagetools inspect ghcr.io/open-webui/open-webui:main
```

Look for the `Digest:` line:

```
Name:      ghcr.io/open-webui/open-webui:main
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:deadbeef...
```

Copy the digest value. Repeat for each component you are refreshing.

**Why:** `docker buildx imagetools inspect` resolves a tag to its current digest
without downloading the whole image. It works for multi-arch indexes (OCI manifests),
which a simple `docker pull` digest may not expose correctly.

> **Tip:** If you do not have `buildx`, `docker manifest inspect <image>:<tag>` also
> works, but `buildx imagetools` is preferred because it handles OCI indexes and
> attestation manifests cleanly.

---

## Step 4 — Update docker-compose.yml

Replace each old digest with the new one. Keep the existing comment style.

Before:

```yaml
  open-webui:
    # CHANGED: pinned to digest (was :main) — this is v0.11.0
    image: ghcr.io/open-webui/open-webui@sha256:6a773e5c3a246b65cbe74ce942b294292c0e5f81c138f703d111bc162f7d7c3d
```

After (example):

```yaml
  open-webui:
    # CHANGED: pinned to digest (was :main) — this is v0.12.0
    image: ghcr.io/open-webui/open-webui@sha256:deadbeef...
```

**Why:** The comment documents the human-readable version that the digest represents.
Future you (or the next tech watch) needs to know whether the digest moved from
v0.11.0 to v0.12.0 or just to a rebuilt v0.11.0 patch.

### For version-tag components (only if bumping the version)

If `scripts/check-upstream.py` says postgres or qdrant has a new MAJOR.MINOR:

1. Update the tag: `postgres:16-alpine` -> `postgres:16.4-alpine`.
2. Inspect the new tag to get its digest.
3. Update the `# freeze:` comment with the new digest.
4. Update the version in `scripts/upstream-watch.json`.

**Why:** Version tags move when upstream publishes a new point release. The freeze
comment is a safety net in case the tag is ever retagged or pulled from a mirror.

---

## Step 5 — Update scripts/upstream-watch.json

For each refreshed component, update:

- `"ours"` — human-readable description, e.g. `pinned 2026-09-17 (:main-stable)`
- `"ours_version"` — version number if known, else `null`
- `"ours_date"` — the date you inspected the digest, e.g. `2026-09-17`

Example diff:

```json
  { "service": "litellm",
    "repo": "berriai/litellm",
    "ours": "pinned 2026-09-17 (:main-stable)",
    "ours_version": null,
    "ours_date": "2026-09-17",
    "track": "security-only" },
```

**Why:** The manifest is what `scripts/check-upstream.py` uses next Monday. If you do
not update it, the script will compare the *new* upstream releases against the old
pin date and either spam false positives or miss the next CVE.

---

## Step 6 — Validate without running the stack

### 6.1 Check compose syntax

```bash
docker compose config
```

**Why:** This catches typos in image references, indentation errors, and invalid
substitutions before you touch a GPU box.

### 6.2 Re-run the upstream watch script

```bash
python3 scripts/check-upstream.py
```

It should now exit `0` (no action needed). If it still exits `1`, you missed a
component or the upstream project published *another* release while you were editing.

**Why:** Confirms the manifest and the refreshed pins are consistent.

### 6.3 Run the doc-sync checker

```bash
python3 scripts/check-doc-sync.py
```

If it complains about embedded script blocks, run:

```bash
python3 scripts/check-doc-sync.py --write
```

**Why:** `docs/manual-build.md` and `docs/scripted-build.md` embed byte-exact copies of
`docker-compose.yml` and the scripts. If the compose file changed, the embedded copies
must be regenerated so future builders do not follow stale instructions.

### 6.4 Lint shell scripts (if any scripts changed)

```bash
shellcheck *.sh
```

**Why:** A pin refresh usually does not touch scripts, but if you changed
`phase1b.sh` or `pathb.sh` to preload a new image, lint them.

---

## Step 7 — Test on a real box

Because this repo cannot run GPU services locally, validation continues on the AWS
instance:

1. Push the branch.
2. On the GPU box, pull the branch.
3. If the stack is already running, pull the new images first so the refresh is fast:

   ```bash
   cd /opt/ai-stack
   docker compose pull
   ```

4. Bring the stack up:

   ```bash
   docker compose up -d
   ```

5. Run the canary checks from `AGENTS.md`:
   - Expense-policy mileage rate (any user) -> 67 cents/mile.
   - CEO base salary (admin only) -> $425,000.

**Why:** A security bump that breaks behavior is not an upgrade. The canaries prove
RAG, ACLs, and the LLM path still work end-to-end.

---

## Step 8 — Commit and merge

Use one commit that updates compose and the manifest together:

```bash
git add docker-compose.yml scripts/upstream-watch.json docs/
git commit -m "security: refresh image digest pins (#25)

- open-webui: v0.11.0 -> v0.12.0 (sha256:...)
- litellm: ...
- llamacpp: ...
- n8n: ...
- mailpit: ...

Manifest and freeze comments updated."
```

**Why:** Keeping compose and `upstream-watch.json` in one commit prevents a mismatch
that would confuse the next tech-watch run.

---

## Quick reference — one-liner digest fetch

If you trust the current tag and just want all five direct-pin digests:

```bash
for img in \
  "ghcr.io/ggml-org/llama.cpp:server-cuda" \
  "ghcr.io/berriai/litellm:main-stable" \
  "ghcr.io/open-webui/open-webui:main" \
  "docker.n8n.io/n8nio/n8n:latest" \
  "axllent/mailpit:latest"
do
  echo "=== $img ==="
  docker buildx imagetools inspect "$img" | grep -E "^Name:|^Digest:"
done
```

Copy each `Digest:` value into `docker-compose.yml` and update the manifest.

---

## What can go wrong

- **Multi-arch digest vs single-arch digest:** Always use the index digest (the one
  printed at the top of `imagetools inspect`), not a per-architecture manifest digest.
  Using a per-arch digest will fail on a different CPU architecture.
- **Tag retagging:** Upstream occasionally re-tags `:latest` to the same version but a
  different build. That is fine; just record the new digest. The manifest date tells
  you when you last looked.
- **Forgot upstream-watch.json:** The next Monday issue will be wrong. Update it in the
  same commit.
- **Skipped canaries:** A fresh image may introduce a regression in WebUI, LiteLLM, or
  n8n that is unrelated to security. Always run the canary questions after a refresh.
