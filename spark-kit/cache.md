# Model Caching Strategy: Shared Storage

## Problem
Downloading large models (e.g., `Qwen3.6-35B-A3B-NVFP4` ~18GB+) to every DGX Spark independently wastes lab bandwidth and delays deployment.

## Solution: Network File System (NFS) Mount

### 1. Infrastructure Requirement
One spark (usually the **Hub**) is designated as the model cache server. It exports a directory via NFS.

### 2. Directory Layout
```text
/mnt/shared-models/       # NFS root export on Hub
    ├── nvidia/
    │   └── Qwen3.6-35B-A3B-NVFP4/
    │       ├── model.safetensors
    │       └── config.json
    └── (future models)
```

### 3. Worker Configuration
On each Worker node:
1. Install `nfs-common`: `sudo apt-get install -y nfs-common`
2. Mount the Hub's cache: 
   ```bash
   sudo mount -t nfs <HUB_IP>:/mnt/shared-models /mnt/shared-models
   ```
3. Create a symlink in the worker's container cache path to the NFS mount:
   ```bash
   ln -sf /mnt/shared-models /root/.cache/huggingface/hub
   ```

## Alternative: Centralized Artifact Registry (Future)
If the lab already has an internal artifact registry (e.g., Harbor, Nexus), models can be pulled once into the registry and distributed to nodes via a pull script during provisioning. This avoids NFS latency but requires more initial setup.

## Security Note
- NFS mounts should use `root_squash` on the server side to prevent container root users from escalating privileges on the host.
- Ensure NFS traffic is restricted to the internal lab VLAN via firewall rules.
