#!/usr/bin/env bash
# deploy.sh - Unified deployment script for DGX Spark LLM Stack (kit-3)
#
# This single script deploys the stack on any Spark node.
# It supports both sudo (secure) and non-sudo (degraded security) modes.
#
# Usage (Secure - Recommended):
#   sudo ./deploy.sh                    # Full interactive mode with sudo
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

# Pinned images (GB10-capable, arm64-compatible)
# Using stable version tags - replace with actual digests for production
VLLM_IMAGE="vllm/vllm-openai:latest"  # arm64-capable, GB10-compatible
POSTGRES_IMAGE="pgvector/pgvector:pg17"
LITELLM_IMAGE="ghcr.io/berriai/litellm:v1.65.0"

# Global variables for user input
NODE_ROLE=""
NODE_ID=""
NODE_IP=""
CLIENT_SUBNETS=()
HUB_LAN_IP=""

# Deployment mode
NON_SUDO_MODE=false
USE_CURRENT_USER=false

# --- Functions ---

log() {
    echo "[+] $1"
}

log_error() {
    echo "[!] ERROR: $1" >&2
}

log_warn() {
    echo "[!] WARNING: $1" >&2
}

log_info() {
    echo "[i] $1"
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
This script supports two modes:

SECURE MODE (Recommended):
  sudo ./deploy.sh
  - Full security enforcement
  - Creates service user (llm-svc)
  - Configures firewall automatically
  - Requires root access

NON-SUDO MODE (Degraded Security):
  ./deploy.sh --non-sudo
  - Runs without root
  - Containers run as current user
  - No firewall configuration
  - No service isolation
  - For testing/development only

Options:
  --non-sudo      Run without sudo (degraded security)
  --help, -h      Show this help message and exit

The script will prompt you for all required information interactively.
EOF
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed. Please install Docker and try again."
        exit 1
    fi
    
    # Check Docker daemon
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running. Please start Docker and try again."
        exit 1
    fi
    
    # Check for NVIDIA GPU
    if ! nvidia-smi &> /dev/null; then
        log_error "NVIDIA GPU not detected. This kit requires NVIDIA GPU drivers."
        exit 1
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
            apt-get update -qq && apt-get install -y -qq yq 2>&1 | grep -v "^Selecting\|^Preparing\|^Unpacking\|^Setting"
        elif command -v apk &> /dev/null && [ "${NON_SUDO_MODE}" = false ]; then
            apk add --no-cache yq
        else
            log_error "Cannot install yq without root. Please install yq (https://github.com/mikefarah/yq) and try again."
            exit 1
        fi
    fi
    
    log "All prerequisites met."
}

# Create generated directory
touch_generated_dir() {
    mkdir -p "${GENERATED_DIR}"
    chmod 750 "${GENERATED_DIR}"
}

# Create secrets directory
touch_secrets_dir() {
    mkdir -p "${SECRETS_DIR}"
    
    # In non-sudo mode, current user owns secrets
    if [ "${USE_CURRENT_USER}" = true ]; then
        chmod 700 "${SECRETS_DIR}"
    else
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "${SECRETS_DIR}"
        chmod 750 "${SECRETS_DIR}"
    fi
}

# Detect or prompt for node IP
prompt_node_ip() {
    # Try to auto-detect IP
    CURRENT_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    
    if [ -n "${CURRENT_IP}" ]; then
        read -r -p "Detected node IP: ${CURRENT_IP}. Is this correct? [Y/n]: " response
        case "${response}" in
            [nN])
                read -r -p "Enter node IP address: " NODE_IP
                NODE_IP="${NODE_IP}"
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
     - Perfect for the main Spark node

  2. Hub only
     - Runs LiteLLM (proxy) + Postgres only
     - This node coordinates workers but does NOT serve models itself

  3. Worker only
     - Runs vLLM worker only
     - This node serves a model and connects to the hub

