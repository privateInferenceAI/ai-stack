# AI Stack — Self-Hosted AI for Regulated Business

10-container AI stack on a single GPU box. One question travels:
browser → WebUI → guardrail filter → LiteLLM → llama.cpp → GPU.
Logged at every stop, enforced by code at every boundary.

## Layout

| Path | What |
|---|---|
| `docker-compose.yml` | The 10 services, pinned |
| `genenv.sh` | Generates fresh `.env` (secrets born on-box) |
| `gittar.sh` | Creates runtime dirs Git can't track (run once after clone) |
| `pathb.sh` | Fresh-install orchestrator (Path B) |
| `phase1a.sh` / `phase1b.sh` | Foundation (driver, Docker, toolkit, UFW, model) |
| `backup.sh` / `restore.sh` | Clone / disaster-recovery (Path A) |
| `litellm/config.yaml` | Gateway config: model alias, routing |
| `guardrails/guardrails-function.py` | WebUI filter: guardrails + ACL RAG + redaction |
| `guardrails/policy.txt` | Plain-English guardrail rules |
| `ingestion/` | Dockerfile + ingest.py (document brain) |
| `documents/{company,executive}/` | Source docs, tagged by folder |
| `exports/` | n8n workflow JSON |
| `docs/` | Runbooks: fresh install, clone, bugs, operations |

## Two paths

- **Path B (fresh):** new box, new secrets, new accounts → `docs/PATH-B-FRESH.md`
- **Path A (clone):** restore from backup → `docs/PATH-A-CLONE.md`

## The rules (each cost time — see docs/BUG-LOG.md)

1. Secrets never in Git. `.env` is generated on-box, mode 600.
2. `.env` changes require `docker compose up -d --force-recreate`, never `restart`.
3. chown n8n-data to 1000:1000 ONLY. Never blanket-chown the tree.
4. Scripts with `$` travel via Git or scp, never pasted into a terminal.
