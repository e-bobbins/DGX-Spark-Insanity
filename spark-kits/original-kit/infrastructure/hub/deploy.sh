#!/usr/bin/env bash
# hub/deploy.sh - Deploy the Hub node (LiteLLM + Postgres)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# --- Configuration (Can be overridden by .env file) ---
HUB_LAN_IP="${HUB_LAN_IP:-10.0.0.30}"
HUB_LAN_MASK="${HUB_LAN_MASK:-24}"
LITELM_PORT="${LITELM_PORT:-4000}"

echo ">>> Deploying Hub Node (LiteLLM + Postgres)"

# 1. Create Service User
if ! id -u llm-svc &>/dev/null; then
    echo "[+] Creating non-root service user: llm-svc"
    sudo adduser --disabled-password --gecos "" llm-svc
fi
export UID=$(id -u llm-svc)
export GID=$(id -g llm-svc)

# 2. Setup Firewall (Allow only specific LAN range, block internet)
echo "[+] Configuring ufw for Hub..."
sudo ufw default deny incoming
sudo ufw default deny outgoing
sudo ufw allow from 10.0.0.0/24 comment 'Hub LAN Access'
sudo ufw enable

# 3. Prepare Environment File
if [ ! -f "${ENV_FILE}" ]; then
    echo "[+] Creating .env file for secrets..."
    cat > "${ENV_FILE}" << EOF
DB_PASSWORD=$(openssl rand -base64 32)
LITELM_MASTER_KEY=$(openssl rand -hex 32)
DATABASE_URL=postgresql://litellm:${DB_PASSWORD}:@localhost:5432/litellm
EOF
    chmod 600 "${ENV_FILE}"
fi

# 4. Deploy with Docker Compose
echo "[+] Starting Hub services..."
cd "${SCRIPT_DIR}"
docker compose --env-file="${ENV_FILE}" up -d --remove-orphans

echo ">> Hub is ready. LiteLLM accessible at http://localhost:${LITELM_PORT}/v1"
