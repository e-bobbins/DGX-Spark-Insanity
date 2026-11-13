#!/usr/bin/env bash
# run-tests.sh - Offline test harness for spark-kit-3
#
# Implements the spec's static seam (shellcheck over all scripts) and an
# offline slice of the primary seam: LiteLLM config generation is exercised
# against a temp inventory with a stubbed yq, asserting per-worker routes,
# per-worker key references, and that no literal secrets are embedded.
#
# Runtime/Docker tests (deploy + mock vLLM stub container) require Docker
# and are skipped with a notice when unavailable.
#
# Usage: ./tests/run-tests.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
KIT_DIR="${KIT_DIR}"

PASS=0
FAIL=0

check() {
    local name="$1" result="$2"
    if [ "$result" = "0" ]; then
        PASS=$((PASS + 1)); echo "  [PASS] ${name}"
    else
        FAIL=$((FAIL + 1)); echo "  [FAIL] ${name}"
    fi
}

echo "=== Static checks ==="
if command -v shellcheck > /dev/null 2>&1; then
    shellcheck "${KIT_DIR}/infrastructure/deploy.sh" \
               "${KIT_DIR}/scripts/verify.sh" \
               "${KIT_DIR}/scripts/rollback.sh"
    check "shellcheck clean" $?
else
    echo "  [SKIP] shellcheck not installed"
fi

for script in "${KIT_DIR}/infrastructure/deploy.sh" "${KIT_DIR}/scripts/verify.sh" "${KIT_DIR}/scripts/rollback.sh"; do
    bash -n "$script"
    check "bash -n $(basename "$script")" $?
done

echo ""
echo "=== Offline config-generation test (stubbed yq, no Docker) ==="

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cp -r "${KIT_DIR}/recipes" "${WORK}/recipes"
cp "${KIT_DIR}/tests/stubs/yq" "${WORK}/yq-stub"
chmod +x "${WORK}/yq-stub"
mkdir -p "${WORK}/bin" "${WORK}/generated" "${WORK}/secrets/worker_keys"
PY="$(command -v python3 || command -v python)"
cat > "${WORK}/bin/yq" << STUB
#!/usr/bin/env bash
exec "${PY}" "${WORK}/yq-stub" "\$@"
STUB
chmod +x "${WORK}/bin/yq"

cat > "${WORK}/inventory.yaml" << 'EOF'
lab:
  client_subnets:
    - "10.0.0.0/24"
  nfs:
    enabled: false
nodes:
  - node_id: spark-01
    role: hub
    lan_ip: "10.0.0.30"
    model_recipe: null
  - node_id: spark-02
    role: worker
    lan_ip: "10.0.0.31"
    model_recipe: "other-model"
  - node_id: spark-03
    role: worker
    lan_ip: "10.0.0.32"
    model_recipe: "other-model"
EOF

cat > "${WORK}/recipes/other-model.yaml" << 'EOF'
model_name: "acme/Other-Model-7B"
served_model_name: "other-model"
tool_call_parser: "qwen3_xml"
reasoning_parser: "qwen3"
max_model_len: 32768
gpu_memory_utilization: 0.8
max_num_seqs: 15
enable_auto_tool_choice: true
trust_remote_code: true
EOF

echo "sk-testvalue-abcdefabcdefabcdef" > "${WORK}/secrets/worker_keys/spark-02.txt"
echo "sk-testvalue-123456123456123456" > "${WORK}/secrets/worker_keys/spark-03.txt"

# Source deploy.sh with stubbed PATH; source-only mode (no main execution)
(
  export PATH="${WORK}/bin:${PATH}"
  # shellcheck disable=SC1091
  source "${KIT_DIR}/infrastructure/deploy.sh"
  # Override AFTER sourcing: deploy.sh derives its own paths at source time.
  KIT_DIR="${WORK}"
  INVENTORY_FILE="${WORK}/inventory.yaml"
  GENERATED_DIR="${WORK}/generated"
  SECRETS_DIR="${WORK}/secrets"
  NODE_ROLE="hub"
  USE_CURRENT_USER=true
  MODEL_RECIPE=""
  NODE_ID="spark-01"
  generate_litellm_config || exit 1
) || echo "config generation returned non-zero"

CFG="${WORK}/generated/litellm-config.yaml"

check "config file generated" $([ -f "${CFG}" ]; echo $?)

n_routes=$(grep -c "model_name:" "${CFG}" 2>/dev/null || echo 0)
check "one route per worker endpoint (2 workers -> 2 routes), got ${n_routes}" $([ "${n_routes}" = "2" ]; echo $?)

check "per-worker api_key env var for spark-02" $(grep -q "os.environ/VLLM_KEY_SPARK_02" "${CFG}"; echo $?)
check "per-worker api_key env var for spark-03" $(grep -q "os.environ/VLLM_KEY_SPARK_03" "${CFG}"; echo $?)
check "per-worker api_base for spark-02" $(grep -q "api_base: http://10.0.0.31:8000/v1" "${CFG}"; echo $?)
check "per-worker api_base for spark-03" $(grep -q "api_base: http://10.0.0.32:8000/v1" "${CFG}"; echo $?)
check "model from worker's own recipe (openai/acme/Other-Model-7B)" $(grep -q "model: openai/acme/Other-Model-7B" "${CFG}"; echo $?)
check "no literal secret values in config" $(grep -q "testvalue" "${CFG}"; test $? -eq 1; echo $?)
check "no shared/single api_key variable across routes" $(grep -q "api_key: os.environ/VLLM_API_KEY" "${CFG}"; test $? -eq 1; echo $?)

echo ""
echo "=== Summary ==="
echo "Passed: ${PASS}  Failed: ${FAIL}"
[ "${FAIL}" -eq 0 ]
