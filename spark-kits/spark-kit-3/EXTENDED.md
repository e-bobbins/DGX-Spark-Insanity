# spark-kit-3: extended reference

Background material cut from the main README to keep it readable. This is
for spec reviewers, auditors, and anyone tracing why the kit looks the way
it does. Nothing here is needed for day-to-day deployment.

## Fixed bugs from earlier kits

The consolidated kit replaced spark-kits/spark-kit and spark-kit-2. Bugs
verified against those kits and their status here:

| Bug | kit-1 | kit-2 | kit-3 |
|-----|-------|-------|-------|
| Readonly shell variable assignment (`UID`) | ✓ | ✓ | Fixed (plain variable names) |
| Malformed DB URL (stray construction point) | ✓ | ✓ | Fixed (`DATABASE_URL` built once, service hostname) |
| Wrong-host routing | ✓ | ✓ | Fixed (routes generated from inventory) |
| Comments inside line continuation | ✓ | | Fixed (no continuations carry comments) |
| Firewall breaks stack (deny outgoing) | ✓ | n/a | Fixed (outgoing allowed) |
| Firewall exposes vLLM to LAN | n/a | ✓ | Fixed (source-IP restricted to hub) |
| Secrets in git | ✓ | ✓ | Fixed (`secrets/` gitignored) |
| Root containers | ✓ | | Fixed (`llm-svc`, no-new-privileges) |
| No health checks | ✓ | ✓ | Fixed (all containers) |
| Floating image tags | ✓ | partial | Fixed (version pins, single source) |
| Smoke test prints secrets | n/a | ✓ | Fixed (verify prints no values) |
| Master key lacks `sk-` prefix | ✓ | ✓ | Fixed |

## Security standards implemented

| Standard | Notes |
|----------|-------|
| Non-root containers | All containers run as the `llm-svc` service user |
| Secrets out of version control | `secrets/` is gitignored; keys never printed by tooling |
| vLLM unreachable from LAN | Firewall accepts vLLM traffic from the hub IP only |
| Single ingress | Only LiteLLM's port accepts client-subnet traffic |
| Pinned images | Version tags from one source in `deploy.sh` |
| vLLM bearer auth | Native `VLLM_API_KEY`, random per worker |
| Unique API key per node | One key per worker; hub stores copies under `secrets/worker_keys/` |
| `sk-` master key prefix | Generated with the prefix LiteLLM requires |
| no-new-privileges | Set on every container |
| No Docker socket mounts | Never mounted anywhere |
| Health checks | On all containers, compose and `docker run` |
| Restart policies | `unless-stopped` everywhere, workers included |

## Supported user stories

Original spec (stage 1) mapped to what shipped:

| User story | Where it lives |
|------------|-------|
| Single deploy entry point per node | `infrastructure/deploy.sh` |
| Node asks whether it hosts LiteLLM | Role prompt (hub / worker / hub+worker) |
| One inventory file for the lab | `inventory.yaml`, updated by deploys |
| LiteLLM config generated from inventory | `generate_litellm_config` in `deploy.sh` |
| Replicas of one model load-balance | Same model name across routes |
| Distinct models under distinct aliases | Per-recipe `served_model_name` |
| Unique API key per worker | Per-node generation + `--sync-keys` exchange |
| Worker keys and DB password gitignored | `secrets/` |
| vLLM requires bearer auth | Native `VLLM_API_KEY` |
| Firewall limits vLLM to hub | Source-IP rules in `deploy.sh` |
| LiteLLM is the single ingress | Hub allows 4000 from client subnets only |
| Containers run as non-root service user | `llm-svc`, UID/GID passed to containers |
| no-new-privileges, no Docker socket | `docker run` and compose flags |
| Pinned images | Version tags, single source |
| Per-model recipe files | `recipes/` |
| Defaults tuned for 128 GB | 0.8 memory share, 15 sequences |
| Restart policies and health checks | All containers |
| Verification with pass/fail per check | `scripts/verify.sh` |
| Negative auth test | `verify.sh` expects 401 without a key |
| Verification output free of secrets | Values never printed |
| Optional NFS cache | `lab.nfs` in inventory; off by default |
| Per-node rollback | `scripts/rollback.sh` |
| Docs separate shipped from planned | README known-limits section, issue tracker |
| Static checks on all scripts | `tests/run-tests.sh`, strict `.shellcheckrc` |
| Clone + one script does the rest | The quick start |
| Secrets generated on the node they serve | `openssl rand` at deploy, mode 600 |
| Identical scripts on every node | Behavior differs only by prompts + inventory |
| Hub can also serve a model | hub+worker role |
| One OpenAI endpoint and key for students | LiteLLM on :4000 |
| Survives one Spark going down | LiteLLM routes only to live reachable workers; multi-worker labs keep serving |
| Inventory for review before class | `inventory.yaml` |
| Documented per-student virtual key procedure | LiteLLM admin UI / `/key/generate` with the master key (manual in stage 1) |

## Deployment modes detail

| Aspect | sudo mode | non-sudo mode |
|--------|-----------|---------------|
| Container user | `llm-svc` | current host user |
| Firewall | auto-configured | not configured |
| Docker network | auto-created | must pre-exist |
| Port binding | node IP only | 0.0.0.0 |
| Use case | production | testing |

## Firewall rule detail

Hub: default deny incoming; allow SSH; allow 4000/tcp from each client
subnet; if hub+worker, allow 8000/tcp from its own IP. Default allow
outgoing.

Worker: default deny incoming; allow SSH; allow 8000/tcp from the hub IP
only. Default allow outgoing.

`scripts/rollback.sh` deletes these rules per node (or all of them with
`--remove-all`, which is as dangerous as it sounds).
