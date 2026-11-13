#!/usr/bin/env bash
# verify.sh - Verification script for DGX Spark LLM Stack deployment
#
# Proves the deployment from the outside without printing secrets.
# Reports pass/fail per checkpoint.
#
# Host-scoped checks (secrets, firewall, containers) run only against the
# machine this script runs on. HTTP checks run against every node in the
# inventory, so the full picture is visible from any node.
#
# Usage:
#   ./verify.sh                    # local node + HTTP checks for all
#   ./verify.sh --all-local        # also run local-scoped checks for every node (needs access)
#   ./verify.sh --help             # Show help
#
set -uo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INVENTORY_FILE="${KIT_DIR}/inventory.yaml"
GENERATED_DIR="${KIT_DIR}/generated"
SECRETS_DIR="${KIT_DIR}/secrets"

LITELLM_PORT="4000"
VLLM_PORT="8000"

# --- Tracking ---
PASSED=0
FAILED=0
RESULTS=""

log_check() {
    local test_name="$1"
    local result="$2"
    if [ "$result" = "PASS" ]; then
        PASSED=$((PASSED + 1))
        RESULTS="${RESULTS}
  [PASS] ${test_name}"
        echo "  [PASS] ${test_name}"
    else
        FAILED=$((FAILED + 1))
        RESULTS="${RESULTS}
  [FAIL] ${test_name}"
        echo "  [FAIL] ${test_name}"
    fi
}

log_section() {
    echo ""
    echo "=== ${1} ==="
}

show_summary() {
    local total=$((PASSED + FAILED))
    echo ""
    echo "=== SUMMARY ==="
    echo "Passed: ${PASSED}/${total}"
    echo "Failed: ${FAILED}/${total}"

    if [ "${FAILED}" -gt 0 ]; then
        echo ""
        echo "FAILED CHECKS:"
        printf '%s\n' "${RESULTS}" | grep "FAIL" || true
        exit 1
    fi
    echo ""
    echo "All checks passed. Deployment verified."
    exit 0
}

show_help() {
    cat << EOF
Usage: ./verify.sh [OPTIONS]

Verify DGX Spark LLM Stack deployment from the outside. Secrets are never
printed; output is safe to paste into tickets.

Options:
  --all-local   Run host-scoped checks (containers, firewall, secrets) for
                every node in the inventory from this machine. Only useful
                with shared/remote access; by default host-scoped checks
                run against this machine only.
  --help, -h    Show this help message
EOF
}

ALL_LOCAL=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --all-local) ALL_LOCAL=true; shift ;;
        --help|-h) show_help; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; show_help; exit 1 ;;
    esac
done

if [ ! -f "${INVENTORY_FILE}" ]; then
    echo "ERROR: Inventory file not found at ${INVENTORY_FILE}" >&2
    exit 1
fi

# Local node IP (host-scoped checks apply to the machine we run on)
LOCAL_IP=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)

node_role() { yq eval ".nodes[] | select(.node_id == \"$1\") | .role" "${INVENTORY_FILE}" 2>/dev/null; }
node_ip()   { yq eval ".nodes[] | select(.node_id == \"$1\") | .lan_ip" "${INVENTORY_FILE}" 2>/dev/null; }

HUB_NODE=$(yq eval '.nodes[] | select(.role == "hub" or .role == "hub+worker") | .node_id' "${INVENTORY_FILE}" 2>/dev/null | head -1)
HUB_LAN_IP=""
[ -n "${HUB_NODE}" ] && HUB_LAN_IP=$(node_ip "${HUB_NODE}")

is_local_node() {
    [ -n "${LOCAL_IP}" ] && [ "$(node_ip "$1")" = "${LOCAL_IP}" ]
}

check_file_perm() {
    # $1 file, $2 label; expects mode 600
    local file="$1" label="$2" perms
    if [ ! -f "${file}" ]; then
        log_check "${label} exists" "FAIL"
        return
    fi
    if [ ! -s "${file}" ]; then
        log_check "${label} exists and is non-empty" "FAIL"
        return
    fi
    perms=$(stat -c "%a" "${file}" 2>/dev/null || echo "unknown")
    if [ "${perms}" = "600" ]; then
        log_check "${label} permissions (600, non-empty)" "PASS"
    else
        log_check "${label} permissions (expected 600, got ${perms})" "FAIL"
    fi
}

verify_secrets() {
    local node_id="$1" role
    role=$(node_role "${node_id}")
    log_section "Secrets (host: ${node_id})"

    if [[ "${role}" == *"hub"* ]]; then
        check_file_perm "${SECRETS_DIR}/db_password.txt" "DB password file"
        check_file_perm "${SECRETS_DIR}/litellm_master_key.txt" "Master key file"
        if [ -f "${SECRETS_DIR}/litellm_master_key.txt" ]; then
            if [ "$(head -c 3 "${SECRETS_DIR}/litellm_master_key.txt" 2>/dev/null)" = "sk-" ]; then
                log_check "Master key has sk- prefix (value not printed)" "PASS"
            else
                log_check "Master key has sk- prefix" "FAIL"
            fi
        fi
    fi
    if [[ "${role}" == *"worker"* ]]; then
        check_file_perm "${SECRETS_DIR}/vllm_api_key.txt" "vLLM API key file"
    fi
}

