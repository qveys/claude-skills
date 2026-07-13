#!/usr/bin/env bash
# wsh-push.sh — push/pull a file between the Mac and a remote host WITHOUT
# base64 in cockpit send-keys.
#
# Cockpit `send` is for short commands the user watches. Piping file bytes through
# tmux (base64, printf chunks, heredocs) breaks on length/quotes. Use this script
# from the agent shell instead; verify in cockpit with `send 'wc -c path'`. Called
# both directly and as the shared engine behind wsh-live.sh's `push`/`pull`
# subcommands (see cmd_transfer there) and its remote-init helper push.
#
# Usage:
#   wsh-push.sh [--pull] [--control-path=<path>] <local-file> <remote-abs-path> [connection]
#
# Direction: default is push (local -> remote); --pull reverses it (remote file
# at <remote-abs-path> is written to <local-file>). connection defaults to
# WSH_PUSH_CONN or "qveys@macbook-openclaw".
#
# Examples:
#   wsh-push.sh ./TOOLS.md /Users/qveys/agents/theo-marceau/TOOLS.md
#   wsh-push.sh --pull /tmp/remote-log.txt /var/log/app.log qveys@macbook-openclaw
#
# Strategy (best-first), same for both directions:
#   1. wsh file cp     — Wave already has a route for the connection
#   2. OpenSSH ControlPath multiplexing (--control-path=<path>) — reuses an
#      already-authenticated master connection (see wsh-cockpit's persistent-
#      SSH-session rule: the pane's own `ssh -o ControlMaster=auto -o
#      ControlPath=<path> ...` hop IS the master). Skipped when no live master
#      is found at <path> — this is also how a tailscale ssh hop (which does
#      NOT support ControlMaster) is detected: there's simply never a socket
#      there, so this step falls through cleanly, no special-casing needed.
#   3. tailscale ssh   — stdin pipe (push) / cat (pull); no multiplexing, but
#      tailnet auth is transparent (no fresh FIDO2 prompt)
#   4. scp             — last resort; most likely to trigger a fresh auth prompt
set -euo pipefail

PULL=0
CONTROL_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pull) PULL=1; shift ;;
    --control-path=*) CONTROL_PATH="${1#--control-path=}"; shift ;;
    --) shift; break ;;
    -*) echo "wsh-push.sh: unknown flag: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done

LOCAL="${1:?usage: wsh-push.sh [--pull] [--control-path=<path>] <local-file> <remote-abs-path> [connection]}"
REMOTE="${2:?usage: wsh-push.sh [--pull] [--control-path=<path>] <local-file> <remote-abs-path> [connection]}"
CONN="${3:-${WSH_PUSH_CONN:-qveys@macbook-openclaw}}"
DIRLABEL="push"; [ "$PULL" -eq 1 ] && DIRLABEL="pull"

# BatchMode never prompts for a password (a hardware-key touch still works —
# that's not a terminal prompt); ConnectTimeout keeps an unreachable host from
# hanging the agent instead of failing fast into the next transport.
SSH_TIMEOUT="${WSH_PUSH_SSH_TIMEOUT:-8}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT")

if [ "$PULL" -eq 0 ]; then
  [ -f "$LOCAL" ] || { echo "local file not found: $LOCAL" >&2; exit 2; }
fi

# Derive wsh:// URI connection id (strip user@ for conn name Wave may know).
conn_id() {
  local c="$1"
  if [[ "$c" == *@* ]]; then printf '%s\n' "${c#*@}"; else printf '%s\n' "$c"; fi
}

# user@host form scp/ssh expect, mirroring wsh's own CONN convention.
ssh_host_for() {
  local c="$1"
  if [[ "$c" == *@* ]]; then printf '%s\n' "$c"; else printf '%s\n' "qveys@${c}"; fi
}

