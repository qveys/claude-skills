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

# The tmux session that is CURRENTLY running the calling process itself, if any.
# `$TMUX` is set by tmux in every process spawned inside a pane — including a
# Bash tool call whose shell lives inside the Claude Code CLI's own wrapping
# tmux session (Wave wraps every terminal in tmux, one block = one session).
# `tmux display-message` asks the tmux server, not the pane content, so it's
# authoritative regardless of what's currently drawn on screen.
own_tmux_session() {
  [ "$MUX" = tmux ] || return 1
  [ -n "${TMUX:-}" ] || return 1
  tmux display-message -p '#S' 2>/dev/null
}

# A session is safe to silently reuse only if BOTH hold:
#  1. It is not the tmux session the caller is itself currently running inside
#     (absolute, unconditional block — see own_tmux_session).
#  2. Its foreground process is a bare shell, not some other interactive
#     program left running in an otherwise-orphaned cockpit.
# Guards against reusing a tmux session that — unbeknownst to the caller — is
# hosting an interactive program, most dangerously another Claude Code CLI: a
# blind `send` there doesn't run a command, it types the "situate" probe into
# that program's own prompt, and the caller only finds out from a confused
# reply. (Incident: `find_reusable_session` returned the exact tmux session
# wrapping the calling agent's own Claude Code CLI — `send`ing into it
# resubmitted the probe as a new chat message. `pane_current_command` alone
# can't catch this specific case: querying it from inside a Bash tool call
# always transiently reports "bash", since that IS the process running the
# check — hence guard #1 being a separate, name-based, unconditional check
# rather than relying on the foreground-process heuristic for this scenario.)
# Empty pane_current_command (zellij: unsupported, or a transient read) is
# treated as unverifiable-but-safe, not unsafe.
session_safe_to_reuse() {
  local sess="$1" cmd own
  if own=$(own_tmux_session) && [ "$sess" = "$own" ]; then
    echo "⚠️  session '$sess' IS the tmux session this call is running inside (your own controlling terminal) — refusing to reuse it under any circumstance" >&2
    return 1
  fi
  cmd=$(mux_pane_command "$sess")
  case "$cmd" in
    ""|bash|zsh|sh|fish|-bash|-zsh|-sh|-fish) return 0 ;;
    *)
      echo "⚠️  session '$sess' foreground process is '$cmd', not a bare shell — refusing silent reuse (pass --force for a fresh cockpit, or 'read' it manually first)" >&2
      return 1 ;;
  esac
}

# Prefer last remembered session; else newest alive session for the spawn prefix.
# Both candidates must also pass session_safe_to_reuse before being handed back.
find_reusable_session() {
  local prefix="${1:-}"
  local norm remembered newest
  norm=$(normalize_prefix "$prefix")
  if remembered=$(last_session 2>/dev/null) && session_safe_to_reuse "$remembered"; then
    printf '%s\n' "$remembered"
    return 0
  fi
  if newest=$(newest_session_for_prefix "$norm" 2>/dev/null) && session_safe_to_reuse "$newest"; then
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