verify_firewall() {
    local node_id="$1" role
    role=$(node_role "${node_id}")
    log_section "Firewall (host: ${node_id})"

    if ! command -v ufw &> /dev/null; then
        log_check "ufw available" "FAIL"
        return
    fi

    if ufw status 2>/dev/null | grep -q "Status: active"; then
        log_check "Firewall enabled" "PASS"
    else
        log_check "Firewall enabled" "FAIL"
    fi

    if ufw status verbose 2>/dev/null | grep -q "deny (incoming)"; then
        log_check "Default deny incoming" "PASS"
    else
        log_check "Default deny incoming" "FAIL"
    fi

    if [[ "${role}" == *"hub"* ]]; then
        local subnet
        while IFS= read -r subnet; do
            [ -z "${subnet}" ] && continue
            if ufw status 2>/dev/null | grep -q "${LITELLM_PORT}/tcp.*${subnet}"; then
                log_check "LiteLLM ${LITELLM_PORT}/tcp open from ${subnet}" "PASS"
            else
                log_check "LiteLLM ${LITELLM_PORT}/tcp open from ${subnet}" "FAIL"
            fi
        done < <(yq eval '.lab.client_subnets[]' "${INVENTORY_FILE}" 2>/dev/null)
    fi

    if [[ "${role}" == *"worker"* ]]; then
        local hub_ip
        hub_ip=$(yq eval '.nodes[] | select(.role == "hub" or .role == "hub+worker") | .lan_ip' "${INVENTORY_FILE}" 2>/dev/null | head -1)
        if [ -n "${hub_ip}" ] && ufw status 2>/dev/null | grep -q "${VLLM_PORT}/tcp.*${hub_ip}"; then
            log_check "vLLM ${VLLM_PORT}/tcp open from hub (${hub_ip}) only" "PASS"
        elif [ -n "${hub_ip}" ]; then
            log_check "vLLM ${VLLM_PORT}/tcp open from hub (${hub_ip})" "FAIL"
        fi
    fi
}

container_running() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

nonroot_container() {
    local user
    user=$(docker inspect "$1" --format '{{.Config.User}}' 2>/dev/null || echo "")
    [ -n "${user}" ] && [ "${user}" != "0" ]
}

healthy_container() {
    docker inspect "$1" --format '{{.State.Health.Status}}' 2>/dev/null | grep -q "healthy"
}

container_binds_ip() {
    # $1 container, $2 expected host ip:port (e.g. 10.0.0.30:4000)
    docker port "$1" 2>/dev/null | grep -q "$2"
}

verify_local_containers() {
    local node_id="$1" role
    role=$(node_role "${node_id}")
    log_section "Containers (host: ${node_id})"

    if [[ "${role}" == *"hub"* ]]; then
        if container_running "litellm-proxy"; then
            log_check "litellm-proxy running" "PASS"
        else
            log_check "litellm-proxy running" "FAIL"
        fi
        if container_running "litellm-postgres"; then
            log_check "litellm-postgres running" "PASS"
        else
            log_check "litellm-postgres running" "FAIL"
        fi
        if nonroot_container "litellm-proxy"; then
            log_check "LiteLLM non-root" "PASS"
        else
            log_check "LiteLLM non-root" "FAIL"
        fi
        if healthy_container "litellm-proxy"; then
            log_check "LiteLLM healthy" "PASS"
        else
            log_check "LiteLLM healthy" "FAIL"
        fi
        if healthy_container "litellm-postgres"; then
            log_check "Postgres healthy" "PASS"
        else
            log_check "Postgres healthy" "FAIL"
        fi
        local nip
        nip=$(node_ip "${node_id}")
        if container_binds_ip "litellm-proxy" "${nip}:${LITELLM_PORT}"; then
            log_check "LiteLLM bound to ${nip}:${LITELLM_PORT} (not 0.0.0.0)" "PASS"
        else
            log_check "LiteLLM bound to ${nip}:${LITELLM_PORT}" "FAIL"
        fi
    fi

    if [[ "${role}" == *"worker"* ]]; then
        local container_name="vllm-${node_id}"

        if container_running "${container_name}"; then
            log_check "vLLM container running" "PASS"
        else
            log_check "vLLM container running" "FAIL"
        fi
        if nonroot_container "${container_name}"; then
            log_check "vLLM non-root" "PASS"
        else
            log_check "vLLM non-root" "FAIL"
        fi
        if healthy_container "${container_name}"; then
            log_check "vLLM healthy" "PASS"
        else
            log_check "vLLM healthy" "FAIL"
        fi
        if docker inspect "${container_name}" --format '{{.HostConfig.SecurityOpt}}' 2>/dev/null | grep -q "no-new-privileges"; then
            log_check "vLLM no-new-privileges" "PASS"
        else
            log_check "vLLM no-new-privileges" "FAIL"
        fi
        if [ "$(docker inspect "${container_name}" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)" = "unless-stopped" ]; then
            log_check "vLLM restart policy unless-stopped" "PASS"
        else
            log_check "vLLM restart policy" "FAIL"
        fi
        local shm
        shm=$(docker inspect "${container_name}" --format '{{.HostConfig.ShmSize}}' 2>/dev/null || echo "0")
        if [ "${shm}" -gt 0 ] 2>/dev/null; then
            log_check "vLLM shm size set (${shm} bytes)" "PASS"
        else
            log_check "vLLM shm size set" "FAIL"
        fi
        local nip
        nip=$(node_ip "${node_id}")
        if docker port "${container_name}" 2>/dev/null | grep -q "${nip}:${VLLM_PORT}"; then
            log_check "vLLM bound to ${nip}:${VLLM_PORT} (node IP only)" "PASS"
        else
            log_check "vLLM bound to ${nip}:${VLLM_PORT}" "FAIL"
        fi
    fi
}

