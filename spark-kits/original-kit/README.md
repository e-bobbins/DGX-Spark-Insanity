# Original Kit — Known Working vLLM + LiteLLM Deployment

> **Source**: `spark-kit/` (first iteration in this repo).  
> Verified working on DGX Spark arm64 with CUDA 13.0, running Qwen3.6-35B-A3B-NVFP4 under concurrency.

---

## 1. Directory Layout

```
original-kit/
├── README.md
└── infrastructure/
    ├── hub/
    │   ├── deploy.sh          # One-command Hub deployment (creates user, firewall, env, compose)
    │   ├── docker-compose.yml # Litellm-proxy + postgres stack
    │   ├── config.yaml        # Model routing: openai/nvidia/Qwen3.6-35B-A3B-NVFP4 → localhost:8000/v1
    │   └── init.sh            # Postgres volume chown shim for non-root container
    └── worker/
        ├── deploy.sh          # One-command vLLM deployment (pulls image, runs container)
        └── vllm.env.template  # Template — deploy.sh generates real secrets at first run
```

---

## 2. Docker Images — Use These Exact Ones

| Service | Image | Tag | Status |
|---------|-------|-----|--------|
| LiteLLM | `ghcr.io/berriai/litellm` | `latest` | Working |
| Postgres | `postgres` | `15-alpine` | Working |
| vLLM | `vllm/vllm-openai` | `nightly` | **Working — this is critical** |

### ⚠️ Image That Does NOT Work on This Hardware

| Image | Tag | Problem |
|-------|-----|---------|
| `nvcr.io/nvidia/vllm` | `26.04-py3` or `26.10-py3` | Crashes on restart — arm64/CUDA compatibility issues |

The agent MUST NOT use the `nvcr.io/nvidia/vllm` image. Always use `vllm/vllm-openai:nightly`.

---

## 3. Deployment Order (Must Be Exact)

### Step 0: Stop Conflicting Containers

If any previous deployment is running, clean it first:

```bash
docker stop litellm-proxy litellm-new vllm-Founder qwen36-worker 2>/dev/null || true
docker rm litellm-proxy litellm-new vllm-Founder qwen36-worker 2>/dev/null || true
```

### Step 1: Deploy the Hub (first)

```bash
cd original-kit/infrastructure/hub
sudo ./deploy.sh
```

What deploy.sh does internally:
1. Creates non-root user `llm-svc` (`--disabled-password --gecos ""`)
2. Sets `ufw default deny incoming/outgoing`, allows `10.0.0.0/24` inbound+outbound, enables it
3. Generates `.env` with:
   - `DB_PASSWORD=$(openssl rand -base64 32)`
   - `LITELLM_MASTER_KEY=$(openssl rand -hex 32)`
   - `DATABASE_URL=postgresql://litellm:${DB_PASSWORD}:@localhost:5432/litellm`
4. Runs `docker compose --env-file=.env up -d --remove-orphans`

### Step 2: Deploy the Worker(s)

```bash
cd original-kit/infrastructure/worker
sudo ./deploy.sh
```

What deploy.sh does internally:
1. Creates non-root user `llm-svc` (idempotent check)
2. Sets strict ufw firewall — only allows traffic from Hub subnet (`10.0.0.30/24`)
3. Mounts NFS at `/mnt/shared-models` if available
4. Generates `vllm.env` with:
   - `VLLM_API_KEY=$(openssl rand -hex 32)`
   - `APP_HOST=10.0.0.30` (Hub LAN IP)
   - `APP_PORT=8000`
5. Pulls `vllm/vllm-openai:nightly` if not present
6. Runs the container (see exact docker run below)

---

## 4. vLLM Container — Exact docker Run Command

```bash
docker run -d \
    --name qwen36-worker \
    --network host \
    --user ${UID}:${GID} \
    --env-file "${SCRIPT_DIR}/vllm.env" \
    --gpus all \
    vllm/vllm-openai:nightly \
    nvidia/Qwen3.6-35B-A3B-NVFP4 \
        --host 0.0.0.0 \
        --port 8000 \
        --max-model-len 262144 \
        --gpu-memory-utilization 0.4 \
        --max-num-seqs 6 \
        --reasoning-parser qwen3 \
        --tool-call-parser qwen3_xml \
        --enable-auto-tool-choice \
        --trust-remote-code
```

