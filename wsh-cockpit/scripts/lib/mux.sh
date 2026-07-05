#!/usr/bin/env bash
# lib/mux.sh — multiplexer backend abstraction, dispatched on $MUX (tmux|zellij).
# Sourced by wsh-live.sh; not meant to be run standalone.
#
# --- Mux backend dispatch ----------------------------------------------------
# Every core operation the live loop needs, dispatched on $MUX. The tmux arms
# are the historical code, byte-for-byte. The zellij arms drive a background
# session through its CLI actions; a background zellij session has NO pane
# until one is created with `run`, and actions must target that pane id
# explicitly (a headless session has no focused pane) — so mux_create stores
# the pane id in a state file that send/read look up.

have_mux() {
  command -v "$MUX" >/dev/null 2>&1 || {
    echo "$MUX not found — install it on the Mac: brew install $MUX" >&2; exit 3; }
}

zellij_bin() { command -v zellij 2>/dev/null || echo /opt/homebrew/bin/zellij; }
pane_file()  { printf '%s/pane-%s\n' "$STATE_DIR" "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_')"; }
zellij_pane() { cat "$(pane_file "$1")" 2>/dev/null || true; }

mux_has() {
  if [ "$MUX" = tmux ]; then tmux has-session -t "$1" 2>/dev/null
  else mux_list_sessions | grep -qx "$1"; fi
}
mux_list_sessions() {
  if [ "$MUX" = tmux ]; then tmux list-sessions -F '#{session_name}' 2>/dev/null
  else "$(zellij_bin)" list-sessions -s 2>/dev/null; fi
}
mux_create() {
  if [ "$MUX" = tmux ]; then
    tmux new-session -d -s "$1" \; set-option -t "$1" history-limit 50000 >/dev/null
  else
    local zb pane
    zb=$(zellij_bin)
    "$zb" attach --create-background "$1" >/dev/null 2>&1 || true
    # The background session starts pane-less; `run` returns "terminal_<id>".
    pane=$("$zb" --session "$1" run -- "${SHELL:-/bin/zsh}" 2>/dev/null || true)
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$pane" >"$(pane_file "$1")"
    sleep 1   # let the pane's shell come up before the first write-chars
  fi
}
mux_send_line() {  # $1 sess  $2 text — type text, then Enter
  if [ "$MUX" = tmux ]; then
    # -l sends the text literally (so a command that happens to read like a
    # tmux key name isn't interpreted); Enter is a separate keypress.
    tmux send-keys -t "$1" -l "$2"
    tmux send-keys -t "$1" Enter
  else
    local zb pane; zb=$(zellij_bin); pane=$(zellij_pane "$1")
    if [ -n "$pane" ]; then
      "$zb" --session "$1" action write-chars -p "$pane" "$2"
      "$zb" --session "$1" action write -p "$pane" 13
    else
      "$zb" --session "$1" action write-chars "$2"
      "$zb" --session "$1" action write 13
    fi
  fi
}
mux_capture() {  # $1 sess  $2 lines of scrollback to look back
  if [ "$MUX" = tmux ]; then
    tmux capture-pane -pt "$1" -S "-$2" 2>/dev/null
  else
    local zb pane; zb=$(zellij_bin); pane=$(zellij_pane "$1")
    if [ -n "$pane" ]; then
      "$zb" --session "$1" action dump-screen --full -p "$pane" 2>/dev/null | tail -n "$2"
    else
      "$zb" --session "$1" action dump-screen --full 2>/dev/null | tail -n "$2"
    fi
  fi
}
mux_clients() {  # attached client lines (empty output = nobody watching)
  if [ "$MUX" = tmux ]; then tmux list-clients -t "$1" 2>/dev/null
  else "$(zellij_bin)" --session "$1" action list-clients 2>/dev/null | tail -n +2; fi
}
mux_kill() {
  if [ "$MUX" = tmux ]; then tmux kill-session -t "$1" 2>/dev/null
  else
    local zb rc; zb=$(zellij_bin)
    "$zb" kill-session "$1" >/dev/null 2>&1; rc=$?
    # A killed zellij session lingers as EXITED (resurrectable) — delete it,
    # or the GC/list logic would keep seeing a ghost.
    "$zb" delete-session --force "$1" >/dev/null 2>&1 || true
    rm -f "$(pane_file "$1")" 2>/dev/null || true
    return "$rc"
  fi
}
mux_attach_cmd() {  # the command a human types to join the session
  if [ "$MUX" = tmux ]; then printf 'tmux attach -t %s\n' "$1"
  else printf 'zellij attach %s\n' "$1"; fi
}

# Audit trail: pipe the pane's rendered output to a per-session log file.
# WSH_LIVE_LOG=0 disables. Best-effort by design (`|| return 0` everywhere):
# a cockpit must open even if the log dir is unwritable. pipe-pane -o is
# idempotent (only opens a pipe when none exists), so calling this on reuse
# is safe. Logs can contain whatever the pane shows — treat them as sensitive
# (dir 700 / files 600) and purge after 30 days.
audit_log_start() {
  [ "${WSH_LIVE_LOG:-1}" = "1" ] || return 0
  if [ "$MUX" != tmux ]; then
    echo "note: audit log unavailable under $MUX (pipe-pane is tmux-only) — session runs UNLOGGED" >&2
    return 0
  fi
  local sess="$1" dir f slug
  dir="${WSH_LIVE_LOG_DIR:-$HOME/Library/Logs/wsh-cockpit}"
  mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || return 0
  # The file is named after a sanitized slug of the session name: the path is
  # interpolated into pipe-pane's shell command, so it must stay quote-free.
  slug=$(printf '%s' "$sess" | tr -cs 'A-Za-z0-9_.-' '_')
  f="$dir/${slug}.log"
  ( umask 077; : >>"$f" ) 2>/dev/null || return 0
  find "$dir" -name '*.log' -type f -mtime +30 -delete 2>/dev/null || true
  tmux pipe-pane -o -t "$sess" "cat >> '$f'" 2>/dev/null || true
}

create_session() {
  mux_create "$1"
  audit_log_start "$1"
}