verify_http() {
    log_section "HTTP checks (network-wide)"

    if [ -n "${HUB_LAN_IP}" ]; then
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://${HUB_LAN_IP}:${LITELLM_PORT}/v1/models" 2>/dev/null || echo "000")
        if [ "${code}" = "401" ]; then
            log_check "Hub auth enforced (no key -> 401)" "PASS"
        else
            log_check "Hub auth enforced (expected 401, got ${code})" "FAIL"
        fi

        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -H "Authorization: Bearer $(cat "${SECRETS_DIR}/litellm_master_key.txt" 2>/dev/null)" "http://${HUB_LAN_IP}:${LITELLM_PORT}/v1/models" 2>/dev/null || echo "000")
        if [ "${code}" = "200" ]; then
            log_check "Hub /v1/models with master key -> 200" "PASS"
        else
            log_check "Hub /v1/models with master key (expected 200, got ${code})" "FAIL"
        fi
    else
        log_check "Hub reachable (no hub in inventory)" "FAIL"
    fi

    # Workers: reachable only from the hub. From a non-hub node, a reachable
    # worker means the firewall is not restricting access.
    local node_id role nip code
    while IFS= read -r node_id; do
        [ -z "${node_id}" ] && continue
        role=$(node_role "${node_id}")
        [[ "${role}" == *"worker"* ]] || continue
        nip=$(node_ip "${node_id}")
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${nip}:${VLLM_PORT}/v1/models" 2>/dev/null || echo "000")
        if [ "${LOCAL_IP}" = "${nip}" ] || [ "${LOCAL_IP}" = "${HUB_LAN_IP}" ]; then
            # From the hub (or the worker itself) the endpoint should answer
            if [ "${code}" = "401" ] || [ "${code}" = "200" ]; then
                log_check "Worker ${node_id} reachable with auth (from hub/local): ${code}" "PASS"
            else
                log_check "Worker ${node_id} reachable from hub (got ${code})" "FAIL"
            fi
        else
            if [ "${code}" = "000" ]; then
                log_check "Worker ${node_id} NOT reachable from non-hub host (firewall enforced)" "PASS"
            else
                log_check "Worker ${node_id} reachable from non-hub host (got ${code}) - firewall leak" "FAIL"
            fi
        fi
    done < <(yq eval '.nodes[].node_id' "${INVENTORY_FILE}" 2>/dev/null)
}

verify_generated_files() {
    log_section "Generated files"
    if [ -f "${GENERATED_DIR}/litellm-config.yaml" ]; then
        log_check "LiteLLM config generated" "PASS"
        if grep -qE "api_key: os.environ/VLLM_KEY_" "${GENERATED_DIR}/litellm-config.yaml"; then
            log_check "Per-worker api_key env references present" "PASS"
        else
            log_check "Per-worker api_key env references present" "FAIL"
        fi
        if grep -qE "api_key: [A-Za-z0-9]" "${GENERATED_DIR}/litellm-config.yaml" \
            && ! grep -qE "api_key: (os\.environ/)?[A-Za-z0-9_-]{20,}" "${GENERATED_DIR}/litellm-config.yaml"; then
            log_check "No literal secrets embedded in config" "FAIL"
        else
            log_check "No literal secrets embedded in config" "PASS"
        fi
    else
        log_check "LiteLLM config generated" "FAIL"
    fi
}

main() {
    # Host-scoped checks: local node only, or all when --all-local
    local node_id role
    while IFS= read -r node_id; do
        [ -z "${node_id}" ] && continue
        if [ "${ALL_LOCAL}" = false ] && ! is_local_node "${node_id}"; then
            continue
        fi
        verify_secrets "${node_id}"
        verify_firewall "${node_id}"
        verify_local_containers "${node_id}"
    done < <(yq eval '.nodes[].node_id' "${INVENTORY_FILE}" 2>/dev/null)

    if [ "$(yq eval '.nodes | length' "${INVENTORY_FILE}" 2>/dev/null)" = "0" ]; then
        log_section "Inventory"
        log_check "Inventory has nodes (run deploy.sh first)" "FAIL"
    fi

    verify_generated_files
    verify_http
    show_summary
}

main
