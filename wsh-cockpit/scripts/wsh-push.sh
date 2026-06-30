#!/usr/bin/env bash
# wsh-push.sh — push a local file to a remote host WITHOUT base64 in cockpit send-keys
#
# Cockpit `send` is for short commands the user watches. Piping file bytes through
# tmux (base64, printf chunks, heredocs) breaks on length/quotes. Use this script
# from the agent shell instead; verify in cockpit with `send 'wc -c path'`.
#
# Usage:
#   wsh-push.sh <local-file> <remote-abs-path> [connection]
#
# connection defaults to WSH_PUSH_CONN or "qveys@macbook-openclaw"
# Examples:
#   wsh-push.sh ./TOOLS.md /Users/qveys/agents/theo-marceau/TOOLS.md
#   wsh-push.sh /tmp/patch.json5 /Users/qveys/theo-patch.json5 qveys@macbook-openclaw
#
# Strategy (best-first):
#   1. wsh file cp   — when Wave already has a route for the connection
#   2. tailscale ssh — stdin pipe (tested; works without Wave conn registration)
#   3. scp           — last resort if tailscale ssh unavailable
set -euo pipefail

LOCAL="${1:?usage: wsh-push.sh <local-file> <remote-abs-path> [connection]}"
REMOTE="${2:?usage: wsh-push.sh <local-file> <remote-abs-path> [connection]}"
CONN="${3:-${WSH_PUSH_CONN:-qveys@macbook-openclaw}}"

[ -f "$LOCAL" ] || { echo "local file not found: $LOCAL" >&2; exit 2; }

# Derive wsh:// URI connection id (strip user@ for conn name Wave may know).
conn_id() {
  local c="$1"
  if [[ "$c" == *@* ]]; then printf '%s\n' "${c#*@}"; else printf '%s\n' "$c"; fi
}

# Echo the remote byte count, or EMPTY when the size cannot be measured (no
# tailscale channel, or wc failed). Empty means "unverified" — NOT zero — so the
# caller never reports a bogus mismatch when the transport itself succeeded.
remote_size() {
  local c="$1" path="$2"
  command -v tailscale >/dev/null 2>&1 || { printf ''; return 0; }
  tailscale ssh "$c" "wc -c < '$path' 2>/dev/null" 2>/dev/null | tr -d '[:space:]'
}

try_wsh_cp() {
  command -v wsh >/dev/null 2>&1 || return 1
  local id local_abs
  id=$(conn_id "$CONN")
  local_abs=$(cd "$(dirname "$LOCAL")" && pwd)/$(basename "$LOCAL")
  # Wave route must exist (`wsh conn status` shows connected). Try user@host then host-only.
  if wsh file cp -f "$local_abs" "wsh://${CONN}/${REMOTE}" 2>/dev/null \
    || wsh file cp -f "$local_abs" "wsh://${id}/${REMOTE}" 2>/dev/null; then
    return 0
  fi
  return 1
}

try_tailscale_pipe() {
  command -v tailscale >/dev/null 2>&1 || return 1
  # Stream into a sibling temp on the REMOTE (same dir = same fs → atomic mv), then
  # rename. The old code ran `mktemp` LOCALLY and reused its path as the remote temp,
  # which (a) leaked a 0-byte local file and (b) borrowed a /tmp path with no meaning
  # on the remote. Clean up the remote temp on any mid-flight failure.
  local rtmp="${REMOTE}.wsh-tmp.$$"
  tailscale ssh "$CONN" "cat > '$rtmp' && mv -f '$rtmp' '$REMOTE' || { rm -f '$rtmp'; exit 1; }" <"$LOCAL"
}

try_scp() {
  command -v scp >/dev/null 2>&1 || return 1
  local host path
  if [[ "$CONN" == *@* ]]; then
    host="$CONN"
  else
    host="qveys@${CONN}"
  fi
  scp -q "$LOCAL" "${host}:${REMOTE}"
}

LOCAL_SIZE=$(wc -c <"$LOCAL" | tr -d '[:space:]')
echo "push: $LOCAL (${LOCAL_SIZE} bytes) -> ${CONN}:${REMOTE}"

METHOD=""
if try_wsh_cp; then
  METHOD=wsh-file-cp
elif try_tailscale_pipe; then
  METHOD=tailscale-ssh
elif try_scp; then
  METHOD=scp
else
  echo "all push methods failed (need wsh route, tailscale ssh, or scp)" >&2
  exit 3
fi

R_SIZE=$(remote_size "$CONN" "$REMOTE")
if [ -z "$R_SIZE" ]; then
  # Transport reported success but we have no channel to confirm the size. Report
  # success-unverified rather than a false mismatch (the old code returned 0 here
  # and failed with exit 4 whenever tailscale was absent but wsh-cp had worked).
  echo "ok via ${METHOD}: remote ${REMOTE} (${LOCAL_SIZE} bytes, size unverified)"
elif [ "$R_SIZE" = "$LOCAL_SIZE" ]; then
  echo "ok via ${METHOD}: remote ${REMOTE} (${R_SIZE} bytes)"
else
  echo "warn: size mismatch local=${LOCAL_SIZE} remote=${R_SIZE} (method=${METHOD})" >&2
  exit 4
fi