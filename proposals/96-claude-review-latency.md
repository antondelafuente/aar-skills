# Proposal: Teach ship-change Claude review latency norms (#96)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

Codex authors sometimes treat a quiet Claude-family `wf.sh` review as suspicious after roughly one minute. That has led to noisy status narration and duplicate kill/retry decisions while the reviewer is still in a normal latency window.

The missing product behavior is not a timeout mechanism; it is a clear norm at the moment an agent is likely to worry. With `AUDIT_VERIFIER_CMD='claude -p ... > "$OUT_TMP"'`, the output file often remains empty until Claude completes the full response, so an empty temp output file before five minutes is not evidence of a hang.

## Approach

Add the review-latency norm in the three places issue #96 names:

- `plugins/aar-engineering/skills/ship-change/SKILL.md`: add the operator norm near the cross-family review lifecycle. State that 0-5 minutes is normal for Claude-family reviews, 5 minutes is the first inspect-once threshold, and 10 minutes is suspicious without evidence of progress.
- `plugins/aar-engineering/skills/ship-change/RUNBOOK.md`: add a short "Reviewer latency" debug policy with the exact thresholds and the `$OUT_TMP` caveat.
- `plugins/aar-engineering/skills/ship-change/scripts/wf.sh`: print a concise note immediately before invoking a review, so the expectation appears in terminal output when the author is waiting.
- `plugins/aar-engineering/.claude-plugin/plugin.json`: bump `aar-engineering` from `0.3.17` to `0.3.18` because the shipped plugin behavior/docs changed.

Keep this as guidance. Do not add a hard timeout in `wf.sh`: a timeout policy would need a more careful design because review duration depends on prompt size, model state, and provider latency. This issue is specifically about preventing premature human-agent reactions during the normal 0-5 minute window.

## Alternatives considered

- Only update `SKILL.md`. Rejected because the user specifically called out operational thresholds/debug policy and the terminal moment where agents worry.
- Only update `wf.sh` output. Rejected because the norm would disappear from the durable skill docs and would not help agents reasoning about a blocked or inherited run.
- Add automatic timeout/retry behavior. Rejected for this ready issue because automatic retry risks duplicate reviews and stale outputs; the desired fix is instruction, not orchestration.

## Blast radius

This touches only the `aar-engineering` plugin's ship-change docs, one terminal note in `wf.sh`, and the plugin version. It does not change review execution, PR posting, merge gates, branch protection, or the verify-claims reviewer.

The runtime blast radius of the `wf.sh` note is low: every review prints one extra expectation line before the potentially quiet reviewer call. The line should be concise so it reduces chatter rather than adding a new source of noise.

## Rollout + rollback

Roll out through the standard `ship-change` path for ready issue #96: design review, implementation, code review, classifier, `.aar-ci` checks including fake-HOME smoke for the plugin, final review, and merge.

Rollback is a normal revert PR restoring the previous docs/output/version if the added note proves noisy or misleading.
