#!/usr/bin/env bash
# deploy.sh - Unified deployment script for DGX Spark LLM Stack (kit-3)
#
# This single script deploys the stack on any Spark node.
# It supports both sudo (secure) and non-sudo (degraded security) modes.
#
# Usage (Secure - Recommended):
#   sudo ./deploy.sh                    # Full interactive mode with sudo
#   sudo ./deploy.sh --sync-keys        # Re-pull worker API keys and regenerate config
#
# Usage (Non-Sudo - Degraded Security):
#   ./deploy.sh --non-sudo             # Non-sudo mode with warnings
#   ./deploy.sh --help                 # Show help
#
# Requirements:
#   - Docker installed and running
#   - NVIDIA GPU drivers installed
#   - For sudo mode: root access
#
set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INVENTORY_FILE="${KIT_DIR}/inventory.yaml"
GENERATED_DIR="${KIT_DIR}/generated"
SECRETS_DIR="${KIT_DIR}/secrets"

# Default ports
LITELLM_PORT="4000"
# Worker port. SPARK_KIT_VLLM_PORT lets a second kit instance on the same
# node (e.g. a testbed account) avoid colliding with a running worker.
VLLM_PORT="${SPARK_KIT_VLLM_PORT:-8000}"
POSTGRES_PORT="5432"

# Service user
SERVICE_USER="llm-svc"
SERVICE_GROUP="llm-svc"

# Docker network
DOCKER_NETWORK="spark-kit-llm-net"
# Pinned subnet: ufw's FORWARD rules for container egress reference it (see
# setup_firewall); a fixed subnet keeps those rules valid across restarts.
DOCKER_NETWORK_SUBNET="172.30.0.0/24"

# Pinned images (arm64-capable, GB10-compatible).
# Single source of truth: docker-compose.hub.yml consumes hub images via env-file.
# - vLLM: the vLLM project's and NVIDIA's official DGX Spark path is the
#   UPSTREAM image on the CUDA-13 track (vllm/vllm-openai:cu130-nightly),
#   because cu130 matches the 580.x driver family DGX Spark ships. NGC
#   nvcr.io/nvidia/vllm:* tags target newer driver branches (measured:
#   26.04-py3 needs 595.58, 26.10-py3 needs 615.71) and crash-loop on 580.x.
#   nvcr.io/nvidia/vllm:* tags target newer driver branches (measured:
#   26.04-py3 needs 595.58, 26.10-py3 needs 615.71) and crash-loop on 580.x.
#   Plain :nightly is a moving target and has broken on driver 580 before;
#   so the default below is PINNED BY DIGEST — the exact cu130-nightly
#   image validated on driver 580.178.04 (boots, all flags parse, model
#   loader runs). Re-validate a new digest on every driver upgrade.
#   deploy_worker probes the image against the real driver after pull —
#   never trust a recipe's claimed floor over the probe.
#   Command form: "vllm serve" is prefixed only when the image entrypoint is
#   pass-through (NGC); upstream images whose entrypoint already ends in
#   vLLM/serve get bare serve flags — see deploy_worker.
# - LiteLLM: stable branch tag from BerriAI's published images (cosign-signed).
VLLM_IMAGE_DEFAULT="vllm/vllm-openai@sha256:3dbe092ec5b2cef63b6104d33fa75d6ce53a7870962529ada69f78bbbc38e776"
# Runtime env copies (checked/set per-node; recipes may override the image).
VLLM_IMAGE="${VLLM_IMAGE_DEFAULT}"
# Minimum host driver any NGC image pinned in this kit is known to work on:
# the R580 branch floor. Recipes may raise it via `min_driver`.
MIN_DRIVER_VERSION="580.65"
# LiteLLM: v1.83.7-stable is wolfi-based and its prisma query engine cannot
# start (NotConnectedError crash loop, #14 cause 2). The main-stable branch
# image verified healthy on the node (health/liveliness 200, zero prisma
# errors) is pinned by digest; re-validate on every re-pin.
LITELLM_IMAGE="ghcr.io/berriai/litellm:main-stable@sha256:11175975a3093e05e92faee2fe2fe3412a3ae2fcaa849eb0fe25d5f0d8bcb2e9"
POSTGRES_IMAGE="pgvector/pgvector:pg17"

# Global variables for user input
NODE_ROLE=""
NODE_ID=""
NODE_IP=""
CLIENT_SUBNETS=()
HUB_LAN_IP=""
MODEL_RECIPE=""
CONFIG_PREFILLED=false

# Deployment mode
NON_SUDO_MODE=false
USE_CURRENT_USER=false
SYNC_KEYS_ONLY=false
RESTART_ONLY=false
STATUS_ONLY=false
SECURE_UI=false

# --- Functions ---

log() {
    echo "[$(date '+%H:%M:%S')] [+] $1"
}

log_error() {
    echo "[$(date '+%H:%M:%S')] [!] ERROR: $1" >&2
}

log_warn() {
    echo "[$(date '+%H:%M:%S')] [!] WARNING: $1" >&2
}

log_info() {
    echo "[$(date '+%H:%M:%S')] [i] $1"
}

# Progress tracker: call step "Doing X" before each major phase.
# STEP_TOTAL is set in main() once the role is known.
STEP_NUM=0
STEP_TOTAL=10
step() {
    STEP_NUM=$((STEP_NUM + 1))
    printf '\n[%d/%d] %s...\n' "${STEP_NUM}" "${STEP_TOTAL}" "$1"
}

# Wait for a container to report healthy, with visible progress.
# $1 container name, $2 label. Bounded: after the timeout the script moves
# on and tells the user how to check (model downloads can outwait any wait).
# LOUD ABORT: a container whose engine keeps dying (restart loop) never
# becomes healthy and previously restarted forever under unless-stopped
# while the deploy declared success. If the container accumulates >=
# CRASH_LOOP_MAX restarts during this wait, dump recent logs and exit 1.
CRASH_LOOP_MAX=3
wait_healthy() {
    local container="$1" label="$2"
    local tries=36 interval=10  # ~6 minutes
    local i restarts baseline
    baseline=$(docker inspect "${container}" --format '{{.RestartCount}}' 2>/dev/null | head -1)
    baseline=${baseline:-0}
    for ((i = 1; i <= tries; i++)); do
        if docker inspect "${container}" --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; then
            printf '\r[%d/%d] %s: healthy ✓\n' "${i}" "${tries}" "${label}"
            return 0
        fi
        restarts=$(docker inspect "${container}" --format '{{.RestartCount}}' 2>/dev/null | head -1)
        restarts=${restarts:-0}
        if [ $((restarts - baseline)) -ge "${CRASH_LOOP_MAX}" ]; then
            printf '\n'
            log_error "${label} is crash-looping (${restarts} restarts since this check started)."
            log_error "Deploy is aborting instead of waiting on a container that never becomes healthy."
            log_error "Last 60 log lines from ${container}:"
            echo "--- begin ${container} logs ---"
            docker logs --tail 60 "${container}" 2>&1 | sed 's/\r$//'
            echo "--- end ${container} logs ---"
            log_error "Common causes: model/checkpoint incompatible with the pinned image (recipe), or a bad serve flag."
            log_error "Fix the recipe, then re-run. The container is stopped to stop the loop consuming GPU memory."
            docker stop "${container}" > /dev/null 2>&1 || true
            exit 1
        fi
        printf '\r[%d/%d] waiting for %s (pull/download can take a while; Ctrl-C safe, deployment continues in background)...' "${i}" "${tries}" "${label}"
        sleep "${interval}"
    done
    printf '\n'
    log_warn "${label} not healthy after ~6 min. It is still running in the background;"
    log_warn "follow progress with: docker logs -f ${container}"
    log_warn "then verify with: ./scripts/verify.sh"
    return 0
}

# Validate mode and sudo
validate_mode() {
    # Check if --non-sudo flag was passed
    if [ "${NON_SUDO_MODE}" = true ]; then
        # Non-sudo mode ALWAYS runs containers as the invoking user: an
        # unprivileged account cannot chown anything to the service user,
        # and that is the point of the mode (no privilege escalation, no
        # root-owned artifacts in the user's tree).
        USE_CURRENT_USER=true
        log_warn "Running in non-sudo mode - Security features will be degraded!"
        log_warn "  - Containers will run as current user (not isolated service user)"
        log_warn "  - Firewall will not be configured (vLLM may be exposed to LAN)"
        log_warn "  - Docker network may not be created automatically"
        return 0
    fi

    # Default: sudo mode
    if [ "$(id -u)" != "0" ]; then
        log_error "In sudo mode: This script must be run with sudo for security features."
        log_error "Use: sudo $0"
        log_error "OR use: $0 --non-sudo (degraded security)"
        exit 1
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --non-sudo)
                NON_SUDO_MODE=true
                shift
                ;;
            --sync-keys)
                SYNC_KEYS_ONLY=true
                shift
                ;;
            --restart-services)
                RESTART_ONLY=true
                shift
                ;;
            --status)
                STATUS_ONLY=true
                shift
                ;;
            --secure-ui)
                SECURE_UI=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

show_help() {
    cat << EOF
Usage: ./deploy.sh [OPTIONS]     OR     sudo ./deploy.sh

Deploy the DGX Spark LLM Stack on the current node.

Options:
  --non-sudo          Run without sudo (degraded security, testing only)
  --sync-keys         Hub only: fetch worker API keys over scp, regenerate
                      the LiteLLM config, and restart the LiteLLM container.
                      Run this after deploying new/re-keyed workers.
  --restart-services  Skip all prompts. Look this node's role/recipe up in
                      the inventory (by its IP) and re-apply its stack with
                      existing secrets and config. Fails if the node was
                      never deployed here.
  --status            Report this node's install state (containers, health,
                      GPU, model cache, endpoints) with a plain verdict.
                      Never changes anything; safe to run unattended.
  --help, -h          Show this help message and exit

The script will prompt you for all required information interactively.
EOF
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    # Check Docker (skip for pure config operations)
    if [ "${SYNC_KEYS_ONLY}" = false ]; then
        if ! command -v docker &> /dev/null; then
            log_error "Docker is not installed. Please install Docker and try again."
            exit 1
        fi

        if ! docker info &> /dev/null; then
            log_error "Docker daemon is not running. Please start Docker and try again."
            exit 1
        fi

        # GPU is only required when this node serves a model; checked after role is known.
        if ! command -v nvidia-smi &> /dev/null; then
            log_warn "NVIDIA GPU not detected. If this node serves a model, deployment will fail."
        fi
    fi

    # Check inventory file
    if [ ! -f "${INVENTORY_FILE}" ]; then
        log_error "Inventory file not found at ${INVENTORY_FILE}"
        log_error "Please ensure you are in the spark-kit-3 directory."
        exit 1
    fi

    # yq: mikefarah flavor only (the apt "yq" package is a different program).
    # ensure_yq checks the flavor and vendors a pinned copy if needed.
    # shellcheck disable=SC1091
    source "${KIT_DIR}/scripts/ensure-yq.sh"
    # shellcheck disable=SC1091
    source "${KIT_DIR}/scripts/lib-driver.sh"
    if ! ensure_yq; then
        log_error "Could not provision mikefarah/yq. See scripts/ensure-yq.sh."
        exit 1
    fi

    log "All prerequisites met."
}

