#!/usr/bin/env bash
# lib/session.sh — session naming, last-session state, and resolution guards.
# Sourced by wsh-live.sh; not meant to be run standalone.

# Unique session name: cockpit-<prefix>-<HHMMSS>. Prefix defaults to WSH_COCKPIT_PREFIX
# or the basename of the caller (e.g. "grok", "claude") when detectable.
unique_session_name() {
  local prefix; prefix=$(normalize_prefix "$1")   # same slug rules, one definition
  local ts
  ts=$(date '+%H%M%S')
  local name="cockpit-${prefix}-${ts}"
  local n=0
  while mux_has "$name"; do
    n=$((n + 1))
    name="cockpit-${prefix}-${ts}-${n}"
  done
  printf '%s\n' "$name"
}

# Remember the last spawned session so send/read can default to it within one workflow.
# Pure path computation — no mkdir here: state_file() is called on every read path
# (last_session → resolve_session, on each send/read/banner), and the dir only needs
# to exist when we actually WRITE (remember_session). (Lowercasing stays on `tr`, not
# ${x,,}: macOS ships bash 3.2 and the rest of this script avoids bash-4 expansions.)
state_file() {
  local key="${WSH_COCKPIT_AGENT:-${WSH_COCKPIT_PREFIX:-default}}"
  key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '_')
  printf '%s/last-session-%s\n' "$STATE_DIR" "$key"
}

remember_session() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" >"$(state_file)"
}

last_session() {
  local f
  f=$(state_file)
  [ -f "$f" ] || return 1
  local s
  s=$(tr -d '[:space:]' <"$f")
  [ -n "$s" ] && mux_has "$s" || return 1
  printf '%s\n' "$s"
}

