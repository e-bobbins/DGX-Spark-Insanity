# AGENT.md: Agent Deployment Guide for DGX Spark LLM Stack

## Purpose

This document describes how to deploy and verify the Spark Kit stack across multiple NVIDIA DGX Spark nodes in the lab. All present-tense procedures below use only the committed, non-sudo deployment scripts; items that are planned but not implemented are explicitly marked as such.

---

## Quick Start

```bash
# Copy the repo to each target Spark node (replace user/host with real values):
rsync -av "/path/to/Spark Kit/" <user>@spark-node:/opt/spark-kit/

# On the designated Hub node (non-sudo):
cd /opt/spark-kit/infrastructure/hub
./deploy.sh

# On each Worker node (non-sudo):
cd /opt/spark-kit/infrastructure/worker
export MODEL_NAME="nvidia/Qwen3.6-35B-A3B-NVFP4"  # or your model choice
./deploy.sh
```

---

## Deployment Modes

### 1. Deploy the Hub

`infrastructure/hub/deploy.sh` (non-sudo): creates `.env` with generated secrets, then starts the committed `docker-compose.yml` stack — LiteLLM published on port 4000, Postgres internal only. Firewall rules are NOT configured by the script; allow port 4000 from the trusted LAN subnet manually (`ufw`) if needed.

### 2. Deploy Workers

`infrastructure/worker/deploy.sh` (non-sudo): model selected via the `MODEL_NAME` environment variable. Runs the vLLM container with `--network host` on port 8000, reachable only by the Hub (enforced by manual firewall rules). The container runs as the image-default (root) user with `--security-opt=no-new-privileges` applied; non-root execution is pending on-node validation.

### 3. Discovery and Verification

- **Hub discovery**: probe port 4000 on the candidate subnet; a node answering on `/health` is the Hub.
- **Worker verification**: from the Hub, `curl http://<worker-ip>:8000/v1/models` should list the deployed model.
- **Topology**: see the Inventory Format section below.

---

## Hardware Facts (canonical)

Each DGX Spark is a single Grace-Blackwell (GB10) SoC: **one unified GPU, 128 GB unified memory**. There is no 8-GPU configuration and no 24 GB GPU SKU for the Spark. The vLLM worker uses `--gpu-memory-utilization 0.4` by default (env-overridable via `GPU_MEM_UTIL`).

---

## Agent Deployment Script — NOT IMPLEMENTED (Future work)

`scripts/agent-deploy.sh`, referenced in earlier documentation, **does not exist and is not implemented**. The following capabilities are planned only:

1. **Scan network** - probe port 4000 on each IP in a subnet for LiteLLM health
2. **Identify GPU nodes** - check `/proc/driver/nvidia/gpus/` for NVIDIA GPUs
3. **Deploy Hub** - invoke `infrastructure/hub/deploy.sh`
4. **Deploy Workers** - invoke `infrastructure/worker/deploy.sh`
5. **Generate inventory** - output a JSON topology map

---

## Agent Checkpoints (for verification)

After deployment, verify the following:

|Checkpoint|Method|Expected Result|
|---|---|---|
|Hub discovery|`curl http://<hub-ip>:4000/health`|Returns `{"status":"ok"}` or similar|
|Worker availability|From the Hub: `curl http://<worker-ip>:8000/v1/models`|Deployed model is listed|
|Health endpoints|Poll nodes at 30s intervals|All show "healthy" status after ~60s startup|
|Inventory accuracy|Compare actual vs discovered topology|Match within ±1 node (transient failures)|

---

## Agent Communication Protocol — NOT IMPLEMENTED (Future work)

The endpoint and heartbeat protocol below have **no backing service** and are not implemented. Kept here as a design sketch only:

```yaml
endpoint: http://localhost:8001/deploy/health  # UNIMPLEMENTED — no service listens on 8001
heartbeat_interval: 300s

# Discovery message format (design sketch)
{
  "type": "hub_discovery_probe",
  "agent_id": "<uuid>",
  "timestamp": "<iso-8601>",
  "target_port": 4000,
  "response_format": {"status": "ok"}
}
```

---

## Inventory Format (Agent Output)

```json
{
  "deployment_timestamp": "2026-11-06T09:05:00Z",
  "hub_nodes": [
    {
      "node_id": "spark-01",
      "ip": "10.0.0.30",
      "role": "hub",
      "endpoint": "http://10.0.0.30:4000/v1",
      "health_check_url": "http://10.0.0.30:4000/health"
    }
  ],
  "worker_nodes": [
    {
      "node_id": "spark-02",
      "ip": "10.0.0.31",
      "role": "worker",
      "model": "nvidia/Qwen3.6-35B-A3B-NVFP4",
      "endpoint": "http://10.0.0.31:8000"
    },
    {
      "node_id": "spark-03",
      "ip": "10.0.0.32",
      "role": "worker",
      "model": "nvidia/Qwen3.6-35B-A3B-NVFP4"
    }
  ]
}
```

---

## Rollback Procedure

The automated `scripts/agent-deploy.sh --mode=rollback` does not exist (see above). Manual rollback on an affected node:

```bash
# Hub:
cd infrastructure/hub
docker compose down

# Worker:
docker rm -f qwen36-worker
```

---

## Security Considerations for Agents

- **Credential injection**: Never store API keys in agent code; generate via `openssl rand` at deployment time
- **Network isolation**: Agent must be airgapped from the internet; all probes use the internal VLAN only
- **Privilege escalation**: Deploy scripts run as a regular user (no sudo); the hub container runs as the current host user and the worker container runs as the image-default user with `--security-opt=no-new-privileges` applied (non-root worker execution pending on-node validation)

---

## Failure Handling

|Failure Type|Recovery Action|
|---|---|
|NFS mount unavailable|Worker downloads the model independently (slower first startup)|
|Docker daemon not running|`deploy.sh` exits non-zero (`set -euo pipefail`); retry once the daemon is up|
|Port 4000 already in use|`docker compose up` fails to bind; resolve the port conflict manually|

---

## Future work (not implemented)

- `scripts/agent-deploy.sh` automation (see above)
- Node marker files `infrastructure/hub/.hub-node` / `infrastructure/worker/.worker-node` and the `NODE_ROLE` environment variable — no code reads these; planned, not active
- Docker-socket mount checks for worker discovery
- Agent-to-agent communication service on port 8001

---

**Document Version**: 1.1  
**Last Updated**: 2026-11-06
