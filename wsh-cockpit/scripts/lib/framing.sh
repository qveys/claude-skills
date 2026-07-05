#!/usr/bin/env bash
# lib/framing.sh — visual framing for `send` (sep) and `banner` (step).
# Sourced by wsh-live.sh; not meant to be run standalone.
#
# --- Visual delimiters for `send` (live mode) -------------------------------
# In live mode the user *watches* the same pane Claude types into. Without any
# separation, successive commands and their output run together and it's hard to
# tell where one call ends and the next begins. So each `send` is framed by a
# header banner (before the command) and a footer banner (after it finishes),
# with blank-line breathing room around both.
#
# Design notes / why it's safe:
#   * The framing is built as ONE shell line — `printf HEADER; { CMD ; }; rc=$?;
#     printf FOOTER` — so the FOOTER only prints *after* CMD returns. Interactive
#     commands (a `sudo` waiting for a password, a pager, an editor) run normally
#     and the closing banner appears only once they actually finish. The `{ ; }`
#     group keeps CMD's own `;`, `&&`, pipes etc. intact.
#   * Separators are plain `printf` (POSIX) so they render identically locally and
#     after an `ssh` / `wsh ssh` into a remote shell inside the session.
#   * They do NOT use the tokens `START`/`END`: the `rexec` mode (separate script)
#     keys off those markers, and the live `read` is just a human-readable
#     capture-pane, so these extra lines never interfere with any parsing.
#   * Toggle with WSH_LIVE_SEP: default on (=1). Set WSH_LIVE_SEP=0 to send the
#     raw command with no framing (e.g. when feeding a TUI that hates noise).
#   * Per-session incremental counter lives in a state file so it
#     persists across `send` calls without any tmux options.
#
# A header/footer rule is sized to the pane width (capped) and colored when the
# pane is a TTY: 256-color vivid framing (turquoise rules, electric-cyan seq,
# orange $ prompt, white command, neon green/red footer). Plain text when not TTY.
# over a dumb pipe.

# Next sequence number for a session (reads+writes state file). Echoes it.
sep_next_seq() {
  local sess="$1" f n
  f=$(seq_file "$sess"); mkdir -p "$STATE_DIR"
  n=$(cat "$f" 2>/dev/null || true)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  printf '%s\n' "$n" >"$f"
  printf '%s\n' "$n"
}

# --- Generic install-once helper machinery (shared by sep framing + step banners) ---
# A versioned helper file in /tmp, sourced once per tmux session, with "loaded"
# tracked in a per-session tmux option. The send framing (kind=sep) and the banner
# defs (kind=step) differ ONLY in (kind, version, defs-producer) — everything else is
# this shared code. The thin sep_*/step_* wrappers below bind those three params, so
# every call site keeps its readable name while the logic lives in exactly one place.
helper_path()   { printf '%s/helpers/wsh-live-%s-v%s.sh\n' "$STATE_DIR" "$1" "$2"; }  # kind version
helper_marker() { printf '# wsh-live-%s-helper-version=%s' "$1" "$2"; }                   # kind version
helper_option() { printf '@wsh_%s_helpers_%s\n' "$1" "$(printf '%s' "$2" | tr -cs 'A-Za-z0-9_' '_')"; }  # kind sess
# Write the helper if missing/stale; echo its path. $1 kind $2 version $3 defs-fn
# (the defs-fn emits the version marker line + the function bodies).
helper_ensure() {
  local helper tmp first
  helper=$(helper_path "$1" "$2")
  first=""; [ -f "$helper" ] && IFS= read -r first <"$helper" || true
  if [ "$first" != "$(helper_marker "$1" "$2")" ]; then
    mkdir -p "$STATE_DIR/helpers"
    tmp="${helper}.$$"; "$3" >"$tmp"; mv "$tmp" "$helper"; chmod 600 "$helper" 2>/dev/null || true
  fi
  printf '%s\n' "$helper"
}
# $1 kind $2 version $3 sess — "loaded" requires BOTH the tmux flag AND the file: a
# purge of the state dir mid-session must force a re-source, else a bare call hits an
# undefined function and the framed command/banner fails silently in the pane.
helper_loaded() {
  # Under zellij there is no per-session option store, so "loaded" is never
  # remembered: every framed send re-sources the helper (a slightly longer
  # visible line, but correct by construction).
  [ "$MUX" = tmux ] || return 1
  [ "$(tmux show-option -qv -t "$3" "$(helper_option "$1" "$3")" 2>/dev/null || true)" = "$2" ] \
    && [ -f "$(helper_path "$1" "$2")" ]
}
helper_mark_loaded() {  # $1 kind $2 version $3 sess
  [ "$MUX" = tmux ] || return 0
  tmux set-option -t "$3" "$(helper_option "$1" "$3")" "$2" >/dev/null 2>&1 || true
}