touch_generated_dir() {
    mkdir -p "${GENERATED_DIR}"
    chmod 750 "${GENERATED_DIR}"
}

touch_secrets_dir() {
    mkdir -p "${SECRETS_DIR}"

    if [ "${USE_CURRENT_USER}" = true ]; then
        chmod 700 "${SECRETS_DIR}"
    else
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "${SECRETS_DIR}"
        chmod 750 "${SECRETS_DIR}"
    fi
}

# Detect or prompt for node IP
prompt_node_ip() {
    local CURRENT_IP
    CURRENT_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)

    if [ -n "${CURRENT_IP}" ]; then
        read -r -p "Detected node IP: ${CURRENT_IP}. Is this correct? [Y/n]: " response
        case "${response}" in
            [nN])
                read -r -p "Enter node IP address: " NODE_IP
                ;;
            *)
                NODE_IP="${CURRENT_IP}"
                ;;
        esac
    else
        read -r -p "Enter node IP address: " NODE_IP
    fi
    if [ -z "${NODE_IP}" ]; then
        log_error "Node IP is required."
        prompt_node_ip
        return
    fi

    log "Using node IP: ${NODE_IP}"
}

# Prompt for node role
prompt_role() {
    echo ""
    cat << EOF

Select the role for this node:

  1. Hub + Worker (RECOMMENDED)
     - Runs LiteLLM (proxy) + Postgres + vLLM worker
     - This node will serve both as the central hub AND host a model

  2. Hub only
     - Runs LiteLLM (proxy) + Postgres only

  3. Worker only
     - Runs vLLM worker only, connects to the hub

EOF

    read -r -p "Enter choice [1-3, default=1]: " choice

    case "${choice:-1}" in
        1) NODE_ROLE="hub+worker" ;;
        2) NODE_ROLE="hub" ;;
        3) NODE_ROLE="worker" ;;
        *)
            log_error "Invalid choice. Please enter 1, 2, or 3."
            prompt_role
            return
            ;;
    esac

    log "Selected role: ${NODE_ROLE}"
}

is_hub() { [[ "${NODE_ROLE}" == *hub* ]]; }
is_worker() { [[ "${NODE_ROLE}" == *worker* ]]; }

