#!/usr/bin/env bash
# hub/deploy.sh - Deploy the Hub node (LiteLLM + Postgres)
# Non-Root Deployment: All operations work as regular user, no sudo required
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# --- Configuration (Can be overridden by .env file) ---
HUB_LAN_IP="${HUB_LAN_IP:-10.0.0.30}"
HUB_LAN_MASK="${HUB_LAN_MASK:-24}"
LITELM_PORT="${LITELM_PORT:-4000}"

echo ">>> Deploying Hub Node (LiteLLM + Postgres)"
echo "[!] Running in non-sudo mode - all operations as regular user"

# 1. Create Service User (create without sudo)
echo "[+] Creating non-root service user: llm-svc (non-sudo method)"
if ! id -u llm-svc &>/dev/null; then
    # Create user group and adduser without sudo (may fail if no write to /etc/passwd)
    # Alternative for regular users: skip user creation and run containers as root
    # Inside container, drop privileges via Docker --security-opt=no-new-privileges
    echo "[!] Skipping user creation - running as current user UID=${UID}, GID=${GID}"
else
    echo "[+] Service user 'llm-svc' already exists"
fi

export UID=${UID:-$(id -u)}
export GID=${GID:-$(id -g)}

# 2. Setup Firewall (skip ufw - document manual setup for non-root)
echo "[!] Skipping ufw firewall configuration (requires root)"
echo "[+] Documented in security.md: configure host firewall manually for port 4000"
echo "[+] Alternative: use Docker network isolation instead of host firewall"

# 3. Prepare Environment File
if [ ! -f "${ENV_FILE}" ]; then
    echo "[+] Creating .env file for secrets..."
    DB_PASSWORD="$(openssl rand -base64 32)"
    LITELLM_MASTER_KEY="$(openssl rand -hex 32)"
    cat > "${ENV_FILE}" << EOF
DB_PASSWORD=${DB_PASSWORD}
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
DATABASE_URL=postgresql://litellm:${DB_PASSWORD}@localhost:5432/litellm
EOF
    chmod 600 "${ENV_FILE}"
else
    echo "[+] .env file already exists"
fi

# 4. Deploy with Docker Compose
echo "[+] Starting Hub services..."
cd "${SCRIPT_DIR}"
docker compose --env-file="${ENV_FILE}" up -d --remove-orphans

echo ">> Hub is ready. LiteLLM accessible at http://localhost:\${LITELM_PORT}/v1"
echo ""
echo "--- Deployment Complete ---"
echo "Manual firewall setup (optional for non-root):"
echo "  # Allow port 4000 on host firewall:"
echo "  sudo ufw allow 4000/tcp"
echo "  sudo ufw enable"
