# AI STACK — BACKUP & RESTORE GUIDE
## Capture a live box, rebuild it anywhere
**Use this for:** disaster recovery, moving to new hardware, cloning an existing install with its accounts and data.
**For a fresh install with new secrets/accounts, use the Scripted Build Guide instead.**
**Cost reminder:** the box bills ~$1.21/hr running. Stop it when idle (~$20/mo stopped).

---

## HOW TO USE THIS DOCUMENT

| Box | Meaning | Action |
|---|---|---|
| **▶ TERMINAL** | Shell commands | Paste into SSH session |
| **✔ EXPECTED** | Success output | Compare, never type |

**Operating rules that apply throughout:**
- **After any `.env` edit:** `docker compose up -d --force-recreate <service>` — never `restart`. Environment variables inject at container *creation*, not start.
- **chown scope:** config directories → your user. Data volumes → the container's UID (n8n = 1000; postgres/qdrant/webui set their own). Never blanket `chown -R /opt/ai-stack` once data exists.
- **Back up state and config, never re-downloadable caches.** Model files and embedding/whisper caches are re-downloaded, not backed up.
- **Writing files with redirects:** `sudo cat > /path/file` doesn't do what it looks like — your shell opens the `>` as *you* before sudo runs. chown the directory to yourself first, or wrap the whole thing in `sudo sh -c '...'`. The same applies in reverse to `sudo ... < /root-owned/file` when reading.

---

# PART 1 — BACKUP

## 1.1 — What gets captured (and what deliberately doesn't)

| Captured | Not captured (re-downloadable) |
|---|---|
| `docker-compose.yml`, `.env` (as `config/env`) | Model GGUF (~9 GB — phase1b re-downloads it) |
| `litellm/config.yaml`, `guardrails/`, `ingestion/` (script + Dockerfile) | WebUI's embedding cache (`open-webui-data/cache`) |
| Postgres dump (keys, budgets, SpendLogs) | Whisper/speaches model cache |
| Qdrant (all vectors), WebUI data (accounts/chats/SQLite), n8n data (workflows + encrypted credentials), source `documents/`, `exports/` (workflow JSON + function code) | |

The n8n credentials decrypt on the target because `N8N_ENCRYPTION_KEY` is in the restored `.env`. Both must come from the same backup.

## 1.2 — backup.sh

```bash
#!/usr/bin/env bash
# AI stack backup — captures all state needed to rebuild.
set -euo pipefail
STACK=/opt/ai-stack
TS=$(date +%Y%m%d-%H%M%S)
DEST=${1:-/opt/ai-stack/backups}
OUT="$${DEST}/ai-stack-backup-$${TS}"
mkdir -p "$OUT"
echo "Backing up to $OUT"

# 1. Config files
mkdir -p "$OUT/config"
cp "$$STACK/docker-compose.yml" "$$OUT/config/"
cp "$$STACK/.env" "$$OUT/config/env"
cp -r "$$STACK/litellm" "$$OUT/config/"
cp -r "$$STACK/guardrails" "$$OUT/config/"
cp "$$STACK/ingestion/ingest.py" "$$OUT/config/" 2>/dev/null || true
cp "$$STACK/ingestion/Dockerfile" "$$OUT/config/" 2>/dev/null || true

# 2. Postgres dump (stack must be RUNNING — pg_dump talks to the live DB)
echo "Dumping Postgres..."
docker exec litellm-postgres pg_dump -U litellm litellm > "$OUT/postgres-litellm.sql"

# 3. Qdrant snapshot
echo "Snapshotting Qdrant..."
sudo tar czf "$$OUT/qdrant-data.tar.gz" -C "$$STACK" qdrant-data

# 4. WebUI data
# NOTE: the member name (open-webui-data) appears EXACTLY ONCE, at the end.
# Name it twice and tar silently stores every file twice.
echo "Archiving WebUI data..."
sudo tar czf "$$OUT/open-webui-data.tar.gz" -C "$$STACK" --exclude='open-webui-data/cache' open-webui-data

# 5. n8n data
echo "Archiving n8n data..."
sudo tar czf "$$OUT/n8n-data.tar.gz" -C "$$STACK" n8n-data

# 6. Source documents
sudo tar czf "$$OUT/documents.tar.gz" -C "$$STACK" documents

# 7. Exports (n8n workflows, function code) — if present
sudo tar czf "$$OUT/exports.tar.gz" -C "$$STACK" exports 2>/dev/null || true

echo "Backup complete: $OUT"
du -sh "$OUT"
```