# `tailscale ssh` itself has no connect/idle timeout, so a stuck tailnet path
# (DERP relay hiccup, host gone unreachable mid-call) would otherwise hang the
# agent indefinitely. Best-effort: wrap with `timeout`/`gtimeout` when either
# is installed (neither ships with stock macOS), else run unwrapped — same
# behavior as before this existed.
ts_ssh() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$SSH_TIMEOUT" tailscale ssh "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$SSH_TIMEOUT" tailscale ssh "$@"
  else
    tailscale ssh "$@"
  fi
}

# Echo the remote byte count, or EMPTY when the size cannot be measured (no
# tailscale channel, or wc failed). Empty means "unverified" — NOT zero — so the
# caller never reports a bogus mismatch when the transport itself succeeded.
remote_size() {
  local c="$1" path="$2"
  command -v tailscale >/dev/null 2>&1 || { printf ''; return 0; }
  # </dev/null: a read-only one-shot must never hold the SSH channel open
  # waiting for stdin EOF it will never get from an inherited pipe.
  ts_ssh "$c" "wc -c < '$path' 2>/dev/null" </dev/null 2>/dev/null | tr -d '[:space:]'
}

local_size() { wc -c <"$1" 2>/dev/null | tr -d '[:space:]'; }

try_wsh_cp() {
  command -v wsh >/dev/null 2>&1 || return 1
  local id local_abs
  id=$(conn_id "$CONN")
  mkdir -p "$(dirname "$LOCAL")" 2>/dev/null || true
  local_abs=$(cd "$(dirname "$LOCAL")" 2>/dev/null && pwd)/$(basename "$LOCAL")
  if [ "$PULL" -eq 1 ]; then
    wsh file cp -f "wsh://${CONN}/${REMOTE}" "$local_abs" 2>/dev/null \
      || wsh file cp -f "wsh://${id}/${REMOTE}" "$local_abs" 2>/dev/null
  else
    wsh file cp -f "$local_abs" "wsh://${CONN}/${REMOTE}" 2>/dev/null \
      || wsh file cp -f "$local_abs" "wsh://${id}/${REMOTE}" 2>/dev/null
  fi
}

# True only when a live OpenSSH ControlMaster is listening at $CONTROL_PATH —
# `-O check` is a purely local socket probe (no network round-trip) so this is
# fast even when no master exists yet (first hop, or a tailscale ssh hop).
control_master_alive() {
  [ -n "$CONTROL_PATH" ] || return 1
  command -v ssh >/dev/null 2>&1 || return 1
  local host; host=$(ssh_host_for "$CONN")
  ssh -o ControlPath="$CONTROL_PATH" -O check "$host" >/dev/null 2>&1
}

try_control_path() {
  control_master_alive || return 1
  command -v scp >/dev/null 2>&1 || return 1
  local host; host=$(ssh_host_for "$CONN")
  mkdir -p "$(dirname "$LOCAL")" 2>/dev/null || true
  if [ "$PULL" -eq 1 ]; then
    scp -q -o ControlPath="$CONTROL_PATH" "${host}:${REMOTE}" "$LOCAL"
  else
    scp -q -o ControlPath="$CONTROL_PATH" "$LOCAL" "${host}:${REMOTE}"
  fi
}

try_tailscale_push() {
  command -v tailscale >/dev/null 2>&1 || return 1
  # Stream into a sibling temp on the REMOTE (same dir = same fs → atomic mv), then
  # rename. Clean up the remote temp on any mid-flight failure.
  local rtmp="${REMOTE}.wsh-tmp.$$"
  ts_ssh "$CONN" "cat > '$rtmp' && mv -f '$rtmp' '$REMOTE' || { rm -f '$rtmp'; exit 1; }" <"$LOCAL"
}