---

## 5. LiteLLM Config (config.yaml)

```yaml
model_list:
  - model_name: qwen3.6-35b
    litellm_params:
      model: openai/nvidia/Qwen3.6-35B-A3B-NVFP4
      api_base: http://localhost:8000/v1
      api_key: os.environ/VLLM_API_KEY
      reasoning_effort: medium
      litellm_settings:
        model_api_name: openai-completion
        tool_choice: auto
      max_tokens: 8192

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

---

## 6. docker-compose.yml (Hub)

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:15-alpine
    container_name: litellm-postgres
    restart: unless-stopped
    user: "${UID}:${GID}"
    environment:
      POSTGRES_USER: litellm
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: litellm
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./init.sh:/docker-entrypoint-initdb.d/init.sh:ro
    networks:
      - llm-net

  litellm-new:
    image: berriai/litellm:latest
    container_name: litellm-new
    restart: unless-stopped
    user: "${UID}:${GID}"
    command: >
      --config /app/config.yaml
      --port 4000
      --detailed_debug
    volumes:
      - ./config.yaml:/app/config.yaml:ro
    environment:
      DATABASE_URL: postgresql://litellm:${DB_PASSWORD}:@postgres:5432/litellm
    ports:
      - "4000:4000"
    networks:
      llm-net:
        aliases:
          - litellm-service
    depends_on:
      - postgres

volumes:
  pgdata:

networks:
  llm-net:
    driver: bridge
```

---

## 7. Failure Modes & Troubleshooting

### vLLM Container Crashes on Start
- **Cause**: Using `nvcr.io/nvidia/vllm:*` image instead of `vllm/vllm-openai:nightly`
- **Fix**: Always use `vllm/vllm-openai:nightly`. The nvcr.io images have arm64 compatibility issues on this hardware.

### LiteLLM Health Check Failing (unhealthy status)
- **Cause**: Postgres not yet ready when Litellm-proxy starts, or config.yaml path issue
- **Fix**: `docker logs litellm-new` to check startup errors; ensure `--config /app/config.yaml` volume is mounted read-only

### No Response on Port 4000
- Ensure Hub deployed first (postgreSQL must be healthy)
- Check `ufw status` — the firewall allows only `10.0.0.0/24`, not arbitrary IPs
- Verify config.yaml `api_base` points to correct vLLM endpoint

### GPU Memory OOM
- `--gpu-memory-utilization 0.4` is critical — do NOT increase it. At higher values, concurrency fails with Qwen3.6-35B-A3B-NVFP4 on DGX Spark hardware.

### NFS Model Cache Not Mounting
- Worker deploy.sh checks if `/mnt/shared-models` exists and mounts NFS from Hub
- If no NFS is available, models will download fresh each run (slower)
- This does not break deployment — only affects performance

---

## 8. API Endpoints

| Service | URL | Purpose |
|---------|-----|---------|
| LiteLLM (Chat Completions) | `http://<HUB_LAN_IP>:4000/v1/chat/completions` | Agent-facing endpoint, routes to vLLM |
| vLLM (OpenAI Compatible) | `http://<WORKER_IP>:8000/v1/chat/completions` | Direct access, bypasses LiteLLM |

---

## 9. Notes for Automation Agents

- **User**: Always creates `llm-svc` if it doesn't exist — the deploy scripts check `id -u llm-svc`
- **Firewall**: ufw rules are strict. Do NOT run from outside `10.0.0.0/24` or connections will be blocked
- **UID/GID**: Both containers use `${UID}:${GID}` from the service user — do NOT hardcode 1000:1000
- **vllm.env is generated per-run**: deploy.sh creates it only if missing. If re-running, delete old vllm.env first to get a new API key
- **Secrets**: `.env` in hub/ and `vllm.env` in worker/ contain real secrets — chmod 600, never commit real values
- **Model download**: First run downloads Qwen3.6-35B from HuggingFace (~35GB). Subsequent runs use cached weights under `/mnt/shared-models`
