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

# Human-only narration. The cockpit is driven by Claude through a non-TTY Bash pipe,
# where every line is re-read into the model's context on each call — so per-command
# confirmations and multi-line "how to attach" help are pure token cost there. Print
# such guidance ONLY when stdout is a real TTY (a human running the script by hand);
# machine lines (SESSION=, sent #N) stay unconditional and terse.
tty_only() { [ -t 1 ] && printf '%s\n' "$@" || true; }

# Per-session sequence counter file path: normalized slug of session name.
seq_file() { printf '%s/seq-%s\n' "$STATE_DIR" "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_')"; }
# Per-session Wave block id file: lets `stop` delete the block `open` created, so
# killing the cockpit doesn't leave an orphaned dead-terminal pane in Wave.
block_file() { printf '%s/block-%s\n' "$STATE_DIR" "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_')"; }
