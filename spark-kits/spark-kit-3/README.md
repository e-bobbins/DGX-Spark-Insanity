# DGX Spark LLM Stack - Spark Kit 3 (Consolidated)

**Status**: Stage 1 - Consolidated canonical kit

This kit replaces both spark-kit and spark-kit-2. It resolves all identified bugs, implements lab security standards, and provides a single, reviewable deployment path.

---

## Quick Start

## Installation & Pull Guide

Practical deployment steps reflecting what the scripts actually do today,
including known rough edges — see [Known issues you will hit](#known-issues-you-will-hit) before your first run.

### Prerequisites (per node)

- DGX Spark (GB10, arm64) with NVIDIA drivers and `nvidia-smi` working
- Docker installed and the daemon running (`docker info` succeeds)
- `git` and `openssl`
- `yq` (mikefarah Go version) and `curl` — the deploy script tries to
  `apt-get install yq` for you when running with sudo
- Root (sudo) access on the node
- Network reachability to the other nodes' LAN IPs and outbound internet
  (model and image pulls)

### Pull / update the kit

```bash
git clone https://github.com/e-bobbins/DGX-Spark-Insanity
cd DGX-Spark-Insanity/spark-kits/spark-kit-3

# later, to update:
git pull
sudo ./infrastructure/deploy.sh   # re-run; secrets are reused if present
```

Everything runs from this one directory on the node itself. No files are
copied between machines; secrets are generated locally on each node and stay
there (`secrets/` is gitignored — verify it is untracked with
`git status --ignored`).

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


### 1. Hub node (usually your first / main Spark)

```bash
sudo ./infrastructure/deploy.sh
```

Answer the prompts:

| Prompt | What to answer |
|---|---|
| Node IP | Accept the auto-detected IP if correct |
| Node role | `1` = Hub + Worker (recommended: hub also serves a model), `2` = Hub only, `3` = Worker only |
| Client subnets (hub only) | Space-separated CIDRs that may reach LiteLLM, e.g. `10.0.0.0/24 192.168.1.0/24` |
| Node ID | Enter or press Enter to auto-generate from the IP |
| Model recipe (worker role only) | Enter for the default `qwen3.6-35b-a3b-nvfp4` |

The script then: creates the `llm-svc` service user, configures the firewall
(default deny incoming; SSH + LiteLLM 4000 from client subnets; vLLM 8000 from
the hub IP only; outgoing allowed), generates secrets into `secrets/`,
starts LiteLLM + Postgres via `docker-compose.hub.yml`, and starts the vLLM
container if you chose a worker role.

Equivalent via make: `make deploy`

### 2. Each worker node

Same procedure on every other Spark:

```bash
sudo ./infrastructure/deploy.sh
```

Choose role `3` (Worker only) and enter the **hub node's IP** when prompted.
The vLLM port is firewalled to accept traffic from the hub IP only.

### 3. Sync worker keys to the hub (required for multi-node)

After deploying workers, run this **on the hub** so it can authenticate to
each worker's vLLM:

```bash
sudo ./infrastructure/deploy.sh --sync-keys
```

It fetches each worker's `secrets/vllm_api_key.txt` over `scp` (you'll be
prompted for the ssh target and remote path per worker), stores copies in
`secrets/worker_keys/` (mode 600, gitignored), regenerates the LiteLLM
config with one route and one dedicated key variable per worker, and
restarts LiteLLM. Re-run it whenever a worker is re-keyed or added.

### 3. Non-sudo mode (testing only — not for production)

```bash
./infrastructure/deploy.sh --non-sudo
```

Degraded on purpose: no firewall, no service user, containers run as your
user, port 8000 binds to `0.0.0.0`. Requires the Docker network to exist:

```bash
sudo docker network create spark-kit-llm-net
```

### Using the stack (students / client apps)

One OpenAI-compatible endpoint, from any client subnet:

```bash
BASE=http://<hub-ip>:4000/v1
KEY=$(sudo cat /path/to/spark-kit-3/secrets/litellm_master_key.txt)

curl $BASE/chat/completions \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3.6-35b-a3b-nvfp4", "messages": [{"role":"user","content":"hello"}]}'
```

Per-user virtual keys (spend tracking, budgets) are issued through LiteLLM's
admin surface backed by Postgres — create users/keys via the LiteLLM admin UI
or `/key/generate` with the master key; that is the documented stage-1
procedure (no automated issuance yet).

### Rollback (per node)

```bash
sudo ./scripts/rollback.sh            # interactive
sudo ./scripts/rollback.sh --yes              # no prompt
sudo ./scripts/rollback.sh --yes --keep-firewall
```

Stops and removes this node's containers, removes the Docker network if
unused, removes this node's firewall rules, and deletes `generated/`. Secrets
are preserved for redeploy. **On a hub, the Postgres data volume is removed —
data is not recoverable.** Other nodes are untouched.

### Known issues you will hit

The issues tracked in the repository issue tracker (#2–#9) were fixed in the
same change that added this guide. Remaining operational notes:

1. **Worker key sync is manual by design.** After deploying (or re-keying) a
   worker, run `sudo ./infrastructure/deploy.sh --sync-keys` on the hub.
   Routes to a worker without a synced key fail auth.
2. **Image pins are version tags, not digests.** vLLM is pinned to NVIDIA's
   NGC multi-arch image `nvcr.io/nvidia/vllm:26.10` and LiteLLM to
   `ghcr.io/berriai/litellm:v1.83.7-stable`; pin digests for stricter
   reproducibility.
3. **Offline tests cover config generation only.** `tests/run-tests.sh`
   runs shellcheck plus an offline config-generation test with a stubbed
   `yq`. Full end-to-end validation (real GPU load, LiteLLM routing) still
   requires an on-node run of `scripts/verify.sh`.

### Firewall quick reference

| Node role | Allowed in | Notes |
|---|---|---|
| Hub | SSH; 4000/tcp from client subnets; 8000/tcp from own IP (if hub+worker) | Outgoing allowed |
| Worker | SSH; 8000/tcp from hub IP only | Outgoing allowed |

vLLM is unreachable from the rest of the LAN; LiteLLM :4000 is the only
ingress for clients.

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
├── tests/
│   ├── run-tests.sh            # Offline harness: shellcheck + config-gen tests
│   └── stubs/                  # Test-only yq stub (not a general yq)
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

Off by default (`lab.nfs.enabled: false` in `inventory.yaml`). When enabled:

### Hub (NFS Server)
`deploy.sh` writes `/etc/exports.d/spark-kit-3.exports` with `root_squash`,
restricted to the configured client subnets, and runs `exportfs -ra`. The
NFS server package (`nfs-kernel-server`) must be installed; if it is not,
the deploy warns and continues.

### Workers
`deploy.sh` attempts a **read-only** mount of the export and points
`HF_HUB_CACHE` at it when mounted. If the mount fails, the worker falls back
to downloading models independently — deployment is not blocked.

Set `lab.nfs.enabled: true` before deploying to use this.

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

## Supported Use Cases

| Scenario | Status |
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
