#!/usr/bin/env bash
# wsh-rexec.sh — run a command in a VISIBLE Wave Terminal block, LOCAL or REMOTE,
# and capture its output + exit code. The block lingers (default 60s) after the
# command finishes so the user can SEE what was run before it auto-closes — but
# the linger runs DETACHED, so the script returns as soon as the command is done
# (it does NOT block the caller for LINGER seconds). The visible-then-delete
# window is the point of this skill (doing things *in the open*); making it
# non-blocking just means the agent isn't forced to idle while the human reads.
#
# Usage:
#   wsh-rexec.sh local         'uname -a; ls ~/Git'      # on the user's Mac
#   wsh-rexec.sh qveys@1.2.3.4 'docker ps; uname -a'     # on a Wave connection
#
# Env:
#   WSH_REXEC_TIMEOUT=60   seconds to wait for the command to finish
#   WSH_REXEC_LINGER=60    seconds the visible block stays before auto-delete
#                          (detached — does NOT delay the script's return)
#
# Why the remote path is weird: `wsh ssh` only *controls* a block, `wsh run`
# executes locally, and there is no `wsh sendinput`. So for a remote host we make
# a PAUSED block, switch its `connection` meta to the host, and flip
# `cmd:runonstart=true` — changing the connection triggers a controller resync
# that launches the command on the host (Wave owns the SSH creds; no local key).
# Local needs none of that: a plain `wsh run` already runs on the Mac.
set -euo pipefail

TARGET="${1:?usage: wsh-rexec.sh <local|connection> <command...>}"; shift
CMD="$*"
[ -n "$CMD" ] || { echo "wsh-rexec: empty command" >&2; exit 2; }

TIMEOUT="${WSH_REXEC_TIMEOUT:-60}"
LINGER="${WSH_REXEC_LINGER:-60}"
# Validate up front. TIMEOUT must be ≥1: a non-numeric OR zero timeout makes the
# poll loop run zero iterations → a phantom timeout on an empty buffer that masks
# the real result. LINGER may be 0 (documented: block vanishes the instant the
# command ends), so it only has to be a non-negative integer.
case "$TIMEOUT" in ''|*[!0-9]*|0)
  echo "wsh-rexec: WSH_REXEC_TIMEOUT must be a positive integer (got '$TIMEOUT')" >&2; exit 2 ;;
esac
case "$LINGER" in ''|*[!0-9]*)
  echo "wsh-rexec: WSH_REXEC_LINGER must be a non-negative integer (got '$LINGER')" >&2; exit 2 ;;
esac
START="__WSH_START_$$__"
MARK="__WSH_END_$$__"

# Markers slice exactly the command's output. The leading `true ...` is a
# SACRIFICIAL first statement: Wave starts a remote block by *typing* the command
# into the shell, and that handoff reliably mangles the very first statement
# (it loses its argument). `true` is silent and exit-0 with or without args, so
# the damage lands on it — everything after the first `;` arrives intact.
WRAP="true __wsh_warmup__; echo ${START}; ${CMD}; echo ${MARK}\$?"

if [ "$TARGET" = "local" ]; then
  # Local: run immediately in a visible block — no connection, no resync.
  RAW=$(wsh run -c "$WRAP" 2>&1)
else
  # Remote: a PAUSED block we then point at the connection.
  RAW=$(wsh run -p -c "$WRAP" 2>&1)
fi
# Extract the block id with a builtin regex (bash) instead of grep|head|cut (3 forks).
if [[ "$RAW" =~ block:([0-9a-f-]+) ]]; then ID="${BASH_REMATCH[1]}"; else ID=""; fi
[ -n "$ID" ] || { echo "wsh-rexec: could not create block: $RAW" >&2; exit 1; }

# Keep the block visible for LINGER seconds before removing it, on EVERY exit
# path — that pause lets the user watch what ran (and read errors). But it runs
# DETACHED: the linger is the *block's* lifetime, not ours to block on. The
# script returns as soon as the command finishes; the visible-then-delete window
# plays out in a backgrounded orphan. fd redirection + </dev/null + disown are
# what let the Bash caller get its prompt back instead of waiting out LINGER
# (the caller blocks until the child's stdout/stderr pipes close — so we must
# detach them). setsid would be cleaner but macOS lacks it.
schedule_cleanup() {
  { sleep "$LINGER"; wsh deleteblock -b "$ID" >/dev/null 2>&1 || true; } \
    </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}
trap schedule_cleanup EXIT

if [ "$TARGET" != "local" ]; then
  # runonce=true is essential: without it the controller re-runs the command on
  # every restart, and switching the connection *is* a restart — so the command
  # would run twice. runonce makes it fire exactly once, then disarms itself.
  # Explicit failure handling: under `set -e` a bare failing setmeta would abort
  # mid-statement (trap still cleans the block, but silently). Report it instead.
  if ! wsh setmeta -b "$ID" \
    "connection=$TARGET" \
    'cmd:clearonstart=false' \
    'cmd:runonstart=true' \
    'cmd:runonce=true' >/dev/null 2>&1; then
    echo "wsh-rexec: failed to arm remote command on block $ID (connection=$TARGET)" >&2
    exit 1
  fi
fi

# Poll for the END marker. `wsh termscrollback` returns the WHOLE buffer each call
# (no incremental API), so the fetch itself is unavoidable — but the per-iteration
# match is a builtin `case` glob (0 forks) instead of `printf | grep -q` (2 forks ×
# up to TIMEOUT), and the loop counter replaces a `seq` fork.
SB=""; __i=0
while [ "$__i" -lt "$TIMEOUT" ]; do
  __i=$((__i + 1))
  SB=$(wsh termscrollback -b "$ID" 2>&1 || true)
  case "$SB" in *"$MARK"*) break ;; esac
  sleep 1
done

case "$SB" in
  *"$MARK"*) ;;   # marker found — fall through to the slicing below
  *)
    echo "wsh-rexec: timed out after ${TIMEOUT}s waiting for command to finish" >&2
    printf '%s\n' "$SB" | tail -n 40    # cap the dump — the scrollback can be huge
    exit 124
    ;;
esac

# Emit only what's between START and END, then the real exit code.
printf '%s\n' "$SB" | awk -v s="$START" -v e="$MARK" '
  $0 ~ e { exit }
  seen   { print }
  $0 ~ s { seen=1 }
'
# `$?` is always 0-255, so the marker is `MARK<digits>` — no sign. Anchor to the
# last marker occurrence and take its trailing digits.
RC=$(printf '%s' "$SB" | grep -oE "${MARK}[0-9]+" | tail -1 | grep -oE '[0-9]+$')
echo "---- exit code: ${RC:-unknown} ----"
