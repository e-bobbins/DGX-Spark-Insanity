#!/usr/bin/env bash
# rollback.sh - Per-node rollback script for DGX Spark LLM Stack
#
# Stops and removes the node's containers and (optionally) its firewall rules.
# Leaves the rest of the lab untouched.
#
# Usage:
#   sudo ./rollback.sh                    # Interactive mode
#   sudo ./rollback.sh --yes              # Rollback without confirmation
#   sudo ./rollback.sh --keep-firewall    # Rollback but keep firewall rules
#   sudo ./rollback.sh --help             # Show help
#
set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INVENTORY_FILE="${KIT_DIR}/inventory.yaml"
GENERATED_DIR="${KIT_DIR}/generated"

# Docker network
DOCKER_NETWORK="spark-kit-llm-net"

# --- Functions ---

log() {
    echo "[+] $1"
}

log_error() {
    echo "[!] ERROR: $1" >&2
}

log_warn() {
    echo "[-] WARNING: $1" >&2
}

show_help() {
    cat << EOF
Usage: sudo ./rollback.sh [OPTIONS]

Rollback DGX Spark LLM Stack deployment on the current node.

This script will:
  - Stop and remove all stack containers on this node
  - Remove the Docker network (if empty)
  - Optionally remove firewall rules
  - NOT affect other nodes in the lab

Options:
  --yes               Skip confirmation prompt
  --keep-firewall     Do not remove firewall rules
  --remove-all        Remove ALL firewall rules (use with caution)
  --help, -h          Show this help message

This script must be run with sudo.
EOF
}

# Parse arguments
SKIP_CONFIRM=false
KEEP_FIREWALL=false
REMOVE_ALL_FIREWALL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --yes)
            SKIP_CONFIRM=true
            shift
            ;;
        --keep-firewall)
            KEEP_FIREWALL=true
            shift
            ;;
        --remove-all)
            REMOVE_ALL_FIREWALL=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            show_help
            exit 1
            ;;
    esac
done

# Validate sudo
validate_sudo() {
    if [ "$(id -u)" != "0" ]; then
        log_error "This script must be run with sudo. Please run: sudo $0"
        exit 1
    fi
}

# Detect current node
get_current_node() {
    CURRENT_IP=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    
    if [ -f "${INVENTORY_FILE}" ]; then
        NODE_ID=$(yq eval '.nodes[] | select(.lan_ip == "'"${CURRENT_IP}"'") | .node_id' "${INVENTORY_FILE}" 2>/dev/null || echo "")
        NODE_ROLE=$(yq eval '.nodes[] | select(.node_id == "'"${NODE_ID}"'") | .role' "${INVENTORY_FILE}" 2>/dev/null || echo "")
    else
        # Try to detect by running containers
        if docker ps --format '{{.Names}}' | grep -q "^litellm-proxy$"; then
            NODE_ROLE="hub"
            NODE_ID="$(hostname)-hub"
        elif docker ps --format '{{.Names}}' | grep -q "^vllm-"; then
            NODE_ROLE="worker"
            NODE_ID="$(hostname)-worker"
        else
            log "Cannot auto-detect node role. Please specify manually."
        fi
    fi
    
    if [ -z "${NODE_ID}" ]; then
        NODE_ID="$(hostname)"
    fi
}

# Confirm rollback
confirm_rollback() {
    if [ "${SKIP_CONFIRM}" = true ]; then
        return 0
    fi
    
    cat << EOF

=== ROLLBACK CONFIRMATION ===

You are about to rollback the DGX Spark LLM Stack on this node:

  Node ID: ${NODE_ID:-unknown}
  Role:    ${NODE_ROLE:-unknown}

This will:
  ✓ Stop and remove all stack containers on this node
  ✓ Remove Docker network (if no other nodes are using it)
EOF
    
    if [ "${KEEP_FIREWALL}" = true ]; then
        echo "  ✓ KEEP existing firewall rules"
    else
        echo "  ✗ Remove firewall rules for this node"
    fi
    
    if [ "${REMOVE_ALL_FIREWALL}" = true ]; then
        echo "  ✗ Remove ALL firewall rules (DANGEROUS)"
    fi
    
    echo ""
    echo "  ✓ Preserve secrets directory (for potential redeploy)"
    echo "  ✓ NOT affect other nodes in the lab"
    echo ""
    
    read -r -p "Are you sure you want to continue? [y/N]: " response
    
    case "${response}" in
        [yY][eE][sS]|[yY])
            return 0
            ;;
        *)
            log "Rollback cancelled."
            exit 0
            ;;
    esac
}