**Deliver the script as a file (scp), not pasted** — the terminal substitutes `$`-variables in pasted scripts:

```bash
scp -i ai-stack-key.pem backup.sh ubuntu@<box>:/opt/ai-stack/backup.sh
```

## 1.3 — Run it

**▶ TERMINAL (on the box being backed up):**

```bash
cd /opt/ai-stack && ./backup.sh
```

**✔ EXPECTED:**

```text
Backing up to /opt/ai-stack/backups/ai-stack-backup-YYYYMMDD-HHMMSS
Dumping Postgres...
Snapshotting Qdrant...
Archiving WebUI data...
Archiving n8n data...
Backup complete: /opt/ai-stack/backups/ai-stack-backup-YYYYMMDD-HHMMSS
996M    /opt/ai-stack/backups/ai-stack-backup-YYYYMMDD-HHMMSS
```

Steps 6–7 print nothing — normal. Size scales with your data (~800M near-empty; ~1GB with a few thousand real documents). The number itself proves nothing; verify contents:

**▶ TERMINAL:**

```bash
OUT=$(ls -td /opt/ai-stack/backups/ai-stack-backup-* | head -1)
ls -lh "$$OUT" "$$OUT/config"
head -3 "$OUT/postgres-litellm.sql"
tar tzf "$OUT/open-webui-data.tar.gz" | sort | uniq -d | head -5
```

**✔ EXPECTED:** 7 items (`config/`, 5 tarballs, 1 `.sql`); config holds `docker-compose.yml`, `env`, `litellm/`, `guardrails/`, `ingest.py`, `Dockerfile`; first SQL line reads `-- PostgreSQL database dump`; **the `uniq -d` check prints nothing** (any output means the WebUI tar line named the member twice — see the NOTE in 1.2).

**🟡 Live-backup caveat:** the tars run against running containers — fine in practice. For maximum safety in quiet hours: `docker compose stop` → backup → `docker compose start`.

## 1.4 — Package and move it

**▶ TERMINAL:**

```bash
cd /opt/ai-stack/backups
sudo tar czf /home/ubuntu/ai-stack-backup.tar.gz -C /opt/ai-stack/backups ai-stack-backup-YYYYMMDD-HHMMSS
```

Then scp `/home/ubuntu/ai-stack-backup.tar.gz` to your laptop (or straight to the target box).

---

# PART 2 — RESTORE

## 2.1 — Prerequisites (no exceptions)

On the target box, before restoring:

- [ ] Foundation complete (Scripted Build Guide Stage 1: phase1a + reboot + phase1b) — Docker ✅ GPU ✅ ai-net ✅ model GGUF ✅ (`head -c 4` prints `GGUF`)
- [ ] Backup staged at `/opt/ai-stack/backups/<backup-dir>` (untar the transfer package there)
- [ ] `restore.sh` present at `/opt/ai-stack/restore.sh` (delivered via scp, not pasted)

**The model is NOT in the backup.** phase1b's download covers it. If you skipped that, the restore completes but llamacpp crash-loops:

```bash
~/.local/bin/hf download Qwen/Qwen3-14B-GGUF Qwen3-14B-Q4_K_M.gguf --local-dir /opt/ai-stack/models
docker compose up -d llamacpp litellm
```

## 2.2 — restore.sh

