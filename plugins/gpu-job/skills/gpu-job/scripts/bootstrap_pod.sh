#!/bin/bash
# bootstrap_pod.sh — run ON the pod (first ssh). Minimal, provider-image-agnostic:
# 1) installs rclone if absent and materializes your injected rclone config, so jobs can
#    persist artifacts to YOUR store; 2) pulls an optional identity/env bundle
#    (<remote>/gpu-job/bundle.tar) if you've staged one (e.g. agent auth, .gitconfig).
set -euo pipefail
# Multi-threaded rclone by default (automated-researcher #284): exported here so THIS bootstrap's own
# rclone pulls use it, and (below) written to /etc/environment so later pod shells / ssh eval-drivers
# inherit it. Overridable — respects a value already set in the environment.
export RCLONE_MULTI_THREAD_STREAMS="${RCLONE_MULTI_THREAD_STREAMS:-16}" RCLONE_MULTI_THREAD_CUTOFF="${RCLONE_MULTI_THREAD_CUTOFF:-100M}"
if [ -n "${RCLONE_CONF_B64:-}" ]; then
  command -v rclone >/dev/null || (curl -fsSL https://rclone.org/install.sh | bash >/dev/null 2>&1)
  mkdir -p ~/.config/rclone
  echo "$RCLONE_CONF_B64" | base64 -d > ~/.config/rclone/rclone.conf
  echo "[bootstrap] rclone configured"
  if [ -n "${RCLONE_REMOTE:-}" ] && rclone lsf "$RCLONE_REMOTE/gpu-job/" 2>/dev/null | grep -qx bundle.tar; then
    rclone copy "$RCLONE_REMOTE/gpu-job/bundle.tar" /tmp/ && tar xf /tmp/bundle.tar -C ~ && rm /tmp/bundle.tar
    echo "[bootstrap] identity bundle restored"
  fi
fi
# Default multi-threaded rclone so large single-file R2 pulls (venvs, big adapters) parallelize instead
# of throttling to ~1 MB/s single-stream (~148 MB/s measured; automated-researcher #284). Written to
# /etc/environment so EVERY pod shell — incl. `ssh pod 'rclone …'` used by eval-drivers — inherits it;
# overridable per-call. Needs a root pod (RunPod default); skipped gracefully otherwise.
if [ "$(id -u)" = 0 ] && ! grep -q '^RCLONE_MULTI_THREAD_STREAMS=' /etc/environment 2>/dev/null; then
  printf 'RCLONE_MULTI_THREAD_STREAMS=16\nRCLONE_MULTI_THREAD_CUTOFF=100M\n' >> /etc/environment
  echo "[bootstrap] rclone multi-thread defaults set"
fi
touch /workspace/.gpu-job-ready 2>/dev/null || touch ~/.gpu-job-ready
echo "[bootstrap] ready"
