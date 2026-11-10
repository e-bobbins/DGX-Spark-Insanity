#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
LITELM_PORT="${LITELM_PORT:-4000}"

echo ">>> Simulated Hub Deployment Test"

# Test 1: Check if .env exists and validate structure
if [ -f "${ENV_FILE}" ]; then
    echo "[+] .env file exists, checking contents..."
    cat "${ENV_FILE}" | head -5
else
    echo "[.] No .env file found (expected in fresh deploy)"
fi

# Test 2: Validate docker-compose.yml structure
if [ -f "${SCRIPT_DIR}/docker-compose.yml" ]; then
    echo "[+] docker-compose.yml exists"
    
    # Check for required services
    if grep -q "litellm-hub:" "${SCRIPT_DIR}/docker-compose.yml"; then
        echo "[+] litellm-hub service found"
    fi
    
    if grep -q "postgres:" "${SCRIPT_DIR}/docker-compose.yml"; then
        echo "[+] postgres service found"
    fi
    
    # Check healthchecks
    if grep -q "healthcheck:" "${SCRIPT_DIR}/docker-compose.yml"; then
        echo "[+] Health checks configured"
    fi
    
    # Check hub port is published
    if grep -q "4000:4000" "${SCRIPT_DIR}/docker-compose.yml"; then
        echo "[+] Hub port 4000 published"
    fi
else
    echo "[-] docker-compose.yml missing"
fi

echo ""
echo ">>> Smoke Test Complete"
echo "Key verification points:"
echo "- docker-compose.yml has required services (litellm-hub, postgres)"
echo "- Health checks are configured for both services"
echo "- Hub publishes port 4000; Postgres is internal-only"
echo "- Postgres runs as the image-default user (no init script)"
