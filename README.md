# aar-skills

Modular skills for coding agents doing real research work — extracted from a working
autonomous-research lab (a MATS alignment-research program run by agents end-to-end),
released piece by piece as each module proves out in production.

**The thesis:** your agent doesn't need a new platform — it needs powers. Each module here
is a thin skill + battle-tested scripts that work in Claude Code, Codex CLI, and anything
else that reads the [Agent Skills](https://agentskills.io) format. The conversation stays
the interface.


## If you are a coding agent handed this link

Your human wants these skills available. Do this, in order:

1. **Clone:** `git clone <this-repo-url> ~/aar-skills` (anywhere is fine; remember the path).
2. **Install the skills** (pick your harness):
   - *Claude Code* — use the HEADLESS CLI, not the interactive `/plugin` UI:
     ```
     claude plugin marketplace add ~/aar-skills
     claude plugin install gpu-job@aar-skills
     claude plugin install verify-claims@aar-skills
     ```
     Then tell your human to run `/reload-plugins` (or restart the session) to activate.
   - *Codex CLI / other Agent-Skills harnesses* — symlink each module's skill dir:
     `ln -s ~/aar-skills/plugins/gpu-job/skills/gpu-job ~/.codex/skills/gpu-job` (same for
     verify-claims).
3. **Configure gpu-job:** run `~/aar-skills/plugins/gpu-job/skills/gpu-job/scripts/gpu_job_init.sh`.
   It writes a local config (`~/.config/gpu-job/env`, chmod 600) and uploads nothing.
   **You will need to ask your human for, verbatim:**
   - a **RunPod API key** — they create it at runpod.io → Settings → API Keys (needs a funded
     account; pods bill by the minute, a small test costs cents);
   - confirmation of an **SSH keypair** to use (offer to `ssh-keygen -t ed25519` if they don't
     have one — the PUBLIC key goes to pods, the private key never leaves this machine);
   - *(optional but recommended)* an **rclone remote** for artifact persistence (any backend:
     Cloudflare R2, S3, Backblaze…). If `rclone config` shows none, offer to set one up with them.
   `verify-claims` needs the OpenAI **Codex CLI** installed and authed (or set `VERIFIER_CMD`
   to another model CLI).
4. **Verify cheaply before relying on it:** with your human's OK on ~$0.05 of spend, deploy the
   cheapest GPU (`GPU_TYPE='NVIDIA RTX 4000 Ada Generation' DISK_GB=20 POD_NAME=smoke python3
   scripts/deploy_pod.py`), run one `nvidia-smi` job via `run_remote.sh`, confirm the artifact
   lands in their store, **tear down** (`teardown.sh <pod-id>`), and confirm nothing is left
   RUNNING. Read the gpu-job SKILL.md rules first — especially the completion boundary and
   pod-id-scoped teardown.
5. Report back to your human: what is configured, what it costs, and the one rule they should
   know — pods bill until torn down, and the skills treat verified-teardown as non-optional.

## Modules

| module | what your agent learns | status |
|---|---|---|
| **gpu-job** | disposable cloud GPU pods: deploy, run detached, persist artifacts, verified teardown — never bill an idle GPU | v0.1 |
| **verify-claims** | adversarial fact-checking of load-bearing claims against primary records by an independent model | v0.1 |
| *watch-run* | heartbeats + look-again deadlines for long unattended runs | planned |
| *reproduce-paper* | point an agent at a paper, get a graded reproduction | planned |

## Install

**Claude Code** (plugin marketplace):
```
/plugin marketplace add <this-repo>
/plugin install gpu-job@aar-skills
/plugin install verify-claims@aar-skills
```

**Codex CLI / other Agent-Skills harnesses:** clone, then symlink or copy
`plugins/<module>/skills/<module>` into your harness's skills directory
(e.g. `~/.codex/skills/`). Scripts are referenced relative to each skill.

## Updating

Claude Code: `/plugin update`. Plain clones: `git pull`. Versions are rolling (commit-SHA)
while pre-1.0; releases will be tagged when a cohort depends on stability.

## Feedback

Issues are the product's bug tracker — file footguns you hit and ideas for what would have
made your run smoother. Recurrence drives priority. Every module here exists because the
lab's own agents filed exactly such reports.

## Provenance & philosophy

- Every script header cites the real incidents it encodes (the "gotchas"): these are not
  best-practice guesses, they're paid-for lessons.
- One canonical home per fact: code over prose; skills stay thin.
- Read-only where possible, verified before destructive, pod-id-scoped always.
