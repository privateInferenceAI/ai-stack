# Adding Whisper (speaches) to the stack — DRAFT RUNBOOK

**Status: UNVERIFIED — run this on the box, report results, then it merges into the
main guides (scripted-build / manual-build / AGENTS.md). Tracked in issue #17.**

Adds **speaches** (OpenAI-compatible speech-to-text, faster-whisper) as container
**#11**, following stack conventions: model pre-downloaded at build time (no egress
at boot), `HF_HUB_OFFLINE=1`, internal-only on `ai-net` (no published port),
digest-pinned image, GPU reserved.

Facts verified 2026-09-15 against speaches.ai docs + GHCR:
- Image `ghcr.io/speaches-ai/speaches`, tag `0.8.3-cuda` (latest stable; per-tag digests exist).
- Container runs as **UID 1000** (cache dir needs matching ownership — like n8n-data).
- Models download **explicitly** (via `PRELOAD_MODELS` or `POST /v1/models/{id}`),
  not on first request. Cache path in container: `/home/ubuntu/.cache/huggingface/hub`.
- `/v1/audio/transcriptions` is OpenAI-compatible; `/health` exists (curl in image).
- Telemetry is disabled in the image by default. STT endpoint needs **no** API key
  unless `API_KEY` is set (WebUI still wants a non-empty string in the key field).

## 0. VRAM budget (pick your model first)

| Box | Current norm | + large-v3 fp16 (~5 GB) | + distil-large-v3 (~2.5–3 GB) | + large-v3 int8 (~3 GB) |
|---|---|---|---|---|
| g6e.2xlarge (L40S 48 GB, 32B stack ~31–33 GB) | ~31–33 GB | **~36–38 GB ✅ recommended** | ~34–36 GB ✅ | ~34–36 GB ✅ |
| g5.2xlarge (A10G 24 GB, 14B stack ~16.6 GB) | ~16.6 GB | ~21.6 GB ⚠ over watch line | **~19.6 GB ✅ recommended** | ~19.6 GB ✅ |

This runbook defaults to **large-v3 float16** (the 48 GB box). For the 24 GB box,
substitute `Systran/faster-distil-whisper-large-v3` everywhere (or keep large-v3 and
set `WHISPER__COMPUTE_TYPE: int8`). Distil is ~2× faster, slightly less accurate.

## 1. Pre-download the model (as ubuntu, no sudo)

```bash
HF_HUB_CACHE=/opt/ai-stack/models/speaches ~/.local/bin/hf download Systran/faster-whisper-large-v3
sudo chown -R 1000:1000 /opt/ai-stack/models/speaches   # container runs as UID 1000
```

✔ EXPECTED: `/opt/ai-stack/models/speaches/models--Systran--faster-whisper-large-v3/`
(~3.1 GB). For distil: same command with `Systran/faster-distil-whisper-large-v3` (~1.5 GB).

## 2. Pin the image digest

```bash
docker buildx imagetools inspect ghcr.io/speaches-ai/speaches:0.8.3-cuda --format '{{.Manifest.Digest}}'
```

✔ EXPECTED: `sha256:…` — substitute it in the `image:` line below
(`ghcr.io/speaches-ai/speaches@sha256:…`) and record the tag in a freeze comment.

## 3. Add the compose service

Append to `docker-compose.yml` (same style as the other services), then
`docker compose config --quiet && echo OK`:

```yaml
  speaches:
    # freeze: ghcr.io/speaches-ai/speaches@sha256:<digest from step 2>  (tag: 0.8.3-cuda)
    image: ghcr.io/speaches-ai/speaches@sha256:<digest from step 2>
    container_name: speaches
    restart: unless-stopped
    environment:
      UVICORN_PORT: "8000"
      WHISPER__INFERENCE_DEVICE: cuda
      WHISPER__COMPUTE_TYPE: float16        # int8 on the 24 GB tier
      PRELOAD_MODELS: '["Systran/faster-whisper-large-v3"]'
      STT_MODEL_TTL: "-1"                   # keep loaded on 48 GB; use 300 (idle-unload) on tight VRAM
      HF_HUB_OFFLINE: "1"                   # model pre-downloaded in step 1 — zero egress at boot
      LOG_LEVEL: info
      ENABLE_UI: "false"
    volumes:
      - /opt/ai-stack/models/speaches:/home/ubuntu/.cache/huggingface/hub
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    healthcheck:
      test: ["CMD-SHELL", "curl --fail http://localhost:8000/health || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 60s
    networks:
      - ai-net
```

