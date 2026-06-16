# START.md — <EXP_NAME>  (<one-line what this run does>)

You are a **fresh-context executor** on a disposable compute environment (<backend / GPU, e.g. a cloud GPU pod>).
Zero prior context — **this file is your whole brief.** Work autonomously, do NOT ask questions. A supervising agent
watches your progress; talk to it with clear status lines.

> **Executor disposition (verbatim — this is what makes the handoff work):** Run this experiment to completion — do
> not end your turn until you hit a real blocker or you're done; stopping after planning is the failure mode.
> Mechanical/reversible gap → pick a sensible default, record it, keep going. Load-bearing gap (changes
> method/cost/meaning) → notify the designer-of-record and work AROUND it; only a gap that blocks the whole run stops
> you, and then you notify + arm your self-wake — NEVER park silently. The design is locked: execute per `DESIGN.md`,
> judge results against its pre-registered decision rules, do not redesign.

## Your one job
<One sentence: build/train/eval X, upload, report. What new data point this produces.>

## The idea (so you can sanity-check your own work)
<2–4 sentences on what the experiment is and what a correct result looks like, so you can catch your own bugs —
e.g. "if any single arm wins >90% the selection is degenerate".>

## Inputs. ⚠️ FILE NAMES CAN BE MISLEADING — verify by content, not name:
- <label>: `<storage path / URI>`  (<discriminator: avg length, label rate, etc.>)
- <label>: `<storage path / URI>`
- Scripts: `<where the executor pulls the worked-example drivers from>` (pull them; don't write from scratch).
- Base model / artifacts: `<model id>`. <Any cache/env setup needed before download.>

## Environment
- <The readiness signal to wait for before training/eval, and how the env is provisioned.>
- <Named venvs / containers / toolchains and what each is for.>
- <The repo / code location.>  Work dir: `<scratch dir>` (touch only this).
- <The check that the right compute is present — else print `<NAME> BLOCKED: wrong env` and stop.>

## Steps
1. Wait for the readiness signal; verify compute.
2. Pull inputs → the work dir.
3. <Generation / selection / preprocessing, with the EXACT script + flags.>
4. <Train / transform, with the matched recipe — every hyperparameter pinned. Verify the output artifact exists.>
5. <Eval — the EXACT eval definition + flags (this is load-bearing for comparability). Don't kill a slow long tail.>
6. <Any second eval axis, with its grader + config + required API keys.>
7. **Upload:** `<copy work dir → durable storage>` (artifact + summaries + a SUMMARY.md).

## Reporting (completion = the durable artifacts, not a chat message)
- Status lines as you go: `>>> env ready`, `>>> data pulled`, `>>> train done loss=…`, `>>> eval1 done <m>=…`, …,
  `>>> uploaded`.
- Reference points / known anchors for sanity: <e.g. base metric ≈ X; other expected values>.
- When summaries are uploaded, print exactly: **`<NAME> DONE <metric1>=<n> <metric2>=<n> …`**.
- If stuck >15 min, print **`<NAME> BLOCKED: <one-line reason>`** and stop — don't spin.

## Constraints
- Touch only your work dir (+ read the repo, shared envs, inputs).
- Throwaway environment. Match the reference recipe exactly EXCEPT the variable under test; get the numbers; upload; report.

<!-- This is the substrate-neutral skeleton. An instance fills the placeholders from its own frozen recipes
     (backend, env topology, model, exact eval definitions) — those are instance content, not part of the product. -->
