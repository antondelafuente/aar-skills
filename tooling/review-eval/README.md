# review-eval — eval harness for the ship-change reviewer prompt

Engineering tooling (the aar-engineering / SWE-pipeline layer), **not** part of the shipped research
product. It lets you change the cross-family reviewer prompt (`verify-claims` `--code` / `--scaffold`)
and *see the score move* against real cases, instead of guessing and shipping.

## Run

```bash
./run-eval.sh <prompt-file> [cases.tsv]
```

For each case it runs the prompt as the reviewer (via `codex exec`, the deployment reviewer family),
parses the `VERDICT: APPROVE|BLOCK`, scores it against the golden label, and reports **per-review token
cost** (a review is ~10–90k tokens, scaling with diff size).

## Corpus (`cases.tsv`)

`id | type | ref | golden`
- `type=pr` → fetches the diff of that PR# from `automated-researcher`.
- `type=syn` → uses the diff in `syn/<ref>`.
- `golden` = `APPROVE`|`BLOCK`, our judgment — the label a good reviewer *should* produce.

The 14 cases are deliberately balanced across the two failure modes:
- **Earlier-era proportionate PRs** (#1/#7/#82/#92/#110 …) that *look* over-built but are fine → test the reviewer does **not over-block**.
- **A disguised over-build** (#5) and **today's clear over-builds** (#184/#187/#173/#142) → test it **catches over-engineering**.
- **Synthetic** simple/buggy/elaborate pod-reaper variants → approve-simple / catch-bug / catch-over-build anchors.

## Prompts

- `prompt-v1.txt` — the scale-aware "second opinion" calibration whose *spirit* shipped in PR #218
  (doesn't over-block justified work; concedes to a correct author rebuttal). 7/7 on the
  don't-over-block cases.
- `prompt-v2.txt` — a more heavily-specified variant. **Kept as a documented negative result:** it
  tested *worse* (over-blocked the simple reaper and still missed #5). The lesson — less prompt, more
  trust in the model given scale — is why the shipped change was a minimal two-line edit.

## Caveats

Instance-coupled by design (it sources the box's engineer-auth env and calls `codex` locally) — fine
for the engineering-team layer. A 6-case run is noisy; widen the corpus before tuning hard. Evals
don't need to be perfect — the primary thing to guard is the reviewer *pushing* over-building, not a
perfect verdict on every case.