**Deliberately no `ports:`** — WebUI reaches speaches over `ai-net`; browsers never
talk to it directly (WebUI proxies the STT call server-side).

## 4. Start it and wait for healthy

```bash
cd /opt/ai-stack
sudo docker compose up -d speaches
for i in $(seq 1 24); do
  sudo docker inspect --format '{{.State.Health.Status}}' speaches 2>/dev/null | grep -q healthy && { echo HEALTHY; break; }
  sleep 5
done
sudo docker logs speaches | tail -10
```

✔ EXPECTED: `HEALTHY`, and the log shows the model loaded from the local cache
(**no download lines** — offline proof). `docker ps` now shows 11 containers.

## 5. End-to-end transcription test

```bash
sudo apt install -y espeak-ng
espeak-ng -w /tmp/stt-test.wav "the mileage reimbursement rate is sixty seven cents per mile"
docker cp /tmp/stt-test.wav speaches:/tmp/stt-test.wav
docker exec speaches curl -s \
  -F "file=@/tmp/stt-test.wav" \
  -F "model=Systran/faster-whisper-large-v3" \
  http://localhost:8000/v1/audio/transcriptions
```

✔ EXPECTED: JSON with `"text"` containing `sixty seven cents per mile`.

Also verify the model listing: `docker exec speaches curl -s http://localhost:8000/v1/models`

## 6. Wire Open WebUI

Browser (your SSH tunnel already forwards 3000):
**Admin Panel → Settings → Audio** → Speech-to-Text:
- Engine: **OpenAI**
- API Base URL: `http://speaches:8000/v1`   *(the `/v1` is required)*
- API Key: `sk-local`  *(any non-empty string — no key is set on the server)*
- Model: `Systran/faster-whisper-large-v3`  *(exact repo id; `whisper-1` alias also works)*
- Save.

✔ TEST: new chat → microphone icon → dictate a sentence → text appears correctly.

## 7. Confirm VRAM

```bash
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
```

✔ EXPECTED (48 GB box): roughly **+5 GB** over your previous norm (~36–38 / 49,140 MiB).

## 8. If anything's wrong — rollback

```bash
sudo docker compose stop speaches && sudo docker compose rm -f speaches
# remove the speaches block from docker-compose.yml, then:
sudo rm -rf /opt/ai-stack/models/speaches
```

## Notes / gotchas

- **Cache ownership is the classic failure**: permission errors in the speaches log
  → you skipped the `chown 1000:1000` in step 1.
- **"model not found" on first transcription** → preload didn't happen (check logs);
  with `HF_HUB_OFFLINE=1` it can only mean the cache dir isn't mounted/populated.
- **`STT_MODEL_TTL: "-1"`** keeps the model resident (~5 GB always). On tight-VRAM
  boxes use `300` — it unloads after 5 min idle and reloads on demand (adds a few
  seconds to the first transcription after idle).
- Future, not in scope today: SSE streaming transcription; the OpenAI-compatible
  **Realtime WebSocket API** (voice conversations — point its
  `CHAT_COMPLETION_BASE_URL` at LiteLLM); n8n transcription nodes via HTTP request;
  TTS (`/v1/audio/speech`).

## After it works — merge checklist (docs team)

- [ ] compose block into `docker-compose.yml` (digest-pinned + freeze comment) → `check-doc-sync.py --write` for the manual-build embed
- [ ] scripted-build.md + manual-build.md sections (model download in phase1b/§10 pattern; Stage 3/Part 9 audio wiring)
- [ ] backup-restore.md: speaches model cache is re-downloadable — confirm excluded like the GGUF/TEI cache
- [ ] AGENTS.md: service table row + container count 10 → 11
- [ ] phase1b §5: speaches model pre-download alongside GGUF + TEI
- [ ] upstream-watch.json: add speaches-ai/speaches component
- [ ] close issue #17