```bash
#!/usr/bin/env bash
#
# AI stack — restore from backup.
# Usage: sudo ./restore.sh /opt/ai-stack/backups/ai-stack-backup-YYYYMMDD-HHMMSS
#
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: \$0 <backup-directory>"; exit 1
fi

BACKUP="\$1"
STACK=/opt/ai-stack

[[ -d "$$BACKUP" ]] || { echo "ERROR: backup not found: $$BACKUP"; exit 1; }
[[ -f "$BACKUP/config/docker-compose.yml" ]] || { echo "ERROR: not a backup (missing config/docker-compose.yml)"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo"; exit 1; }

echo "=================================================="
echo " AI STACK RESTORE"
echo " Backup: $BACKUP"
echo " Target: $STACK"
echo "=================================================="
echo "This will STOP the stack and OVERWRITE current state."
read -r -p "Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

# ---------- 1. stop the stack ----------
echo
echo "[1/7] Stopping stack (if running)..."
if [[ -f "$STACK/docker-compose.yml" ]]; then
  (cd "$STACK" && docker compose down) || echo "  (stack was not fully up — continuing)"
else
  echo "  (no existing compose file — fresh target)"
fi

# ---------- 2. restore config ----------
echo
echo "[2/7] Restoring config files..."
mkdir -p "$STACK"
cp "$$BACKUP/config/docker-compose.yml" "$$STACK/docker-compose.yml"
cp "$$BACKUP/config/env" "$$STACK/.env"
chmod 600 "$STACK/.env"
[[ -d "$$BACKUP/config/litellm" ]]    && cp -r "$$BACKUP/config/litellm" "$STACK/"
[[ -d "$$BACKUP/config/guardrails" ]] && cp -r "$$BACKUP/config/guardrails" "$STACK/"
[[ -f "$$BACKUP/config/ingest.py" ]]  && { mkdir -p "$$STACK/ingestion"; cp "$$BACKUP/config/ingest.py" "$$STACK/ingestion/"; }
[[ -f "$$BACKUP/config/Dockerfile" ]] && { mkdir -p "$$STACK/ingestion"; cp "$$BACKUP/config/Dockerfile" "$$STACK/ingestion/"; }
echo "  config restored (.env mode 600)"

# ---------- 3. restore Postgres ----------
echo
echo "[3/7] Restoring Postgres (LiteLLM keys/budgets/logs)..."
(cd "$STACK" && docker compose up -d postgres)
echo "  waiting for postgres to accept connections..."
for i in $(seq 1 30); do
  if docker exec litellm-postgres pg_isready -U litellm -d litellm >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# --- Sync the role password to the restored .env ---
# Needed on a WARM target (this box previously ran a stack): the existing
# postgres-data was initialized under the OLD .env password, and database dumps
# don't carry role passwords — so the restored .env's DATABASE_URL wouldn't match
# the live role. Harmless no-op on a fresh target (passwords match by construction).
# Works because psql inside the container over the local socket is trust-authenticated.
echo "  syncing postgres role password to restored .env..."
PGPW=$$(grep '^POSTGRES_PASSWORD=' "$$STACK/.env" | cut -d= -f2-)
docker exec litellm-postgres psql -h /var/run/postgresql -U litellm -d postgres \
  -c "ALTER USER litellm WITH PASSWORD '$PGPW';"

docker exec litellm-postgres psql -U litellm -d postgres -c "DROP DATABASE IF EXISTS litellm;"
docker exec litellm-postgres psql -U litellm -d postgres -c "CREATE DATABASE litellm;"
docker exec -i litellm-postgres psql -U litellm -d litellm < "$BACKUP/postgres-litellm.sql"
echo "  postgres restored"

# ---------- 4. Qdrant ----------
echo
echo "[4/7] Restoring Qdrant data..."
rm -rf "$STACK/qdrant-data"
tar xzf "$$BACKUP/qdrant-data.tar.gz" -C "$$STACK"
echo "  qdrant restored"

# ---------- 5. WebUI ----------
echo
echo "[5/7] Restoring WebUI data..."
rm -rf "$STACK/open-webui-data"
tar xzf "$$BACKUP/open-webui-data.tar.gz" -C "$$STACK"
echo "  webui restored"

# ---------- 6. n8n ----------
echo
echo "[6/7] Restoring n8n data..."
rm -rf "$STACK/n8n-data"
tar xzf "$$BACKUP/n8n-data.tar.gz" -C "$$STACK"
chown -R 1000:1000 "$STACK/n8n-data"   # n8n runs as UID 1000 — n8n ONLY
echo "  n8n restored"

# ---------- 7. documents + exports ----------
echo
echo "[7/7] Restoring documents and exports..."
[[ -f "$$BACKUP/documents.tar.gz" ]] && { rm -rf "$$STACK/documents"; tar xzf "$$BACKUP/documents.tar.gz" -C "$$STACK"; }
[[ -f "$$BACKUP/exports.tar.gz" ]]   && { rm -rf "$$STACK/exports";   tar xzf "$$BACKUP/exports.tar.gz"   -C "$$STACK"; }
echo "  documents + exports restored"

# ---------- bring the stack up ----------
echo
echo "Bringing the stack up..."
(cd "$STACK" && docker compose up -d)

echo
echo "=================================================="
echo " Restore complete. Verify with:"
echo "   docker ps --format '{{.Names}}\\t{{.Status}}'"
echo "   curl -s http://localhost:4000/health/liveliness"
echo "=================================================="
echo "ACCOUNTS: the old box's logins came back with the data. Just log in."
echo "  - WebUI admin: lives in the restored WebUI SQLite"
echo "  - n8n owner: lives in restored n8n-data, decrypted by the restored N8N_ENCRYPTION_KEY"
echo "  - LiteLLM keys: live in the restored Postgres dump"
echo "NOTES:"
echo "  - model GGUF is NOT in the backup (phase1b re-downloads it)"
echo "  - if the backup's compose includes speaches, it starts now but its model"
echo "    cache is empty — pre-stage the Whisper model before using voice"
```