EOF
    
    read -r -p "Enter choice [1-3, default=1]: " choice
    
    case "${choice:-1}" in
        1)
            NODE_ROLE="hub+worker"
            IS_HUB=true
            IS_WORKER=true
            ;;
        2)
            NODE_ROLE="hub"
            IS_HUB=true
            IS_WORKER=false
            ;;
        3)
            NODE_ROLE="worker"
            IS_HUB=false
            IS_WORKER=true
            ;;
        *)
            log_error "Invalid choice. Please enter 1, 2, or 3."
            prompt_role
            ;;
    esac
    
    log "Selected role: ${NODE_ROLE}"
}

# Prompt for client subnets
prompt_client_subnets() {
    if [ "${IS_HUB}" != true ]; then
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
    
    read -r -p "Enter client subnet(s) separated by spaces: " input_subnets
    
    if [ -z "${input_subnets}" ]; then
        log_error "At least one client subnet is required for hub deployment."
        prompt_client_subnets
    fi
    
    # Validate CIDR format
    CLIENT_SUBNETS=()
    for subnet in ${input_subnets}; do
        if [[ "$subnet" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            CLIENT_SUBNETS+=("$subnet")
        else
            log_error "Invalid CIDR notation: $subnet. Expected format: X.X.X.X/XX"
            prompt_client_subnets
            return
        fi
    done
    
    log "Client subnets: ${CLIENT_SUBNETS[*]}"
}

# Prompt for hub IP if this is a worker
prompt_hub_ip() {
    if [ "${IS_HUB}" = true ]; then
        HUB_LAN_IP="${NODE_IP}"
        return 0
    fi
    
    # This is a worker node, need hub IP
    echo ""
    cat << EOF
This node will be a worker and needs to connect to the LiteLLM hub.

Please provide the IP address of your hub node.
EOF
    
    read -r -p "Enter hub node IP address: " HUB_LAN_IP
    
    if [ -z "${HUB_LAN_IP}" ]; then
        log_error "Hub IP is required for worker nodes."
        prompt_hub_ip
    fi
    
    log "Hub IP: ${HUB_LAN_IP}"
}

# Try to detect node from inventory
try_detect_node() {
    # Only try if NODE_IP is set
    if [ -z "${NODE_IP:-}" ]; then
        return 1
    fi
    
    local node_id
    node_id=$(yq eval '.nodes[] | select(.lan_ip == "'"${NODE_IP}"'") | .node_id' "${INVENTORY_FILE}" 2>/dev/null || echo "")
    
    if [ -n "${node_id}" ]; then
        NODE_ID="${node_id}"
        local detected_role
        detected_role=$(yq eval '.nodes[] | select(.node_id == "'"${NODE_ID}"'") | .role' "${INVENTORY_FILE}" 2>/dev/null || echo "")
        
        echo ""
        log_info "Detected existing node in inventory: ${NODE_ID} (was: ${detected_role})"
        read -r -p "Use this node ID? [Y/n]: " response
        case "${response}" in
            [nN])
                NODE_ID=""
                ;;
        esac
    fi
    
    return 0
}

# Prompt for node ID
prompt_node_id() {
    if [ -n "${NODE_ID:-}" ]; then
        log "Using node ID: ${NODE_ID}"
        return 0
    fi
    
    echo ""
    local existing_nodes
    existing_nodes=$(yq eval '.nodes[].node_id' "${INVENTORY_FILE}" 2>/dev/null || echo "")
    
    if [ -n "${existing_nodes}" ]; then
        cat << EOF
Choose a node ID for this machine.

Existing nodes in inventory:
EOF
        echo "${existing_nodes}" | while read -r node; do
            echo "  - ${node}"
        done
        echo ""
        read -r -p "Enter node ID (or press Enter for auto-generated): " NODE_ID
    else
        read -r -p "Enter node ID for this node (e.g., spark-01): " NODE_ID
    fi
    
    if [ -z "${NODE_ID}" ]; then
        # Auto-generate
        NODE_ID="spark-$(echo "${NODE_IP}" | tr '.' '-' | sed 's/-$//')"
        log "Auto-generated node ID: ${NODE_ID}"
    fi
}

# Prompt for model recipe if worker
prompt_model_recipe() {
    if [ "${IS_WORKER}" != true ]; then
        return 0
    fi
    
    echo ""
    cat << EOF
Select a model recipe for this worker.
EOF
    
    local recipes
    recipes=$(ls "${KIT_DIR}/recipes/" 2>/dev/null | grep -E '\.yaml$' | sed 's/\.yaml$//' || echo "")
    
    if [ -n "${recipes}" ]; then
        echo "Available recipes:"
        echo "${recipes}" | while read -r recipe; do
            echo "  - ${recipe}"
        done
        echo ""
    fi
    
    read -r -p "Enter model recipe name [default=qwen3.6-35b-a3b-nvfp4]: " MODEL_RECIPE
    MODEL_RECIPE="${MODEL_RECIPE:-qwen3.6-35b-a3b-nvfp4}"
    
    # Validate recipe exists (skip validation in non-interactive/non-sudo if file doesn't exist)
    if [ ! -f "${KIT_DIR}/recipes/${MODEL_RECIPE}.yaml" ]; then
        log_warn "Recipe '${MODEL_RECIPE}' not found in recipes/ directory. Using default."
        MODEL_RECIPE="qwen3.6-35b-a3b-nvfp4"
    fi
    
    log "Model recipe: ${MODEL_RECIPE}"
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
    
    # Node IP
    prompt_node_ip
    
    # Try to detect existing node
    try_detect_node
    
    # Node role
    prompt_role
    
    # If worker, need hub IP
    if [ "${IS_WORKER}" = true ]; then
        prompt_hub_ip
    fi
    
    # Client subnets (only needed for hub)
    if [ "${IS_HUB}" = true ]; then
        prompt_client_subnets
    fi
    
    # Node ID
    prompt_node_id
    
    # Model recipe (if worker)
    if [ "${IS_WORKER}" = true ]; then
        prompt_model_recipe
    fi
    
    echo ""
    echo "=========================================="
    echo "  Configuration Summary"
    echo "=========================================="
    echo "  Node ID:       ${NODE_ID}"
    echo "  Node IP:       ${NODE_IP}"
    echo "  Role:          ${NODE_ROLE}"
    if [ "${IS_HUB}" = true ]; then
        echo "  Client Subnets:${CLIENT_SUBNETS[*]}"
    fi
    if [ "${IS_WORKER}" = true ]; then
        echo "  Hub IP:        ${HUB_LAN_IP}"
        echo "  Model Recipe: ${MODEL_RECIPE:-N/A}"
    fi
    echo "=========================================="
    echo ""
    
    # Show mode-specific warnings
    if [ "${NON_SUDO_MODE}" = true ]; then
        echo "  *** NON-SUDO MODE WARNINGS ***"
        echo "  - Containers will run as current user"
        echo "  - No service user isolation"
        echo "  - No firewall configuration"
        echo "  - No Docker network creation"
        echo ""
    fi
    
    # Ask for confirmation
    read -r -p "Proceed with deployment? [y/N]: " response
    case "${response}" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            log "Deployment cancelled."
            exit 0
            ;;
    esac
}

# Create service user (sudo only)
create_service_user() {
    if [ "${USE_CURRENT_USER}" = true ]; then
        log "Running in current user mode --no service user created"
        SVC_UID=$(id -u)
        SVC_GID=$(id -g)
        export SVC_UID SVC_GID
        return 0
    fi
    
    if [ "${NON_SUDO_MODE}" = true ]; then
        log_warn "Not creating service user in non-sudo mode - using current user"
        SVC_UID=$(id -u)
        SVC_GID=$(id -g)
        export SVC_UID SVC_GID
        return 0
    fi
    
    log "Creating service user..."
    
    # Create group if it doesn't exist
    if ! getent group "${SERVICE_GROUP}" > /dev/null; then
        groupadd "${SERVICE_GROUP}"
        log "Created group: ${SERVICE_GROUP}"
    fi
    
    # Create user if it doesn't exist
    if ! id "${SERVICE_USER}" &> /dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin \
                --gid "${SERVICE_GROUP}" "${SERVICE_USER}"
        log "Created user: ${SERVICE_USER}"
    else
        log "User ${SERVICE_USER} already exists."
    fi
    
    # Get UID and GID (use local variables, NOT readonly UID/GID)
    SVC_UID=$(id -u "${SERVICE_USER}")
    SVC_GID=$(id -g "${SERVICE_USER}")
    export SVC_UID SVC_GID
}

# Setup firewall
setup_firewall() {
    if [ "${NON_SUDO_MODE}" = true ]; then
        log_warn "Skipping firewall configuration in non-sudo mode"
        log_warn "vLLM ports may be exposed to the entire LAN!"
        return 0
    fi
    
    log "Configuring firewall..."
    
    # Default deny incoming
    ufw default deny incoming
    
    # Allow SSH (if we're not breaking existing access)
    ufw allow ssh
    
    if [ "${IS_HUB}" = true ]; then
        # Hub: Allow LiteLLM port from client subnets
        if [ ${#CLIENT_SUBNETS[@]} -gt 0 ]; then
            for subnet in "${CLIENT_SUBNETS[@]}"; do
                ufw allow from "${subnet}" to any port "${LITELLM_PORT}" proto tcp comment 'LiteLLM Hub Access'
                log "Allowed LiteLLM port ${LITELLM_PORT} from ${subnet}"
            done
        fi
        
        # Hub: Allow worker connections to self (if hub+worker)
        if [ "${IS_WORKER}" = true ]; then
            ufw allow from "${NODE_IP}" to any port "${VLLM_PORT}" proto tcp comment 'Self Worker Access'
        fi
    fi
    
    if [ "${IS_WORKER}" = true ]; then
        # Worker: Allow vLLM port from hub only
        ufw allow from "${HUB_LAN_IP}" to any port "${VLLM_PORT}" proto tcp comment 'Worker Hub Access'
        log "Allowed vLLM port ${VLLM_PORT} from hub at ${HUB_LAN_IP}"
    fi
    
    # Allow outgoing traffic (fixes kit-1's bug)
    ufw default allow outgoing
    
    # Enable firewall
    ufw --force enable
    log "Firewall configured and enabled."
}

# Create Docker network
create_network() {
    log "Creating Docker network..."
    
    if [ "${NON_SUDO_MODE}" = true ]; then
        log_warn "In non-sudo mode: checking if network exists..."
        if ! docker network inspect "${DOCKER_NETWORK}" &> /dev/null; then
            log_error "Docker network ${DOCKER_NETWORK} does not exist and cannot be created without root."
            log_error "Please create the network manually with: sudo docker network create ${DOCKER_NETWORK}"
            exit 1
        fi
        log "Using existing Docker network: ${DOCKER_NETWORK}"
        return 0
    fi
    
    if ! docker network inspect "${DOCKER_NETWORK}" &> /dev/null; then
        docker network create "${DOCKER_NETWORK}" 2>&1
        log "Created Docker network: ${DOCKER_NETWORK}"
    else
        log "Docker network ${DOCKER_NETWORK} already exists."
    fi
}

# Generate secrets
generate_secrets() {
    log "Generating secrets..."
    
    touch_secrets_dir
    
    if [ "${IS_HUB}" = true ]; then
        # Hub secrets: DB password, LiteLLM master key
        local DB_PASSWORD_FILE="${SECRETS_DIR}/db_password.txt"
        local LITELLM_MASTER_KEY_FILE="${SECRETS_DIR}/litellm_master_key.txt"
        
        if [ ! -f "${DB_PASSWORD_FILE}" ]; then
            openssl rand -base64 32 > "${DB_PASSWORD_FILE}"
            chmod 600 "${DB_PASSWORD_FILE}"
            if [ "${USE_CURRENT_USER}" = false ]; then
                chown "${SERVICE_USER}:${SERVICE_GROUP}" "${DB_PASSWORD_FILE}"
            fi
            log "Generated DB password."
        fi
        
        if [ ! -f "${LITELLM_MASTER_KEY_FILE}" ]; then
            # LiteLLM requires sk- prefix for master key
            echo "sk-$(openssl rand -hex 31)" > "${LITELLM_MASTER_KEY_FILE}"
            chmod 600 "${LITELLM_MASTER_KEY_FILE}"
            if [ "${USE_CURRENT_USER}" = false ]; then
                chown "${SERVICE_USER}:${SERVICE_GROUP}" "${LITELLM_MASTER_KEY_FILE}"
            fi
            log "Generated LiteLLM master key with sk- prefix."
        fi
        
        # Generate database URL
        local DB_PASSWORD=$(cat "${DB_PASSWORD_FILE}")
        DATABASE_URL="postgresql://litellm:${DB_PASSWORD}@localhost:${POSTGRES_PORT}/litellm"
        export DATABASE_URL
    fi
    
    # Worker secrets: VLLM API key
    if [ "${IS_WORKER}" = true ]; then
        local VLLM_API_KEY_FILE="${SECRETS_DIR}/vllm_api_key.txt"
        
        if [ ! -f "${VLLM_API_KEY_FILE}" ]; then
            openssl rand -hex 32 > "${VLLM_API_KEY_FILE}"
            chmod 600 "${VLLM_API_KEY_FILE}"
            if [ "${USE_CURRENT_USER}" = false ]; then
                chown "${SERVICE_USER}:${SERVICE_GROUP}" "${VLLM_API_KEY_FILE}"
            fi
            log "Generated VLLM API key."
        fi
        
        VLLM_API_KEY=$(cat "${VLLM_API_KEY_FILE}")
        export VLLM_API_KEY
    fi
}

# Generate LiteLLM config
generate_litellm_config() {
    if [ "${IS_HUB}" != true ]; then
        return 0
    fi
    
    log "Generating LiteLLM configuration..."
    
    local config_file="${GENERATED_DIR}/litellm-config.yaml"
    
    cat > "${config_file}" << 'LITELLM_CONFIG_HEADER'
model_list:
LITELLM_CONFIG_HEADER
    
    # For this node (hub+worker) add self as worker
    if [ "${IS_WORKER}" = true ]; then
        cat >> "${config_file}" << LITELLM_CONFIG_ENTRY
  - model_name: ${MODEL_RECIPE}
    litellm_params:
      model: openai/nvidia/Qwen3.6-35B-A3B-NVFP4
      api_base: http://host.docker.internal:${VLLM_PORT}/v1
      api_key: os.environ/VLLM_API_KEY
      reasoning_effort: medium
      max_tokens: 8192
LITELLM_CONFIG_ENTRY
    fi
    
    # Add worker entries from inventory that match role
    local inventory_workers
    inventory_workers=$(yq eval '.nodes[] | select(.role | contains("worker")) | select(.lan_ip != "'"${NODE_IP}"'")' "${INVENTORY_FILE}" 2>/dev/null || echo "")
    
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            continue
        fi
        
        local worker_ip worker_model
        worker_ip=$(echo "$line" | yq eval '.lan_ip' 2>/dev/null || echo "")
        worker_model=$(echo "$line" | yq eval '.model_recipe' 2>/dev/null || echo "qwen3.6-35b-a3b-nvfp4")
        
        if [ -n "${worker_ip}" ]; then
            cat >> "${config_file}" << LITELLM_CONFIG_ENTRY
  - model_name: ${worker_model}
    litellm_params:
      model: openai/nvidia/Qwen3.6-35B-A3B-NVFP4
      api_base: http://${worker_ip}:${VLLM_PORT}/v1
      api_key: os.environ/VLLM_API_KEY
      reasoning_effort: medium
      max_tokens: 8192
LITELLM_CONFIG_ENTRY
        fi
    done <<< "${inventory_workers}"
    
    # Add general settings
    cat >> "${config_file}" << 'LITELLM_CONFIG_FOOTER'

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  disable_env_credential_login: true
LITELLM_CONFIG_FOOTER
    
    log "Generated LiteLLM config: ${config_file}"
    chmod 640 "${config_file}"
    if [ "${USE_CURRENT_USER}" = false ]; then
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "${config_file}"
    fi
}

# Deploy hub
deploy_hub() {
    if [ "${IS_HUB}" != true ]; then
        return 0
    fi
    
    log "Deploying Hub..."
    
    local docker_compose_file="${SCRIPT_DIR}/docker-compose.hub.yml"
    local env_file="${SECRETS_DIR}/hub.env"
    
    # Create hub.env
    cat > "${env_file}" << EOF
DB_PASSWORD=$(cat "${SECRETS_DIR}/db_password.txt")
LITELLM_MASTER_KEY=$(cat "${SECRETS_DIR}/litellm_master_key.txt")
DATABASE_URL=${DATABASE_URL}
NODE_IP=${NODE_IP}
SVC_UID=${SVC_UID}
SVC_GID=${SVC_GID}
EOF
    chmod 600 "${env_file}"
    if [ "${USE_CURRENT_USER}" = false ]; then
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "${env_file}"
    fi
    
    log "Starting Hub services via Docker Compose..."
    cd "${SCRIPT_DIR}"
    
    docker compose -f "${docker_compose_file}" \
        --env-file "${env_file}" \
        up -d --remove-orphans
    
    log "Hub deployed successfully."
    log "LiteLLM accessible at http://${NODE_IP}:${LITELLM_PORT}/v1"
}

# Deploy worker
deploy_worker() {
    if [ "${IS_WORKER}" != true ]; then
        return 0
    fi
    
    log "Deploying Worker..."
    
    # Load recipe
    local recipe_file="${KIT_DIR}/recipes/${MODEL_RECIPE}.yaml"
    local hf_model_name served_model_name
    hf_model_name=$(yq eval '.model_name' "${recipe_file}" 2>/dev/null || echo "nvidia/Qwen3.6-35B-A3B-NVFP4")
    served_model_name=$(yq eval '.served_model_name' "${recipe_file}" 2>/dev/null || echo "${MODEL_RECIPE}")
    local max_model_len=$(yq eval '.max_model_len' "${recipe_file}" 2>/dev/null || echo "262144")
    local gpu_mem_util=$(yq eval '.gpu_memory_utilization' "${recipe_file}" 2>/dev/null || echo "0.8")
    local max_num_seqs=$(yq eval '.max_num_seqs' "${recipe_file}" 2>/dev/null || echo "15")
    local tool_call_parser=$(yq eval '.tool_call_parser' "${recipe_file}" 2>/dev/null || echo "qwen3_xml")
    local reasoning_parser=$(yq eval '.reasoning_parser' "${recipe_file}" 2>/dev/null || echo "qwen3")
    local auto_tool_choice=$(yq eval '.enable_auto_tool_choice' "${recipe_file}" 2>/dev/null || echo "true")
    local trust_remote=$(yq eval '.trust_remote_code' "${recipe_file}" 2>/dev/null || echo "true")
    
    # Create worker environment file
    local worker_config_dir="${GENERATED_DIR}/workers"
    mkdir -p "${worker_config_dir}"
    local worker_env_file="${worker_config_dir}/${NODE_ID}.env"
    
    cat > "${worker_env_file}" << EOF
VLLM_API_KEY=$(cat "${SECRETS_DIR}/vllm_api_key.txt")
NODE_ID=${NODE_ID}
NODE_IP=${NODE_IP}
SVC_UID=${SVC_UID}
SVC_GID=${SVC_GID}
HUB_IP=${HUB_LAN_IP}
EOF
    chmod 600 "${worker_env_file}"
    if [ "${USE_CURRENT_USER}" = false ]; then
        chown "${SERVICE_USER}:${SERVICE_GROUP}" "${worker_env_file}"
    fi
    
    local container_name="vllm-${NODE_ID}"
    
    log "Starting vLLM container for model: ${served_model_name}"
    
    # Determine port binding
    local port_flags=""
    if [ "${NON_SUDO_MODE}" = true ]; then
        # Non-sudo: can only bind to ports > 1024 or use 0.0.0.0 with appropriate permissions
        log_warn "In non-sudo mode: binding to 0.0.0.0:8000 (may require port > 1024)"
        port_flags="--publish 0.0.0.0:${VLLM_PORT}:${VLLM_PORT}"
    else
        # Sudo: bind to node IP only
        port_flags="--publish ${NODE_IP}:${VLLM_PORT}:${VLLM_PORT}"
    fi
    
    docker run -d \
        --name "${container_name}" \
        --network "${DOCKER_NETWORK}" \
        --user "${SVC_UID}:${SVC_GID}" \
        --security-opt=no-new-privileges \
        --env-file "${worker_env_file}" \
        --gpus all \
        --restart unless-stopped \
        ${port_flags} \
        --health-cmd "curl -f http://localhost:${VLLM_PORT}/v1/models || exit 1" \
        --health-interval 30s \
        --health-timeout 10s \
        --health-retries 3 \
        "${VLLM_IMAGE}" \
        "${hf_model_name}" \
        --host 0.0.0.0 \
        --port "${VLLM_PORT}" \
        --max-model-len "${max_model_len}" \
        --gpu-memory-utilization "${gpu_mem_util}" \
        --max-num-seqs "${max_num_seqs}" \
        --reasoning-parser "${reasoning_parser}" \
        --tool-call-parser "${tool_call_parser}" \
        $( [ "${auto_tool_choice}" = "true" ] && echo "--enable-auto-tool-choice" ) \
        $( [ "${trust_remote}" = "true" ] && echo "--trust-remote-code" )
    
    log "Worker deployed successfully."
    log "vLLM serving ${served_model_name} at http://${NODE_IP}:${VLLM_PORT}/v1"
}

# Main deployment
main() {
    parse_args "$@"
    validate_mode
    check_prerequisites
    touch_generated_dir
    
    # Collect all user input interactively
    collect_user_input
    
    # Deploy based on role
    create_service_user
    create_network
    setup_firewall
    generate_secrets
    
    if [ "${IS_HUB}" = true ]; then
        generate_litellm_config
        deploy_hub
    fi
    
    if [ "${IS_WORKER}" = true ]; then
        deploy_worker
    fi
    
    log ""
    log "=== Deployment Complete ==="
    if [ "${IS_HUB}" = true ]; then
        log "LiteLLM endpoint: http://${NODE_IP}:${LITELLM_PORT}/v1"
        if [ "${NON_SUDO_MODE}" = true ]; then
            log_warn "Firewall NOT configured - ensure port ${LITELLM_PORT} is secured manually"
        fi
    fi
    if [ "${IS_WORKER}" = true ]; then
        log "vLLM worker active on port: ${VLLM_PORT}"
        if [ "${NON_SUDO_MODE}" = true ]; then
            log_warn "Firewall NOT configured - vLLM may be exposed to LAN"
        fi
    fi
    log ""
    log "To verify deployment, run: ./scripts/verify.sh"
    log "To rollback, run: sudo ./scripts/rollback.sh"
}

main "$@"
