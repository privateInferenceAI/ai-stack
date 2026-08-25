# AI STACK — MANUAL BUILD GUIDE
## The full longhand: every command by hand, every file authored from scratch
**Use this for:** learning the stack cold, building where you don't trust scripts yet, or auditing exactly what the helper scripts do for you.
**The scripted version of this build is the Scripted Build Guide. The clone/DR version is the Backup & Restore Guide.**
**Hardware:** AWS g5.2xlarge (A10G 24GB, 8 vCPU, 32GB RAM, 200GB gp3), Ubuntu 24.04, Elastic IP, security group inbound 22 only. **~$1.21/hr running — stop the instance when idle (~$20/mo stopped).**

---

## HOW TO USE THIS DOCUMENT

| Box | Meaning | Action |
|---|---|---|
| **▶ TERMINAL** | Shell commands | Paste into SSH session, one block at a time |
| **🖱 UI** | Browser action | Click, don't type into a terminal |
| **✔ EXPECTED** | Success output | Compare, never type |

**Operating rules that apply throughout:**
- **After any `.env` edit:** `docker compose up -d --force-recreate <service>` — never `restart`. Environment variables inject at container *creation*, not start; `restart` reuses the old container with its frozen env.
- **chown scope:** config directories you author into → your user (`ubuntu:ubuntu`). Data volumes → the container's UID (n8n = 1000; postgres/qdrant/webui set their own on first write). Never blanket `chown -R /opt/ai-stack` once data exists.
- **Writing files with redirects:** `sudo cat > /path/file` does not do what it looks like — your shell opens the `>` as *you* before sudo runs, so the write still fails on a root-owned path. chown the directory to yourself first, then write as your normal user.
- **`{{ }}` expressions belong in n8n node fields in the browser, never the terminal** — the shell can't parse them.

---

# PART 1 — FOUNDATION (12 steps)

## 1. Stack directory + install log

▶ TERMINAL:
```bash
sudo mkdir -p /opt/ai-stack
sudo touch /opt/ai-stack/install-log.txt
sudo chown -R $$USER:$$USER /opt/ai-stack
```

(In a root shell, use the literal name: `sudo chown -R ubuntu:ubuntu /opt/ai-stack`.)

## 2. System update + timezone + baseline

▶ TERMINAL:
```bash
sudo apt update && sudo apt upgrade -y
sudo timedatectl set-timezone UTC
sudo apt install -y unattended-upgrades curl ca-certificates gnupg
```

✔ EXPECTED: upgrade scrolls several minutes, ends clean. A kernel upgrade triggers a "Pending kernel upgrade" notice — normal; the reboot in step 4 covers it.

## 3. NVIDIA driver — the decision step

▶ TERMINAL:
```bash
sudo apt install -y ubuntu-drivers-common
ubuntu-drivers devices
```

✔ EXPECTED: a driver list, one marked `recommended`.

**Decide:**
- Recommended = 595 (any variant) → it matches known-good:
  ```bash
  sudo ubuntu-drivers autoinstall
  ```
- Recommended has moved past 595 → choose: known-good `sudo apt install -y nvidia-driver-595` (what the stack is tested on, 595.84), or `autoinstall` for the newer unproven one. Stay at 595 unless you have a reason.

✔ EXPECTED: several minutes of package output; ends without errors.

**Noise you'll see (all normal):** `udevadm hwdb is deprecated` repeated, `ERROR:root:aplay command not found` (headless box, no audio stack), `dpkg-query: no packages found matching libnvidia-gl-550`.

## 4. REBOOT — not optional

▶ TERMINAL:
```bash
sudo reboot
```

The driver doesn't load until the box comes back. SSH reconnects in ~60–90s.

## 5. Prove the driver loaded before touching anything GPU

▶ TERMINAL:
```bash
nvidia-smi
```

✔ EXPECTED: GPU table, **NVIDIA A10G**, **Driver Version: 595.84**, `0MiB / 23028MiB`, no processes. If this errors → STOP; fix the driver first.

## 6. Docker (official repo — literal `noble`)

▶ TERMINAL:
```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER
```

## 7. NVIDIA Container Toolkit

▶ TERMINAL:
```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update
sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

✔ EXPECTED: `Wrote updated config to /etc/docker/daemon.json`; docker restarts clean.

## 8. Firewall + fail2ban

▶ TERMINAL:
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw --force enable
sudo apt install -y fail2ban jq
printf '[sshd]\nenabled = true\nbackend = systemd\n' | sudo tee /etc/fail2ban/jail.d/sshd.local
sudo systemctl enable --now fail2ban
```

✔ EXPECTED: `Firewall is active and enabled on system startup`; fail2ban enabled. **A wall of Python `SyntaxWarning` lines during the fail2ban install is normal** — Python 3.12 linting fail2ban's own test files.

✔ VERIFY:
```bash
sudo ufw status
sudo fail2ban-client status sshd
```
→ `Status: active`, only OpenSSH allowed inbound; jail `sshd`, `Currently banned: 0`. (Optional extra: restrict SSH to your IP in the AWS security group — belt and suspenders.)

## 9. Stack tree + Docker network

▶ TERMINAL:
```bash
sudo mkdir -p /opt/ai-stack/models
sudo touch /opt/ai-stack/.env
sudo chmod 600 /opt/ai-stack/.env
sudo chown -R $$USER:$$USER /opt/ai-stack
sudo docker network create ai-net
```

## 10. Model download (~9 GB — the long pole)

▶ TERMINAL:
```bash
sudo apt install -y python3-pip
python3 -m pip install --user --break-system-packages huggingface_hub
```

⚠ **The pip line runs WITHOUT sudo, as the ubuntu user.** `pip --user` under sudo scatters root-owned files into the wrong home and `hf` won't be where you look for it.

▶ TERMINAL (still as ubuntu, no sudo):
```bash
~/.local/bin/hf download Qwen/Qwen3-14B-GGUF Qwen3-14B-Q4_K_M.gguf --local-dir /opt/ai-stack/models
```

