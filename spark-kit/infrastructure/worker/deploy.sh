#!/usr/bin/env bash
# worker/deploy.sh - Deploy a single vLLM worker node
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

# 1. Create Service User
if ! id -u llm-svc &>/dev/null; then
    echo "[+] Creating non-root service user: llm-svc"
    sudo adduser --disabled-password --gecos "" llm-svc
fi
export UID=$(id -u llm-svc)
export GID=$(id -g llm-svc)

# 2. Setup Firewall (Strictly block all inbound/outbound except known LAN)
echo "[+] Configuring ufw for Worker..."
sudo ufw default deny incoming
sudo ufw default deny outgoing
sudo ufw allow from ${HUB_LAN_IP}/${LAN_MASK} comment 'Worker Hub Access'
sudo ufw enable

# 3. Prepare Model Cache (If NFS is available)
NFS_DIR="/mnt/shared-models"
if [ -d "${NFS_DIR}" ] && ! mountpoint -q "${NFS_DIR}"; then
    echo "[+] Mounting shared model cache..."
    sudo mount -t nfs ${HUB_LAN_IP}:${NFS_DIR} ${NFS_DIR}
fi

# 4. Generate .env for vLLM API Key (only if missing)
if [ ! -f "${ENV_FILE}" ]; then
    echo "[+] Generating vllm.env for secrets..."
    cat > "${ENV_FILE}" << EOF
VLLM_API_KEY=$(openssl rand -hex 32)
APP_HOST=${HUB_LAN_IP}
APP_PORT=8000
EOF
    chmod 600 "${ENV_FILE}"
fi

# 5. Ensure Image is Present
if ! docker image inspect vllm/vllm-openai:nightly &>/dev/null; then
    echo "[+] Pulling vLLM nightly image..."
    docker pull vllm/vllm-openai:nightly
fi

# 6. Start vLLM Container
echo "[+] Starting vLLM container..."
docker run -d \
    --name qwen36-worker \
    --network host \
    --user ${UID}:${GID} \
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
