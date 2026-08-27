# Guardrails — per-client customization

The guardrails filter (`guardrails/guardrails-function.py`) is an Open WebUI Filter
function. **All of its knobs are Valves** — editable in the WebUI at
**Admin → Functions → Company Guardrails + RAG → Valves**, with no redeploy and no
code edit. The defaults in the code are only what a fresh install starts with.

`guardrails/policy.txt` is the human-readable contract a client signs off on.
**After any valve change, update `policy.txt` in the same breath.** The policy's
credibility is its line "enforced by CODE" — if the two drift apart, the code is
what actually happens and the policy becomes a lie.

## The knobs

| Valve | Default | What it does |
|---|---|---|
| `denied_keywords` | `salary of, how much does, ssn, social security number, ignore previous instructions, ignore all previous, you are now, system:` | Comma-separated lowercase **substrings**. If any appears in the user's (lowercased) last message, it is refused before the model sees it. |
| `refusal_message` | "I'm not able to help with that. Please contact your administrator…" | Text returned on denial. |
| `redact_patterns` | `\b\d{3}-\d{2}-\d{4}\b` (SSN) | Comma-separated **regexes** (Python `re`); matches in the assistant's reply become `[REDACTED]` before display. |
| `executive_roles` | `admin` | Comma-separated WebUI roles that may see `executive/`-folder chunks in RAG. Everyone else sees `company/` only. |
| `rag_top_k` | `10` | Chunks retrieved and injected per message. |
| `enable_rag`, `enable_rerank` | `true` | Feature toggles. |
| `qdrant_url`, `qdrant_collection`, `qdrant_api_key`, `embed_url`, `rerank_url` | internal service URLs / `company_docs` | Plumbing; rarely changed per client. |

## Tailoring denied topics for a client

1. **Get the client's denied-topics list in writing** (HR/legal/management). Each
   topic needs a decision: refuse outright, or answer from company docs only.
2. **Translate each topic into multi-word phrases, not single words.** Substring
   matching is blunt — every phrase will hit phrasings you didn't intend:
   - ✅ Reasonable: `salary of`, `legal advice`, `should i sue`, `is it legal to`, `lawsuit against`
   - ❌ Dangerous: `legal` (blocks "legal fees" in the expense policy), `contract`
     (blocks legit contract summaries), `sue` (blocks "ask Sue about…")
   - Phrases are literal — no wildcards. "how much does … make?" cannot be expressed;
     `how much does` is the current crude approximation and it false-positives
     ("how much does the mileage policy reimburse?" is refused). Tune to the client's
     real vocabulary.
3. **Test both directions** after editing:
   - Each denied phrase → expect the refusal message.
   - A battery of questions the client *actually asks* → expect answers. False
     positives here are what erode trust in the tool.
4. **Update `policy.txt`** to list exactly the topics enforced — no more, no less.
5. **Re-verify after WebUI upgrades.** Valves persist in WebUI's own database
   (`open-webui-data`, captured by `backup.sh`), but confirm they survive restores
   and upgrades.

## PII redaction per client

Add regexes to `redact_patterns` for client-specific identifiers (employee IDs,
account numbers, phone formats). Test each pattern against real sample outputs —
over-broad patterns mangle normal answers.

## Document ACL per client

- A document's ACL is its **folder name** under `/opt/ai-stack/documents/`
  (`company/` vs `executive/` today; subfolders are included — the ACL comes from
  the top-level folder). After moving/adding documents, either wait for the
  ingestion worker's next cycle (default 15 min) or run immediately:
  `docker exec ingestion python3 /app/ingest.py`
- `executive_roles` maps WebUI roles → executive visibility.
- Adding a **third tier** (e.g. `hr/`) is a *code* change, not a valve: new folder,
  re-ingest, then extend `_acl_for_user()` and the Qdrant filter. v1 supports
  exactly two tiers.

## Known limits / roadmap

- Substring matching cannot do phrasing-independent topics (legal advice in all its
  forms is the canonical example). The planned fix is an LLM-classifier pre-pass in
  the inlet — tracked in GitHub issue #3.
- Denial currently returns one generic message; per-topic redirect text is discussed
  in the same issue.
