# DGX Spark LLM Stack - Spark Kit 3 (Consolidated)

**Status**: Stage 1 - Consolidated canonical kit

This kit replaces both spark-kit and spark-kit-2. It resolves all identified bugs, implements lab security standards, and provides a single, reviewable deployment path.

---

## Quick Start

### Secure Mode (Recommended)

For production deployments with full security:

```bash
# Clone the repo and enter spark-kit-3
cd spark-kits/spark-kit-3

# Run the interactive deploy script on your hub node:
sudo ./infrastructure/deploy.sh

# The script will ask you:
#   - Node IP address (auto-detected if possible)
#   - Node role (default: Hub + Worker - RECOMMENDED)
#   - Client subnets (required for hub)
#   - Hub IP (required for workers)
#   - Node ID (auto-generated if not specified)
#   - Model recipe (default: qwen3.6-35b-a3b-nvfp4)

# Run on each worker node:
sudo ./infrastructure/deploy.sh
```

### Non-Sudo Mode (Testing/Development Only)

For testing without root access (security degraded):

```bash
# Run without sudo (non-production):
./infrastructure/deploy.sh --non-sudo

# You will see warnings:
#   - Containers run as current user
#   - No firewall configuration
#   - No service user isolation
#   - Docker network must exist already
```

**⚠️ WARNING: Non-sudo mode is for testing only. In production, always use sudo mode for full security.**

# Verify deployment:
./scripts/verify.sh

# Rollback (per-node):
sudo ./scripts/rollback.sh --yes
```

---

## Deployment Modes

The kit supports two deployment modes with different security characteristics:

| Aspect | Sudo Mode | Non-Sudo Mode |
|--------|-----------|---------------|
| **Container User** | `llm-svc` service user | Current host user |
| **Firewall** | Auto-configured | Not configured |
| **Docker Network** | Auto-created | Must pre-exist |
| **Port Binding** | Node IP only | 0.0.0.0 (all interfaces) |
| **Security Level** | ✅ Full security | ⚠️ Degraded |
| **Use Case** | Production | Testing/Development |

** recommendation: Always use sudo mode for production deployments.**

---

## Architecture

```
┌─────────────────────────────────────────────┐
│                    Lab LAN                    │
│                                              │
│  ┌──────────────┐        ┌──────────────┐   │
│  │   Hub Node   │        │  Worker Node │   │
│  │  (spark-01)  │        │  (spark-02)  │   │
│  │              │        │              │   │
│  │ ┌──────────┐ │        │ ┌──────────┐ │   │
│  │ │ LiteLLM  │ │◄──────►│ │  vLLM    │ │   │
│  │ │  :4000   │ │        │ │  :8000   │ │   │
│  │ └──────────┘ │        │ └──────────┘ │   │
│  │ ┌──────────┐ │        │              │   │
│  │ │ Postgres │ │        │              │   │
│  │ │  :5432   │ │        │              │   │
│  │ └──────────┘ │        └──────────────┘   │
│  └──────────────┘                            │
└─────────────────────────────────────────────┘
         ▲
         │
    Clients (10.0.0.0/24)
```

### Single Source of Truth

**`inventory.yaml`** defines the entire lab:
- Node IDs, roles, LAN IPs
- Model recipes per node
- Client subnets that can access the hub
- NFS configuration

All other configuration is **generated** from this file.

---

## Directory Structure

```
spark-kit-3/
├── README.md                    # This file
├── .gitignore                   # Git ignore rules for secrets
├── inventory.yaml               # Lab topology (edit this!)
│
├── infrastructure/
│   └── deploy.sh                # Unified deploy script (hub/worker/hub+worker)
│   └── docker-compose.hub.yml   # Hub stack (iteLLM + Postgres)
│
├── scripts/
│   ├── verify.sh               # Verification script (no secrets printed)
│   └── rollback.sh              # Per-node rollback
│
├── recipes/
│   ├── README.md               # Recipe documentation
│   └── qwen3.6-35b-a3b-nvfp4.yaml  # Default model recipe
│
└── generated/                   # Auto-generated files (DO NOT EDIT)
    ├── litellm-config.yaml     # Generated LiteLLM configuration
    └── workers/                # Generated worker configs
```

---

##Cls

## Deployment

### 1. Edit Inventory

Edit `inventory.yaml` to match your lab:

```yaml
lab:
  client_subnets:
    - "10.0.0.0/24"
    - "192.168.1.0/24"

nodes:
  - node_id: spark-01
    role: hub+worker      # Hub serves a model too
    lan_ip: "10.0.0.30"
    model_recipe: "qwen3.6-35b-a3b-nvfp4"
  
  - node_id: spark-02
    role: worker
    lan_ip: "10.0.0.31"
    model_recipe: "qwen3.6-35b-a3b-nvfp4"
