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
VLLM_PORT="8000"
POSTGRES_PORT="5432"

# Service user
SERVICE_USER="llm-svc"
SERVICE_GROUP="llm-svc"

# Docker network
DOCKER_NETWORK="spark-kit-llm-net"

# Pinned images (arm64-capable, GB10-compatible).
# Single source of truth: docker-compose.hub.yml consumes these via env-file.
# - vLLM: NVIDIA NGC multi-arch image (linux/arm64 build verified for 26.10).
# - LiteLLM: stable branch tag from BerriAI's published images (cosign-signed).
VLLM_IMAGE="nvcr.io/nvidia/vllm:26.10"
LITELLM_IMAGE="ghcr.io/berriai/litellm:v1.83.7-stable"
POSTGRES_IMAGE="pgvector/pgvector:pg17"

# Global variables for user input
NODE_ROLE=""
NODE_ID=""
NODE_IP=""
CLIENT_SUBNETS=()
HUB_LAN_IP=""
MODEL_RECIPE=""

# Deployment mode
NON_SUDO_MODE=false
USE_CURRENT_USER=false
SYNC_KEYS_ONLY=false

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
STEP_NUM=0
STEP_TOTAL=9
step() {
    STEP_NUM=$((STEP_NUM + 1))
    printf '\n[%d/%d] %s...\n' "${STEP_NUM}" "${STEP_TOTAL}" "$1"
}

# Wait for a container to report healthy, with visible progress.
# $1 container name, $2 label. Bounded: after the timeout the script moves
# on and tells the user how to check (model downloads can outwait any wait).
wait_healthy() {
    local container="$1" label="$2"
    local tries=36 interval=10  # ~6 minutes
    local i
    for ((i = 1; i <= tries; i++)); do
        if docker inspect "${container}" --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; then
            printf '\r[%d/%d] %s: healthy ✓\n' "${i}" "${tries}" "${label}"
            return 0
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
        if [ "$(id -u)" = "0" ]; then
            log_warn "Running as root with --non-sudo flag. Using current user mode."
            USE_CURRENT_USER=true
        fi
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
  --non-sudo      Run without sudo (degraded security, testing only)
  --sync-keys     Hub only: fetch worker API keys over scp, regenerate
                  the LiteLLM config, and restart the LiteLLM container.
                  Run this after deploying new/re-keyed workers.
  --help, -h      Show this help message and exit

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

    # Check yq for YAML parsing (install if missing)
    if ! command -v yq &> /dev/null; then
        log "yq not found. Installing..."
        if command -v apt-get &> /dev/null && [ "${NON_SUDO_MODE}" = false ]; then
            apt-get update -qq && apt-get install -y -qq yq 2>&1 | grep -v "^Selecting\|^Preparing\|^Unpacking\|^Setting" || true
        elif command -v apk add &> /dev/null && [ "${NON_SUDO_MODE}" = false ]; then
            apk add --no-cache yq
        else
            log_error "Cannot install yq without root. Please install yq (https://github.com/mikefarah/yq) and try again."
            exit 1
        fi
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

# Try to detect node from inventory by IP
try_detect_node() {
    if [ -z "${NODE_IP}" ]; then
        return 0
    fi

    local node_id
    node_id=$(yq eval ".nodes[] | select(.lan_ip == \"${NODE_IP}\") | .node_id" "${INVENTORY_FILE}" 2>/dev/null || true)

    if [ -n "${node_id}" ]; then
        local detected_role
        detected_role=$(yq eval ".nodes[] | select(.node_id == \"${node_id}\") | .role" "${INVENTORY_FILE}" 2>/dev/null || true)

        log_info "Found existing node in inventory: ${node_id} (was: ${detected_role})"
        read -r -p "Use this node ID? [Y/n]: " response
        case "${response}" in
            [nN]) ;;
            *) NODE_ID="${node_id}" ;;
        esac
    fi
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
    try_detect_node
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

    echo ""
    echo "=========================================="
    echo "  Configuration Summary"
    echo "=========================================="
    echo "  Node ID:       ${NODE_ID}"
    echo "  Node IP:       ${NODE_IP}"
    echo "  Role:          ${NODE_ROLE}"
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
        export SVC_UID SVC_GID
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
    export SVC_UID SVC_GID
}

