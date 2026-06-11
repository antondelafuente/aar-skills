# verify_claim.sh calibration — 2026-06-11 (claude-1)

Benchmark: the regen suite's three REAL validity catches replayed as planted errors among
7 true-claim controls, against the same primary records, zero-context. Verifier: codex exec
(codex-cli 0.139.0, default model, ChatGPT subscription).

| case | planted error (real incident) | caught? | decisive citation |
|---|---|---|---|
| 1 | "persona = pre-DPO baseline" (wave-2 inversion) | ✅ DISPUTE | progress.md step-10 merge line |
| 2 | "no trained weights survive in any form" (wave-3) | ✅ DISPUTE | PROGRESS.md s33-upload line |
| 3 | "qwen3_training logs = the GRPO runs" (wave-3) | ✅ DISPUTE | SFT script ref + no GRPO/verl markers |

False DISPUTEs on true controls: 0/7 (all CONFIRM with correct citations; first harness run
produced all-UNKNOWN due to the sandbox failure below — honest behavior, not hallucinated verdicts).

**Sandbox history (box-specific):** codex's `--sandbox read-only` needs bubblewrap user
namespaces, which this box's kernel originally restricted (`bwrap: RTM_NEWADDR: Operation not
permitted`; Ubuntu `kernel.apparmor_restrict_unprivileged_userns=1`) — the initial calibration
ran with the sandbox bypassed. **Resolved 2026-06-11:** Anton's root session set the sysctl to 0
(persisted: `/etc/sysctl.d/99-userns-agent-sandboxes.conf`, rollback documented in-file).
Case 1 re-run under `--sandbox read-only`: identical verdicts (3 CONFIRM / 1 DISPUTE, same
citations). The verifier is now mechanically read-only, which is the script's default.
