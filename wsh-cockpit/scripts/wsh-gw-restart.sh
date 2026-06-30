#!/usr/bin/env bash
# wsh-gw-restart.sh — restart OpenClaw gateway and WAIT until probe OK before returning.
# Use as ONE cockpit send (or chained) so follow-up commands don't race a dead gateway.
#
# Usage (inside cockpit / remote shell):
#   wsh-gw-restart.sh [max-wait-seconds]
#
# From agent (visible cockpit) — EXECUTE it, never `source` it (it calls `exit`,
# which would kill a shell that sourced it):
#   COCKPIT=.../wsh-live.sh
#   $COCKPIT send 'bash .../wsh-gw-restart.sh 90'   # run as a child, waits then returns
#   $COCKPIT send '<inline wait loop below>'        # alternative — see SKILL.md
set -euo pipefail

# Guard: refuse to run when sourced — `exit` below would take the caller's shell
# down with it. Detect sourcing in BOTH shells (the panes are zsh on macOS): in bash
# BASH_SOURCE[0] != $0 when sourced; in zsh ZSH_EVAL_CONTEXT carries a `:file` frame.
__wsh_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
  case "${ZSH_EVAL_CONTEXT:-}" in *:file*) __wsh_sourced=1 ;; esac
elif [ -n "${BASH_VERSION:-}" ]; then
  [ "${BASH_SOURCE[0]:-$0}" != "$0" ] && __wsh_sourced=1
fi
if [ "$__wsh_sourced" = 1 ]; then
  echo "wsh-gw-restart.sh: execute this script, do not source it (it calls exit)" >&2
  return 2 2>/dev/null || exit 2
fi
unset __wsh_sourced

MAX_WAIT="${1:-60}"
INTERVAL=3
ELAPSED=0

echo "── gateway restart ──"
openclaw gateway restart 2>&1 || true

echo "── waiting up to ${MAX_WAIT}s for Connectivity probe: ok ──"
while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  if openclaw gateway status 2>&1 | grep -q 'Connectivity probe: ok'; then
    echo "── gateway ready (${ELAPSED}s) ──"
    openclaw gateway status 2>&1 | head -16
    exit 0
  fi
  sleep "$INTERVAL"
  ELAPSED=$((ELAPSED + INTERVAL))
  echo "  ... still starting (${ELAPSED}s)"
done

echo "── TIMEOUT: gateway not ready after ${MAX_WAIT}s ──" >&2
openclaw gateway status 2>&1 | head -16
exit 1