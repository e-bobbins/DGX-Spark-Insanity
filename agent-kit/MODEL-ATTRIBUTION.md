# Multi-Model Git Attribution

## Problem
You run multiple AI models and want each commit to show which model authored it — both for accountability and to distinguish contribution patterns in `git log`.

## Solution
Use **your verified GitHub email** + a **distinct author name per model**. This ensures:
- Commits attribute to your GitHub account (shows on your profile/contributors page)
- The author name field identifies which model made the change

## Setup

### Step 1: Configure globally (applies across all repos)
```bash
git config --global user.email "<your-verified-email>"   # ← must be a verified email linked to your GitHub account
git config --global user.name "<model-name> (via <github-username>)"
```

### Step 2: Override per-repo if needed
```bash
cd /path/to/repo
git config user.email "<your-verified-email>"
git config user.name "<model-name-here> (via <github-username>)"
```

## Attribution Pattern
```
Author: <model-name> <your-verified-email>
e.g., Author: qwen3.6:35b <your-verified-email>
      Author: ornith-1.5:9B <your-verified-email>
```

## Why not unlinked emails?
- Unlinked emails (e.g., `bot@local`) show the author name in `git log` but **won't appear on your GitHub contributors page** or link to your profile.
- Your verified email shows up as you on GitHub while the author name field still identifies the model.

## When to create a bot account instead
If you want a model to show up as its own top-level contributor (not attributed to your account), create a GitHub bot account and use that account's email. For most cases, the verified-email trick is simpler.

## Commit Confirmation
**Every AI model MUST ask the user to confirm the author name before executing `git commit`.**  
Never assume or default silently.

Ask: `"Authorizing commit as [model-name] — correct?"`

Wait for explicit approval (yes / updated name) before running the commit command. This prevents accidental cross-contamination of attribution when multiple models contribute to the same repo.

## Overrides (from AGENTS.md)

The latest `AGENTS.md` project ground rules supersede the defaults above. Key changes:

| Earlier rule | New rule |
|---|---|
| Custom model author name per repo by default | **Default to repository's configured Git author** (no customization unless explicitly requested) |
| Co-author trailers for AI models | **Never add AI/co-author attribution unless explicitly requested** |
| Commit confirmation asks for model name | Confirmation question is now: *"Authorizing commit as `[default-identity]` — correct?"* (still asked, but defaults to repo config) |

**When to use model attribution:** Only when you explicitly ask for it. The multi-model setup from Steps 1–2 above still applies on demand.