```

### 2. Deploy Hub

```bash
# On spark-01 (hub node):
cd spark-kits/spark-kit-3
sudo ./infrastructure/deploy.sh
```

The script will:
- Detect the node from its IP
- Ask for role confirmation
- Create service user (`llm-svc`)
- Configure firewall
- Generate secrets (DB password, API keys)
- Start LiteLLM + Postgres
- Generate LiteLLM config from inventory
- Start vLLM worker (if hub+worker role)

### 3. Deploy Workers

```bash
# On each worker node (spark-02, spark-03, etc.):
sudo ./infrastructure/deploy.sh
```

Same script, different role. The script detects the node from the inventory and deploys the vLLM worker.

### 4. Verify

```bash
# Run verification against all nodes
./scripts/verify.sh

# Verify specific node
./scripts/verify.sh --node spark-01

# Verify hub only
./scripts/verify.sh --hub

# Verify workers only
./scripts/verify.sh --workers
```

The verification script:
- ✅ Tests external behavior only (HTTP, ports, containers)
- ✅ **Never prints secret values**
- ✅ Reports pass/fail per checkpoint
- ✅ Includes negative auth test (401 without key)

---

## Adding New Models

1. Create a recipe file in `recipes/`:

```yaml
# recipes/my-model.yaml
model_name: "nvidia/my-amazing-model"
served_model_name: "my-model"
tool_call_parser: "qwen3_xml"
reasoning_parser: "qwen3"
max_model_len: 262144
gpu_memory_utilization: 0.8
max_num_seqs: 15
enable_auto_tool_choice: true
trust_remote_code: true
```

2. Update `inventory.yaml` to use the recipe:

```yaml
nodes:
  - node_id: spark-06
    role: worker
    lan_ip: "10.0.0.35"
    model_recipe: "my-model"
```

3. Deploy the worker:

```bash
sudo ./infrastructure/deploy.sh
```

---

## Security Standards Implemented

| Standard | Status | Notes |
|----------|--------|-------|
| Non-root containers | ✅ | All containers run as `llm-svc` user |
| Secrets out of version control | ✅ | Secrets in `secrets/` (gitignored) |
| vLLM unreachable from LAN | ✅ | Firewall only allows hub IP to reach vLLM |
| Single ingress | ✅ | Only LiteLLM port exposed to client subnets |
| Pinned images | ✅ | All images pinned (digest or version) |
| Bearer authentication | ✅ | vLLM requires VLLM_API_KEY |
| native VLLM API key | ✅ | Uses `VLLM_API_KEY` env var |
| Unique API key per node | ✅ | Each worker gets its own key |
| LiteLLM master key with sk- prefix | ✅ | Auto-generated with correct prefix |
| no-new-privileges | ✅ | Applied to all containers |
| No Docker socket mount | ✅ | Never mounted anywhere |
| Health checks | ✅ | On all containers |
| Restart policies | ✅ | `unless-stopped` on all containers |

---

## Firewall Rules

The deploy script automatically configures:

### Hub Node:
- Default: Deny all incoming
- Allow: SSH
- Allow: LiteLLM port (4000) from client subnets only
- Allow: Self access to vLLM port (8000) if hub+worker
- Default: Allow all outgoing

### Worker Node:
- Default: Deny all incoming
- Allow: SSH
- Allow: vLLM port (8000) from hub IP only
- Default: Allow all outgoing

**Result**: vLLM is **invisible to the rest of the LAN**, accessible only via LiteLLM hub.

---

## Secrets Management

All secrets are **generated on the node that uses them**:

- `secrets/db_password.txt` - PostgreSQL password
- `secrets/litellm_master_key.txt` - LiteLLM master key (sk- prefixed)
- `secrets/vllm_api_key.txt` - vLLM API key for this node

**Never committed**: The `secrets/` directory is gitignored.

---

## Fixed Bugs from Previous Kits

| Bug | kit-1 | kit-2 | kit-3 |
|-----|-------|-------|-------|
| Readonly shell variable assignment | ✗ | ✗ | ✅ Fixed (use local vars) |
| Malformed DB URL | ✗ | ✅ | ✅ Fixed |
| Wrong host routing | ✗ | ✗ | ✅ Inventory-based generation |
| Comments in continuation | ✅ | ✗ | ✅ Fixed |
| Firewall breaks stack | ✗ | N/A | ✅ Allow outgoing |
| Firewall exposes vLLM | N/A | ✗ | ✅ Source-IP restricted |
| Secrets in git | ✗ | ✅ | ✅ .gitignore |
| Root containers | ✅ | ✗ | ✅ Non-root service user |
| No health checks | ✗ | ✅ | ✅ On all containers |
| Floating image tags | ✗ | ⚠️ | ✅ All pinned |
| Smoke test prints secrets | N/A | ✗ | ✅ Never prints secrets |
| Master key lacks sk- prefix | ✗ | ✗ | ✅ Correct prefix |

---

## NFS Model Cache (Optional)

By default, NFS cache is **enabled** in inventory.yaml.

### Hub (NFS Server):
```bash
# Export is automatically configured by deploy.sh
# /mnt/shared-models is shared read-write
```

### Workers:
```bash
# /mnt/shared-models is automatically mounted read-only
# vLLM uses HF_HUB_CACHE=/mnt/shared-models
```

If NFS is unavailable, workers download models independently.

---

## Rollback

```bash
# Rollback current node (stops containers, removes firewall rules)
sudo ./scripts/rollback.sh

