# Proposal: API-blip quick-wins + StopFailure notifier (#54 child 4) (#171)

> The canonical design doc (ADR + PR description). Reviewed by `--scaffold` before build. Lands on main.

## Problem

When the Anthropic API has a short blip, Claude Code's built-in SDK retry runs out after a few attempts and the session dies — and with a GPU pod attached, that pod then bills for hours with no agent to collect the result or tear it down (the 2026-06-13 incident: an intermittent API error stranded an `$8.78/hr` pod for ~3h). The #54 crash-resilience design splits the fix into a model-free supervisor (children 1–3) plus a set of cheap, independent quick-wins (child 4, this issue) that reduce how often a blip kills the session in the first place and make a death loud when it does happen.

Two of those quick-wins are pure **instance** wiring on the always-on box — bump `API_TIMEOUT_MS` and set `API_FORCE_IDLE_TIMEOUT="0"` so a *short* blip is ridden out in-process, and add a `StopFailure` hook that fires on an API-error exit to push-notify and wake the supervisor. The one thing that belongs in the **product** is a single clarification: the `StopFailure` hook is a **notifier, not a recovery path** — it can wake/notify the supervisor, but it **cannot itself resume** the session (it runs *after* the agent process is already gone). Without that note written down beside the resume contract, a future reader could wire the hook expecting it to recover the run and quietly reintroduce the exact gap #54 exists to close.

The *needs-relaunch marker* the hook may also drop is **child 3's** to define — #54 (B.2) assigns the marker (the positive, model-free "recovery wanted" signal the supervisor acts on) to the relaunch-supervisor child, which has not landed. So this PR does **not** invent a marker API or schema; it states only the substrate-neutral operation (notify/wake the supervisor) and notes that *where* child 3's marker exists, the same hook can drop it. The marker's canonical contract stays with child 3, so this child doesn't strand a hidden instance convention the future supervisor would have to guess.

## Approach

Land the **product clarification only** in this PR; the settings values and the hook script are instance (they ship on the consuming box, not in `automated-researcher`, per the #54 blast radius). The clarification goes where the supervisor relaunch behavior is already documented: the **resume-contract section of `run-experiment`'s `SKILL.md`** (added by child 1). One short paragraph states the contract:

- A `StopFailure`-style hook (an instance may wire one) can **fire** on an API-error exit — push-notify and/or wake the supervisor (and, where child 3's *needs-relaunch* marker exists, drop it) — but it **cannot resume** the session itself, because it runs only after the agent process has exited. Recovery is the model-free supervisor's job (`resume_same_session` / `launch_successor`), not the hook's. The hook is a **signal into** that path, never a substitute for it.

This is deliberately one paragraph: it names the *operation* (a fire-not-resume notifier feeding the supervisor's marker) in substrate-neutral product terms, and leaves the concrete hook command + the `settings.json` values to instance guidance, consistent with how the rest of #54 keeps the product doc naming operations and the instance naming commands.

**Instance side (NOT this repo — done same-day with a pointer back here):** set `API_TIMEOUT_MS` (raised) and `API_FORCE_IDLE_TIMEOUT="0"` in the box's `settings.json`, and add the `StopFailure` hook that push-notifies (and, once child 3 lands its marker contract, drops the *needs-relaunch* marker). The settings bump stands alone (it just makes the in-process retry ride out a longer blip); the hook's marker-drop is inert until child 3's supervisor consumes it.

## Alternatives considered

- **Put the settings values + hook script in the product repo.** Rejected: `API_TIMEOUT_MS`, `API_FORCE_IDLE_TIMEOUT`, and the concrete hook command are this-box configuration, not a releasable product interface — the #54 blast radius explicitly lists them under "Instance (NOT this repo)". Shipping a box's `settings.json` value as product would force that value on every consumer.
- **Skip the product note entirely (it's "just instance work").** Rejected: the whole reason child 4 has *any* product footprint is the failure mode where a reader wires the notifier expecting it to recover the session. The one-line "notifier ≠ recovery" clarification is the cheap guard against silently reintroducing the #54 gap; the design calls it out as the single product deliverable of this child.
- **Write a new top-level section for the notifier.** Rejected as over-weight: the note is a one-paragraph qualifier on the supervisor relaunch behavior the resume-contract section already describes, so it belongs there, not in a section of its own.

## Blast radius

- **Product (this PR):** `plugins/experiment-lifecycle/skills/run-experiment/SKILL.md` — one paragraph in the resume-contract section (the "notifier ≠ recovery" clarification). Plus the `plugins/experiment-lifecycle/.claude-plugin/plugin.json` version bump + root `CHANGELOG.md` entry. No code, no schema, no behavior change — docs only.
- **Instance (NOT this repo):** the box's `settings.json` (`API_TIMEOUT_MS`, `API_FORCE_IDLE_TIMEOUT`) and the `StopFailure` hook script under `~/.claude/`, shipped same-day with a pointer back to this spec.
- No change to the SWE pipeline (`aar-engineering`), `gpu-job`, or any other plugin.

## Rollout + rollback

Single doc-paragraph + version bump — lands as one squash commit on `main`; rollback is the standard one-command revert. The instance settings/hook are a separate same-day change on the box (`settings.json` edit + a hook file); rolling them back is a `settings.json` revert and removing the hook, with no product change required. The product note is inert text until an instance wires a `StopFailure` hook, so there is no behavior to stage or dry-run.