# Prompt for client subnets
prompt_client_subnets() {
    if ! is_hub; then
        return 0
    fi

    echo ""
    cat << EOF
Configure client subnets that will be allowed to access LiteLLM.

These are the IP ranges (in CIDR notation) where your students/clients
will be making requests to the LiteLLM hub.

Examples:
  - Single subnet: 10.0.0.0/24
  - Multiple subnets: 10.0.0.0/24 192.168.1.0/24
EOF

    if [ "${NON_SUDO_MODE}" = true ]; then
        log_warn "In non-sudo mode: firewall will NOT be configured."
        log_warn "Client subnet configuration is for documentation only."
    fi

    read -r -p "Enter client subnet(s) separated by spaces [default from inventory if set]: " input_subnets

    if [ -z "${input_subnets}" ]; then
        local configured
        configured=$(yq eval '.lab.client_subnets // [] | join(" ")' "${INVENTORY_FILE}" 2>/dev/null || echo "")
        if [ -n "${configured}" ]; then
            input_subnets="${configured}"
            log "Using client subnets from inventory: ${input_subnets}"
        fi
    fi

    if [ -z "${input_subnets}" ]; then
        log_error "At least one client subnet is required for hub deployment."
        prompt_client_subnets
        return
    fi

    CLIENT_SUBNETS=()
    local subnet
    for subnet in ${input_subnets}; do
        if [[ "${subnet}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            CLIENT_SUBNETS+=("${subnet}")
        else
            log_error "Invalid CIDR notation: ${subnet}. Expected format: X.X.X.X/XX"
            prompt_client_subnets
            return
        fi
    done

    log "Client subnets: ${CLIENT_SUBNETS[*]}"
}

# Prompt for the docker bridge subnet. This subnet is the single source of
# truth for (a) `docker network create` and (b) the firewall rules that let
# same-node containers reach the worker's published vLLM port, so it is
# user-specifiable — any RFC1918 CIDR works, nothing is pinned to
# 10.0.0.0/24-style networks. SPARK_KIT_DOCKER_SUBNET overrides the prompt
# for unattended deploys. The previous value in the inventory is the default.
prompt_docker_subnet() {
    local configured
    configured=$(yq eval '.lab.docker_subnet // ""' "${INVENTORY_FILE}" 2>/dev/null || echo "")
    local default_subnet="${configured:-${DOCKER_NETWORK_SUBNET}}"

    if [ -n "${SPARK_KIT_DOCKER_SUBNET:-}" ]; then
        DOCKER_NETWORK_SUBNET="${SPARK_KIT_DOCKER_SUBNET}"
    else
        read -r -p "Enter docker network subnet [default: ${default_subnet}]: " input_subnet
        DOCKER_NETWORK_SUBNET="${input_subnet:-${default_subnet}}"
    fi

    if [[ ! "${DOCKER_NETWORK_SUBNET}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        log_error "Invalid CIDR notation: ${DOCKER_NETWORK_SUBNET}. Expected format: X.X.X.X/XX"
        prompt_docker_subnet
        return
    fi

    export DOCKER_NETWORK_SUBNET
    log "Docker network subnet: ${DOCKER_NETWORK_SUBNET}"
}

# Prompt for the Admin UI account email (the DB-backed proxy admin, replaces
# bootstrap env credentials once provisioned). Default: the previously used
# value, else admin@lab.local.
prompt_admin_email() {
    local default_email="admin@lab.local"
    [ -f "${SECRETS_DIR}/admin_email.txt" ] && default_email="$(cat "${SECRETS_DIR}/admin_email.txt")"
    read -r -p "Enter the Admin UI account email [default: ${default_email}]: " input_email
    ADMIN_UI_EMAIL="${input_email:-${default_email}}"
    if [[ ! "${ADMIN_UI_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
        log_error "Invalid email: ${ADMIN_UI_EMAIL}"
        prompt_admin_email
        return
    fi
    log "Admin UI account: ${ADMIN_UI_EMAIL}"
}

# Prompt for hub IP if this is a worker
prompt_hub_ip() {
    if is_hub; then
        HUB_LAN_IP="${NODE_IP}"
        return 0
    fi

    echo ""
    cat << EOF
This node will be a worker and needs to connect to the LiteLLM hub.
Please provide the IP address of your hub node.
EOF

    read -r -p "Enter hub node IP address: " HUB_LAN_IP

    if [ -z "${HUB_LAN_IP}" ]; then
        log_error "Hub IP is required for worker nodes."
        prompt_hub_ip
        return
    fi

    log "Hub IP: ${HUB_LAN_IP}"
}

# Try to detect this node in the inventory by IP and, with one confirmation,
# reuse everything recorded about it (id, role, recipe, hub IP) so a re-run
# after an unattended/degraded deployment needs no retyping.
try_detect_node() {
    if [ -z "${NODE_IP}" ]; then
        return 0
    fi

    local node_id detected_role detected_recipe detected_hub
    node_id=$(yq eval ".nodes[] | select(.lan_ip == \"${NODE_IP}\") | .node_id" "${INVENTORY_FILE}" 2>/dev/null || true)
    if [ -z "${node_id}" ] || [ "${node_id}" = "null" ]; then
        return 0
    fi

    detected_role=$(yq eval ".nodes[] | select(.node_id == \"${node_id}\") | .role" "${INVENTORY_FILE}" 2>/dev/null || true)
    detected_recipe=$(yq eval ".nodes[] | select(.node_id == \"${node_id}\") | .model_recipe" "${INVENTORY_FILE}" 2>/dev/null || true)
    [ "${detected_recipe}" = "null" ] && detected_recipe=""

    log_info "Found previous deployment in inventory: ${node_id} (role: ${detected_role}${detected_recipe:+, recipe: ${detected_recipe}})"
    read -r -p "Reuse this configuration? [Y/n]: " response
    case "${response}" in
        [nN]) return 0 ;;
    esac

    NODE_ID="${node_id}"
    NODE_ROLE="${detected_role}"
    MODEL_RECIPE="${detected_recipe}"
    if [[ "${detected_role}" == *hub* ]]; then
        # hub and hub+worker host the hub endpoint themselves.
        HUB_LAN_IP="${NODE_IP}"
    else
        detected_hub=$(yq eval '.nodes[] | select(.role == "hub" or .role == "hub+worker") | .lan_ip' "${INVENTORY_FILE}" 2>/dev/null | head -1)
        [ -n "${detected_hub}" ] && [ "${detected_hub}" != "null" ] && HUB_LAN_IP="${detected_hub}"
    fi
    CONFIG_PREFILLED=true
    log "Reusing recorded configuration (change any answer by re-running and answering 'n')."
}

# Prompt for node ID
prompt_node_id() {
    if [ -n "${NODE_ID}" ]; then
        log "Using node ID: ${NODE_ID}"
        return 0
    fi

    echo ""
    read -r -p "Enter node ID for this node (or press Enter to auto-generate from IP): " NODE_ID

    if [ -z "${NODE_ID}" ]; then
        NODE_ID="spark-$(echo "${NODE_IP}" | tr '.' '-')"
        log "Auto-generated node ID: ${NODE_ID}"
    fi
}

# Prompt for model recipe if worker
prompt_model_recipe() {
    if ! is_worker; then
        return 0
    fi

    echo ""
    local recipes=()
    local recipe_file
    for recipe_file in "${KIT_DIR}/recipes/"*.yaml; do
        [ -e "${recipe_file}" ] || continue
        recipes+=("$(basename "${recipe_file}" .yaml)")
    done

    if [ "${#recipes[@]}" -gt 0 ]; then
        echo "Available recipes:"
        local recipe
        for recipe in "${recipes[@]}"; do
            echo "  - ${recipe}"
        done
        echo ""
    fi

    read -r -p "Enter model recipe name [default=qwen3.6-35b-a3b-nvfp4]: " MODEL_RECIPE
    MODEL_RECIPE="${MODEL_RECIPE:-qwen3.6-35b-a3b-nvfp4}"

    if [ ! -f "${KIT_DIR}/recipes/${MODEL_RECIPE}.yaml" ]; then
        log_error "Recipe '${MODEL_RECIPE}' not found in recipes/ directory."
        log_error "Add the recipe file first, then re-run. It will not be silently replaced."
        exit 1
    fi

    log "Model recipe: ${MODEL_RECIPE}"
}

# Read a field from a recipe file
recipe_field() {
    local recipe_name="$1"
    local field="$2"
    local default_value="$3"
    local value
    value=$(yq eval ".${field}" "${KIT_DIR}/recipes/${recipe_name}.yaml" 2>/dev/null || true)
    if [ -z "${value}" ] || [ "${value}" = "null" ]; then
        echo "${default_value}"
    else
        echo "${value}"
    fi
}

# For workers: prefill from inventory entry if the node already exists
sync_state_from_inventory() {
    if [ -z "${NODE_ID}" ]; then
        return 0
    fi
    if [ -z "${MODEL_RECIPE}" ] && is_worker; then
        local inv_recipe
        inv_recipe=$(yq eval ".nodes[] | select(.node_id == \"${NODE_ID}\") | .model_recipe" "${INVENTORY_FILE}" 2>/dev/null || true)
        if [ -n "${inv_recipe}" ] && [ "${inv_recipe}" != "null" ]; then
            MODEL_RECIPE="${inv_recipe}"
            log "Using model recipe from inventory: ${MODEL_RECIPE}"
        fi
    fi
}

# Collect all user input
collect_user_input() {
    echo ""
    echo "=========================================="
    echo "  DGX Spark LLM Stack - Deployment Setup"
    echo "=========================================="
    echo ""

    if [ "${NON_SUDO_MODE}" = true ]; then
        echo "  *** NON-SUDO MODE - SECURITY FEATURES DEGRADED ***"
        echo ""
    fi

    prompt_node_ip
    prompt_docker_subnet
    try_detect_node
    if [ "${CONFIG_PREFILLED}" = true ]; then
        # Restore hub-side extras from the same recorded config.
        if is_hub; then
            local subnets
            subnets=$(yq eval '.lab.client_subnets // [] | join(" ")' "${INVENTORY_FILE}" 2>/dev/null || true)
            if [ -n "${subnets}" ]; then
                # shellcheck disable=SC2206
                CLIENT_SUBNETS=(${subnets})
                log "Restored client subnets from inventory: ${CLIENT_SUBNETS[*]}"
            fi
        fi
        echo ""
    else
        prompt_role
        sync_state_from_inventory
        if is_worker; then
            prompt_hub_ip
        fi
        if is_hub; then
            prompt_client_subnets
        fi
        prompt_node_id
        if is_worker; then
            prompt_model_recipe
        fi
        if is_hub; then
            prompt_admin_email
        fi
    fi

    echo ""
    echo "=========================================="
    echo "  Configuration Summary"
    echo "=========================================="
    echo "  Node ID:       ${NODE_ID}"
    echo "  Node IP:       ${NODE_IP}"
    echo "  Role:          ${NODE_ROLE}"
    echo "  Docker Subnet: ${DOCKER_NETWORK_SUBNET}"
    if is_hub && [ "${#CLIENT_SUBNETS[@]}" -gt 0 ]; then
        echo "  Client Subnets: ${CLIENT_SUBNETS[*]}"
    fi
    if is_worker; then
        echo "  Hub IP:        ${HUB_LAN_IP}"
        echo "  Model Recipe:  ${MODEL_RECIPE}"
    fi
    echo "=========================================="
    echo ""

    read -r -p "Proceed with deployment? [y/N]: " response
    case "${response}" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *)
            log "Deployment cancelled."
            exit 0
            ;;
    esac
}

chown_svc() {
    # Ownership helper: files are owned by the service user in sudo mode.
    if [ "${USE_CURRENT_USER}" = false ]; then
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "$1"
    fi
}

# Create service user (sudo only)
create_service_user() {
    if [ "${USE_CURRENT_USER}" = true ]; then
        SVC_UID=$(id -u)
        SVC_GID=$(id -g)
        SVC_USERNAME=$(id -un)
        export SVC_UID SVC_GID SVC_USERNAME
        return 0
    fi

    log "Creating service user..."

    if ! getent group "${SERVICE_GROUP}" > /dev/null; then
        groupadd "${SERVICE_GROUP}"
        log "Created group: ${SERVICE_GROUP}"
    fi

    if ! id "${SERVICE_USER}" &> /dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin \
                --gid "${SERVICE_GROUP}" "${SERVICE_USER}"
        log "Created user: ${SERVICE_USER}"
    else
        log "User ${SERVICE_USER} already exists."
    fi

    SVC_UID=$(id -u "${SERVICE_USER}")
    SVC_GID=$(id -g "${SERVICE_USER}")
    SVC_USERNAME="${SERVICE_USER}"
    export SVC_UID SVC_GID
}

setup_firewall() {
    if [ "${NON_SUDO_MODE}" = true ]; then
        log_warn "Skipping firewall configuration in non-sudo mode"
        log_warn "vLLM ports may be exposed to the entire LAN!"
        return 0
    fi

    log "Configuring firewall..."

    ensure_container_forward_allowances

    ufw default deny incoming
    ufw allow ssh

    if is_hub && [ "${#CLIENT_SUBNETS[@]}" -gt 0 ]; then
        local subnet
        for subnet in "${CLIENT_SUBNETS[@]}"; do
            ufw allow from "${subnet}" to any port "${LITELLM_PORT}" proto tcp comment 'LiteLLM Hub Access'
            log "Allowed LiteLLM port ${LITELLM_PORT} from ${subnet}"
        done
    fi

    if is_worker; then
        # Worker (or hub+worker): vLLM port reachable from the hub IP only.
        if [ -z "${HUB_LAN_IP}" ]; then
            log_error "Hub IP is empty; cannot write the vLLM firewall rule. Re-run the deploy and confirm the recorded configuration (or enter the hub IP when asked)."
            exit 1
        fi
        ufw allow from "${HUB_LAN_IP}" to any port "${VLLM_PORT}" proto tcp comment 'Worker Hub Access'
        log "Allowed vLLM port ${VLLM_PORT} from hub at ${HUB_LAN_IP}"
        # Same-node containers (LiteLLM hub on the same host reaching its own
        # worker) arrive at the docker-proxy socket with a source from the
        # docker bridge subnet; without this rule ufw INPUT drops them and the
        # hub cannot route to its local worker (#14 cause 3).
        ufw allow from "${DOCKER_NETWORK_SUBNET}" to any port "${VLLM_PORT}" proto tcp comment 'Worker Container Access (same-node)'
        log "Allowed vLLM port ${VLLM_PORT} from docker subnet ${DOCKER_NETWORK_SUBNET}"
    fi

    ufw default allow outgoing
    ufw --force enable
    log "Firewall configured and enabled."
}

create_network() {
    if [ "${SYNC_KEYS_ONLY}" = true ]; then
        return 0
    fi

    log "Creating Docker network..."

    if [ "${NON_SUDO_MODE}" = true ]; then
        if ! docker network inspect "${DOCKER_NETWORK}" &> /dev/null; then
            log_error "Docker network ${DOCKER_NETWORK} does not exist and cannot be created without root."
            log_error "Please create it manually: sudo docker network create ${DOCKER_NETWORK}"
            exit 1
        fi
        log "Using existing Docker network: ${DOCKER_NETWORK}"
        return 0
    fi

    if ! docker network inspect "${DOCKER_NETWORK}" &> /dev/null; then
        if ! docker network create --subnet "${DOCKER_NETWORK_SUBNET}" "${DOCKER_NETWORK}" > /dev/null; then
            log_error "Could not create network ${DOCKER_NETWORK} with subnet ${DOCKER_NETWORK_SUBNET}."
            log_error "The subnet may collide with an existing Docker network; choose another in infrastructure/deploy.sh (DOCKER_NETWORK_SUBNET)."
            exit 1
        fi
        log "Created Docker network: ${DOCKER_NETWORK} (${DOCKER_NETWORK_SUBNET})"
    else
        # Reconcile: an existing network (created by an earlier deploy, the
        # non-sudo path, or by hand) may be on a different subnet than the
        # one requested now. Firewall rules must target the LIVE subnet, so
        # adopt it and warn if it differs from what was asked for.
        local live_subnet
        live_subnet=$(resolve_network_subnet)
        if [ -n "${live_subnet}" ] && [ "${live_subnet}" != "${DOCKER_NETWORK_SUBNET}" ]; then
            log_warn "Docker network ${DOCKER_NETWORK} exists on subnet ${live_subnet}, but ${DOCKER_NETWORK_SUBNET} was requested."
            log_warn "Adopting the live subnet ${live_subnet} for firewall rules so container-to-worker traffic is not dropped (#14 cause 3)."
            log_warn "To move the network to ${DOCKER_NETWORK_SUBNET}: stop the kit's containers, 'docker network rm ${DOCKER_NETWORK}', then redeploy."
            DOCKER_NETWORK_SUBNET="${live_subnet}"
        fi
        log "Docker network ${DOCKER_NETWORK} already exists."
    fi

    # The DOCKER-USER chain only exists once Docker has something to manage;
    # (re-)apply the forwarding rules now that the network exists.
    ensure_container_forward_allowances
}

# Generate secrets.
# NOTE: DATABASE_URL is constructed in exactly one place, here, with the
# compose service hostname `postgres` (the container resolves it on the
# bridge network). Never reconstruct it elsewhere.
generate_secrets() {
    if [ "${SYNC_KEYS_ONLY}" = true ]; then
        return 0
    fi

    log "Generating secrets..."
    touch_secrets_dir

    # Worker secret first: a hub+worker node's hub.env embeds this key.
    if is_worker; then
        local VLLM_API_KEY_FILE="${SECRETS_DIR}/vllm_api_key.txt"
        if [ ! -f "${VLLM_API_KEY_FILE}" ]; then
            (umask 077 && openssl rand -hex 32 > "${VLLM_API_KEY_FILE}")
            chown_svc "${VLLM_API_KEY_FILE}"
            log "Generated VLLM API key."
        fi
    fi

    if is_hub; then
        local DB_PASSWORD_FILE="${SECRETS_DIR}/db_password.txt"
        local LITELLM_MASTER_KEY_FILE="${SECRETS_DIR}/litellm_master_key.txt"

        if [ ! -f "${DB_PASSWORD_FILE}" ]; then
            # hex, NOT base64: the password is interpolated unencoded into
            # DATABASE_URL (postgresql://litellm:<pw>@postgres:...). Base64's
            # '/' breaks prisma's URL parse ("P1013: invalid port number")
            # and '+' is lost to form-encoding — the #14 restart loop.
            (umask 077 && openssl rand -hex 32 > "${DB_PASSWORD_FILE}")
            chown_svc "${DB_PASSWORD_FILE}"
            log "Generated DB password."
        fi

        if [ ! -f "${LITELLM_MASTER_KEY_FILE}" ]; then
            # LiteLLM requires the sk- prefix for the master key
            (umask 077 && echo "sk-$(openssl rand -hex 31)" > "${LITELLM_MASTER_KEY_FILE}")
            chown_svc "${LITELLM_MASTER_KEY_FILE}"
            log "Generated LiteLLM master key with sk- prefix."
        fi

        # LiteLLM UI login (admin panel). Explicit credentials generated once
        # and reused on every redeploy; read via secrets/ui_username.txt and
        # secrets/ui_password.txt.
        local UI_USERNAME_FILE="${SECRETS_DIR}/ui_username.txt"
        local UI_PASSWORD_FILE="${SECRETS_DIR}/ui_password.txt"
        if [ ! -f "${UI_USERNAME_FILE}" ]; then
            (umask 077 && echo "admin" > "${UI_USERNAME_FILE}")
            chown_svc "${UI_USERNAME_FILE}"
        fi
        if [ ! -f "${UI_PASSWORD_FILE}" ]; then
            (umask 077 && openssl rand -hex 16 > "${UI_PASSWORD_FILE}")
            chown_svc "${UI_PASSWORD_FILE}"
            log "Generated LiteLLM UI password."
        fi

        # DB-backed Admin UI account (proxy admin). Provisioned once after
        # services are healthy (provision_ui_admin), then env-credential
        # login is disabled. Password is generated for the email; changing
        # the email regenerates it.
        local ADMIN_EMAIL_FILE="${SECRETS_DIR}/admin_email.txt"
        local ADMIN_PASSWORD_FILE="${SECRETS_DIR}/admin_ui_password.txt"
        if [ ! -f "${ADMIN_EMAIL_FILE}" ]; then
            (umask 077 && echo "${ADMIN_UI_EMAIL:-admin@lab.local}" > "${ADMIN_EMAIL_FILE}")
            chown_svc "${ADMIN_EMAIL_FILE}"
        fi
        if [ ! -f "${ADMIN_PASSWORD_FILE}" ]; then
            (umask 077 && openssl rand -hex 16 > "${ADMIN_PASSWORD_FILE}")
            chown_svc "${ADMIN_PASSWORD_FILE}"
            log "Generated Admin UI password for $(cat "${ADMIN_EMAIL_FILE}")."
        fi

        local vllm_self_key=""
        if is_worker; then
            vllm_self_key="$(cat "${SECRETS_DIR}/vllm_api_key.txt")"
        fi

        # hub.env: single env source for the compose stack (substitution + env_file)
        local env_file="${SECRETS_DIR}/hub.env"
        {
            echo "DB_PASSWORD=$(cat "${DB_PASSWORD_FILE}")"
            echo "LITELLM_MASTER_KEY=$(cat "${LITELLM_MASTER_KEY_FILE}")"
            # LiteLLM UI login (admin panel); values from ui_username/_password.
            # NOTE: LiteLLM reads the UN-prefixed names (login_utils.py:
            # os.getenv("UI_USERNAME")), not LITELLM_UI_*.
            echo "UI_USERNAME=$(cat "${UI_USERNAME_FILE}")"
            echo "UI_PASSWORD=$(cat "${UI_PASSWORD_FILE}")"
            echo "DATABASE_URL=postgresql://litellm:$(cat "${DB_PASSWORD_FILE}")@postgres:${POSTGRES_PORT}/litellm"
            echo "NODE_IP=${NODE_IP}"
            echo "LITELLM_IMAGE=${LITELLM_IMAGE}"
            echo "POSTGRES_IMAGE=${POSTGRES_IMAGE}"
            echo "GENERATED_DIR=${GENERATED_DIR}"
            echo "SECRETS_DIR=${SECRETS_DIR}"
            # Per-worker vLLM API keys, one variable per route. This node's own
            # key (hub+worker) plus every remote worker key under
            # secrets/worker_keys/<node>.txt (see sync_worker_keys).
            if [ -n "${vllm_self_key}" ]; then
                echo "VLLM_KEY_$(sanitize_node_id "${NODE_ID}")=${vllm_self_key}"
            fi
            local key_file
            for key_file in "${SECRETS_DIR}/worker_keys"/*.txt; do
                if [ -e "${key_file}" ]; then
                    local wid
                    wid="$(basename "${key_file}" .txt)"
                    echo "VLLM_KEY_$(sanitize_node_id "${wid}")=$(cat "${key_file}")"
                fi
            done
        } > "${env_file}"
        chmod 600 "${env_file}"
        chown_svc "${env_file}"
    fi
}

# Node IDs may contain '-' or '.'; sanitize for use in env var names.
sanitize_node_id() {
    echo "$1" | tr '[:lower:].-' '[:upper:]__'
}

# Fetch each remote worker's vLLM API key over scp and register it on the hub.
# Run on the hub: sudo ./infrastructure/deploy.sh --sync-keys
sync_worker_keys() {
    mkdir -p "${SECRETS_DIR}/worker_keys"
    chmod 700 "${SECRETS_DIR}/worker_keys" 2>/dev/null || true

    local workers
    workers=$(yq eval ".nodes[] | select(.role == \"worker\") | \"\(.node_id) \(.lan_ip)\"" "${INVENTORY_FILE}" 2>/dev/null || true)

    if [ -z "${workers}" ]; then
        log_warn "No worker nodes in the inventory yet. Deploy workers first, then re-run --sync-keys."
        return 0
    fi

    local entry
    while read -r entry; do
        [ -z "${entry}" ] && continue
        local wid wip
        wid="$(echo "${entry}" | awk '{print $1}')"
        wip="$(echo "${entry}" | awk '{print $2}')"
        if [ -z "${wid}" ] || [ "${wid}" = "null" ] || [ -z "${wip}" ] || [ "${wip}" = "null" ]; then
            log_warn "Skipping malformed inventory entry: '${entry}' (empty node_id or lan_ip)."
            continue
        fi

        local existing="${SECRETS_DIR}/worker_keys/${wid}.txt"
        if [ -s "${existing}" ]; then
            read -r -p "Worker ${wid} (${wip}) key already present. Re-fetch? [y/N]: " resp
            case "${resp}" in
                [yY]|[yY][eE][sS]) ;;
                *) continue ;;
            esac
        fi

        read -r -p "Fetch API key for ${wid}: ssh target [${wip}] (Enter=default, 'skip' to skip): " target
        target="${target:-${wip}}"
        [ "${target}" = "skip" ] && continue

        read -r -p "Path to spark-kit-3 on ${wid} [~/DGX-Spark-Insanity/spark-kits/spark-kit-3]: " remote_dir
        remote_dir="${remote_dir:-$HOME/DGX-Spark-Insanity/spark-kits/spark-kit-3}"

        # shellcheck disable=SC2029
        if scp -q "${target}:${remote_dir}/secrets/vllm_api_key.txt" "${existing}"; then
            chmod 600 "${existing}"
            chown_svc "${existing}"
            log "Stored API key for ${wid}."
        else
            log_warn "Could not fetch key for ${wid} (scp failed). Routing to it will fail until the key is present."
        fi
    done <<< "${workers}"
}

# Generate LiteLLM config from the inventory.
# Every worker endpoint gets its own route with its own api_key env var;
# replicas sharing a model name load-balance via the router.
generate_litellm_config() {
    if ! is_hub; then
        return 0
    fi

    log "Generating LiteLLM configuration..."

    local config_file="${GENERATED_DIR}/litellm-config.yaml"

    cat > "${config_file}" << 'LITELLM_CONFIG_HEADER'
model_list:
LITELLM_CONFIG_HEADER

    # This node's own worker (hub+worker role)
    if is_worker; then
        local served
        served=$(recipe_field "${MODEL_RECIPE}" "served_model_name" "${MODEL_RECIPE}")
        cat >> "${config_file}" << LITELLM_CONFIG_ENTRY
  - model_name: ${served}
    litellm_params:
      # The worker serves --served-model-name (= ${served}), not the HF path;
      # 'openai/' is LiteLLM's OpenAI-compatible-provider prefix.
      model: openai/${served}
      # Same-node worker: route via the node's LAN IP, not any
      # gateway alias — nothing is published on the default bridge gateway,
      # the worker binds NODE_IP only. Reachability from this bridge is
      # granted by the firewall rule on the docker subnet.
      api_base: http://${NODE_IP}:${VLLM_PORT}/v1
      api_key: os.environ/VLLM_KEY_$(sanitize_node_id "${NODE_ID}")
LITELLM_CONFIG_ENTRY
    fi

    # Remote workers from the inventory: one route per endpoint, keyed by
    # that worker's own API key; model name/flags come from its recipe.
    local workers
    workers=$(yq eval ".nodes[] | select(.role == \"worker\") | \"\(.node_id)|\(.lan_ip)|\(.model_recipe)\"" "${INVENTORY_FILE}" 2>/dev/null || true)

    local entry
    while IFS= read -r entry; do
        [ -z "${entry}" ] && continue
        local wid wip wrecipe served
        wid="$(echo "${entry}" | cut -d'|' -f1)"
        wip="$(echo "${entry}" | cut -d'|' -f2)"
        wrecipe="$(echo "${entry}" | cut -d'|' -f3)"

        # Skip malformed inventory rows (empty id/ip would generate an
        # unrouteable 'http://:8000' endpoint and a confusing key warning).
        if [ -z "${wid}" ] || [ "${wid}" = "null" ] || [ -z "${wip}" ] || [ "${wip}" = "null" ]; then
            log_warn "Skipping malformed inventory entry: '${entry}' (empty node_id or lan_ip)."
            continue
        fi

        [ -f "${KIT_DIR}/recipes/${wrecipe}.yaml" ] || wrecipe="qwen3.6-35b-a3b-nvfp4"
        served=$(recipe_field "${wrecipe}" "served_model_name" "${wrecipe}")

        local key_var
        key_var="os.environ/VLLM_KEY_$(sanitize_node_id "${wid}")"
        local key_file="${SECRETS_DIR}/worker_keys/${wid}.txt"
        if [ ! -s "${key_file}" ] && [ "${wid}" != "${NODE_ID}" ]; then
            log_warn "No API key on file for worker ${wid}; its route will fail auth until you run: sudo $0 --sync-keys"
        fi

        cat >> "${config_file}" << LITELLM_CONFIG_ENTRY
  - model_name: ${served}
    litellm_params:
      # The worker serves --served-model-name (= ${served}).
      model: openai/${served}
      api_base: http://${wip}:${VLLM_PORT}/v1
      api_key: ${key_var}
LITELLM_CONFIG_ENTRY
    done <<< "${workers}"

    cat >> "${config_file}" << LITELLM_CONFIG_FOOTER

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
LITELLM_CONFIG_FOOTER

    # Env-credential login (UI_USERNAME/UI_PASSWORD) is bootstrap-only:
    # enabled until a DB-backed proxy-admin account has been provisioned
    # (marker: ${SECRETS_DIR}/env_login_disabled), then permanently off.
    if [ -f "${SECRETS_DIR}/env_login_disabled" ]; then
        cat >> "${config_file}" << 'LITELLM_CONFIG_FOOTER'
  disable_env_credential_login: true
LITELLM_CONFIG_FOOTER
    else
        cat >> "${config_file}" << 'LITELLM_CONFIG_FOOTER'
  # Bootstrap-only: a DB-backed admin account has NOT been provisioned yet.
  # The deploy provisions one automatically; until then env credentials are
  # the only way into the admin panel.
  disable_env_credential_login: false
LITELLM_CONFIG_FOOTER
    fi

    log "Generated LiteLLM config: ${config_file}"
    chmod 640 "${config_file}"
    chown_svc "${config_file}"
}

# Provision an Admin UI invitation for the DB-backed proxy-admin account.
# This LiteLLM build refuses passwords via /user/new; the user sets their
# own password through the returned invite link. Idempotent per stored
# invite; --secure-ui finalizes by disabling bootstrap env login.
provision_ui_admin() {
    local marker="${SECRETS_DIR}/env_login_disabled"
    if [ -f "${marker}" ]; then
        log "Admin UI account already provisioned; env-credential login disabled."
        return 0
    fi

    local email
    email="$(cat "${SECRETS_DIR}/admin_email.txt" 2>/dev/null || echo "")"
    if [ -z "${email}" ]; then
        log_warn "Admin email file missing; skipping admin invitation (bootstrap env login stays enabled)."
        return 0
    fi

    local master_key http_code
    master_key="$(cat "${SECRETS_DIR}/litellm_master_key.txt")"

    # 1. Create the user record (no password — this build refuses passwords
    #    via /user/new; the password is set via the invitation link).
    local user_resp
    user_resp=$(mktemp)
    http_code=$(curl -s -o "${user_resp}" -w "%{http_code}" -m 30 \
        -X POST "http://${NODE_IP}:${LITELLM_PORT}/user/new" \
        -H "Authorization: Bearer ${master_key}" \
        -H "Content-Type: application/json" \
        -d "{\"user_email\": \"${email}\", \"user_role\": \"proxy_admin\"}" \
        2>/dev/null || echo "000")
    if [ "${http_code}" != "200" ] && [ "${http_code}" != "201" ]; then
        log_warn "Could not create admin user via /user/new (HTTP ${http_code}) (user may already exist); trying the invitation anyway."
    fi

    # 2. Mint the invitation link the admin uses to set their own password.
    local resp
    resp=$(mktemp)
    http_code=$(curl -s -o "${resp}" -w "%{http_code}" -m 30 \
        -X POST "http://${NODE_IP}:${LITELLM_PORT}/invitation/new" \
        -H "Authorization: Bearer ${master_key}" \
        -H "Content-Type: application/json" \
        -d "{\"user_email\": \"${email}\"}" \
        2>/dev/null || echo "000")
    if [ "${http_code}" = "200" ] || [ "${http_code}" = "201" ]; then
        (umask 077 && cp "${resp}" "${SECRETS_DIR}/admin_invite.json")
        chown_svc "${SECRETS_DIR}/admin_invite.json"
        log "Admin UI invitation created for ${email}."
    else
        # Invitation may already exist from a previous deploy; keep going —
        # the banner prints the stored invite and the --secure-ui path.
        log_warn "Could not create admin invitation via /invitation/new (HTTP ${http_code}) (may already exist)."
    fi
    rm -f "${resp}"
    return 0
}

# --secure-ui: after the admin has set their password via the invite link,
# disable bootstrap env-credential login (marker + config regen + restart).
secure_ui() {
    if [ -f "${SECRETS_DIR}/env_login_disabled" ]; then
        log "Env-credential login is already disabled."
        return 0
    fi
    if [ ! -f "${SECRETS_DIR}/admin_email.txt" ]; then
        log_error "No admin account provisioned yet; run a full deploy first."
        exit 1
    fi
    read -r -p "Have you set YOUR OWN password via the invitation link for $(cat "${SECRETS_DIR}/admin_email.txt")? Env login WILL be disabled. Proceed? [y/N]: " response
    case "${response}" in
        [yY][eE][sS]|[yY]) ;;
        *) log "Aborted; env-credential login left enabled."; return 0 ;;
    esac
    (umask 077 && touch "${SECRETS_DIR}/env_login_disabled")
    chown_svc "${SECRETS_DIR}/env_login_disabled"
    generate_litellm_config
    deploy_hub
    wait_healthy "litellm-proxy" "LiteLLM"
    log "Env-credential login disabled. UI login: $(cat "${SECRETS_DIR}/admin_email.txt") + your invitation password."
}

# Record this node in the inventory so the file stays the single source of truth.
update_inventory() {
    log "Recording node ${NODE_ID} in inventory..."
    export NODE_ID NODE_ROLE NODE_IP MODEL_RECIPE
    yq eval -i 'del(.nodes[] | select(.node_id == env(NODE_ID) or .lan_ip == env(NODE_IP)))' "${INVENTORY_FILE}"
    if is_worker; then
        yq eval -i '.nodes += [{"node_id": env(NODE_ID), "role": env(NODE_ROLE), "lan_ip": env(NODE_IP), "model_recipe": env(MODEL_RECIPE)}]' "${INVENTORY_FILE}"
    else
        yq eval -i '.nodes += [{"node_id": env(NODE_ID), "role": env(NODE_ROLE), "lan_ip": env(NODE_IP), "model_recipe": null}]' "${INVENTORY_FILE}"
    fi
    # Remember the docker bridge subnet so later runs default to it.
    export DOCKER_NETWORK_SUBNET
    yq eval -i '.lab.docker_subnet = env(DOCKER_NETWORK_SUBNET)' "${INVENTORY_FILE}"
    export -n DOCKER_NETWORK_SUBNET
    # Drop the export attribute without undefining the globals: later code
    # (is_hub / is_worker / summary) still reads them under set -u.
    export -n NODE_ID NODE_ROLE NODE_IP MODEL_RECIPE
}

# Optional NFS model cache (spec: optional, root_squash, subnet-restricted).
setup_nfs() {
    if [ "${SYNC_KEYS_ONLY}" = true ]; then
        return 0
    fi

    local enabled export_path
    enabled=$(yq eval '.lab.nfs.enabled // false' "${INVENTORY_FILE}")
    if [ "${enabled}" != "true" ]; then
        log "NFS model cache disabled (inventory lab.nfs.enabled != true). Skipping."
        return 0
    fi

    export_path=$(yq eval '.lab.nfs.export_path // "/mnt/shared-models"' "${INVENTORY_FILE}")

    mkdir -p "${export_path}"

    if is_hub; then
        log "Configuring NFS export ${export_path} (root_squash, subnet-restricted)..."
        if ! command -v exportfs &> /dev/null; then
            log_warn "NFS server tools not installed (nfs-kernel-server). Install and re-run to share the cache."
            return 0
        fi
        local subnet
        {
            echo "# Managed by spark-kit-3 deploy.sh"
            for subnet in "${CLIENT_SUBNETS[@]}"; do
                echo "${export_path} ${subnet}(rw,sync,no_subtree_check,root_squash)"
            done
        } > /etc/exports.d/spark-kit-3.exports 2>/dev/null || {
            mkdir -p /etc/exports.d
            {
                echo "# Managed by spark-kit-3 deploy.sh"
                for subnet in "${CLIENT_SUBNETS[@]}"; do
                    echo "${export_path} ${subnet}(rw,sync,no_subtree_check,root_squash)"
                done
            } > /etc/exports.d/spark-kit-3.exports
        }
        exportfs -ra || log_warn "exportfs -ra failed; check /etc/exports.d/spark-kit-3.exports"
        if [ "${#CLIENT_SUBNETS[@]}" -gt 0 ]; then
            ufw allow from "${CLIENT_SUBNETS[0]}" to any port 2049 proto tcp comment 'NFS model cache'
        fi
        log "NFS export configured."
    fi

    if is_worker && [ "${HUB_LAN_IP}" != "${NODE_IP}" ]; then
        log "Attempting read-only NFS mount from hub (${HUB_LAN_IP})..."
        if mountpoint -q "${export_path}" 2>/dev/null; then
            log "Already mounted."
        elif mount -t nfs -o ro,hard,timeo=50 "${HUB_LAN_IP}:${export_path}" "${export_path}" 2>/dev/null; then
            log "NFS cache mounted read-only at ${export_path}."
        else
            log_warn "NFS mount failed. Falling back to independent model downloads on this node."
        fi
    fi
}

deploy_hub() {
    if ! is_hub; then
        return 0
    fi

    log "Deploying Hub..."

    local docker_compose_file="${SCRIPT_DIR}/docker-compose.hub.yml"
    local env_file="${SECRETS_DIR}/hub.env"

    log "Starting Hub services via Docker Compose..."
    cd "${SCRIPT_DIR}"

    # Re-deploy safety: stale containers with these fixed names (e.g. from an
    # interrupted earlier `up`) make compose abort with a name conflict.
    # Removing them keeps the postgres_data named volume, so no data is lost.
    local stale_container
    for stale_container in litellm-proxy litellm-postgres; do
        if docker ps -a --format '{{.Names}}' | grep -qx "${stale_container}"; then
            log "Reusing name: removing stale container ${stale_container} (volumes preserved)"
            docker rm -f "${stale_container}" > /dev/null
        fi
    done

    docker compose -f "${docker_compose_file}" \
        --env-file "${env_file}" \
        up -d --remove-orphans

    log "Hub deployed successfully."
    log "LiteLLM accessible at http://${NODE_IP}:${LITELLM_PORT}/v1"
}

deploy_worker() {
    if ! is_worker; then
        return 0
    fi

    log "Deploying Worker..."

    local hf_model_name served_model_name
    hf_model_name=$(recipe_field "${MODEL_RECIPE}" "model_name" "nvidia/Qwen3.6-35B-A3B-NVFP4")
    served_model_name=$(recipe_field "${MODEL_RECIPE}" "served_model_name" "${MODEL_RECIPE}")
    local max_model_len gpu_mem_util max_num_seqs tool_call_parser reasoning_parser
    max_model_len=$(recipe_field "${MODEL_RECIPE}" "max_model_len" "262144")
    gpu_mem_util=$(recipe_field "${MODEL_RECIPE}" "gpu_memory_utilization" "0.6")
    max_num_seqs=$(recipe_field "${MODEL_RECIPE}" "max_num_seqs" "15")
    tool_call_parser=$(recipe_field "${MODEL_RECIPE}" "tool_call_parser" "qwen3_xml")
    reasoning_parser=$(recipe_field "${MODEL_RECIPE}" "reasoning_parser" "qwen3")
    local auto_tool_choice trust_remote shm_size
    auto_tool_choice=$(recipe_field "${MODEL_RECIPE}" "enable_auto_tool_choice" "true")
    trust_remote=$(recipe_field "${MODEL_RECIPE}" "trust_remote_code" "true")
    shm_size=$(recipe_field "${MODEL_RECIPE}" "shm_size" "2g")
    local model_revision extra_flags_str
    model_revision=$(recipe_field "${MODEL_RECIPE}" "revision" "")
    extra_flags_str=$(recipe_field "${MODEL_RECIPE}" "extra_flags" "")

    local worker_config_dir="${GENERATED_DIR}/workers"
    mkdir -p "${worker_config_dir}"
    local worker_env_file="${worker_config_dir}/${NODE_ID}.env"

    {
        echo "VLLM_API_KEY=$(cat "${SECRETS_DIR}/vllm_api_key.txt")"
        echo "NODE_ID=${NODE_ID}"
        echo "NODE_IP=${NODE_IP}"
        echo "SVC_UID=${SVC_UID}"
        echo "SVC_GID=${SVC_GID}"
        echo "HUB_IP=${HUB_LAN_IP}"
        # HF model cache is NOT decided here: deploy_worker picks it after
        # checking NFS, and mounts the matching volume. Nothing writes
        # HF_HUB_CACHE into this env-file, so there is exactly one source.
    } > "${worker_env_file}"
    chmod 600 "${worker_env_file}"
    chown_svc "${worker_env_file}"

    local container_name="vllm-${NODE_ID}"

    # Remove a stale container from a previous run so the new flags apply
    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log "Removing existing container ${container_name}..."
        docker rm -f "${container_name}" > /dev/null
    fi

    log "Starting vLLM container for model: ${served_model_name}"

    # Per-recipe image and driver floor: a recipe documents the NGC tag the
    # model is validated against and the minimum host driver for it. Falls
    # back to the kit defaults when the recipe omits the fields.
    VLLM_IMAGE=$(recipe_field "${MODEL_RECIPE}" "vllm_image" "${VLLM_IMAGE_DEFAULT}")
    local min_driver
    min_driver=$(recipe_field "${MODEL_RECIPE}" "min_driver" "${MIN_DRIVER_VERSION}")

    # Version compare: sort -V orders dotted versions correctly
    # ("580.178.04" >= "580.00"; "526.x" < "580.00").
    # One driver version per node is fine on GB10 (single GPU); with multiple
    # lines we still take the first, which matches the primary GPU nvidia-smi
    # initializes first in practice.
    local host_driver
    host_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
    if [ -n "${host_driver}" ]; then
        log "Host NVIDIA driver: ${host_driver} (kit baseline >= ${MIN_DRIVER_VERSION})"
        if ! driver_meets_min "${host_driver}" "${min_driver}"; then
            log_error "Host NVIDIA driver ${host_driver} is below the baseline ${min_driver} required by ${VLLM_IMAGE}."
            log_error "Upgrade the driver (see README: 'Driver baseline') or pick a recipe pinned to an older NGC image."
            exit 1
        fi
    else
        log_warn "Could not read the NVIDIA driver version via nvidia-smi; skipping the driver baseline check."
    fi

    # Preflight: ensure the pinned image is usable. Skipped when already
    # pulled locally (use rollback + redeploy to force a fresh pull).
    if docker image inspect "${VLLM_IMAGE}" > /dev/null 2>&1; then
        log "Using already-pulled image ${VLLM_IMAGE}"
    else
        log "Pulling worker image ${VLLM_IMAGE} (first pull is ~8.5 GB on arm64)..."
        if ! docker pull "${VLLM_IMAGE}"; then
            log_error "Could not pull ${VLLM_IMAGE}."
            log_error "Check the image reference and tag format; NGC tags look like 26.01-py3."
            log_error "If the tag has moved on, update VLLM_IMAGE_DEFAULT in infrastructure/deploy.sh, or pin vllm_image in the node's recipe."
            exit 1
        fi
    fi

    # Probe the image against the real driver. Image build floors (embedded
    # in the NGC image) are the only source of truth; recipe-claimed floors
    # can be wrong. One throwaway container: libnvidia-container's check
    # runs in ~2s and names the required release when it fails.
    local probe_out required_release
    # --entrypoint true: the check only needs libnvidia-container's stderr
    # ("Driver Release ..." requirement line), which fires at container
    # start. Running the image's real entrypoint here executes its actual
    # command ("vllm serve true" on serve-entrypoint digests) and can take
    # minutes or hang the deploy (issue #19).
    probe_out=$(docker run --rm --gpus all --entrypoint true "${VLLM_IMAGE}" 2>&1 || true)
    required_release=$(echo "${probe_out}" | grep -oP '(?<=Driver Release )[0-9.]+' | head -1 || true)
    if [ -n "${required_release}" ]; then
        log_error "${VLLM_IMAGE} requires NVIDIA driver ${required_release}; this host has ${host_driver:-unknown}."
        log_error "The upstream cu130 track (vllm/vllm-openai:cu130-nightly) matches the 580.x driver family; or upgrade the host driver (README: 'Driver baseline')."
        exit 1
    fi

    local port_flags=()
    if [ "${NON_SUDO_MODE}" = true ]; then
        log_warn "In non-sudo mode: binding to 0.0.0.0:${VLLM_PORT} (NOT restricted to the hub)"
        port_flags=(--publish "0.0.0.0:${VLLM_PORT}:${VLLM_PORT}")
    else
        port_flags=(--publish "${NODE_IP}:${VLLM_PORT}:${VLLM_PORT}")
    fi

    local extra_flags=()
    [ "${auto_tool_choice}" = "true" ] && extra_flags+=("--enable-auto-tool-choice")
    [ "${trust_remote}" = "true" ] && extra_flags+=("--trust-remote-code")
    # Recipe-pinned checkpoint revision: selects the exact HF revision so
    # every node loads byte-identical weights.
    [ -n "${model_revision}" ] && extra_flags+=("--revision" "${model_revision}")
    # Recipe-declared vLLM serve flags, whitespace split. Quotes inside the
    # field are not honored; use single-token flags in the recipe.
    # shellcheck disable=SC2206
    extra_flags+=(${extra_flags_str})

    # vLLM needs shared memory for activation/compile buffers; size comes from
    # the recipe (shm_size). This is an ipc/disc setting, not host networking.
    # HF MODEL CACHE — DO NOT DELETE: weights are downloaded once (~23 GB
    # for the default recipe) and every redeploy/probe/test reuses them.
    # The cache lives in exactly one place and is never removed by the
    # script; wiping it forces a full re-download and wears the SSD.
    #   - NFS mounted at /mnt/shared-models: shared multi-node cache,
    #     mounted into the container at the same host path. Takes precedence.
    #   - otherwise: per-node host dir ${GENERATED_DIR}/hf-cache, bind-mounted
    #     read-write at /hf-cache (HF_HUB_CACHE). Persists across container
    #     recreation, redeploys, and --restart-services because it lives
    #     outside docker's lifespan. The container runs as the service user,
    #     so the local dir must be owned by it. HOME is redirected to a
    #     writable path: with --user the image's default HOME (/ or /root)
    #     is unwritable and tooling (HF download, torch) dies on first write.
    # To reclaim disk intentionally, remove the specific model dir under
    # hf-cache/<org>/<model> — never the whole directory tree blindly.
    local cache_flags=()
    if [ -d "/mnt/shared-models" ] && mountpoint -q "/mnt/shared-models" 2>/dev/null; then
        log "Using NFS model cache at /mnt/shared-models"
        cache_flags=(--env "HF_HUB_CACHE=/mnt/shared-models" -v "/mnt/shared-models:/mnt/shared-models")
    else
        local hf_cache_dir="${GENERATED_DIR}/hf-cache"
        mkdir -p "${hf_cache_dir}"
        chown_svc "${hf_cache_dir}"
        cache_flags=(--env "HF_HUB_CACHE=/hf-cache" -v "${hf_cache_dir}:/hf-cache")
        # Surface cache hits so operators can tell "download" from "load".
        if [ -n "$(ls -A "${hf_cache_dir}" 2>/dev/null)" ]; then
            local cache_kb
            cache_kb=$(du -sk "${hf_cache_dir}" 2>/dev/null | cut -f1)
            log "HF model cache already populated at ${hf_cache_dir} ($((cache_kb / 1024 / 1024)) GB) — no re-download."
        else
            log "HF model cache empty; the worker will download the checkpoint into ${hf_cache_dir} (one-time, ~23 GB for the default recipe)."
        fi
    fi

    # Command form depends on the image's entrypoint, which differs between
    # image families AND between upstream builds:
    #   - NGC images: pass-through entrypoint -> the command must be the full
    #     "vllm serve <model> ..." (bare "--model" gets parsed as a CLI
    #     subcommand and aborts).
    #   - Upstream vllm-openai (cu130-nighly, digest 3dbe092e and later):
    #     ENTRYPOINT is ["vllm","serve"] -> a literal "vllm serve" prefix
    #     would double up ("unrecognized arguments: vllm serve"); the command
    #     must be bare serve flags. Earlier upstream builds had the CLI as
    #     the entrypoint, where "vllm serve ..." also works.
    # So: probe the image's entrypoint after pull and add the "vllm serve"
    # prefix only when the entrypoint is pass-through (empty or neither
    # vllm nor serve).
    local vllm_entrypoint serve_prefix
    vllm_entrypoint=$(docker image inspect --format '{{json .Config.Entrypoint}}' "${VLLM_IMAGE}" 2>/dev/null || echo null)
    serve_prefix=("vllm" "serve")
    if echo "${vllm_entrypoint}" | grep -q -e '"vllm' -e 'vllm"' -e 'serve' ; then
        serve_prefix=()
    fi
    docker run -d \
        --name "${container_name}" \
        --network "${DOCKER_NETWORK}" \
        --user "${SVC_UID}:${SVC_GID}" \
        --security-opt=no-new-privileges \
        --env HOME=/tmp \
        --env USER="${SVC_USERNAME}" \
        --env LOGNAME="${SVC_USERNAME}" \
        --env-file "${worker_env_file}" \
        "${cache_flags[@]}" \
        --gpus all \
        --restart unless-stopped \
        --shm-size "${shm_size}" \
        "${port_flags[@]}" \
        --health-cmd "curl -f http://localhost:${VLLM_PORT}/health || exit 1" \
        --health-interval 30s \
        --health-timeout 10s \
        --health-retries 5 \
        --health-start-period 180s \
        "${VLLM_IMAGE}" \
        ${serve_prefix[@]+"${serve_prefix[@]}"} \
        --model "${hf_model_name}" \
        --served-model-name "${served_model_name}" \
        --host 0.0.0.0 \
        --port "${VLLM_PORT}" \
        --max-model-len "${max_model_len}" \
        --gpu-memory-utilization "${gpu_mem_util}" \
        --max-num-seqs "${max_num_seqs}" \
        --reasoning-parser "${reasoning_parser}" \
        --tool-call-parser "${tool_call_parser}" \
        "${extra_flags[@]+"${extra_flags[@]}"}"

    log "Worker deployed successfully."
    log "vLLM serving ${served_model_name} at http://${NODE_IP}:${VLLM_PORT}/v1"
}

# Load this node's identity from the inventory (by IP) for --restart-services
load_node_from_inventory() {
    local ip
    ip=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
    [ -z "${ip}" ] && { log_error "Could not detect this node's IP."; exit 1; }

    NODE_ID=$(yq eval ".nodes[] | select(.lan_ip == \"${ip}\") | .node_id" "${INVENTORY_FILE}" 2>/dev/null || true)
    if [ -z "${NODE_ID}" ]; then
        log_error "No inventory entry for IP ${ip} on this node. Run the full interactive deploy first."
        exit 1
    fi
    NODE_IP="${ip}"
    NODE_ROLE=$(yq eval ".nodes[] | select(.node_id == \"${NODE_ID}\") | .role" "${INVENTORY_FILE}")
    MODEL_RECIPE=$(yq eval ".nodes[] | select(.node_id == \"${NODE_ID}\") | .model_recipe" "${INVENTORY_FILE}" 2>/dev/null || true)
    if [ "${MODEL_RECIPE}" = "null" ]; then MODEL_RECIPE=""; fi
    HUB_LAN_IP=$(yq eval '.nodes[] | select(.role == "hub" or .role == "hub+worker") | .lan_ip' "${INVENTORY_FILE}" 2>/dev/null | head -1)
    HUB_LAN_IP="${HUB_LAN_IP:-${NODE_IP}}"
    local subnets
    subnets=$(yq eval '.lab.client_subnets // [] | join(" ")' "${INVENTORY_FILE}" 2>/dev/null || true)
    if [ -n "${subnets}" ]; then
        # shellcheck disable=SC2206
        CLIENT_SUBNETS=(${subnets})
    fi
    log "Restarting: ${NODE_ID} role=${NODE_ROLE} ip=${NODE_IP} recipe=${MODEL_RECIPE:-none}"
}

# Report this node's install state. Read-only; safe to run repeatedly and
# unattended. Exit code: 0 healthy, 1 something is broken.
show_status() {
    echo "=========================================="
    echo "  spark-kit-3 status: $(hostname)"
    echo "=========================================="

    local host_driver="unknown"
    host_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
    if [ -n "${host_driver}" ]; then
        echo "GPU driver:          ${host_driver} (kit baseline ${MIN_DRIVER_VERSION})"
        if driver_meets_min "${host_driver}" "${MIN_DRIVER_VERSION}"; then
            echo "  driver baseline:   OK"
        else
            echo "  driver baseline:   BELOW BASELINE (see README: Driver baseline)"
        fi
    else
        echo "GPU driver:          not detected (nvidia-smi failed)"
    fi

    # Inventory record for this node (local file; no docker needed).
    local my_ip my_id my_role my_recipe
    my_ip=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
    my_id=$(yq eval ".nodes[] | select(.lan_ip == \"${my_ip}\") | .node_id" "${INVENTORY_FILE}" 2>/dev/null || true)
    if [ -n "${my_id}" ] && [ "${my_id}" != "null" ]; then
        my_role=$(yq eval ".nodes[] | select(.node_id == \"${my_id}\") | .role" "${INVENTORY_FILE}")
        my_recipe=$(yq eval ".nodes[] | select(.node_id == \"${my_id}\") | .model_recipe" "${INVENTORY_FILE}" 2>/dev/null || true)
        echo "Inventory record:    ${my_id} (role: ${my_role}${my_recipe:+, recipe: ${my_recipe}})"
    else
        echo "Inventory record:    none for IP ${my_ip:-?} (node never fully deployed here)"
    fi

    echo ""
    echo "Containers (docker ps -a):"
    if command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1; then
        docker ps -a --filter "name=litellm" --filter "name=vllm-" \
            --format "  {{.Names}}\t{{.Status}}\t{{.Image}}" || true
    else
        echo "  (docker not available from this user/daemon down)"
    fi

    echo ""
    echo "Endpoints (probed only if their container is running):"
    local broken=0
    if command -v docker > /dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -qx "litellm-proxy"; then
        if curl -fsS -o /dev/null -m 5 "http://${my_ip:-localhost}:${LITELLM_PORT}/health/liveliness" 2>/dev/null; then
            echo "  LiteLLM  http://${my_ip:-?}:${LITELLM_PORT}/v1   healthy"
            echo "  LiteLLM UI: http://${my_ip:-?}:${LITELLM_PORT}/ui — login in ${SECRETS_DIR}/ui_username.txt / ui_password.txt (sudo cat)"
        else
            echo "  LiteLLM  http://${my_ip:-?}:${LITELLM_PORT}/v1   NOT RESPONDING (docker logs litellm-proxy)"
            broken=1
        fi
    fi
    if [ -n "${my_id}" ] && [ "${my_id}" != "null" ] && command -v docker > /dev/null 2>&1 \
        && docker ps --format '{{.Names}}' | grep -qx "vllm-${my_id}"; then
        if curl -fsS -o /dev/null -m 5 "http://localhost:${VLLM_PORT}/health" 2>/dev/null; then
            echo "  vLLM     http://${my_ip:-?}:${VLLM_PORT}/v1    healthy"
        else
            echo "  vLLM     http://${my_ip:-?}:${VLLM_PORT}/v1    NOT RESPONDING (docker logs vllm-${my_id})"
            broken=1
        fi
    fi
    if docker ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null | grep -E '^(litellm|vllm-)' | grep -qiE 'restart|unhealthy|exited'; then
        echo ""
        echo "  [!] One or more containers are restarting/exited/unhealthy — see 'docker logs <name>'."
        broken=1
    fi

    echo ""
    echo "Model cache:"
    local hf_cache="${GENERATED_DIR}/hf-cache"
    if [ -d "${hf_cache}" ]; then
        echo "  ${hf_cache}: $(du -sh "${hf_cache}" 2>/dev/null | cut -f1 || echo ?)"
    else
        echo "  ${hf_cache}: not created yet (first model download has not run)"
    fi

    echo ""
    if [ "${broken}" = 0 ]; then
        echo "Verdict: nothing looks broken. To confirm end-to-end: ./scripts/verify.sh"
    else
        echo "Verdict: BROKEN (see [!] items above). Re-run ./infrastructure/deploy.sh to repair;"
        echo "it will offer to reuse this node's recorded configuration."
    fi
    return "${broken}"
}

# Ensure containers on the kit's bridge can reach the internet and each
# other. ufw's default-forward policy + Docker's inserted chains silently
# drop container egress on user-created bridges (observed: Errno 101 inside
# containers while the host browses fine). Two layers, both idempotent:
#   1. runtime: ACCEPT rules at the top of Docker's DOCKER-USER chain —
#      evaluated before anything can drop the traffic;
#   2. persistent: a marked block in /etc/ufw/after.rules so the rules
#      survive reboots and `ufw reload`.
# Resolve the subnet rules must allow. The pinned default only applies to
# networks we create; a network that already exists (e.g. from an earlier
# deploy, auto-assigned subnet) keeps its subnet — allow THAT, or container
# egress stays broken while the rules point at a subnet nothing uses.
resolve_network_subnet() {
    local subnet
    if docker network inspect "${DOCKER_NETWORK}" > /dev/null 2>&1; then
        subnet=$(docker network inspect "${DOCKER_NETWORK}" \
            --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | head -1)
    fi
    echo "${subnet:-${DOCKER_NETWORK_SUBNET}}"
}

# Provision what Docker's disabled iptables integration would have done:
# ip_forward on, MASQUERADE for the bridge subnet, FORWARD accepts.
# Idempotent; filter rule persistence lives in the after.rules block, and
# NAT persistence in the marked block in /etc/ufw/before.rules.
ensure_manual_container_nat() {
    local subnet="$1"

    # IP forwarding (runtime + persistent).
    if [ "$(sysctl -n net.ipv4.ip_forward)" != "1" ]; then
        sysctl -w net.ipv4.ip_forward=1 > /dev/null
    fi
    local sysctl_file="/etc/sysctl.d/60-spark-kit-3-forward.conf"
    if [ ! -f "${sysctl_file}" ] || ! grep -q "net.ipv4.ip_forward=1" "${sysctl_file}"; then
        echo "net.ipv4.ip_forward=1" > "${sysctl_file}"
    fi

    # MASQUERADE for container egress (nat POSTROUTING). Runtime + persistent
    # (ufw's nat table lives in before.rules; append a marked block there).
    # ${masq_rule} is deliberately word-split at the call sites below.
    local masq_rule="-s ${subnet} ! -d ${subnet} -j MASQUERADE"
    # shellcheck disable=SC2086
    if ! iptables -t nat -C POSTROUTING ${masq_rule} 2>/dev/null; then
        # shellcheck disable=SC2086
        iptables -t nat -A POSTROUTING ${masq_rule}
    fi

    local nat_file="/etc/ufw/before.rules"
    local nat_begin="# BEGIN spark-kit-3 container NAT"
    local nat_end="# END spark-kit-3 container NAT"
    if ! grep -qF "${nat_begin}" "${nat_file}"; then
        # ufw's before.rules starts its *nat table at the top; append a
        # dedicated nat section after the filter sections (ufw supports
        # multiple table sections).
        local tmp
        tmp=$(mktemp)
        {
            echo ""
            echo "*nat"
            echo "${nat_begin}"
            echo ":POSTROUTING ACCEPT [0:0]"
            echo "-A POSTROUTING ${masq_rule}"
            echo "${nat_end}"
            echo "COMMIT"
        } > "${tmp}"
        if ! cat "${tmp}" >> "${nat_file}";  then
            rm -f "${tmp}"
            log_warn "Could not persist NAT rules to ${nat_file} (runtime NAT is active; it will be re-applied on next deploy)."
        else
            rm -f "${tmp}"
        fi
    fi

    # FORWARD accepts (runtime; filter persistence comes from after.rules).
    local -a fwd_rules=(
        "-s ${subnet} -d ${subnet} -j ACCEPT"
        "-s ${subnet} ! -d ${subnet} -j ACCEPT"
        "-d ${subnet} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    )
    local rule
    # ${rule} is intentionally unquoted: each entry is multiple iptables
    # arguments that must word-split.
    # shellcheck disable=SC2086
    for rule in "${fwd_rules[@]}"; do
        if ! iptables -C FORWARD ${rule} 2>/dev/null; then
            iptables -I FORWARD 1 ${rule}
        fi
    done
    log "Manual container NAT + forwarding provisioned for ${subnet}"
}

ensure_container_forward_allowances() {
    if [ "${NON_SUDO_MODE}" = true ]; then
        return 0
    fi

    # 1. Runtime rules. Preferred: Docker's DOCKER-USER chain (top of
    #    FORWARD). Fallback: if the chain does not exist, Docker's iptables
    #    integration is disabled on this host (observed on one Spark:
    #    daemon.json iptables=false) — then containers have no masquerade
    #    and NO route out (Errno 101) no matter what filter rules we add, so
    #    provision ip_forward + NAT + FORWARD accepts by hand.
    local ipt_ok="no"
    local ipt_err=""
    if ipt_err=$(iptables -L DOCKER-USER 2>&1); then
        ipt_ok="yes"
    fi

    local subnet
    subnet=$(resolve_network_subnet)

    if [ "${ipt_ok}" = "yes" ]; then
        local -a rules=(
            "-s ${subnet} -d ${subnet} -j ACCEPT"
            "-s ${subnet} ! -d ${subnet} -j ACCEPT"
            "-s ! ${subnet} -d ${subnet} -j ACCEPT"
        )
        local rule
        # ${rule} is intentionally unquoted: each entry is multiple iptables
        # arguments that must word-split.
        # shellcheck disable=SC2086
        for rule in "${rules[@]}"; do
            if ! iptables -C DOCKER-USER ${rule} 2>/dev/null; then
                if ! iptables -I DOCKER-USER 1 ${rule}; then
                    log_warn "Could not add forwarding rule '${rule}' to DOCKER-USER."
                fi
            fi
        done
        log "Container forwarding rules active in DOCKER-USER for ${subnet}"

        # 1b. Published-port guard. Docker's DNAT for published ports
        # bypasses ufw's INPUT chain, so source restrictions for LAN clients
        # must live in DOCKER-USER (evaluated before Docker's own accept
        # rules). Keep the DOCKER subnet, client subnets and the hub IP
        # allowed; drop everything else aimed at the kit's published ports.
        local -a guard_rules=()
        local gport gsub
        for gport in "${LITELLM_PORT}" "${VLLM_PORT}"; do
            if is_hub && [ "${gport}" = "${LITELLM_PORT}" ]; then
                guard_rules+=("-p tcp --dport ${gport} -j DROP")
                for gsub in "${CLIENT_SUBNETS[@]}"; do
                    guard_rules+=("-s ${gsub} -p tcp --dport ${gport} -j ACCEPT")
                done
                guard_rules+=("-s ${DOCKER_NETWORK_SUBNET} -p tcp --dport ${gport} -j ACCEPT")
            fi
            if is_worker && [ "${gport}" = "${VLLM_PORT}" ]; then
                guard_rules+=("-p tcp --dport ${gport} -j DROP")
                [ -n "${HUB_LAN_IP}" ] && guard_rules+=("-s ${HUB_LAN_IP} -p tcp --dport ${gport} -j ACCEPT")
                guard_rules+=("-s ${DOCKER_NETWORK_SUBNET} -p tcp --dport ${gport} -j ACCEPT")
            fi
        done
        # Insert in reverse at position 1 so the final order is
        # accepts-then-drops, all ahead of the generic rules above.
        local -i i
        for ((i = ${#guard_rules[@]} - 1; i >= 0; i--)); do
            # shellcheck disable=SC2086
            if ! iptables -C DOCKER-USER ${guard_rules[i]} 2>/dev/null; then
                if ! iptables -I DOCKER-USER 1 ${guard_rules[i]}; then
                    log_warn "Could not add published-port guard '${guard_rules[i]}'."
                fi
            fi
        done
        if [ "${#guard_rules[@]}" -gt 0 ]; then
            log "Published-port guard active in DOCKER-USER (vLLM ${VLLM_PORT}, LiteLLM ${LITELLM_PORT})."
            log_warn "DOCKER-USER rules are runtime-only; re-run the deploy after a reboot (or dockerd restart) to restore them."
        fi
    else
        log_warn "DOCKER-USER chain missing (${ipt_err})."
        log_warn "Docker's iptables integration appears disabled; provisioning NAT + forwarding manually."
        ensure_manual_container_nat "${subnet}"
    fi

    # 2. Persistent rules surviving reboot / ufw reload.
    local rules_file="/etc/ufw/after.rules"
    local marker_begin="# BEGIN spark-kit-3 container forwarding"
    local marker_end="# END spark-kit-3 container forwarding"

    if [ -f "${rules_file}" ] && grep -qF "${marker_begin}" "${rules_file}"; then
        # Subnet may have changed (network recreated); refresh the block.
        sed -i "/${marker_begin}/,/${marker_end}/d" "${rules_file}"
    fi

    log "Writing persistent container forwarding rules (${subnet}) to ${rules_file}..."
    local tmp
    tmp=$(mktemp)
    {
        echo ""
        echo "${marker_begin}"
        echo "# Container egress + intra-bridge traffic for ${DOCKER_NETWORK} (fixes Errno 101)"
        echo "-A ufw-after-forward -s ${subnet} -d ${subnet} -j ACCEPT"
        echo "-A ufw-after-forward -s ${subnet} ! -d ${subnet} -j ACCEPT"
        echo "-A ufw-after-forward -s ! ${subnet} -d ${subnet} -j ACCEPT"
        echo "${marker_end}"
    } > "${tmp}"
    if ! cat "${tmp}" >> "${rules_file}"; then
        rm -f "${tmp}"
        log_error "Could not write to ${rules_file}."
        return 1
    fi
    rm -f "${tmp}"
    ufw reload > /dev/null 2>&1 || true
    log "Persistent container forwarding rules installed for ${subnet}."
}

# Main deployment
main() {
    parse_args "$@"
    if [ "${STATUS_ONLY}" = false ]; then
        validate_mode
    fi
    if [ "${SECURE_UI}" = true ]; then
        # Needs yq (config regen) + docker; no other deployment changes.
        # shellcheck disable=SC1091
        source "${KIT_DIR}/scripts/ensure-yq.sh"
        ensure_yq || { log_error "Could not provision mikefarah/yq."; return 1; }
        # shellcheck disable=SC1091
        source "${KIT_DIR}/scripts/lib-driver.sh"
        secure_ui
        return $?
    fi
    if [ "${STATUS_ONLY}" = true ]; then
        # Read-only: needs only the yq flavor check; no service changes.
        # Runs without sudo by design — status is the node operator's
        # unattended health check and must not require privilege.
        # shellcheck disable=SC1091
        source "${KIT_DIR}/scripts/ensure-yq.sh"
        ensure_yq || { log_error "Could not provision mikefarah/yq."; return 1; }
        # shellcheck disable=SC1091
        source "${KIT_DIR}/scripts/lib-driver.sh"
        show_status
        return $?
    fi
    step "Checking prerequisites"
    check_prerequisites
    touch_generated_dir

    if [ "${RESTART_ONLY}" = true ]; then
        STEP_TOTAL=5
        step "Reading node configuration from inventory"
        load_node_from_inventory
        step "Preparing service user and secrets"
        create_service_user
        generate_secrets   # idempotent: reuses secret files, rebuilds env files
        step "Starting services"
        if is_worker; then deploy_worker; fi
        if is_hub; then deploy_hub; fi
        step "Waiting for services to become healthy"
        if is_hub; then
            wait_healthy "litellm-postgres" "Postgres"
            wait_healthy "litellm-proxy" "LiteLLM"
        fi
        if is_worker; then
            wait_healthy "vllm-${NODE_ID}" "vLLM (${served_model_name:-model})"
        fi
        log ""
        log "=== Services restarted ==="
        log "To verify deployment, run: ./scripts/verify.sh"
        return 0
    fi

    if [ "${SYNC_KEYS_ONLY}" = true ]; then
        STEP_TOTAL=4
        if [ ! -f "${SECRETS_DIR}/hub.env" ]; then
            log_error "No hub.env found; run a full deploy on this node first."
            exit 1
        fi
        touch_secrets_dir
        step "Fetching worker API keys"
        sync_worker_keys
        step "Regenerating LiteLLM config"
        generate_litellm_config
        # Re-apply the stack with regenerated config; hub.env retains NODE_IP
        # and the new VLLM_KEY_* entries, so no re-prompting is needed.
        docker compose -f "${SCRIPT_DIR}/docker-compose.hub.yml" \
            --env-file "${SECRETS_DIR}/hub.env" \
            up -d --remove-orphans
        step "Restarting LiteLLM"
        wait_healthy "litellm-proxy" "LiteLLM"
        log "Worker keys synced and LiteLLM restarted."
        return 0
    fi

    step "Collecting configuration"
    collect_user_input

    # Step total depends on the role chosen: hub takes 10 steps, worker 8.
    if is_hub; then STEP_TOTAL=11; else STEP_TOTAL=8; fi

    step "Creating service user"
    create_service_user
    # Firewall BEFORE network/container creation: bringing ufw up after
    # Docker has wired its iptables chains is what broke container egress
    # (Errno 101, issue #14).
    step "Configuring firewall"
    setup_firewall
    step "Preparing Docker network"
    create_network
    step "Generating secrets"
    generate_secrets

    if is_hub; then
        step "Syncing worker keys and generating LiteLLM config"
        sync_worker_keys
        generate_litellm_config
    fi

    step "Starting services"
    if is_worker; then
        deploy_worker
    fi
    if is_hub; then
        deploy_hub
    fi

    step "Waiting for services to become healthy"
    if is_hub; then
        wait_healthy "litellm-postgres" "Postgres"
        wait_healthy "litellm-proxy" "LiteLLM"
    fi
    if is_worker; then
        wait_healthy "vllm-${NODE_ID}" "vLLM (${served_model_name:-model})"
    fi

    step "Recording node in inventory"
    if is_hub; then
        update_inventory
    fi
    setup_nfs

    if is_hub; then
        step "Provisioning Admin UI account"
        provision_ui_admin
    fi

    log ""
    log "=== Deployment Complete ==="
    if is_hub; then
        log "LiteLLM endpoint: http://${NODE_IP}:${LITELLM_PORT}/v1"
        log "LiteLLM UI (admin panel): http://${NODE_IP}:${LITELLM_PORT}/ui"
        if [ -f "${SECRETS_DIR}/env_login_disabled" ]; then
            log "LiteLLM UI login: $(cat "${SECRETS_DIR}/admin_email.txt") with the password you set via the invitation link."
            log "Bootstrap env-credential login is DISABLED."
        else
            log "Admin UI account email: $(cat "${SECRETS_DIR}/admin_email.txt" 2>/dev/null || echo "?")"
            if [ -f "${SECRETS_DIR}/admin_invite.json" ]; then
                local invite_id invite_url
                invite_id=$(yq eval '.id // ""' "${SECRETS_DIR}/admin_invite.json" 2>/dev/null || true)
                invite_url="http://${NODE_IP}:${LITELLM_PORT}/ui/onboarding?invitation_id=${invite_id}"
                log "Set YOUR password now — invitation link (copy it somewhere safe; NOT shown again; expires in 7 days):"
                log "  ${invite_url:-see ${KIT_DIR}/secrets/admin_invite.json}"
            else
                log_warn "No admin invitation on file. Log in with the bootstrap credentials and create an admin user in the UI."
            fi
            log_warn "Bootstrap UI credentials are still ACTIVE (admin / ${SECRETS_DIR}/ui_password.txt) — this is the critical warning LiteLLM shows. Set your password via the link above, then run: sudo $0 --secure-ui"
        fi
        if [ "${NON_SUDO_MODE}" = true ]; then
            log_warn "Firewall NOT configured - ensure port ${LITELLM_PORT} is secured manually"
        fi
    fi
    if is_worker; then
        log "vLLM worker active on port: ${VLLM_PORT}"
        log "Model download/loading continues in the background on first run:"
        log "  docker logs -f vllm-${NODE_ID}"
        log "Next step on the HUB node, run: sudo ./infrastructure/deploy.sh --sync-keys"
        log "so it can fetch this node's API key and route to it."
        if [ "${NON_SUDO_MODE}" = true ]; then
            log_warn "Firewall NOT configured - vLLM may be exposed to LAN"
        fi
    fi
    log ""
    log "To verify deployment, run: ./scripts/verify.sh"
    log "To rollback, run: sudo ./scripts/rollback.sh"
}

# Allow sourcing for tests without executing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
