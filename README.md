# aar-skills

Modular skills for coding agents doing real research work — extracted from a working
autonomous-research lab (a MATS alignment-research program run by agents end-to-end),
released piece by piece as each module proves out in production.

**The thesis:** your agent doesn't need a new platform — it needs powers. Each module here
is a thin skill + battle-tested scripts that work in Claude Code, Codex CLI, and anything
else that reads the [Agent Skills](https://agentskills.io) format. The conversation stays
the interface.

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