(If `hf` isn't found: `~/.local/bin/huggingface-cli download ...`, same arguments.)

✔ EXPECTED: ~9 GB at EC2 bandwidth (under a minute), then `✓ Downloaded /opt/ai-stack/models/Qwen3-14B-Q4_K_M.gguf`. HF's unauthenticated-request warning and CLI upsell hint: normal.

✔ VERIFY (do not trust `file` for this — it misidentifies GGUF):
```bash
ls -lh /opt/ai-stack/models/Qwen3-14B-Q4_K_M.gguf
head -c 4 /opt/ai-stack/models/Qwen3-14B-Q4_K_M.gguf; echo
```
→ ~8–9 GB file; prints `GGUF`.

**TEI models (embeddings + reranker) — same idea, smaller downloads.** Pre-download them now so the TEI containers never touch the network at boot (compose mounts this cache at `/data` and sets `HF_HUB_OFFLINE=1`):

▶ TERMINAL (still as ubuntu, no sudo):
```bash
HF_HUB_CACHE=/opt/ai-stack/models/tei ~/.local/bin/hf download BAAI/bge-m3
HF_HUB_CACHE=/opt/ai-stack/models/tei ~/.local/bin/hf download BAAI/bge-reranker-v2-m3
```

✔ EXPECTED: two HF cache trees under `/opt/ai-stack/models/tei` (`models--BAAI--bge-m3`, `models--BAAI--bge-reranker-v2-m3`). Without these, embeddings/reranker try to download from HuggingFace at first boot — and fail on an offline client LAN.

## 11. Final verification

▶ TERMINAL:
```bash
sudo docker run --rm --gpus all nvidia/cuda:13.2.0-base-ubuntu24.04 nvidia-smi
docker --version
docker compose version
```

✔ EXPECTED: the container prints the same A10G/595.84 table as the host (proves GPU→container passthrough). If it fails *only* because that CUDA tag moved, don't panic — the stack's own containers are the true test.

## 12. Docker without sudo

▶ TERMINAL:
```bash
newgrp docker
docker ps
```

✔ EXPECTED: empty container list, no sudo. (Or log out/in.)

---

# PART 2 — DIRECTORIES (data + config)

Two kinds of directories, two ownership rules:

- **Data dirs** (containers write here): create with sudo; chown **only n8n-data to 1000:1000**; the rest set their own ownership on first write.
- **Config dirs** (you author files here): create with sudo, then **immediately chown to yourself** so you can write into them as your normal user.

▶ TERMINAL:
```bash
# data dirs (containers own these)
sudo mkdir -p /opt/ai-stack/postgres-data /opt/ai-stack/open-webui-data /opt/ai-stack/qdrant-data /opt/ai-stack/n8n-data
sudo chown -R 1000:1000 /opt/ai-stack/n8n-data     # n8n ONLY

# config dirs (you author into these)
sudo mkdir -p /opt/ai-stack/ingestion /opt/ai-stack/litellm /opt/ai-stack/guardrails /opt/ai-stack/exports /opt/ai-stack/documents/company /opt/ai-stack/documents/executive /opt/ai-stack/backups
sudo chown -R ubuntu:ubuntu /opt/ai-stack/ingestion /opt/ai-stack/litellm /opt/ai-stack/guardrails /opt/ai-stack/exports /opt/ai-stack/documents /opt/ai-stack/backups
```

---

# PART 3 — AUTHOR THE STACK FILES (from scratch)

Everything the stack needs, written by hand. Terminal paste of multi-line content occasionally garbles mid-file — if a file misbehaves later, `cat` it and compare against what's printed here.

## 3.1 — ingestion/Dockerfile

▶ TERMINAL:
```bash
cat > /opt/ai-stack/ingestion/Dockerfile << 'EOF'
FROM python:3.11-slim
RUN pip install --no-cache-dir pypdf python-docx requests
WORKDIR /app
CMD ["tail", "-f", "/dev/null"]
EOF
```

Packages baked in — nothing to reinstall later.

## 3.2 — ingestion/ingest.py

▶ TERMINAL (one paste):
```bash
cat > /opt/ai-stack/ingestion/ingest.py << 'EOF'
#!/usr/bin/env python3
"""
Document ingestion for the AI stack document brain.
Reads PDFs/DOCX from /documents/<acl_folder>/, chunks, embeds, stores in Qdrant with ACL tags.
Usage: python3 ingest.py
Idempotent: re-running re-embeds and overwrites by document name (safe to re-run).
"""
import os, sys, uuid, glob
import requests

# --- Config (from environment) ---
QDRANT_URL = os.environ.get("QDRANT_URL", "http://qdrant:6333")
QDRANT_API_KEY = os.environ["QDRANT_API_KEY"]
EMBED_URL = os.environ.get("EMBED_URL", "http://embeddings:80")
COLLECTION = "company_docs"
DOCS_ROOT = "/documents"
CHUNK_SIZE = 512        # characters per chunk (simple char chunking)
CHUNK_OVERLAP = 64
VECTOR_SIZE = 1024      # bge-m3 output dimension

HEADERS = {"api-key": QDRANT_API_KEY, "Content-Type": "application/json"}

def extract_text(path):
    """Pull raw text from PDF or DOCX."""
    ext = path.lower().rsplit(".", 1)[-1]
    if ext == "pdf":
        from pypdf import PdfReader
        reader = PdfReader(path)
        return "\n".join(page.extract_text() or "" for page in reader.pages)
    elif ext in ("docx",):
        import docx
        doc = docx.Document(path)
        return "\n".join(p.text for p in doc.paragraphs)
    elif ext in ("txt", "md"):
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read()
    else:
        print(f"  SKIP (unsupported type): {path}")
        return None

def chunk_text(text):
    """Simple overlapping character chunker. Not fancy, works fine for business docs."""
    chunks = []
    start = 0
    while start < len(text):
        end = start + CHUNK_SIZE
        chunk = text[start:end].strip()
        if chunk:
            chunks.append(chunk)
        start = end - CHUNK_OVERLAP
    return chunks

def embed(texts):
    """Embed a list of strings via the TEI embeddings service."""
    resp = requests.post(f"{EMBED_URL}/embed", json={"inputs": texts}, timeout=120)
    resp.raise_for_status()
    return resp.json()

def ensure_collection():
    """Create the collection if it doesn't exist."""
    r = requests.get(f"{QDRANT_URL}/collections/{COLLECTION}", headers=HEADERS, timeout=30)
    if r.status_code == 200:
        return
    payload = {"vectors": {"size": VECTOR_SIZE, "distance": "Cosine"}}
    r = requests.put(f"{QDRANT_URL}/collections/{COLLECTION}", headers=HEADERS, json=payload, timeout=30)
    r.raise_for_status()
    print(f"Created collection '{COLLECTION}' (size={VECTOR_SIZE}, cosine)")

def doc_point_id(filename, chunk_index):
    """Deterministic UUID from filename+chunk so re-runs overwrite instead of duplicate."""
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, f"{filename}:{chunk_index}"))

def ingest_file(path, acl):
    filename = os.path.basename(path)
    print(f"Ingesting [{acl}] {filename} ...")
    text = extract_text(path)
    if not text or not text.strip():
        print(f"  SKIP (no text extracted): {filename}")
        return 0
    chunks = chunk_text(text)
    if not chunks:
        print(f"  SKIP (no chunks): {filename}")
        return 0
    vectors = embed(chunks)
    points = []
    for i, (chunk, vec) in enumerate(zip(chunks, vectors)):
        points.append({
            "id": doc_point_id(filename, i),
            "vector": vec,
            "payload": {
                "source": filename,
                "chunk_index": i,
                "acl": acl,
                "text": chunk,
            },
        })
    # Upsert in batches of 64
    for i in range(0, len(points), 64):
        batch = points[i:i+64]
        r = requests.put(f"{QDRANT_URL}/collections/{COLLECTION}/points?wait=true",
                         headers=HEADERS, json={"points": batch}, timeout=120)
        r.raise_for_status()
    print(f"  OK: {len(points)} chunks from {filename}")
    return len(points)

def main():
    ensure_collection()
    total = 0
    for acl in ("company", "executive"):
        folder = os.path.join(DOCS_ROOT, acl)
        for path in sorted(glob.glob(os.path.join(folder, "*.*"))):
            try:
                total += ingest_file(path, acl)
            except Exception as e:
                print(f"  ERROR on {path}: {e}", file=sys.stderr)
    print(f"\nDone. Total chunks upserted: {total}")
    # Show collection stats
    r = requests.get(f"{QDRANT_URL}/collections/{COLLECTION}", headers=HEADERS, timeout=30)
    info = r.json().get("result", {})
    print(f"Collection points count: {info.get('points_count')}")

if __name__ == "__main__":
    main()
EOF
```

▶ TERMINAL — sanity-check it arrived intact:
```bash
python3 -c "compile(open('/opt/ai-stack/ingestion/ingest.py').read(), 'ingest.py', 'exec'); print('SYNTAX OK')"
```

✔ EXPECTED: `SYNTAX OK`. (This is v1 — the base-build script. The extended version with recursion, batched embedding, and OCR handling belongs to the voice/ingestion upgrade, documented separately.)

## 3.3 — litellm/config.yaml

▶ TERMINAL (one paste — the quoted heredoc keeps `$` and YAML indentation intact):
```bash
cat > /opt/ai-stack/litellm/config.yaml << 'EOF'
model_list:
  - model_name: company-ai
    litellm_params:
      model: openai/qwen3-14b
      api_base: http://llamacpp:8080/v1
      api_key: os.environ/LLAMA_API_KEY
      input_cost_per_token: 0.000001
      output_cost_per_token: 0.000001
      extra_body: {"chat_template_kwargs": {"enable_thinking": false}}
litellm_settings:
  drop_params: true
  set_verbose: false

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL
EOF
```

**Why these lines:**
- `company-ai` is the alias — the client contract. The backend behind it can change without touching a client.
- `openai/` prefix = "this backend speaks the OpenAI API format." The name after the slash is cosmetic to llama.cpp.
- `extra_body ... enable_thinking: false` — suppresses the model's visible reasoning scratch-work for every client, at the gateway, in one place.
- `input/output_cost_per_token: 0.000001` — nominal $1/1M-token pricing so LiteLLM budgets trip. "$10 budget" = 10M tokens.
- `drop_params: true` — real clients send params llama.cpp doesn't know; drop them instead of returning 400s.

## 3.4 — guardrails/policy.txt

▶ TERMINAL:
```bash
cat > /opt/ai-stack/guardrails/policy.txt << 'EOF'
COMPANY AI — GUARDRAILS POLICY (v1)

DENIED TOPICS (input is refused with a polite redirect):
  - payroll_individual : questions about a specific person salary or pay
  - legal_advice       : requests for legal opinions or contract interpretation

PII REDACTION (output is scanned and redacted before display):
  - SSN pattern (###-##-####)

INJECTION DEFENSE (input is refused):
  - attempts to override instructions ("ignore previous instructions", "you are now", "system:")

NOTE: these rules are enforced by CODE on every message, not by asking the AI nicely.
EOF
```

This is the audit artifact — the plain-English rules you can show a client. The code that enforces it is next.

## 3.5 — exports/guardrails-function.py

The middleware: input guardrail + role-ACL'd RAG injection + rerank in `inlet`, PII redaction in `outlet`. Imported into WebUI during browser wiring (Part 9); the copy on disk is the export of record.

▶ TERMINAL (one paste):
```bash
cat > /opt/ai-stack/exports/guardrails-function.py << 'EOF'
"""
title: Company Guardrails + RAG
author: ai-stack
version: 0.2
description: Input guardrails (topic denial, injection), RAG injection from Qdrant with role-based ACL, output PII redaction.

CHANGELOG:
- v0.2: Changed rag_top_k from 3 to 10. Restructured ACL search to use Qdrant "should" filter
        so all users get the same retrieval count (ACL controls visibility, not volume).
        Previously: looped per-ACL with per-ACL limit, then truncated — gave admins more results by accident.
"""

from pydantic import BaseModel, Field
from typing import Optional
import os
import re
import requests


class Filter:
    class Valves(BaseModel):
        # --- Guardrails config ---
        denied_keywords: str = Field(
            default="salary of,how much does,ssn,social security number,ignore previous instructions,ignore all previous,you are now,system:",
            description="Comma-separated lowercase substrings that trigger an input refusal.",
        )
        refusal_message: str = Field(
            default="I'm not able to help with that. Please contact your administrator if you believe this is an error.",
            description="Message returned when input is denied.",
        )
        # --- RAG config ---
        enable_rag: bool = Field(default=True, description="Inject Qdrant doc context.")
        qdrant_url: str = Field(
            default="http://qdrant:6333", description="Qdrant base URL."
        )
        qdrant_collection: str = Field(
            default="company_docs", description="Qdrant collection."
        )
        embed_url: str = Field(
            default="http://embeddings:80", description="Embeddings base URL."
        )
        rerank_url: str = Field(
            default="http://reranker:80", description="Reranker base URL."
        )
        enable_rerank: bool = Field(
            default=True, description="Re-rank retrieved chunks before injection."
        )
        qdrant_api_key: str = Field(
            default=os.environ.get("QDRANT_API_KEY", ""),
            description="Qdrant API key.",
        )
        rag_top_k: int = Field(default=10, description="Number of chunks to retrieve and inject.")
        executive_roles: str = Field(
            default="admin",
            description="Comma-separated roles that get the 'executive' ACL filter; all others get 'company'.",
        )
        # --- Output redaction ---
        redact_patterns: str = Field(
            default=r"\b\d{3}-\d{2}-\d{4}\b",
            description="Comma-separated regex patterns to redact in output.",
        )

    def __init__(self):
        self.valves = self.Valves()

    # ---------------- helpers ----------------

    def _acl_for_user(self, __user__: Optional[dict]) -> str:
        role = (__user__ or {}).get("role", "user")
        exec_roles = [
            r.strip() for r in self.valves.executive_roles.split(",") if r.strip()
        ]
        return "executive" if role in exec_roles else "company"

    def _is_denied(self, text: str) -> bool:
        t = text.lower()
        kws = [k.strip() for k in self.valves.denied_keywords.split(",") if k.strip()]
        return any(k in t for k in kws)

    def _embed(self, text: str):
        resp = requests.post(
            f"{self.valves.embed_url}/embed",
            json={"inputs": [text]},
            timeout=60,
        )
        resp.raise_for_status()
        return resp.json()[0]

    def _search(self, vector, acls):
        headers = {
            "api-key": self.valves.qdrant_api_key,
            "Content-Type": "application/json",
        }
        payload = {
            "vector": vector,
            "limit": self.valves.rag_top_k,
            "with_payload": True,
            "filter": {
                "should": [
                    {"key": "acl", "match": {"value": acl}} for acl in acls
                ]
            },
        }
        resp = requests.post(
            f"{self.valves.qdrant_url}/collections/{self.valves.qdrant_collection}/points/search",
            headers=headers,
            json=payload,
            timeout=60,
        )
        resp.raise_for_status()
        return resp.json().get("result", [])

    def _rerank(self, query: str, hits):
        # Re-order retrieved chunks by true relevance to the question.
        if not hits or not self.valves.enable_rerank:
            return hits
        try:
            texts = [h["payload"]["text"] for h in hits if h.get("payload")]
            if not texts:
                return hits
            resp = requests.post(
                f"{self.valves.rerank_url}/rerank",
                json={"query": query, "texts": texts},
                timeout=60,
            )
            resp.raise_for_status()
            ranked = resp.json()  # list of {"index": i, "score": s}
            # sort by score descending, map back to hits, keep order
            order = sorted(ranked, key=lambda r: r.get("score", 0), reverse=True)
            reranked = [
                hits[r["index"]] for r in order if 0 <= r.get("index", -1) < len(hits)
            ]
            print(
                f"[guardrails] reranked {len(reranked)} chunk(s); top score={order[0].get('score') if order else 'n/a'}"
            )
            return reranked
        except Exception as e:
            print(f"[guardrails] rerank error (keeping original order): {e}")
            return hits

    def _last_user_text(self, body: dict) -> str:
        messages = body.get("messages", [])
        for m in reversed(messages):
            if m.get("role") == "user":
                return m.get("content", "")
        return ""

    # ---------------- hooks ----------------

    def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        print(f"[guardrails] inlet start; user={(__user__ or {}).get('email')}")

        user_text = self._last_user_text(body)

        # 1. INPUT GUARDRAIL — stop denied topics / injection before the model ever sees it
        if user_text and self._is_denied(user_text):
            print("[guardrails] INPUT DENIED")
            raise Exception(self.valves.refusal_message)

        # 2. DOCUMENT CONNECTOR (RAG) — inject role-filtered context
        if self.valves.enable_rag and user_text:
            try:
                role = (__user__ or {}).get("role", "user")
                exec_roles = [
                    r.strip()
                    for r in self.valves.executive_roles.split(",")
                    if r.strip()
                ]
                # executives see company + executive; everyone else sees company only
                acls = ["company", "executive"] if role in exec_roles else ["company"]
                vec = self._embed(user_text)

                hits = self._search(vec, acls)
                hits = self._rerank(user_text, hits)

                acl = "+".join(acls)  # for the log line below
                if hits:
                    context = "\n\n".join(
                        h["payload"]["text"] for h in hits if h.get("payload")
                    )
                    if context.strip():
                        prefix = (
                            "Answer the user's question using the company information below. "
                            "Quote or paraphrase the relevant line directly. "
                            "Only say you do not have the information if the text below truly does not address the question at all.\n\n"
                            f"--- COMPANY INFORMATION ---\n{context}\n--- END ---\n\n"
                        )
                        # prepend context to the last user message
                        for m in reversed(body.get("messages", [])):
                            if m.get("role") == "user":
                                m["content"] = prefix + m.get("content", "")
                                break
                        print(
                            f"[guardrails] RAG injected {len(hits)} chunk(s) with acl={acl}"
                        )
                else:
                    print(f"[guardrails] RAG: no hits for acl={acl}")
            except Exception as e:
                # fail open: don't break chat if the brain hiccups
                print(f"[guardrails] RAG error (continuing without context): {e}")

        return body

    def outlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        # 3. OUTPUT GUARDRAIL — redact PII patterns in the assistant's reply
        try:
            patterns = [p for p in self.valves.redact_patterns.split(",") if p.strip()]
            messages = body.get("messages", [])
            for m in reversed(messages):
                if m.get("role") == "assistant":
                    content = m.get("content", "")
                    for pat in patterns:
                        content = re.sub(pat, "[REDACTED]", content)
                    m["content"] = content
                    break
        except Exception as e:
            print(f"[guardrails] outlet redaction error: {e}")
        return body
EOF
```

▶ TERMINAL — sanity-check:
```bash
python3 -c "compile(open('/opt/ai-stack/exports/guardrails-function.py').read(), 'guardrails-function.py', 'exec'); print('SYNTAX OK')"
```

✔ EXPECTED: `SYNTAX OK`.

## 3.6 — docker-compose.yml (the master file — all 10 services, pinned)

▶ TERMINAL (one paste):
```bash
cat > /opt/ai-stack/docker-compose.yml << 'EOF'
services:
  llamacpp:
    image: ghcr.io/ggml-org/llama.cpp@sha256:48a88af72b29e865d64f464e3dc1e4fbbad4a36c5e2298d72d13b690f9d17dd2
    container_name: llamacpp
    restart: unless-stopped
    env_file: /opt/ai-stack/.env
    ports:
      - "8080:8080"
    volumes:
      - /opt/ai-stack/models:/models:ro
    command: >
      --model /models/Qwen3-14B-Q4_K_M.gguf
      --host 0.0.0.0
      --port 8080
      --ctx-size 32768
      --n-gpu-layers 99
      --api-key ${LLAMA_API_KEY}
      --flash-attn on
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    networks:
      - ai-net

  postgres:
    image: postgres:16-alpine
    # fallback digest if the version tag ever misbehaves:
    # postgres@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777
    container_name: litellm-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - /opt/ai-stack/postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 12
    networks:
      - ai-net
    # Deliberately NO ports: block. Internal to ai-net only.

  litellm:
    image: ghcr.io/berriai/litellm@sha256:af806882b7a6ced41658db5b6a7e98ed7b9b51d03b935e0417bf1c8552d688af
    container_name: litellm
    restart: unless-stopped
    env_file: /opt/ai-stack/.env
    environment:
      USE_PRISMA_MIGRATE: "true"
    ports:
      - "4000:4000"
    volumes:
      - /opt/ai-stack/litellm/config.yaml:/app/config.yaml:ro
    command: ["--config", "/app/config.yaml", "--port", "4000"]
    depends_on:
      postgres:
        condition: service_healthy
      llamacpp:
        condition: service_started
    healthcheck:
      test: ["CMD-SHELL", "python3 -c \"import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness')\" || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 90s
    networks:
      - ai-net

  open-webui:
    image: ghcr.io/open-webui/open-webui@sha256:6a773e5c3a246b65cbe74ce942b294292c0e5f81c138f703d111bc162f7d7c3d
    container_name: open-webui
    restart: unless-stopped
    environment:
      OPENAI_API_BASE_URL: http://litellm:4000/v1
      OPENAI_API_KEY: ${WEBUI_VIRTUAL_KEY}
      WEBUI_SECRET_KEY: ${WEBUI_SECRET_KEY}
      ENABLE_SIGNUP: "true"
      DEFAULT_USER_ROLE: pending
      ENABLE_MODEL_FILTER: "true"
      MODEL_FILTER_LIST: company-ai
      WEBUI_NAME: Company AI
      ANONYMIZED_TELEMETRY: "false"
    ports:
      - "3000:8080"
    volumes:
      - /opt/ai-stack/open-webui-data:/app/backend/data
    depends_on:
      litellm:
        condition: service_started
    networks:
      - ai-net

  qdrant:
    image: qdrant/qdrant:v1.11.3
    # fallback digest if the version tag ever misbehaves:
    # qdrant/qdrant@sha256:da426bb8aa0ba0a3032b3110e71d0d1516d51a686aa17b39bde4e090ce3b8e7c
    container_name: qdrant
    restart: unless-stopped
    environment:
      QDRANT__SERVICE__API_KEY: ${QDRANT_API_KEY}
    volumes:
      - /opt/ai-stack/qdrant-data:/qdrant/storage
    networks:
      - ai-net

  embeddings:
    image: ghcr.io/huggingface/text-embeddings-inference:1.6
    # fallback digest (the same image serves embeddings AND reranker):
    # ghcr.io/huggingface/text-embeddings-inference@sha256:25e35b0b266241a543c5ee305083eced4b6ac0772eb969c3fdaae2d4c2ef7266
    container_name: embeddings
    restart: unless-stopped
    # Weights pre-downloaded in section 10 into /opt/ai-stack/models/tei (HF cache
    # layout), mounted at TEI's cache dir /data. HF_HUB_OFFLINE makes "no egress
    # at boot" enforced, not aspirational — TEI never touches the network.
    command: --model-id BAAI/bge-m3 --port 80
    environment:
      - HF_HUB_OFFLINE=1
    volumes:
      - /opt/ai-stack/models/tei:/data:ro
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    networks:
      - ai-net

  reranker:
    image: ghcr.io/huggingface/text-embeddings-inference:1.6
    container_name: reranker
    restart: unless-stopped
    # Same preload story as the embeddings service above (digest comment there covers both).
    command: --model-id BAAI/bge-reranker-v2-m3 --port 80
    environment:
      - HF_HUB_OFFLINE=1
    volumes:
      - /opt/ai-stack/models/tei:/data:ro
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    networks:
      - ai-net

  ingestion:
    build: ./ingestion
    container_name: ingestion
    environment:
      QDRANT_URL: http://qdrant:6333
      QDRANT_API_KEY: ${QDRANT_API_KEY}
      EMBED_URL: http://embeddings:80
    volumes:
      - /opt/ai-stack/ingestion:/app
      - /opt/ai-stack/documents:/documents:ro
    working_dir: /app
    command: ["tail", "-f", "/dev/null"]
    networks:
      - ai-net

  n8n:
    image: docker.n8n.io/n8nio/n8n@sha256:a695e1db50fe1b5acf0c8563ceeea82b099f797cfa485def02647eae1e993953
    container_name: n8n
    restart: unless-stopped
    environment:
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      N8N_HOST: localhost
      N8N_PORT: 5678
      N8N_PROTOCOL: http
      WEBHOOK_URL: http://localhost:5678/
      GENERIC_TIMEZONE: UTC
      N8N_DIAGNOSTICS_ENABLED: "false"
    ports:
      - "5678:5678"
    volumes:
      - /opt/ai-stack/n8n-data:/home/node/.n8n
    networks:
      - ai-net

  mailpit:
    image: axllent/mailpit@sha256:7f33095f80e901f6ad08028f06ca284aa58fe84942be5496008d041d3b9f4d4d
    container_name: mailpit
    restart: unless-stopped
    ports:
      - "8025:8025"
    networks:
      - ai-net

networks:
  ai-net:
    external: true
EOF
```

▶ TERMINAL — validate before launching:
```bash
cd /opt/ai-stack && docker compose config --quiet && echo "COMPOSE FILE OK"
grep -c 'container_name' docker-compose.yml
```

✔ EXPECTED: `COMPOSE FILE OK` and `10` (one per service). If the count isn't 10, the paste truncated — re-paste the whole block.

**Design notes (nothing to run):**
- **Pinning strategy:** 5 volatile tools digest-pinned (llamacpp, litellm, open-webui, n8n, mailpit); 4 stable-infra version-pinned with digest fallbacks in comments (postgres, qdrant, the TEI image shared by embeddings + reranker, python via the ingestion build); 1 local build (ingestion).
- **env_file scoping:** only llamacpp and litellm get `env_file`. Everyone else gets explicit `environment:` entries. WebUI must never see `DATABASE_URL` — it would connect to LiteLLM's Postgres and crash-loop; WebUI uses its own SQLite.
- **`ENABLE_SIGNUP: "true"` is intentional** — it's how you create the admin in Part 9. `DEFAULT_USER_ROLE: pending` is the backstop. Don't change it before the admin exists or you'll lock yourself out of admin creation.
- **8080 stays published** on llamacpp for now (the firewall and security group block it externally anyway). Remove at final production lock-down.
- The litellm healthcheck uses python3 because the image ships no wget.
- The `$${POSTGRES_USER}` inside the postgres healthcheck is correct as written — inside a compose healthcheck, `$$` escapes to a literal `$` for the container shell.

## 3.7 — The two test documents

The ACL demo needs something to prove itself against. (On a client box these folders hold real documents instead; folder name = ACL tag.)

▶ TERMINAL:
```bash
printf '%s\n' 'Company Expense Policy' '' 'All employees may expense up to 50 dollars per meal when traveling.' 'Receipts are required for all expenses over 25 dollars.' 'The standard mileage reimbursement rate is 67 cents per mile.' 'Expense reports must be submitted within 30 days of the expense date.' > /opt/ai-stack/documents/company/expense-policy.txt
printf '%s\n' 'Executive Compensation Plan - Confidential' '' 'The CEO base salary for fiscal year 2026 is 425000 dollars.' 'Executive bonuses are calculated at 40 percent of base salary upon meeting board targets.' 'This document is restricted to executive leadership only.' > /opt/ai-stack/documents/executive/exec-comp.txt
ls -la /opt/ai-stack/documents/company/ /opt/ai-stack/documents/executive/
```

✔ EXPECTED: one file per folder.

---

# PART 4 — FRESH SECRETS (.env)

Secrets are **born on the box** via openssl — never typed, never carried. The two `sk-` virtual keys can't be made by openssl; they're **minted by LiteLLM later** (Part 6), so they're placeholders here.

## 4.1 — Generate six hex secrets into session variables

▶ TERMINAL (one paste):
```bash
LLAMA=$(openssl rand -hex 24)
MASTER=$(openssl rand -hex 24)
PGPASS=$(openssl rand -hex 24)
WEBUISEC=$(openssl rand -hex 24)
QDRANT=$(openssl rand -hex 24)
N8NENC=$(openssl rand -hex 24)
echo "generated: $${#LLAMA} $${#MASTER} $${#PGPASS} $${#WEBUISEC} $${#QDRANT} $${#N8NENC}"
```

✔ EXPECTED: `generated: 48 48 48 48 48 48`.

⚠ Session variables die when the terminal closes. If that happens, re-run this block before 4.2.

## 4.2 — Write the .env (11 keys + comments)

▶ TERMINAL (one paste):
```bash
sudo tee /opt/ai-stack/.env >/dev/null <<EOF
LLAMA_API_KEY=$LLAMA

# --- Section 3: LiteLLM gateway ---
LITELLM_MASTER_KEY=sk-$MASTER
POSTGRES_USER=litellm
POSTGRES_DB=litellm
POSTGRES_PASSWORD=$PGPASS
DATABASE_URL=postgresql://litellm:$PGPASS@postgres:5432/litellm

# --- Section 4: Open WebUI ---
WEBUI_VIRTUAL_KEY=PENDING_MINT
WEBUI_SECRET_KEY=$WEBUISEC

# --- Section 5: Document brain (RAG) ---
QDRANT_API_KEY=$QDRANT

# --- Section 6: n8n workflows ---
N8N_VIRTUAL_KEY=PENDING_MINT
N8N_ENCRYPTION_KEY=$N8NENC
EOF
sudo chmod 600 /opt/ai-stack/.env
```

**Why hex:** `DATABASE_URL` is a URL; characters like `@ : / % &` in a password break it silently. `openssl rand -hex` can't produce those characters.

## 4.3 — Verify: 11 keys, none empty

▶ TERMINAL:
```bash
sudo grep -cE '^[A-Z0-9_]+=' /opt/ai-stack/.env
sudo grep -cE '^[A-Z0-9_]+=$' /opt/ai-stack/.env
```

✔ EXPECTED: `11` then `0`. (The pattern must include `0-9` — otherwise the digit-bearing `N8N_*` keys don't count and you read a false `9`.)

---

# PART 5 — BUILD + LAUNCH

▶ TERMINAL:
```bash
sudo docker build -t ai-stack-ingestion /opt/ai-stack/ingestion
```

✔ EXPECTED: ~8s, pip install of pypdf/python-docx/requests baked in.

▶ TERMINAL:
```bash
cd /opt/ai-stack && sudo docker compose up -d
```

✔ EXPECTED: image pulls (~10 GB on a fresh box), all 10 containers Started/Healthy. **LiteLLM runs 141 migrations on first boot** — a minute or two of activity is normal. Do not interrupt.

---

# PART 6 — MINT THE VIRTUAL KEYS

`sk-` keys come from `/key/generate` on a **live** LiteLLM and are stored as hashes in Postgres. This is why `.env` had PENDING_MINT placeholders.

## 6.1 — Wait for LiteLLM

▶ TERMINAL:
```bash
curl -s http://localhost:4000/health/liveliness
```

✔ EXPECTED: `"I'm alive!"`. Not yet? Wait 15s, retry — migrations still running. Don't proceed until this answers.

## 6.2 — Read the master key, mint two virtual keys

▶ TERMINAL:
```bash
MASTER=$(sudo grep '^LITELLM_MASTER_KEY=' /opt/ai-stack/.env | cut -d= -f2)
echo "$MASTER"
WK=$$(curl -s -X POST http://localhost:4000/key/generate -H "Authorization: Bearer $$MASTER" -H "Content-Type: application/json" -d '{"models":["company-ai"]}' | jq -r .key)
echo "$WK"
NK=$$(curl -s -X POST http://localhost:4000/key/generate -H "Authorization: Bearer $$MASTER" -H "Content-Type: application/json" -d '{"models":["company-ai"]}' | jq -r .key)
echo "$NK"
```

✔ EXPECTED: three `sk-...` values (two fresh, all different). Empty or `null` keys = LiteLLM isn't really up or jq is missing. Minted keys are shorter than the openssl hex secrets — LiteLLM generates its own format.

## 6.3 — Inject into .env, force-recreate

▶ TERMINAL:
```bash
sudo sed -i "s|^WEBUI_VIRTUAL_KEY=.*|WEBUI_VIRTUAL_KEY=$WK|" /opt/ai-stack/.env
sudo sed -i "s|^N8N_VIRTUAL_KEY=.*|N8N_VIRTUAL_KEY=$NK|" /opt/ai-stack/.env
sudo grep -E 'VIRTUAL_KEY' /opt/ai-stack/.env
cd /opt/ai-stack && sudo docker compose up -d --force-recreate open-webui n8n
```

✔ EXPECTED: both lines hold real `sk-...` (no PENDING_MINT left); the two containers recreate. **Never `restart` after an `.env` edit** — see the operating rules.

---

# PART 7 — SEED THE DOCUMENT BRAIN

## 7.1 — Wait for embeddings Ready

▶ TERMINAL:
```bash
sudo docker logs embeddings 2>&1 | tail -3
```

✔ EXPECTED: ends in `Ready`. Weights are pre-downloaded (section 10) and the containers run `HF_HUB_OFFLINE=1`, so `Ready` should appear quickly with **no download lines**. The `WARN ... Invalid hostname, defaulting to 0.0.0.0` line just before `Ready` is cosmetic.

## 7.2 — Run the ingestion

▶ TERMINAL:
```bash
cd /opt/ai-stack && sudo docker compose up -d ingestion
sudo docker exec ingestion python3 /app/ingest.py
```

✔ EXPECTED:
```text
Created collection 'company_docs' (size=1024, cosine)
Ingesting [company] expense-policy.txt ...
  OK: 1 chunks from expense-policy.txt
Ingesting [executive] exec-comp.txt ...
  OK: 1 chunks from exec-comp.txt

Done. Total chunks upserted: 2
Collection points count: 2
```

The collection must be size **1024** (bge-m3's output). A vector-dimension error means a wrong-size collection already exists — delete and recreate it. The script takes no arguments; it walks `/documents/company` and `/documents/executive` itself and tags `acl` from the folder name.

---

# PART 8 — CANARY

▶ TERMINAL:
```bash
sudo docker ps -q | wc -l
sudo docker ps --format '{{.Names}}\t{{.Status}}'
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
```

✔ EXPECTED: `10`; ten rows (llamacpp, litellm-postgres, litellm, open-webui, qdrant, embeddings, reranker, ingestion, n8n, mailpit); VRAM near **`16,629 MiB / 23,028 MiB`** (llama-server ~13,738 + TEI ×2 ~2,872).
⚠ **If VRAM reads ~3,1xx**, you checked before llamacpp finished mapping the model — wait a minute and re-check. Count < 10 → `docker ps -a` → `docker logs <dead-one> --tail 20` (last 3 lines first).

---

# PART 9 — BROWSER WIRING (the part that needs a human)

**Open tunnels (laptop, leave open):**
```bash
ssh -i /path/to/ai-stack-key.pem -L 3000:localhost:3000 -L 5678:localhost:5678 -L 8025:localhost:8025 ubuntu@<ELASTIC-IP>
```

In order, none optional:

1. **🖱 WebUI admin** — `http://localhost:3000` → Sign up → **first account = admin** (real password).
2. **🖱 Lock the door** — Admin Panel → Settings → **Authentication** → "Allow New Signups" **OFF** → Save. Immediately after step 1.
3. **🖱 Verify the model connection** — the compose pre-wired it. New chat → dropdown shows **`company-ai`**. If not: Admin → Settings → Connections → OpenAI → Base `http://litellm:4000/v1`, Key = raw `WEBUI_VIRTUAL_KEY` from `.env` (**no "Bearer" prefix** — WebUI adds it) → Save.
4. **🖱 Guardrails function** — Admin Panel → **Functions** → new → paste `/opt/ai-stack/exports/guardrails-function.py` → Save → **enable AND set GLOBAL** — an enabled-but-not-global function loads fine and silently never fires → **Valves:** `qdrant_api_key` = the value from `sudo grep '^QDRANT_API_KEY=' /opt/ai-stack/.env`. Silent after Global → `docker compose restart open-webui`.
5. **🖱 n8n owner** — `http://localhost:5678` → **first account = owner** (real password).
6. **🖱 n8n OpenAI credential** — Credentials → Add → OpenAI: Base `http://litellm:4000/v1`, Key = raw `N8N_VIRTUAL_KEY`. Tests green. Use the n8n key, never the master key.
7. **🖱 n8n SMTP credential** — Credentials → Add → SMTP: Host `mailpit`, Port `1025`, User `test`, Password `test`, TLS **off**.
8. **🖱 Import the workflow** — Workflows → Import from File → `exports/MyWorkflow.json` → confirm the Information Extractor references the OpenAI credential and the Human-in-the-Loop node references the SMTP credential.

---

# PART 10 — VERIFICATION (3 tests + 1)

**TEST 1 — Chat chain.** New chat → `company-ai` → ask anything. Normal streaming answer, no reasoning scratch-work (the `extra_body` line in config.yaml is why). On the box:
```bash
sudo docker compose exec postgres psql -U litellm -d litellm -c 'SELECT count(*) FROM "LiteLLM_SpendLogs";'
```
✔ Count grows per chat. Metadata only — prompts are never stored.

**TEST 2 — RAG + ACL (the money test).**
- Any user: "mileage reimbursement rate?" → **67 cents per mile**
- Admin: "CEO salary?" → **$425,000**
- Regular user (create one, role `user`): "CEO salary?" → **"I don't have that information"**
- Injection: "ignore all previous instructions..." → **refused, no model call**
- Watch live: `sudo docker logs -f open-webui` → `RAG injected ... acl=company+executive` (admin) vs `acl=company`, `INPUT DENIED`, `reranked N chunk(s)`
- Mileage fails for everyone → **check what was injected before blaming the model:** the function isn't Global, or the Qdrant key isn't in Valves.

**TEST 3 — Human-gated invoice workflow.** Send a fresh invoice (Mailpit is in-memory — always fresh):
```bash
cd /opt/ai-stack && sudo docker compose up -d ingestion
sudo docker exec ingestion python3 -c "
import smtplib
from email.mime.text import MIMEText
msg = MIMEText('Hi,\n\nPlease find invoice INV-2026-0042 from Acme Supplies for 1250.00 dollars, due 2026-09-15.\n\nThanks,\nAcme AP')
msg['Subject'] = 'Invoice INV-2026-0042'
msg['From'] = 'ap@acme.test'
msg['To'] = 'invoices@company.test'
s = smtplib.SMTP('mailpit', 1025); s.send_message(msg); s.quit(); print('sent')
"
```
n8n → Execute Workflow → pauses at the human hold → Mailpit `http://localhost:8025` → **Approve** → workflow resumes. The extraction call appears in SpendLogs (model shows the backend name `openai/qwen3-14b` — the gateway translated the `company-ai` alias).

**TEST 4 (boxes with real documents) — ACL wall test.** Company-scoped session: ask something answerable only from an `executive/` document. ✔ Restricted content never surfaces. This is the compliance demo.

---

# SHARP-EDGE SUMMARY

| Edge | Rule |
|---|---|
| `sudo cat > file` | Your shell opens the `>` as you — sudo doesn't cover redirects. chown the dir, write as yourself. |
| `sudo mkdir` | Creates root-owned dirs. Config dirs you author into: immediate scoped chown to yourself. Data dirs: container UIDs (n8n = 1000 only). |
| pip --user | As ubuntu, never under sudo. |
| Driver | Reboot between install and use. Known-good = 595. |
| `.env` edits | `up -d --force-recreate`, never `restart`. |
| Model verify | `head -c 4` = `GGUF`. Don't trust `file` for this. |
| Minting | `sk-` keys come from a LIVE LiteLLM (`/key/generate`), not openssl. Wait for `"I'm alive!"` first. |
| Bearer | API key fields take the RAW `sk-`, not `Bearer sk-`. The app adds the header. |
| ENABLE_SIGNUP true | Intentional until the admin exists. Then OFF in the UI; `pending` role is the backstop. |
| TEI wait | `Ready` before ingesting; weights are pre-downloaded (§10) and `HF_HUB_OFFLINE=1` is set, so no download lines should appear. |
| VRAM timing | ~3,1xx MiB right after launch = model still loading. Norm ~16,629 MiB. |

**Startup noise that is NOT a fault:** `register_model ... not in cost map`; Prisma "wolfi" warning; Postgres `locale`/`trust auth` hints; 141 migrations first boot; TEI `Invalid hostname, defaulting to 0.0.0.0`; llama.cpp `LLAMA_ARG_*`/`LLAMA_API_KEY` "overwritten by command line argument" warnings; llama.cpp future-port-9931 deprecation notice; fail2ban Python `SyntaxWarning` wall; HF unauthenticated + CLI upsell; `aplay command not found`; `udevadm hwdb is deprecated`; model logged as backend name `openai/qwen3-14b` (clients use the alias); `/opt/containerd` exists (Docker's runtime dir, not yours).