setup_firewall() {
    if [ "${NON_SUDO_MODE}" = true ]; then
        log_warn "Skipping firewall configuration in non-sudo mode"
        log_warn "vLLM ports may be exposed to the entire LAN!"
        return 0
    fi

    log "Configuring firewall..."

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
        ufw allow from "${HUB_LAN_IP}" to any port "${VLLM_PORT}" proto tcp comment 'Worker Hub Access'
        log "Allowed vLLM port ${VLLM_PORT} from hub at ${HUB_LAN_IP}"
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
        docker network create "${DOCKER_NETWORK}" > /dev/null
        log "Created Docker network: ${DOCKER_NETWORK}"
    else
        log "Docker network ${DOCKER_NETWORK} already exists."
    fi
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
            (umask 077 && openssl rand -base64 32 > "${DB_PASSWORD_FILE}")
            chown_svc "${DB_PASSWORD_FILE}"
            log "Generated DB password."
        fi

        if [ ! -f "${LITELLM_MASTER_KEY_FILE}" ]; then
            # LiteLLM requires the sk- prefix for the master key
            (umask 077 && echo "sk-$(openssl rand -hex 31)" > "${LITELLM_MASTER_KEY_FILE}")
            chown_svc "${LITELLM_MASTER_KEY_FILE}"
            log "Generated LiteLLM master key with sk- prefix."
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
        local hf served
        hf=$(recipe_field "${MODEL_RECIPE}" "model_name" "nvidia/Qwen3.6-35B-A3B-NVFP4")
        served=$(recipe_field "${MODEL_RECIPE}" "served_model_name" "${MODEL_RECIPE}")
        cat >> "${config_file}" << LITELLM_CONFIG_ENTRY
  - model_name: ${served}
    litellm_params:
      model: openai/${hf}
      api_base: http://host.docker.internal:${VLLM_PORT}/v1
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
        local wid wip wrecipe hf served
        wid="$(echo "${entry}" | cut -d'|' -f1)"
        wip="$(echo "${entry}" | cut -d'|' -f2)"
        wrecipe="$(echo "${entry}" | cut -d'|' -f3)"

        [ -f "${KIT_DIR}/recipes/${wrecipe}.yaml" ] || wrecipe="qwen3.6-35b-a3b-nvfp4"
        hf=$(recipe_field "${wrecipe}" "model_name" "nvidia/Qwen3.6-35B-A3B-NVFP4")
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
      model: openai/${hf}
      api_base: http://${wip}:${VLLM_PORT}/v1
      api_key: ${key_var}
LITELLM_CONFIG_ENTRY
    done <<< "${workers}"

    cat >> "${config_file}" << 'LITELLM_CONFIG_FOOTER'

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  disable_env_credential_login: true
LITELLM_CONFIG_FOOTER

    log "Generated LiteLLM config: ${config_file}"
    chmod 640 "${config_file}"
    chown_svc "${config_file}"
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
    unset NODE_ID NODE_ROLE NODE_IP MODEL_RECIPE
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
    gpu_mem_util=$(recipe_field "${MODEL_RECIPE}" "gpu_memory_utilization" "0.8")
    max_num_seqs=$(recipe_field "${MODEL_RECIPE}" "max_num_seqs" "15")
    tool_call_parser=$(recipe_field "${MODEL_RECIPE}" "tool_call_parser" "qwen3_xml")
    reasoning_parser=$(recipe_field "${MODEL_RECIPE}" "reasoning_parser" "qwen3")
    local auto_tool_choice trust_remote shm_size
    auto_tool_choice=$(recipe_field "${MODEL_RECIPE}" "enable_auto_tool_choice" "true")
    trust_remote=$(recipe_field "${MODEL_RECIPE}" "trust_remote_code" "true")
    shm_size=$(recipe_field "${MODEL_RECIPE}" "shm_size" "2g")

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
        if [ -d "/mnt/shared-models" ] && mountpoint -q "/mnt/shared-models" 2>/dev/null; then
            echo "HF_HUB_CACHE=/mnt/shared-models"
        fi
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

    # vLLM needs shared memory for activation/compile buffers; size comes from
    # the recipe (shm_size). This is an ipc/disc setting, not host networking.
    docker run -d \
        --name "${container_name}" \
        --network "${DOCKER_NETWORK}" \
        --user "${SVC_UID}:${SVC_GID}" \
        --security-opt=no-new-privileges \
        --env-file "${worker_env_file}" \
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

# Main deployment
main() {
    parse_args "$@"
    validate_mode
    step "Checking prerequisites"
    check_prerequisites
    touch_generated_dir

    if [ "${SYNC_KEYS_ONLY}" = true ]; then
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

    step "Creating service user"
    create_service_user
    step "Preparing Docker network"
    create_network
    step "Configuring firewall"
    setup_firewall
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

    log ""
    log "=== Deployment Complete ==="
    if is_hub; then
        log "LiteLLM endpoint: http://${NODE_IP}:${LITELLM_PORT}/v1"
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