# Stop containers
stop_containers() {
    log "Stopping containers..."
    
    # Hub containers
    if [[ "${NODE_ROLE}" == *"hub"* ]]; then
        for container in litellm-proxy litellm-postgres; do
            if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
                docker stop "${container}" 2>/dev/null || log_warn "Failed to stop ${container}"
                docker rm "${container}" 2>/dev/null || log_warn "Failed to remove ${container}"
                log "Stopped and removed: ${container}"
            fi
        done
        
        # Remove named volumes
        if docker volume ls -q | grep -q "spark-kit-llm-net_postgres_data"; then
            docker volume rm "spark-kit-llm-net_postgres_data" 2>/dev/null || log_warn "Failed to remove postgres_data volume"
            log "Removed postgres_data volume"
        fi
    fi
    
    # Worker containers
    if [[ "${NODE_ROLE}" == *"worker"* ]] || [ -z "${NODE_ROLE}" ]; then
        # Find all vllm containers
        local vllm_containers
        vllm_containers=$(docker ps -a --format '{{.Names}}' | grep "^vllm-" || true)
        
        for container in ${vllm_containers}; do
            if [ -n "${container}" ]; then
                docker stop "${container}" 2>/dev/null || log_warn "Failed to stop ${container}"
                docker rm "${container}" 2>/dev/null || log_warn "Failed to remove ${container}"
                log "Stopped and removed: ${container}"
            fi
        done
    fi
}

# Remove Docker network
remove_network() {
    log "Checking Docker network..."
    
    # Check if network exists
    if docker network inspect "${DOCKER_NETWORK}" &> /dev/null; then
        # Check if any containers are using it
        local container_count
        container_count=$(docker network inspect "${DOCKER_NETWORK}" --format '{{len .Containers}}' 2>/dev/null || echo "0")
        
        if [ "${container_count}" = "0" ]; then
            docker network rm "${DOCKER_NETWORK}" 2>/dev/null || log_warn "Failed to remove Docker network"
            log "Removed Docker network: ${DOCKER_NETWORK}"
        else
            log "Docker network ${DOCKER_NETWORK} still in use by ${container_count} containers, not removed."
        fi
    fi
}

# Remove firewall rules
remove_firewall_rules() {
    if [ "${KEEP_FIREWALL}" = true ]; then
        log "Skipping firewall cleanup (--keep-firewall specified)"
        return 0
    fi
    
    if [ "${REMOVE_ALL_FIREWALL}" = true ]; then
        log "Removing ALL firewall rules (DANGEROUS)..."
        ufw --force reset
        log "All firewall rules removed."
        return 0
    fi
    
    log "Removing firewall rules for this node..."
    
    local lport rport all_ports
    lport=4000

    if [[ "${NODE_ROLE}" == *"hub"* ]]; then
        # Remove LiteLLM port rules
        all_ports=$(ufw status numbered | grep -E ":${lport}" | awk '{print $2}' | tr '\n' ' ')
        if [ -n "${all_ports}" ]; then
          for port_rule in ${all_ports}; do
            ufw --force delete "${port_rule}"
            log "Removed firewall rule: ${port_rule}"
          done
        fi
    fi

    if [[ "${NODE_ROLE}" == *"worker"* ]] || [ -z "${NODE_ROLE}" ]; then
        # Remove vLLM port rules
        rport=8000
        all_ports=$(ufw status numbered | grep -E ":${rport}" | awk '{print $2}' | tr '\n' ' ' || true) 
        if [ -n "${all_ports}" ]; then
          for port_rule in ${all_ports}; do
            ufw --force delete "${port_rule}"
            log "Removed firewall rule: ${port_rule}"
          done
        fi
    fi
}

# Cleanup generated files
cleanup_generated() {
    log "Cleaning up generated files..."
    
    # Remove generated directory
    if [ -d "${GENERATED_DIR}" ]; then
        rm -rf "${GENERATED_DIR}"
        log "Removed generated directory"
    fi
}

# Main rollback function
main() {
    validate_sudo
    get_current_node
    
    log "=== DGX Spark LLM Stack Rollback ==="
    log "Node: ${NODE_ID:-unknown} (Role: ${NODE_ROLE:-unknown})"
    log ""
    
    confirm_rollback
    
    stop_containers
    remove_network
    remove_firewall_rules
    
    log ""
    log "=== Rollback Complete ==="
    if [ -n "${NODE_ROLE}" ] && [[ "${NODE_ROLE}" == *"hub"* ]]; then
        log "Note: Postgres data volume was removed. Data is NOT recoverable."
    fi
    log ""
    log "To redeploy, run: ./deploy.sh"
}

main "$@"
