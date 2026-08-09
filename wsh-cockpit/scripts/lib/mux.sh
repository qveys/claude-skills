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
  # "=" anchors on exact session name (tmux tries exact -> prefix -> fnmatch
  # otherwise — measured; see docs/gotchas.md). Strip any leading "=" the
  # caller may already have supplied before re-anchoring: "==name" matches
  # nothing (same guard session_is_own already applies in lib/session.sh).
  if [ "$MUX" = tmux ]; then local s="${1#=}"; tmux has-session -t "=$s" 2>/dev/null
  else mux_list_sessions | grep -Fqx -- "$1"; fi
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
  # "list-clients" takes a target-SESSION and honors "=" (measured; see
  # docs/gotchas.md) — same anchoring as mux_has/mux_kill, same rationale.
  # Free to add: all 4 callers (wsh-live.sh:441,477,727,730) only ever pass
  # names already validated by need_session/last_session.
  if [ "$MUX" = tmux ]; then local s="${1#=}"; tmux list-clients -t "=$s" 2>/dev/null
  else "$(zellij_bin)" --session "$1" action list-clients 2>/dev/null | tail -n +2; fi
}
mux_kill() {
  # Anchored exact match — same rationale as mux_has above: an unanchored
  # kill-session honors tmux's prefix/fnmatch fallback too, so a prefix
  # collision would tear down the wrong (unrelated) session.
  if [ "$MUX" = tmux ]; then local s="${1#=}"; tmux kill-session -t "=$s" 2>/dev/null
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
mux_block_attach_cmd() {  # $1 session, $2 ABSOLUTE mux binary — what a Wave block runs
  # Deliberately NOT `exec`: the attach ending (Ctrl+A d — one key away from the
  # Ctrl+A s everyone uses —, session killed, mux error) would take the block's
  # process down with it, and Wave leaves a DEAD terminal: a black screen that
  # swallows every keystroke, prefix included, indistinguishable from a crash.
  # A surviving shell can say what happened and offer a re-attach on the spot.
  # Both operands are interpolated into shell source, so they get the one
  # escaping that makes a single-quoted string safe ('  ->  '\''): a session
  # named `it's` would otherwise close the quote and hand the rest to sh as
  # commands. The name is also a printf ARGUMENT, never part of its format —
  # a `%` in a session name is data, not a conversion.
  local attach sess_q bin_q
  sess_q=${1//\'/\'\\\'\'}
  bin_q=${2//\'/\'\\\'\'}
  if [ "$MUX" = tmux ]; then attach="'$bin_q' attach -t '$sess_q'"
  else attach="'$bin_q' attach '$sess_q'"; fi
  printf 'while :; do %s; printf "\\n[cockpit] %%s: detached or ended (exit %%s)\\n[cockpit] Enter = re-attach, Ctrl-D = close this block\\n" '\''%s'\'' "$?"; read -r _cockpit_ans || exit 0; done\n' \
    "$attach" "$sess_q"
}
mux_pane_command() {  # foreground process name in the pane's active pane, best-effort
  # display-message resolves `-t` to the target's ACTIVE pane directly; the prior
  # `list-panes | head -1` returned an arbitrary pane of the current window (not
  # necessarily the active one), which could misjudge a session as reusable.
  if [ "$MUX" = tmux ]; then tmux display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null
  else printf ''; fi  # zellij: no cheap equivalent — caller treats unknown as unverifiable
}
mux_session_name() {  # canonical name the target actually resolves to, best-effort
  # tmux resolves `-t` by exact name, then prefix, then fnmatch — so a bare
  # prefix of a session name can still name that session. Round-tripping
  # through `#{session_name}` closes that alias: it reports the ACTUAL
  # session behind whatever the caller passed, not the string they passed.
  if [ "$MUX" = tmux ]; then tmux display-message -p -t "$1" '#{session_name}' 2>/dev/null
  else printf '%s' "$1"; fi  # zellij: no alias resolution to worry about — pass through
}
mux_pane_last_line() {  # last non-blank captured line of the pane's active pane, best-effort
  # -J joins tmux-wrapped physical rows back into one logical line: measured
  # (docs/gotchas.md), a padded right-prompt (RPROMPT) segment can occupy a
  # row wider than #{pane_width} without ever setting the wrap flag, and even
  # when it does wrap, -J re-joins it — either way the caller always sees the
  # true tail of the logical prompt line, never a truncated physical row.
  if [ "$MUX" = tmux ]; then
    tmux capture-pane -pJt "$1" -S -20 2>/dev/null | awk 'NF{last=$0} END{print last}'
  else printf ''; fi  # zellij: no cheap equivalent — caller treats unknown as unverifiable
}
mux_pane_id() {  # id of the target session's ACTIVE pane, best-effort
  if [ "$MUX" = tmux ]; then tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null
  else printf ''; fi  # zellij: no cheap equivalent — caller treats unknown as unverifiable
}
mux_session_panes() {  # ALL pane ids of the target session, one per line
  # mux_pane_id only ever sees the ACTIVE pane — a caller sitting in a
  # non-active pane of a multi-pane (or grouped) session would be invisible
  # to a check built on that alone. The "=" anchor below is kept but is
  # INERT here: measured, `list-panes -s -t "=probe-o"` still resolves by
  # prefix and returns probe-one's panes (an unknown target errors as
  # "can't find window", not "can't find session"). A looser resolution only
  # widens the refusal in session_is_own, never narrows it, so this is
  # harmless — but the pane-membership fix does not rely on the anchor.
  # Lesson: target-session vs target-pane is NOT a reliable predictor of
  # whether "=" is honoured (has-session honours it, list-panes doesn't,
  # split-window rejects it outright) — measure per command, don't assume.
  if [ "$MUX" = tmux ]; then tmux list-panes -s -t "=$1" -F '#{pane_id}' 2>/dev/null
  else printf ''; fi  # zellij: no per-pane enumeration — background sessions are single-pane
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
  chmod 600 "$f" 2>/dev/null || true   # umask only governs creation — tighten a pre-existing file too
  find "$dir" -name '*.log' -type f -mtime +30 -delete 2>/dev/null || true
  tmux pipe-pane -o -t "$sess" "cat >> '$f'" 2>/dev/null || true
}

create_session() {
  mux_create "$1"
  audit_log_start "$1"
}
