# Security Standards: DGX Spark LLM Stack

## 1. Network Isolation & Exposure

### Airgapped Lab Environment Requirements
- **No Internet Access**: All nodes MUST be on internal lab VLAN with NO routing to public internet.
- **Firewall Rules**: `ufw` or `iptables` must explicitly allow inbound traffic ONLY from known agent/client subnets (e.g., `10.0.0.0/24`).
- **DNS Resolution**: DNS servers must be configured for internal lab domains only; block external DNS queries at firewall level.

### Hub vs Worker Networking

| Node Type | Service(s) | LAN Exposure | Internal Scope |
|-----------|------------|--------------|----------------|
| **Hub**   | LiteLLM, Postgres | Port 4000 (`litellm`) on specific hub IP only | Postgres: `localhost` / bridge network ONLY (never LAN exposed) |
| **Worker**| vLLM        | None. No ports open to LAN. Accessible *only* by Hub via internal routing. |

### Docker Network Strategy
- **Hub Stack**: Runs on dedicated `llm-net` bridge network. Containers talk over bridge; only LiteLLM port 4000 is bridged to host with firewall protection.
- **Worker Stack**: Uses `--network host` (for simplicity in airgapped environment) OR connects to Hub's `llm-net` if cross-node sharing needed. Firewall rules are the PRIMARY security boundary.

### Host Networking Security Implications
When using `--network host` on workers:
- All container processes share host network namespace
- Container can communicate with ANY host IP/port
- **Mitigations**: 
  - Strict ufw firewall rules (only Hub subnet allowed)
  - Non-root container user (`llm-svc`)
  - No privileged mode or Docker socket mounts
- **Risk Profile**: Acceptable for airgapped lab if firewall rules are strictly enforced and monitored

---

## 2. Container Hardening

### User Execution Model
**Current (Stage 1)**: Deployments run non-sudo. Hub containers run as the current host user (no service user is created). The worker vLLM container runs as the image-default (root) user with `--security-opt=no-new-privileges` applied; non-root worker execution is pending on-node validation.

**Target**: once validated on-node, run all containers as a non-root service user:

```bash
# Docker run with explicit user (target state, once validated):
docker run --user <uid>:<gid> ...
```

### Volume Mounts & Permissions
- **Postgres volumes**: owned internally by the image-default Postgres user (999) — no init script is used (see README note on prior-stage assumptions)
- **Model cache mounts** (`/mnt/shared-models`): mode 755 (world-readable) so container users can read models under `root_squash`; only mounted when NFS is properly configured (see Appendix A)
- **No world-writable volumes**: All data directories must use `750` or more restrictive

### GPU Mounts
- Only necessary capabilities passed: `--gpus all` (or specific GPU devices if isolating)
- No `/dev/nvidia*` device files mounted directly outside containers unless required for debugging

---

## 3. Secrets Management

### API Keys & Credentials
**NEVER**: Hardcode secrets in Dockerfile, docker-compose.yml, or version-controlled scripts.

**REQUIRED**: 
- Store secrets in `.env` files on host with `chmod 600`
- Use environment variable references (`os.environ/KEY`) not literal values in config
- Generate new keys on each deployment:
  ```bash
  DB_PASSWORD=$(openssl rand -base64 32)
  LITELLM_MASTER_KEY=$(openssl rand -hex 32)
  VLLM_API_KEY=$(openssl rand -hex 32)
  ```

### Credential Refresh
- Rotate keys periodically (quarterly minimum, or on suspected breach)
- Update compose `.env` file without recreating volumes if possible
- Audit logs for key usage patterns to detect misuse

---

## 4. Monitoring & Audit

**Stage 1**: Basic observability via Docker logging drivers and health checks
- Container stdout/stderr piped to host journal or Loki (future)
- Health check endpoints enabled on LiteLLM (`/health`)

**Stage 2** (Future): Full observability stack
- Grafana dashboards for GPU utilization, request latency, error rates
- Prometheus metrics scraping from vLLM and LiteLLM
- Posthog analytics for usage tracking (if permitted by policy)
- Audit logging for API key usage and access patterns

---

## 5. Deployment Checklist

Before marking deployment as ready:

- [ ] `docker-compose.yml` exists in `infrastructure/hub/` with proper network/volume config
- [ ] `.env` template present with placeholder comments, not real secrets
- [ ] Service user policy: hub containers run as the current host user; worker runs as image-default user with `--security-opt=no-new-privileges` (non-root pending on-node validation)
- [ ] Firewall rules applied and verified (ufw default deny, allow only trusted subnets) — configured manually, not by the deploy scripts
- [ ] Postgres runs as the image-default user (no init script)
- [ ] Worker `docker run` includes `--security-opt=no-new-privileges`
- [ ] No hardcoded secrets in compose files or scripts
- [ ] Health checks configured for all services
- [ ] NFS mount configuration documented and tested (if using model cache)

---

## 6. Incident Response Basics

**If student probes system**:
1. Check firewall logs for unauthorized access attempts
2. Review container audit logs (if enabled)
3. Verify `.env` file permissions are still `600`
4. Rotate all API keys if breach suspected
5. Isolate compromised node from network
6. Document incident and update hardening procedures

---

## Appendix A: NFS Configuration for Model Cache

If using shared model cache (`/mnt/shared-models`), Hub must export with:
- `root_squash` enabled (secure default; prevents remote root mapping)
- Valid mount options only: `sync,nosuid,nodev`
- The export directory must be world-readable (mode 755) so non-root container users can read model files under `root_squash`
- Firewall port 2049 allowed only from trusted management subnet

Worker should mount read-only if possible, or with restrictive permissions.

---

**Document Version**: 1.0 (Stage 1 Deployment)  
**Last Updated**: 2026-11-05  
**Classification**: Internal Use - Cybersecurity Lab