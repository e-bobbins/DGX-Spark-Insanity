# spark-kit-3

Turn a DGX Spark (or any GPU Linux box) into an OpenAI-compatible LLM server
for a lab. One command per machine. Secrets and firewalls handled for you.

## Quick start

On the node that will be the hub, run:

```bash
git clone https://github.com/e-bobbins/DGX-Spark-Insanity
cd DGX-Spark-Insanity/spark-kits/spark-kit-3
sudo ./infrastructure/deploy.sh
```

The script asks a handful of questions (it accepts the default for most of
them), then installs everything. When it finishes, you have one endpoint
on `http://<this-ip>:4000/v1` that speaks the OpenAI API. Call it with the
master key, which lives in `secrets/litellm_master_key.txt` on the hub.

## What am I installing?

Three containers:

- **vLLM** actually runs the model on the GPU.
- **LiteLLM** is the front door. Your tools and notebooks talk to it; it
  forwards requests to whichever machine has the model.
- **Postgres** keeps track of keys and usage for LiteLLM.

On the hub machine all three run together. Other machines run only vLLM and
hand their GPU to the lab through the hub. Plain network + firewalls between
them; nothing exotic.

```
┌─────────────────────────────────────────────┐
│                    Lab LAN                  │
│                                             │
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
│         ▲                                    │
│         │                                    │
│    Clients (10.0.0.0/24)                     │
└─────────────────────────────────────────────┘
```

## Deploy a node

```bash
sudo ./infrastructure/deploy.sh
```

Answer the prompts:

1. **Node IP.** It detects this; press Enter to accept.
2. **Role.** Pick `1` (hub + model) for the first machine, `3` (model only)
   for the rest. Default is `1`.
3. **Client subnets** (hub only). Which IP ranges may talk to the endpoint,
   space-separated, e.g. `10.0.0.0/24`. Press Enter to take what is in
   `inventory.yaml`.
4. **Node ID.** Enter gives you one generated from the IP.
5. **Model recipe.** Enter gives the default, `qwen3.6-35b-a3b-nvfp4`.
6. **Confirm.**

The first run on a node pulls a ~8.5 GB image and downloads the model, so
budget several minutes to an hour depending on your pipe. The script waits
with you and says so while it waits.

Already deployed here and just want to restart what's installed?

```bash
sudo ./infrastructure/deploy.sh --restart-services
```

That skips every prompt: it reads this node's role and model from
`inventory.yaml` and re-applies using the secrets already on disk.

## Connect your second machine's key to the hub

After you deploy any machine that runs a model, the hub needs that
machine's API key before it can route to it. On the hub:

```bash
sudo ./infrastructure/deploy.sh --sync-keys
```

It copies the key over SSH, wire, and restarts LiteLLM. Re-run it whenever
you add or re-key a worker. Every worker gets its own key, so one leak
doesn't unlock the whole lab.

If you only have one node, skip this entirely.

## Use it

```bash
export KEY=$(sudo cat secrets/litellm_master_key.txt)
curl http://<hub-ip>:4000/v1/chat/completions \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen3.6-35b-a3b-nvfp4","messages":[{"role":"user","content":"hello"}]}'
```

Any OpenAI client works the same way: base URL + key + model name.

## Check that everything works

```bash
./scripts/verify.sh
```

Reports pass/fail per check: containers up, firewall rules, secret file
permissions, and that the endpoint rejects requests without a key. It never
prints secret values, so the output is safe to paste into a ticket.

## Undo it

```bash
sudo ./scripts/rollback.sh --yes
```

Stops and removes this node's containers and firewall rules. Other nodes
keep running. Your secrets stay on disk for a redeploy. Deleting the node's
Postgres data is part of a hub rollback, which is worth knowing before you
run it.

## Models

The default model is set in a reviewed, small file,
`recipes/qwen3.6-35b-a3b-nvfp4.yaml`: which checkpoint to load, context
length, parser settings, memory share, concurrency. To serve a different
model, copy a recipe, edit the values, and pick the new name at the recipe
prompt. You never edit deploy scripts to add a model.

## When something breaks

- **deploy.sh stopped partway.** Just run it again. It reuses secrets and
  cleans up after interrupted starts. `--restart-services` skips prompts.
