# Tech watch — how we stay current (and secure) on purpose

Our stack is **digest-pinned by design**: nothing updates unless we decide to update
it. That makes *us* the update channel — for ourselves and, eventually, for every
client. The tech watch is the compensating process. It runs **every Monday**.

Two lanes, because they have different natures:

## Lane 1 — upstream version/security watch (deterministic)

- **What:** `scripts/check-upstream.py` compares our pinned components (recorded in
  `scripts/upstream-watch.json`) against upstream GitHub releases and scans release
  notes for security keywords.
- **Cadence:** every Monday 09:00 ET via `.github/workflows/upstream-watch.yml`
  (also runnable by hand: `python3 scripts/check-upstream.py`).
- **Output:** files an *"Upstream watch — YYYY-MM-DD"* issue **only when a
  component needs action** (security flag or version-track drift). Quiet weeks = no issue.
- **Track policies:** `version` components (open-webui, postgres, qdrant, TEI) flag
  on MAJOR.MINOR drift; `security-only` components (llamacpp, litellm, n8n, mailpit —
  pinned from floating tags) flag only on security-relevant notes.

## Lane 2 — forefront research digest (weekly, agent-run)

- **What:** a weekly digest of what's worth knowing in open-source agentic builds:
  agent frameworks, RAG/guardrail techniques, local serving, n8n ecosystem, model
  releases worth benchmarking, eval tooling.
- **Format:** one issue per week — *"Tech watch — week of …"* — three triaged
  sections: **Act** (affects the stack now), **Evaluate** (worth a spike),
  **FYI** (know it exists). Anything in *Act* spawns its own issue.
- **Cadence:** Mondays. First issue: week of 2026-09-15. (Automation via an n8n
  dogfood workflow is a future upgrade; for now it's an agent-run ritual.)

## Rules of engagement

- **Egress boundary:** both lanes run on *our dev infrastructure* and only pull
  public information *in*. The no-egress rule covers shipped client systems and
  client data — never our own research tooling.
- **Updates are deliberate, never automatic.** Bump procedure for any component:
  pull new image → record new digest **and** version in the compose freeze comment
  **and** `scripts/upstream-watch.json` (same commit) → run the eval/canary set on
  the test box → merge → close the watch item.
- **Eval before merge.** A security bump that regresses behavior is not an upgrade.
  (Eval harness is on the roadmap; until then, the canary questions in AGENTS.md
  are the minimum bar.)
- **Quarterly pin refresh.** Even without a security flag, review the
  `security-only` components (llamacpp, litellm, n8n, mailpit) once a quarter:
  re-pull, record versions properly in the manifest, eval, merge.

## Sources

Component repos (via the script): ggml-org/llama.cpp, berriai/litellm,
open-webui/open-webui, qdrant/qdrant, huggingface/text-embeddings-inference,
n8nio/n8n, axllent/mailpit, postgres/postgres.
Lane 2 watches additionally: GitHub Security Advisories for those repos, model
vendors (Qwen, BAAI), r/LocalLLaMA, HF blog, llama.cpp release notes, n8n release
notes/community, and the eval/guardrails tooling space generally.
