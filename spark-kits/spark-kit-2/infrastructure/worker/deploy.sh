#!/usr/bin/env bash
# worker/deploy.sh - Deploy a single vLLM worker node
# Non-Root Deployment: All operations work as regular user, no sudo required
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/vllm.env"

# --- Configuration (Can be overridden by env vars) ---
MODEL_NAME="${MODEL_NAME:-nvidia/Qwen3.6-35B-A3B-NVFP4}"
HUB_LAN_IP="${HUB_LAN_IP:-10.0.0.30}"
LAN_MASK="${LAN_MASK:-24}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-0.4}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-6}"

echo ">>> Deploying Worker Node (vLLM: ${MODEL_NAME})"
echo "[!] Running in non-sudo mode - all operations as regular user"

# 1. Create Service User (skip - run containers without --user flag)
echo "[!] Skipping service user creation - running as current host UID=${UID}, GID=${GID}"
export UID=${UID:-$(id -u)}
export GID=${GID:-$(id -g)}

# 2. Setup Firewall (skip ufw - document manual setup)
echo "[!] Skipping ufw firewall configuration (requires root)"
echo "[+] Documented in security.md: configure host firewall manually for worker network isolation"
echo "[+] Alternative: rely on --network host container isolation + host firewall"

# 3. Prepare Model Cache (If NFS is available - skip mount as non-root)
NFS_DIR="/mnt/shared-models"
if [ -d "${NFS_DIR}" ] && ! mountpoint -q "${NFS_DIR}"; then
    echo "[!] NFS mount skipped - requires root permissions"
    echo "[+] Model cache unavailable; worker will download models independently"
else
    echo "[+] NFS mount already exists or not needed"
fi

# 4. Generate .env for vLLM API Key (only if missing)
if [ ! -f "${ENV_FILE}" ]; then
    echo "[+] Generating vllm.env for secrets..."
    VLLM_API_KEY_VALUE="$(openssl rand -hex 32)"
    cat > "${ENV_FILE}" << EOF
VLLM_API_KEY=${VLLM_API_KEY_VALUE}
APP_HOST=${HUB_LAN_IP}
APP_PORT=8000
EOF
    chmod 600 "${ENV_FILE}"
else
    echo "[+] vllm.env already exists"
fi

# 5. Ensure Image is Present (docker pull doesn't require sudo)
if ! docker image inspect vllm/vllm-openai:nightly &>/dev/null; then
    echo "[+] Pulling vLLM nightly image..."
    docker pull vllm/vllm-openai:nightly
fi

# 6. Start vLLM Container (no sudo required - works as regular user)
echo "[+] Starting vLLM container..."
docker run -d \
    --name qwen36-worker \
    --network host \
    --security-opt=no-new-privileges \
    # Note: no --user flag — the container runs as the image default user (root)
    # pending on-node validation; --security-opt=no-new-privileges is applied above.
    # Alternative: use Docker-in-Docker or Podman with seccomp profiles if root access available
    --env-file "${ENV_FILE}" \
    --env HF_HUB_CACHE=/mnt/shared-models \
    --gpus all \
    vllm/vllm-openai:nightly \
    ${MODEL_NAME} \
        --host 0.0.0.0 \
        --port 8000 \
        --max-model-len 262144 \
        --gpu-memory-utilization ${GPU_MEM_UTIL} \
        --max-num-seqs ${MAX_NUM_SEQS} \
        --reasoning-parser qwen3 \
        --tool-call-parser qwen3_xml \
        --enable-auto-tool-choice \
        --trust-remote-code

echo ">> Worker is ready. Model: ${MODEL_NAME} on http://localhost:8000"
echo ""
echo "--- Deployment Complete ---"
echo "Manual firewall setup (optional for worker isolation):"
echo "  # Allow only Hub subnet to reach worker ports:"
echo "  sudo ufw allow from ${HUB_LAN_IP}/${LAN_MASK} to any port 8000 comment 'Worker Hub Access'"