try_tailscale_pull() {
  command -v tailscale >/dev/null 2>&1 || return 1
  # `tailscale ssh host "cmd"` does NOT propagate cmd's exit code as its own
  # (verified empirically: `tailscale ssh host "exit 7"` still exits 0) — a
  # missing/unreadable remote file would otherwise be silently "pulled" as an
  # empty local file. Pre-flight remote_size first: empty means the file
  # can't be measured (missing, or unreadable) — bail out before touching
  # $LOCAL at all. A real empty file measures "0", which still proceeds.
  local rsize
  rsize=$(remote_size "$CONN" "$REMOTE")
  [ -n "$rsize" ] || return 1
  mkdir -p "$(dirname "$LOCAL")" 2>/dev/null || true
  local ltmp="${LOCAL}.wsh-tmp.$$" got
  # Direct redirection (no command substitution) keeps this binary-safe.
  # </dev/null for the same reason as remote_size above — a read (no stdin
  # to send) must never hang waiting for stdin EOF from an inherited pipe.
  ts_ssh "$CONN" "cat '$REMOTE'" </dev/null >"$ltmp" 2>/dev/null
  got=$(wc -c <"$ltmp" 2>/dev/null | tr -d '[:space:]')
  # Compare against the pre-flight size (not the unreliable exit code): only
  # `mv` into place when what actually arrived matches — a failed/partial
  # remote read never leaves a truncated file at the final path.
  if [ "$got" = "$rsize" ]; then
    mv -f "$ltmp" "$LOCAL"
    return 0
  fi
  rm -f "$ltmp" 2>/dev/null || true
  return 1
}

try_scp() {
  command -v scp >/dev/null 2>&1 || return 1
  local host; host=$(ssh_host_for "$CONN")
  mkdir -p "$(dirname "$LOCAL")" 2>/dev/null || true
  if [ "$PULL" -eq 1 ]; then
    scp -q "${SSH_OPTS[@]}" "${host}:${REMOTE}" "$LOCAL"
  else
    scp -q "${SSH_OPTS[@]}" "$LOCAL" "${host}:${REMOTE}"
  fi
}

if [ "$PULL" -eq 1 ]; then
  echo "pull: ${CONN}:${REMOTE} -> $LOCAL"
else
  LOCAL_SIZE=$(local_size "$LOCAL")
  echo "push: $LOCAL (${LOCAL_SIZE} bytes) -> ${CONN}:${REMOTE}"
fi

METHOD=""
if try_wsh_cp; then
  METHOD=wsh-file-cp
elif try_control_path; then
  METHOD=ssh-controlpath
elif { [ "$PULL" -eq 1 ] && try_tailscale_pull; } || { [ "$PULL" -eq 0 ] && try_tailscale_push; }; then
  METHOD=tailscale-ssh
elif try_scp; then
  METHOD=scp
  echo "warn: fell back to bare scp (no Wave route, no ControlMaster, no tailscale ssh) — a fresh auth prompt is likely" >&2
else
  echo "all ${DIRLABEL} methods failed (need wsh route, ControlMaster socket, tailscale ssh, or scp)" >&2
  exit 3
fi
echo "transfer: using ${METHOD} for ${DIRLABEL}" >&2

if [ "$PULL" -eq 1 ]; then
  [ -f "$LOCAL" ] || { echo "$DIRLABEL via ${METHOD} reported success but $LOCAL is missing" >&2; exit 5; }
  LOCAL_SIZE=$(local_size "$LOCAL")
fi

R_SIZE=$(remote_size "$CONN" "$REMOTE")
if [ -z "$R_SIZE" ]; then
  # Transport reported success but we have no channel to confirm the size. Report
  # success-unverified rather than a false mismatch (e.g. tailscale absent but
  # wsh-cp/ControlPath had worked).
  echo "ok via ${METHOD}: ${DIRLABEL} ${REMOTE} <-> ${LOCAL} (${LOCAL_SIZE} bytes, size unverified)"
elif [ "$R_SIZE" = "$LOCAL_SIZE" ]; then
  echo "ok via ${METHOD}: ${DIRLABEL} ${REMOTE} <-> ${LOCAL} (${R_SIZE} bytes)"
else
  echo "warn: size mismatch local=${LOCAL_SIZE} remote=${R_SIZE} (method=${METHOD})" >&2
  exit 4
fi