# Send-framing (kind=sep) bindings.
sep_helper_option()       { helper_option sep "$1"; }
sep_ensure_helpers()      { helper_ensure sep "$SEP_HELPER_VERSION" sep_helper_defs; }
sep_helpers_loaded()      { helper_loaded sep "$SEP_HELPER_VERSION" "$1"; }
sep_mark_helpers_loaded() { helper_mark_loaded sep "$SEP_HELPER_VERSION" "$1"; }

sep_helper_defs() {
  printf '# wsh-live-sep-helper-version=%s\n' "$SEP_HELPER_VERSION"
  cat <<'HELPERS'
__wsh_rule() {
  __wc=${COLUMNS:-80}
  [ "$__wc" -gt 100 ] && __wc=100
  printf '%*s' "$__wc" '' | tr ' ' '─'
}
__wsh_colors() {
  if [ -t 1 ]; then
    __r=$(printf '\033[0m')
    __dim=$(printf '\033[1;38;5;39m')
    __bc=$(printf '\033[1;38;5;51m')
    __dm=$(printf '\033[38;5;33m')
    __sy=$(printf '\033[1;38;5;226m')
    __tw=$(printf '\033[1;38;5;255m')
  else
    __r=; __dim=; __bc=; __dm=; __sy=; __tw=
  fi
}
__wsh_begin() {
  __wsh_colors
  __wr=$(__wsh_rule)
  printf '\n%s\n' "$__dim$__wr$__r"
  printf '%s┌─%s[#%s]%s %s%s\n' "$__dim" "$__bc" "$1" "$__r" "$__dm$(date '+%H:%M:%S')" "$__r"
  printf '%s│%s$%s %s%s\n' "$__dim" "$__sy" "$__r" "$__tw" "$2" "$__r"
  printf '%s%s%s\n\n' "$__dim" "$__wr" "$__r"
}
__wsh_end() {
  __wsh_colors
  __wr=$(__wsh_rule)
  if [ -t 1 ]; then
    if [ "$2" -eq 0 ]; then
      __fc=$(printf '\033[1;38;5;46m')
    else
      __fc=$(printf '\033[1;38;5;196m')
    fi
  else
    __fc=
  fi
  printf '\n'
  printf '%s└─%s[#%s]%s exit %s%s\n%s\n\n' "$__dim" "$__fc" "$1" "$__r" "$2" "$__r" "$__dim$__wr$__r"
  return "$2"
}
__wsh() {
  __seq=$1
  __cmd=$2
  __wsh_begin "$__seq" "$__cmd"
  eval "$__cmd"
  __rc=$?
  __wsh_end "$__seq" "$__rc"
}
HELPERS
}

# --- Banner helpers (function-based, mirrors sep_* above) --------------------
# The `banner` subcommand used to type wsh-step.sh's ~700-char self-contained
# printf one-liner into the pane on EVERY call — the watching human saw that splat
# scroll past before the banner rendered. Instead we source wsh-step.sh's pane-side
# `__wsh_banner` function ONCE per session (same install-once + tmux-option-tracked
# pattern as the send framing) and each later banner is just a short, readable
# `__wsh_banner done 'msg'`. Set WSH_STEP_INLINE=1 to fall back to the self-contained
# one-liner (e.g. for a pane that has ssh-hopped to a host without the helper file).
step_script_path() { printf '%s\n' "$(cd "$(dirname "$0")" && pwd)/wsh-step.sh"; }