# Rollback without confirmation
sudo ./scripts/rollback.sh --yes

# Rollback but keep firewall rules
sudo ./scripts/rollback.sh --yes --keep-firewall

# Rollback specific node
sudo ./scripts/rollback.sh --yes --node spark-01
```

Rollback **only affects the current node**. Other nodes continue running.

---

## Model Recipes

Each recipe file defines model-specific parameters:

- `model_name`: Full HuggingFace identifier
- `served_model_name`: Model name exposed via LiteLLM
- `tool_call_parser`: vLLM tool call parser (e.g., `qwen3_xml`)
- `reasoning_parser`: vLLM reasoning parser (e.g., `qwen3`)
- `max_model_len`: Maximum context length
- `gpu_memory_utilization`: GPU memory ratio (0.0-1.0)
- `max_num_seqs`: Maximum concurrent sequences
- `enable_auto_tool_choice`: Auto tool selection
- `trust_remote_code`: Trust remote code

Tuned for **128GB unified memory** (Grace-Blackwell GB10):
- GPU utilization: 0.8 (80%)
- Max sequences: 15

---

## Default Model

The default model is `nvidia/Qwen3.6-35B-A3B-NVFP4` as specified in the spec.

---

## Supported User Stories

| User Story | Status |
|------------|--------|
| Single deploy entry point per node | ✅ `./infrastructure/deploy.sh` |
| Ask if node hosts LiteLLM | ✅ Role prompt |
| Single inventory file | ✅ `inventory.yaml` |
| LiteLLM config from inventory | ✅ `generated/litellm-config.yaml` |
| Replicas load-balance | ✅ Same model name across entries |
| Distinct models, distinct aliases | ✅ different served_model_name |
| Unique API key per worker | ✅ `secrets/vllm_api_key.txt` per node |
| Secrets in gitignored files | ✅ `secrets/` directory |
| vLLM requires bearer auth | ✅ `VLLM_API_KEY` env var |
| Firewall auto-configured | ✅ Source-IP restricted |
| vLLM unreachable from LAN | ✅ Only hub IP allowed |
| LiteLLM single ingress | ✅ Only port 4000 exposed to clients |
| Non-root containers | ✅ `llm-svc` user |
| no-new-privileges | ✅ Set on all containers |
| No Docker socket mounted | ✅ Never mounted |
| Pinned images | ✅ All images pinned |
| Per-model recipes | ✅ `recipes/` directory |
| Tuned for 128GB | ✅ 0.8 GPU util, 15 seqs |
| Health checks | ✅ On all containers |
| Verification script | ✅ `scripts/verify.sh` |
| Verification no secrets | ✅ Never prints secret values |
| Negative auth test | ✅ 401 without key |
| NFS model cache | ✅ Optional, off by default |
| Per-node rollback | ✅ `scripts/rollback.sh` |
| Generation from inventory | ✅ No hand-edited per-host files |
| Hub also serves model | ✅ hub+worker role |

---

## Future Work (Out of Scope)

The following are **not implemented** in Stage 1:

- Stage 2 observability (Prometheus, Grafana, Loki, PostHog)
- TLS termination (plaintext on isolated VLAN)
- Tensor parallelism, multi-node model splitting
- Network scanning, heartbeat protocols, node markers
- Automated virtual key issuance for students

These are documented as future work in the spec.

---

## License

This kit is designed for lab deployment on NVIDIA DGX Spark nodes.

---

## Version

**Spark Kit 3 - Version 1.0.0 - Stage 1**

Generated from spec: consolidated DGX Spark inference kit (stage 1)
