# Security Standards: DGX Spark LLM Stack

## 1. Network Isolation & Exposure
### No Internet Exposure
- All nodes must be on an **internal lab VLAN** with no routing to the public internet.
- Firewall rules (`ufw` or `iptables`) should explicitly allow inbound traffic *only* from known agent/client subnets (e.g., `10.0.0.0/24`).

### Hub vs Worker Networking
| Node Type | Service(s) | LAN Exposure | Internal Scope |
|-----------|------------|--------------|----------------|
| **Hub**   | LiteLLM, Postgres | Port 4000 (`litellm`) on specific hub IP only | Postgres: `localhost` / bridge only (never LAN exposed) |
| **Worker**| vLLM        | None. No ports open to the LAN. Accessible *only* by Hub via dedicated bridge. |

### Docker Network Strategy
- **Hub Stack**: Runs on a dedicated `llm-net` bridge network. Containers in this stack talk over the bridge; only the LiteLLM port is bridged to the host.
- **Worker Stack**: Connects to the Hub's `llm-net` if cross-node sharing is needed, or uses `host` networking if local-only (for security).

## 2. Container Hardening
### Non-Root Execution
All containers MUST run as non-root service users (e.g., `vllm-svc`). 
- The `deploy.sh` scripts dynamically create the service user if it doesn't exist.
- Docker is started with: `--user $(id -u):$(id -g)`.
- Volume mounts must be owned/chowned to this UID/GID to avoid `Permission denied` errors.

### GPU Mounts
- Only necessary capabilities are passed (`--gpus all`).
- No shared volumes are mounted unless required for model persistence or logging.

## 3. Secrets Management
### API Keys
- **vLLM**: Set via `VLLM_API_KEY` env var in a dedicated `.env` file (`vllm.env`) on the host. NEVER hardcoded in `docker-compose.yml`.
- **LiteLLM**: `master_key` and database passwords stored in the Hub's `.env`.

### Credential Refresh
- Use environment variable references in config files (e.g., `os.environ/VLLM_API_KEY`) rather than literal strings to prevent leakage in version control.

## 4. Monitoring & Audit
*(To be implemented in future session)*
- Hub metrics endpoint exposed on `/metrics` for Prometheus scraping.
- Container logs piped to Loki via Docker log drivers (optional, if space allows).