- **Container won't get healthy.** Look at the logs:
  `docker logs -f litellm-proxy` or `docker logs -f vllm-<node-id>`. A vLLM
  container that is still downloading the model is normal.
- **Client gets 401.** Key missing from the request, or the hub doesn't
  have the worker's key yet. Run `--sync-keys` on the hub.
- **Can't reach the endpoint from a client machine.** The client's subnet
  must be in the firewall allow list from step 3 of the hub deploy.
- Everything here assumes Ubuntu-style hosts with `ufw` and Docker.

---

# Reference

The rest of this file is background. Nothing below should be needed for a
normal deployment.

### Layout

```
inventory.yaml                one file listing every node, role, IP, model
infrastructure/deploy.sh      the only deploy entry point
infrastructure/docker-compose.hub.yml   hub containers (LiteLLM + Postgres)
scripts/verify.sh             pass/fail checks, secrets never printed
scripts/rollback.sh           per-node teardown
recipes/                      per-model serving flags (reviewed files)
generated/                    written by deploy.sh, never edit by hand
secrets/                      written by deploy.sh, gitignored, never commit
tests/run-tests.sh            offline checks: shellcheck + config generation
```

`deploy.sh` records each node it deploys into `inventory.yaml`. To rebuild
the lab on paper, read that one file.

More background (bug history from the earlier kits, the full spec/story
mapping, security-standards table) lives in [EXTENDED.md](EXTENDED.md).

### Security model

- Containers run as a dedicated `llm-svc` service user, `no-new-privileges`
  set, no Docker socket mounted.
- Incoming traffic is denied by default. vLLM accepts connections only from
  the hub's IP, so the model nodes are invisible to the rest of the LAN.
  LiteLLM's port is reachable only from the client subnets you listed.
- Secrets are generated on the node that uses them with `openssl rand`,
  written to mode-600 files in `secrets/`, and never leave that node except
  the over-SSH copy during `--sync-keys`.
- The LiteLLM master key has the `sk-` prefix LiteLLM requires.
- Outgoing traffic stays open so image and model pulls work.

### Two deploy modes

| | `sudo ./infrastructure/deploy.sh` | `--non-sudo` |
|---|---|---|
| Service user | `llm-svc` | your user |
| Firewall | configured | not configured |
| vLLM port binding | node IP only | 0.0.0.0 (all interfaces) |
| Intended for | production | throwaway tests |

### NFS model cache

Off by default (`lab.nfs.enabled` in `inventory.yaml`). When on, the hub
exports `export_path` with `root_squash`, restricted to the client subnets,
and workers try to mount it read-only and point `HF_HUB_CACHE` there, so a
model downloads once for the whole lab instead of once per node. If the
mount fails, each worker downloads independently and deployment continues.

### Images

Pinned in one place at the top of `infrastructure/deploy.sh` and passed to
compose through the env file:

- vLLM: `nvcr.io/nvidia/vllm:26.10-py3` (NGC tags follow `YY.MM-py3` and
  include linux/arm64 builds; this is what makes it GB10-capable)
- LiteLLM: `ghcr.io/berriai/litellm:v1.83.7-stable`
- Postgres: `pgvector/pgvector:pg17` (a superset of plain Postgres, kept so
  a stage-2 feature can adopt it without migration)

### Known limitations

- Worker key sync is manual (`--sync-keys`) by design; no automation.
- Image pins are version tags, not digests. Digests would be stricter.
- vLLM serving profiles (standard chat vs agentic flag sets) are a single
  recipe value today; profile support is tracked in the issues.
- Redeploy recreates containers and vLLM re-downloads the model unless the
  NFS cache is enabled. Fixing that is tracked in the issues.
- Stage 2 work (monitoring dashboards, TLS, automated student keys) is not
  started. See issue #1.

### Tests

```bash
./tests/run-tests.sh        # or: make test
```

Runs shellcheck over every script and exercises the LiteLLM config
generation against a vendored stub, no Docker needed. The scripts fetch
their own pinned `yq` (`mikefarah/yq`) on first run if a usable copy is not
installed. Runtime behavior needs
a real node; `scripts/verify.sh` is the check there.