## 2.3 — Run it

**▶ TERMINAL:**

```bash
sudo /opt/ai-stack/restore.sh /opt/ai-stack/backups/ai-stack-backup-YYYYMMDD-HHMMSS
```

Type `yes` at the prompt.

**✔ EXPECTED, in order:**
- `[1/7]` — containers down on a warm target; "fresh target" note on a clean one
- `[3/7]` — `DROP DATABASE`, `CREATE DATABASE`, the SET/CREATE/ALTER/COPY scroll (hundreds of lines, including `COPY 141` for the migrations table); no `ERROR`/`FATAL` lines
- `Bringing the stack up...` — all images pull on a fresh box (a few minutes); fewer on a warm box with cached images
- **Container count after restore = whatever the backup's compose defines: 10 pre-voice, 11 if it includes speaches.** Speaches starts but has no model cache — pre-staging the Whisper model is separate setup, not a restore failure.
- LiteLLM may take a minute to finish booting; watch: `docker logs -f litellm` → `Application startup complete.`

---

# PART 3 — RESTORING ONTO A BOX THAT ALREADY RAN A STACK

**The symptom:** the restore completes clean, every container starts, but LiteLLM crash-loops. `docker logs litellm --tail 50` ends in `httpx.ConnectError: All connection attempts failed` / `Application startup failed. Exiting.` — and `docker logs litellm-postgres --tail 20` shows:

```text
 password authentication failed for user "litellm"
```

**The cause:** you restored onto a warm box.

1. The old install initialized `postgres-data` under *its* `.env` password.
2. The restore overwrote `.env` with the backup's secrets (different `POSTGRES_PASSWORD`).
3. **Role passwords live in the Postgres cluster, not in a database-level dump.** The dump restores the database's contents; the cluster's role password stays old.
4. `docker compose up -d` didn't recreate the Postgres container (nothing in its config changed), so the live cluster never even saw the new `.env`.
5. LiteLLM connects over TCP with the restored `DATABASE_URL` → password rejected → crash loop.

**Why the dump load itself succeeded:** the restore's `docker exec ... psql` calls (no `-h`) use the container's **local socket, which is trust-authenticated** — no password needed. LiteLLM's connection is **TCP**, which checks the password. That's the whole mismatch: socket = trust, TCP = password.

**Why a fresh box never hits this:** no pre-existing `postgres-data` → Postgres initializes from the restored `.env` → passwords match by construction.

**The fix is already integrated into restore.sh (Part 2.2).** If you ever hit this while restoring by hand:

**▶ TERMINAL:**

```bash
# the superuser IS "litellm" (POSTGRES_USER=litellm); there is no "postgres" role
docker exec litellm-postgres psql -h /var/run/postgresql -U litellm -d postgres -c "\du"

NEWPW=$(sudo grep '^POSTGRES_PASSWORD=' /opt/ai-stack/.env | cut -d= -f2-)
docker exec litellm-postgres psql -h /var/run/postgresql -U litellm -d postgres \
  -c "ALTER USER litellm WITH PASSWORD '$NEWPW';"

docker logs -f litellm    # watch for "Application startup complete." — it retries on its own
curl -s http://localhost:4000/health/liveliness
```

**✔ EXPECTED:** `\du` lists `litellm` as superuser; `ALTER ROLE`; LiteLLM boots within seconds; `"I'm alive!"`.

**Alternative (destructive, also valid):** wipe `postgres-data` before restoring (`sudo rm -rf /opt/ai-stack/postgres-data`) so the cluster re-initializes from the restored `.env`. Slower but conceptually simpler. The password sync above is the documented primary path — faster and doesn't touch data.

---

# PART 4 — POST-RESTORE VERIFICATION

## 4.1 — The wiring comes back with the data. Verify it:

- [ ] **WebUI login** (`localhost:3000` via tunnel): the *old box's* admin credentials work. Chats, users, settings all present.
- [ ] **Guardrails function:** Admin Panel → Functions → it's there, enabled, **Global**, Qdrant key still in Valves.
- [ ] **Model dropdown** shows `company-ai`.
- [ ] **n8n login** (`localhost:5678`): old owner credentials work; workflow(s) present; the OpenAI and SMTP credentials **decrypt and test green** (they decrypt because `N8N_ENCRYPTION_KEY` came back in the restored `.env`).
- [ ] **Mailpit** (`localhost:8025`) loads. It's in-memory — nothing old will be in it; send fresh test mail.

