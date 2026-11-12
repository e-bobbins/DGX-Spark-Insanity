# Model Cache Guidelines: DGX Spark LLM Stack

## Overview

This document describes the optional shared model cache mechanism using NFS to minimize bandwidth usage across the lab LAN when deploying multiple vLLM worker nodes.

---

## Architecture

```
+------------------+
|   Hub Node       |
|                  |
|  /mnt/shared-   |───(NFS Export)───┐
|  models          |                  |
|                  |                  v
+------------------+               +------------------+
                             +---> | Worker 1        |
                                 |  (Mount Cache)    |
                                 +-------------------+
                                          |
                                         (vLLM loads model from cache)

                             +------------------+
                             | Worker 2         |
                             |  (Same path)     |
                             +-------------------+
```

### Purpose
- Reduce redundant model downloads across workers
- Speed up worker provisioning time
- Centralized model updates/rollouts

---

## NFS Server Configuration (Hub Side)

### Create Export Directory
```bash
# On Hub node where NFS server runs:
sudo mkdir -p /mnt/shared-models
sudo chown root:root /mnt/shared-models
sudo chmod 755 /mnt/shared-models   # world-readable: non-root container users must read models under root_squash
```

### Configure `/etc/exports`
```bash
# Edit this file on the Hub NFS server (root_squash is the secure default):
/mnt/shared-models 10.0.0.0/24(rw,sync,no_subtree_check,root_squash)
```

**Security Notes**:
- `root_squash` (secure default) prevents remote root mapping; the export directory must therefore be world-readable (mode 755) so non-root container users can read model files
- For stricter security, specify the exact trusted hub subnet (e.g., `10.0.0.0/24`) rather than `*`

### Apply Export Configuration
```bash
# After editing /etc/exports:
sudo exportfs -a
sudo systemctl restart nfs-server
```

### Verify Mounts on Workers
On each worker:
```bash
mount | grep shared-models
# Should show: /mnt/shared-models on <nfs-server-ip>:shared-models type nfs4 ...
```

---

## Docker Compose Integration

The current `docker-compose.yml` defines a single named volume:

```yaml
volumes:
  postgres_data:
    driver: local
```

The shared model cache is a **host-level NFS mount** at `/mnt/shared-models`
(see `provision-nfs.sh`), consumed directly by worker vLLM containers via
`HF_HUB_CACHE=/mnt/shared-models`. The hub's `docker-compose.yml` intentionally
defines **no** model-cache volume — the hub is a routing proxy and never touches
model weights. On the worker host, ensure `/mnt/shared-models` is an NFS mount
pointing to the Hub's export.

---

## Cache Population Workflow

1. **Initial Download** (Any Worker)
   ```bash
   # On any worker with GPU access and internet (or internal model registry):
   export MODEL_NAME="nvidia/Qwen3.6-35B-A3B-NVFP4"
   export HF_HUB_CACHE=/mnt/shared-models
   ./infrastructure/worker/deploy.sh
   
   # Model downloads to /mnt/shared-models via HF_HUB_CACHE env var
   ```

2. **Subsequent Workers**
   - Mount same NFS path
   - vLLM loads model from cache instead of downloading
   - Deploy time reduced significantly

---

## Security Considerations

### Permission Model
- NFS export directory is mode 755 (world-readable) so container users can read model files under `root_squash`
- The worker container runs as the image-default (root) user with `--security-opt=no-new-privileges` applied, pending on-node validation; read-only access to models is expected
- Models are typically loaded as world-readable binaries after download

### Network Isolation
- NFS traffic (port 2049) must be allowed on firewall between Hub and Workers
- **Alternative**: Workers pull models independently if cache is unavailable - not a failure, just slower first startup

### Audit Trail
Monitor NFS access logs:
```bash
# On Hub NFS server:
journalctl -u nfs-server | grep shared-models
```

---

## Fallback Behavior

If NFS mount fails or is unavailable:

1. vLLM falls back to local HF cache if exists (`$HOME/.cache/huggingface`)
2. If neither exists, vLLM attempts to download model directly (slow, consumes bandwidth)
3. Consider adding a `.env` fallback for offline models stored locally on Hub

### Recommended Fallback Configuration

In worker's `vllm.env`:
```bash
# Primary: NFS cache (fastest)
HF_HUB_CACHE=/mnt/shared-models

# Fallback to local directory if NFS fails
HF_HOME=/tmp/hf-cache-fallback
HF_HUB_CACHE_FALLOVER=${HF_HOME}
```

Note: Hugging Face hub doesn't officially support multiple caches, but setting `HF_HOME` creates an alternate cache location.

---

## Deployment Commands Summary

### On Hub (NFS Server)
```bash
sudo mkdir -p /mnt/shared-models
echo "/mnt/shared-models 10.0.0.0/24(rw,sync,no_subtree_check,root_squash)" | sudo tee -a /etc/exports
sudo exportfs -a
sudo systemctl restart nfs-server
```

### On Workers (Mount Cache)
```bash
# If NFS path doesn't exist, mount it:
if [ ! -d "/mnt/shared-models" ] && ! mountpoint -q "/mnt/shared-models"; then
  sudo mount -t nfs <HUB_LAN_IP>:/mnt/shared-models /mnt/shared-models
fi

# Verify mount:
mount | grep shared-models
```

Then proceed with normal worker deployment.

---

**Document Version**: 1.0  
**Last Updated**: 2026-11-05  
**Related**: `security.md` (section on NFS configuration)