# Normalize a spawn prefix (same rules as unique_session_name).
normalize_prefix() {
  local prefix="${1:-}"
  if [ -z "$prefix" ]; then
    prefix="${WSH_COCKPIT_PREFIX:-}"
  fi
  if [ -z "$prefix" ]; then
    prefix="${WSH_COCKPIT_AGENT:-live}"
  fi
  prefix=$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-')
  prefix=${prefix#-}; prefix=${prefix%-}
  [ -n "$prefix" ] || prefix="live"
  printf '%s\n' "$prefix"
}

# Newest alive tmux session matching cockpit-<prefix>-* (lex sort ≈ time suffix).
newest_session_for_prefix() {
  local prefix="$1" best=""
  local pattern="cockpit-${prefix}-"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if [ -z "$best" ] || [[ "$s" > "$best" ]]; then
      best="$s"
    fi
  done < <(mux_list_sessions | grep "^${pattern}" || true)
  [ -n "$best" ] && mux_has "$best" || return 1
  printf '%s\n' "$best"
}

# Prefer last remembered session; else newest alive session for the spawn prefix.
find_reusable_session() {
  local prefix="${1:-}"
  local norm remembered newest
  norm=$(normalize_prefix "$prefix")
  if remembered=$(last_session 2>/dev/null); then
    printf '%s\n' "$remembered"
    return 0
  fi
  if newest=$(newest_session_for_prefix "$norm" 2>/dev/null); then
    printf '%s\n' "$newest"
    return 0
  fi
  return 1
}

resolve_session() {
  local requested="${1:-}"
  if [ -n "$requested" ]; then
    printf '%s\n' "$requested"
    return 0
  fi
  if last_session; then return 0; fi
  printf '%s\n' "$SESS_DEFAULT"
}

need_session() {
  mux_has "$1" || {
    echo "no $MUX session '$1' — run: $0 start $1" >&2; exit 4; }
}

# --- Remote mode: sticky per-session inline-framing flag ---------------------
# The local helper files (lib/framing.sh's sep/step helpers) live under
# $STATE_DIR on the Mac. Once a pane `ssh`/`tailscale ssh`-hops to a remote
# host, that path doesn't exist there, so sourcing it fails ("command not
# found") — the existing fix is the self-contained inline framing
# (WSH_LIVE_SEP_REINIT=1 / WSH_STEP_INLINE=1), but requiring the caller to
# repeat those env vars on every single send/banner after the hop is exactly
# the kind of thing that gets forgotten mid-workflow. `remote-init` sets a
# tmux session option once; send/banner then default to inline framing for
# that session until `local-init` clears it. Explicit env vars still win, for
# one-off overrides. Zellij has no per-session option store (same limitation
# as helper_loaded) — remote mode is env-var-only there; remote_mode_set is a
# no-op with a stderr note rather than a silent failure.
remote_mode_option() { printf '@wsh_remote_mode\n'; }
remote_mode_get() {  # $1 sess -> "1" (on) or "" (off/unset)
  [ "$MUX" = tmux ] || return 1
  [ "$(tmux show-option -qv -t "$1" "$(remote_mode_option)" 2>/dev/null || true)" = "1" ]
}
remote_mode_set() {  # $1 sess  $2 (1|0) -> 0 if actually set, 1 if a tmux-only no-op
  if [ "$MUX" != tmux ]; then
    echo "note: remote-init/local-init has no effect under $MUX (no per-session option store) — use WSH_LIVE_SEP_REINIT=1 / WSH_STEP_INLINE=1 explicitly instead" >&2
    return 1
  fi
  tmux set-option -t "$1" "$(remote_mode_option)" "$2" >/dev/null 2>&1 || true
}

# --- Remote mode: pushed-helper paths (when remote-init was given a host) ---
# When `remote-init <session> <host>` manages to push the sep/step helper
# files to the remote host (see wsh-live.sh's remote-init case, which shells
# out to wsh-push.sh), the REMOTE absolute path of each pushed file is
# recorded here so send/banner can build the short `. '<remote-path>' && ...`
# sourcing form instead of falling back to the ~700-char inline blob. Same
# per-session tmux-option store as remote_mode_*, same Zellij limitation
# (no-op — callers just never find a path, so they fall back to inline).
remote_helper_option() { printf '@wsh_remote_helper_%s\n' "$1"; }  # $1 kind (sep|step)
remote_helper_path_get() {  # $1 sess $2 kind -> remote path, or "" if none recorded
  [ "$MUX" = tmux ] || { printf ''; return 0; }
  tmux show-option -qv -t "$1" "$(remote_helper_option "$2")" 2>/dev/null || true
}
remote_helper_path_set() {  # $1 sess $2 kind $3 remote-path
  [ "$MUX" = tmux ] || return 0
  tmux set-option -t "$1" "$(remote_helper_option "$2")" "$3" >/dev/null 2>&1 || true
}
remote_helper_path_clear() {  # $1 sess $2 kind
  [ "$MUX" = tmux ] || return 0
  tmux set-option -u -t "$1" "$(remote_helper_option "$2")" >/dev/null 2>&1 || true
}

# Human-only narration. The cockpit is driven by Claude through a non-TTY Bash pipe,
# where every line is re-read into the model's context on each call — so per-command
# confirmations and multi-line "how to attach" help are pure token cost there. Print
# such guidance ONLY when stdout is a real TTY (a human running the script by hand);
# machine lines (SESSION=, sent #N) stay unconditional and terse.
tty_only() { [ -t 1 ] && printf '%s\n' "$@" || true; }

# Per-session sequence counter file path: normalized slug of session name.
seq_file() { printf '%s/seq-%s\n' "$STATE_DIR" "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_')"; }

# Kill a session and clean up everything that belongs to it: the seq-counter
# file, the sep/step "helpers loaded" tmux options, its ttyd web view (if
# any), and — only if it was the one remembered for the CURRENT agent/prefix
# — the last-session pointer. Shared by `stop` (explicit, one session) and
# `gc` (idle sweep, many sessions) so this cleanup logic lives in exactly one
# place. Returns 0 if a session was actually killed, 1 if there was nothing
# to kill (already gone).
teardown_session() {
  local sess="$1" sf killed=1
  rm -f "$(seq_file "$sess")" 2>/dev/null || true
  if [ "$MUX" = tmux ]; then
    tmux set-option -u -t "$sess" "$(sep_helper_option "$sess")" >/dev/null 2>&1 || true
    tmux set-option -u -t "$sess" "$(step_helper_option "$sess")" >/dev/null 2>&1 || true
    tmux set-option -u -t "$sess" "$(remote_mode_option)" >/dev/null 2>&1 || true
    tmux set-option -u -t "$sess" "$(remote_helper_option sep)" >/dev/null 2>&1 || true
    tmux set-option -u -t "$sess" "$(remote_helper_option step)" >/dev/null 2>&1 || true
  fi
  web_teardown "$sess"
  if mux_kill "$sess"; then killed=0; fi
  sf=$(state_file)
  if [ -f "$sf" ] && [ "$(tr -d '[:space:]' <"$sf")" = "$sess" ]; then
    rm -f "$sf" 2>/dev/null || true
  fi
  return "$killed"
}
