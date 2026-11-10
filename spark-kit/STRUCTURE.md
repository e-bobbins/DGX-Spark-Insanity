# spark-kit — intended structure (scaffold only)

> ⚠️ **NOT BUILT YET.** This folder exists to capture the kit's target structure.
> The files below are NOT created until the current project (RUNBOOK / HANDOFF)
> has reached production-level quality. Do not build kit files until then.

## Kit layout (final target)

```
spark-kit/
├─ README.md            # kit one-pager: what it is, how to read playbook vs runbook, prerequisites-at-a-glance
├─ playbook.md          # ★ main artifact — WHAT + WHY: pattern, Spark constraints, rules ("avoid X", "ensure Y")
├─ runbook.md           # HOW — proven copy-paste steps: prerequisites → bring up vLLM → bring up Bifrost → verify → ops → debug
├─ AGENTS.md            # for agents: how to use this kit          [scaffold — TO DO]
├─ scripts/
│  ├─ bring-up.sh       # [scaffold — TO DO]
│  └─ verify.sh         # [scaffold — TO DO]
└─ skills/
   └─ …                 # [scaffold — TO DO]
```

## Settled decisions (from grill, 2026-10-02)

- **Location:** new subfolder inside this repo (`agent_playground/spark-kit/`), version-controlled, portable by copying elsewhere.
- **Model:** concrete as-run recipe — the *running example* is a real vLLM+Bifrost bring-up, but the specific model is an inline placeholder (`--model <REPLACE_WITH_MODEL>` / `--served-model-name <NAME>`), swappable per DGX Spark.
- **Voice:** single audience-agnostic; one doc structure readable by both humans (inline why) and agents (verbatim commands).
- **Playbook vs runbook:** playbook = what/why + "avoid X" / "ensure Y"; runbook = proven bring-up steps. Debug gotchas live in the runbook (`## Debug`); their *reason* lives in the playbook.
- **Self-contained:** travels standalone, no runtime dependency on the repo. One-line pointer at the bottom only (RUNBOOK.md in `ornith-vllm-bifrost/` is this box's live state).

## Next steps

When the current project is stable enough to productize: build `playbook.md` and `runbook.md` from the current project data; scaffold `AGENTS.md`, `scripts/`, `skills/`.