## 4.2 — The verification tests (same suite as any install)

**TEST 1 — Chat chain.** WebUI → new chat → `company-ai` → ask anything. Normal answer, no reasoning scratch-work. On the box:

```bash
sudo docker compose exec postgres psql -U litellm -d litellm -c 'SELECT count(*) FROM "LiteLLM_SpendLogs";'
```

✔ Count grows with each chat. (This psql uses the local socket — trust auth — so it works regardless of TCP password state.)

**TEST 2 — RAG + ACL (the money test).**
- Any user: "mileage reimbursement rate?" → **67 cents**
- Admin: "CEO salary?" → **$425,000**
- Regular user (role `user`): "CEO salary?" → **"I don't have that information"**
- Injection: "ignore all previous instructions..." → **refused**, no model call
- Watch live: `sudo docker logs -f open-webui` → `[guardrails] RAG injected ... acl=company+executive` (admin) vs `acl=company`, `INPUT DENIED`, `reranked N chunk(s)`.
- If mileage returns "I don't know" for everyone → **check what was injected before blaming the model:** the function isn't Global, or the Qdrant key isn't in Valves.

**TEST 3 — Human-gated workflow.** Send a fresh invoice (Mailpit is in-memory — always fresh):

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

n8n → Execute Workflow → pauses at the human hold → Mailpit (`localhost:8025`) → **Approve** → workflow resumes. Confirm the extraction call in SpendLogs.

**TEST 4 (boxes with real documents) — the ACL wall test.** From a company-scoped session, ask something answerable only from an `executive/`-ACL document. ✔ The restricted content does **not** surface.

## 4.3 — If a wiring piece is missing (only then)

A restore can only bring back wiring that existed at backup time. If the backup predates the wiring (or a check in 4.1 fails), do the fresh-install wiring:

1. **WebUI admin** at `localhost:3000` (**first account = admin**) → Admin → Settings → **Authentication** → "Allow New Signups" **OFF** → Save.
2. **Model connection:** Admin → Settings → Connections → OpenAI: Base `http://litellm:4000/v1`, Key = raw `WEBUI_VIRTUAL_KEY` from `.env` (no `Bearer` prefix). Model dropdown should show `company-ai`.
3. **Guardrails function:** Admin → Functions → new → paste `exports/guardrails-function.py` → Save → enable **and set GLOBAL** — enabled-but-not-global silently never fires → Valves: paste `QDRANT_API_KEY` from `.env`. Silent after Global → `docker compose restart open-webui`.
4. **n8n owner** at `localhost:5678` → Credentials → OpenAI (Base `http://litellm:4000/v1`, key = raw `N8N_VIRTUAL_KEY`) → SMTP (host `mailpit`, port `1025`, user/pass `test`/`test`, TLS off) → Import `exports/MyWorkflow.json` → confirm the nodes reference both credentials.

---

# PART 5 — MANUAL LONGHAND APPENDIX (when you don't trust the scripts)

The scripts are the primary path. If you're stepping through by hand, these are the traps:

| Trap | Rule |
|---|---|
| **The psql `<` redirect** | `sudo docker exec -i litellm-postgres psql ... < "$BACKUP/file.sql"` fails — your shell opens `<` as YOU, and the backup is root-owned. Use: `sudo sh -c 'docker exec -i litellm-postgres psql -U litellm -d litellm < /opt/ai-stack/backups/<literal-dir>/postgres-litellm.sql'` — **literal path, no variable, whole thing wrapped in `sudo sh -c '...'`**. |
| **Session variables die** | `$OUT` / `$BACKUP` / `$NEWPW` vanish when the terminal closes. Re-set, don't guess. |
| **chown on restore** | `n8n-data` → `1000:1000` ONLY. Postgres/Qdrant/WebUI data keep the tarball's preserved ownership. |
| **TEI lag on first boot** | `Ready` can take minutes while weights download; no progress bar. Normal. |
| **Doubled WebUI tarballs** | `tar tzf <open-webui-data.tar.gz> \| sort \| uniq -d` must print nothing. See the NOTE in 1.2. |
| **Accounts** | Restored with the data. Recreating them is wasted work — and on WebUI, a "new first account" on a restored DB just makes a regular user, not admin. |