step_helper_defs() {
  printf '# wsh-live-step-helper-version=%s\n' "$STEP_HELPER_VERSION"
  "$(step_script_path)" defs
}

# Banner (kind=step) bindings — same generic machinery as sep_* above.
step_helper_option()       { helper_option step "$1"; }
step_ensure_helpers()      { helper_ensure step "$STEP_HELPER_VERSION" step_helper_defs; }
step_helpers_loaded()      { helper_loaded step "$STEP_HELPER_VERSION" "$1"; }
step_mark_helpers_loaded() { helper_mark_loaded step "$STEP_HELPER_VERSION" "$1"; }

# Build `__wsh_banner <type> 'arg' 'arg' ...` with single-quote-safe arguments.
step_build_call() {
  local out="__wsh_banner $1" a; shift || true
  for a in "$@"; do
    out="$out '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'"
  done
  printf '%s' "$out"
}

# Emit the shell snippet that frames CMD with header+footer banners. The snippet
# is meant to be typed into the pane (so the user sees it run). All separator
# drawing happens *inside* the pane's shell via printf, sized to its own COLUMNS.
sep_wrap() {
  local seq="$1" cmd="$2" helper="${3:-}" prefix=""
  # Escape single quotes so the literal command can be displayed and eval'd by
  # the pane-side helper while preserving pipes, redirections, groups, etc.
  local cmd_q=${cmd//\'/\'\\\'\'}
  if [ -n "$helper" ]; then
    local helper_q=${helper//\'/\'\\\'\'}
    prefix=". '${helper_q}' && "
  fi
  printf "%s__wsh '%s' '%s'\n" "$prefix" "$seq" "$cmd_q"   # builtin, not a `cat` fork
}

sep_wrap_inline() {
  local seq="$1" cmd="$2"
  local cmd_disp=${cmd//\'/\'\\\'\'}
  cat <<WRAP
{ __wc=\${COLUMNS:-80}; [ "\$__wc" -gt 100 ] && __wc=100; __wr=\$(printf '%*s' "\$__wc" '' | tr ' ' '─'); if [ -t 1 ]; then __r=\$(printf '\033[0m'); __dim=\$(printf '\033[1;38;5;39m'); __bc=\$(printf '\033[1;38;5;51m'); __dm=\$(printf '\033[38;5;33m'); __sy=\$(printf '\033[1;38;5;226m'); __tw=\$(printf '\033[1;38;5;255m'); else __r=; __dim=; __bc=; __dm=; __sy=; __tw=; fi; printf '\n%s\n' "\$__dim\$__wr\$__r"; printf '%s┌─%s[#%s]%s %s%s\n' "\$__dim" "\$__bc" '${seq}' "\$__r" "\$__dm\$(date '+%H:%M:%S')" "\$__r"; printf '%s│%s\$%s %s%s\n' "\$__dim" "\$__sy" "\$__r" "\$__tw" '${cmd_disp}' "\$__r"; printf '%s%s%s\n' "\$__dim" "\$__wr" "\$__r"; printf '\n'; }; { ${cmd}; }; __rc=\$?; { if [ -t 1 ]; then if [ "\$__rc" -eq 0 ]; then __fc=\$(printf '\033[1;38;5;46m'); else __fc=\$(printf '\033[1;38;5;196m'); fi; else __fc=; fi; printf '\n'; printf '%s└─%s[#%s]%s exit %s%s\n%s\n' "\$__dim" "\$__fc" '${seq}' "\$__r" "\$__rc" "\$__r" "\$__dim\$__wr\$__r"; printf '\n'; }
WRAP
}
