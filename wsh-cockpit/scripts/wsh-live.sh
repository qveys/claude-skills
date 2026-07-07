#!/usr/bin/env bash
# wsh-live.sh — a shared, persistent tmux session on the LOCAL Mac that Claude
# drives and the user watches/joins. tmux is the cockpit: Claude types with
# `send-keys`, reads with `capture-pane`, and the user attaches to the SAME
# session to watch live, scroll, split panes, copy text, or grab the keyboard.
#
# Why local tmux (not a remote dispatcher): Claude's own shell runs on the Mac,
# so it can talk to a local tmux server *directly* — no `wsh file` queue, no SSH
# resync, nothing to freeze. tmux only needs to exist on the Mac (`brew install
# tmux`). To co-drive a REMOTE host, open the connection *inside* the session
# (`wsh ssh -n host`, `ssh host`, `docker exec -it ...`) and keep using send/read.
#
# Subcommands:
#   spawn [prefix] [--force]   open/reuse cockpit: reuse last alive session by default;
#                              --force always creates a fresh session + auto-open Wave
#   start [session] [--reuse]  create the session + print the attach command
#   open  [session]            AUTO-OPEN a visible Wave block attached to the session
#   send  '<command>' [sess]   type a command into the pane and press Enter
#   keys  '<tmux-keys>' [sess] send raw tmux keys (C-c, Up, Enter, q ...) verbatim
#   read  [session] [lines]    print the current pane (default 30 lines back)
#   stop  [session]            kill the session
#   current                    print the last session created by `spawn` in this shell tree
#   doctor                     read-only diagnostic of the whole cockpit chain (11 checks,
#                              rc 0/1, never writes anything — safe to run anytime)
#   web   {start|stop|status} [session]
#                              browser view of the cockpit pane via ttyd, loopback-only
#                              (brew install ttyd); read-only by default (WSH_WEB_WRITE=1
#                              for a writable view) — see SKILL.md for tailnet exposure
#   banner {header|phase|step|done} ... [session]
#                              airy step announcement (no send framing — see wsh-step.sh)
#   wait-done [session] [timeout_sec] [seq]
#                              block until last `send` footer shows exit (before next send)
#   selftest-live              end-to-end smoke test on a throwaway cockpit-selftest-$$
#                              session (start/send/wait-done/read/banner/stop, NO Wave
#                              block — never calls spawn/open); rc 0/1
#
# Env: WSH_MUX=tmux (default)    mux backend; WSH_MUX=zellij is EXPERIMENTAL —
#                                core loop only (start/send/read/wait-done/stop/
#                                open/status/spawn); keys/web refuse explicitly
#                                under zellij; the audit log is disabled with a
#                                warning instead (pipe-pane is tmux-only)
#      WSH_LIVE_LOG=1 (default)  enable audit logging; WSH_LIVE_LOG=0 disables
#      WSH_LIVE_LOG_DIR           custom log directory (default ~/Library/Logs/wsh-cockpit)
#      WSH_COCKPIT_AGENT          key for state file (agent name, used in last-session-*)
#      WSH_COCKPIT_PREFIX         default prefix for auto-unique session names
#      WSH_COCKPIT_STATE_DIR      state directory (default ~/.cache/wsh-cockpit)
#      WSH_LIVE_SEP=1 (default)   enable send/recv visual framing; =0 for raw shell
#      WSH_WEB_PORT (default 7681)  loopback TCP port for `web` (ttyd)
#      WSH_WEB_WRITE=1              `web start` becomes writable (default: read-only)
#
# `open` solves the "the user shouldn't have to type `tmux attach` themselves"
# problem: it spawns a visible Wave block running `tmux attach -t <session>`, so
# the shared cockpit appears on the user's screen automatically. Two pitfalls it
# works around — both discovered empirically (see SKILL.md "Auto-open gotchas"):
#   1. STALE WAVE ENV. When Claude runs in a tool shell, the inherited
#      WAVETERM_TABID / WAVETERM_BLOCKID can be PERIMED (Wave was restarted /
#      resurrected since this shell launched). `wsh run` then anchors the new
#      block on the env's tab, which no longer exists, and dies with
#      `tab not found: <tabid>`. We can't trust the env tab, and `wsh blocks
#      list` / `wsh workspace list` are unreliable here too ("no workspaces
#      found" / "[]"). So we read the LIVE active tab straight from Wave's state
#      SQLite (db_workspace.activetabid) and override WAVETERM_TABID with it.
#   2. WAVE BLOCK PATH. The shell Wave spawns for a block does NOT inherit the
#      homebrew PATH, so a bare `tmux` is `command not found` (exit 127). We call
#      tmux by ABSOLUTE path and `exec` it so the block *is* the attach.
set -euo pipefail

SESS_DEFAULT="cockpit"
STATE_DIR="${WSH_COCKPIT_STATE_DIR:-$HOME/.cache/wsh-cockpit}"
SEP_HELPER_VERSION="4"
STEP_HELPER_VERSION="1"
# WSH_MUX selects the multiplexer backend. tmux is the reference (full feature
# set); zellij covers the core loop only (start/send/read/wait-done/stop/open/
# status/spawn). keys and the ttyd web view are tmux-only — each refuses
# explicitly under zellij, never silently. The pipe-pane audit log is also
# tmux-only, but does NOT refuse: the session still starts, unlogged, with an
# explicit stderr warning (see audit_log_start).
MUX="${WSH_MUX:-tmux}"
case "$MUX" in tmux|zellij) ;; *)
  echo "wsh-live: WSH_MUX must be 'tmux' or 'zellij' (got '$MUX')" >&2; exit 2 ;;
esac
sub="${1:-}"; shift || true

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

have_mux() {
  command -v "$MUX" >/dev/null 2>&1 || {
    echo "$MUX not found — install it on the Mac: brew install $MUX" >&2; exit 3; }
}
need_session() {
  mux_has "$1" || {
    echo "no $MUX session '$1' — run: $0 start $1" >&2; exit 4; }
}

# --- Mux backend dispatch ----------------------------------------------------
# Every core operation the live loop needs, dispatched on $MUX. The tmux arms
# are the historical code, byte-for-byte. The zellij arms drive a background
# session through its CLI actions; a background zellij session has NO pane
# until one is created with `run`, and actions must target that pane id
# explicitly (a headless session has no focused pane) — so mux_create stores
# the pane id in a state file that send/read look up.
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

# Human-only narration. The cockpit is driven by Claude through a non-TTY Bash pipe,
# where every line is re-read into the model's context on each call — so per-command
# confirmations and multi-line "how to attach" help are pure token cost there. Print
# such guidance ONLY when stdout is a real TTY (a human running the script by hand);
# machine lines (SESSION=, sent #N) stay unconditional and terse.
tty_only() { [ -t 1 ] && printf '%s\n' "$@" || true; }

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

# Per-session sequence counter file path: normalized slug of session name.
seq_file() { printf '%s/seq-%s\n' "$STATE_DIR" "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_')"; }

# Per-session ttyd pidfile path — same slug-normalization model as seq_file().
web_pid_file() { printf '%s/web-%s.pid\n' "$STATE_DIR" "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_')"; }

# True when pid $1 is alive AND is a ttyd process. A bare PID alone isn't proof
# after a reboot recycled it — shared by web_alive_pid (read-only check, used
# by `web start`/`web status`) and web_teardown (kill, used by `stop` and
# `web stop`), so the alive-and-ttyd condition lives in exactly one place.
web_pid_is_ttyd() { kill -0 "$1" 2>/dev/null && ps -p "$1" -o comm= 2>/dev/null | grep -q 'ttyd$'; }

# Kill this session's ttyd web view if one is running; always drop the pidfile.
# Called both by top-level `stop` (so killing a cockpit session always tears
# down its web view too — a bare tmux/zellij kill used to leak the ttyd
# process) and by `web stop`.
web_teardown() {
  local pf p; pf=$(web_pid_file "$1")
  [ -f "$pf" ] || return 0
  p=$(tr -d '[:space:]' <"$pf")
  if [ -n "$p" ] && web_pid_is_ttyd "$p"; then
    kill "$p" 2>/dev/null || true
  fi
  rm -f "$pf" 2>/dev/null || true
}

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

# Resolve a LIVE Wave tab id to anchor a new block on, robust to a stale env.
# Strategy, best-first (the goal is the INITIATING shell's tab, so the cockpit
# opens next to the Claude Code that spawned it):
#   0. Live signals over env — (a) the wave-init tmux session-group name
#      (wave-<tab8>, 1 tab = 1 group) resolved back to a full tab oid, else
#      (b) the tab whose blockids contain WAVETERM_BLOCKID.
#   1. If WAVETERM_TABID is set AND still present in Wave's state DB, trust it.
#   2. Otherwise read db_workspace.activetabid for the env's workspace (or, if
#      that workspace is gone too, the single/first workspace) from the state
#      SQLite, opened READ-ONLY so we never touch Wave's live DB.
# Prints the tab id on success; prints nothing and returns non-zero if no live
# tab can be found (caller falls back to telling the human to attach by hand).
# Echo the `file:…?mode=ro` URI for Wave's state SQLite, or return 1 if it/sqlite3
# is unavailable. CRITICAL: mode=ro ONLY — never add immutable=1. Wave's DB is in
# WAL mode, so recent writes (the active-tab switch, new blocks, freshly recreated
# tab oids) live in the -wal file; immutable=1 tells SQLite "this file never changes,
# ignore the WAL" → a STALE snapshot that resolves the wrong (often oldest) tab and
# dead oids. mode=ro reads through the WAL (we have rw perms, so -shm/-wal read fine).
wave_db_ro() {
  local data_dir db
  data_dir=$(wsh wavepath data 2>/dev/null) || data_dir=""
  [ -n "$data_dir" ] || data_dir="$HOME/Library/Application Support/waveterm"
  db="$data_dir/db/waveterm.db"
  [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1 || return 1
  printf 'file:%s?mode=ro\n' "$db"
}

resolve_live_tab() {
  local ro tab ws sessname tab8
  ro=$(wave_db_ro) || return 1

  # 0. The tab hosting the INITIATING shell — best signal first. The env
  # WAVETERM_TABID/BLOCKID can be STALE while still existing in the DB (a tmux
  # window outlives the block that created it and gets re-viewed from another
  # tab), so prefer live signals over the env:
  #   a. under the wave-init tmux wrapping, the session group is named
  #      wave-<tab8> (1 tab = 1 group, Wave UUIDs are stable) — the freshest
  #      binding there is; resolve tab8 back to the full oid;
  #   b. else look the spawning block (WAVETERM_BLOCKID) up in db_tab.blockids
  #      to find the tab that CURRENTLY contains it (survives block moves).
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    sessname=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null || true)
    case "$sessname" in
      wave-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
        tab8=${sessname#wave-}; tab8=${tab8%%-*}
        tab=$(sqlite3 "$ro" "SELECT oid FROM db_tab WHERE oid LIKE '${tab8}%';" 2>/dev/null)
        case "$tab" in *$'\n'*) tab="" ;; esac   # ambiguous prefix — fall through
        ;;
    esac
  fi
  if [ -z "${tab:-}" ] && [ -n "${WAVETERM_BLOCKID:-}" ]; then
    tab=$(sqlite3 "$ro" \
      "SELECT oid FROM db_tab WHERE data LIKE '%${WAVETERM_BLOCKID//\'/}%' LIMIT 1;" 2>/dev/null)
  fi
  if [ -n "${tab:-}" ] && [ "$(sqlite3 "$ro" \
        "SELECT count(*) FROM db_tab WHERE oid='${tab//\'/}';" 2>/dev/null)" = "1" ]; then
    printf '%s\n' "$tab"; return 0
  fi
  tab=""

  # 1. Trust the env tab only if it actually exists in the DB.
  if [ -n "${WAVETERM_TABID:-}" ]; then
    if [ "$(sqlite3 "$ro" \
          "SELECT count(*) FROM db_tab WHERE oid='${WAVETERM_TABID//\'/}';" \
          2>/dev/null)" = "1" ]; then
      printf '%s\n' "$WAVETERM_TABID"; return 0
    fi
  fi

  # 2. activetabid of the env workspace, else of any workspace.
  ws="${WAVETERM_WORKSPACEID:-}"
  if [ -n "$ws" ]; then
    tab=$(sqlite3 "$ro" \
      "SELECT json_extract(data,'\$.activetabid') FROM db_workspace WHERE oid='${ws//\'/}';" \
      2>/dev/null)
  fi
  [ -n "${tab:-}" ] || tab=$(sqlite3 "$ro" \
    "SELECT json_extract(data,'\$.activetabid') FROM db_workspace LIMIT 1;" 2>/dev/null)

  # Sanity-check the resolved tab actually exists as a tab row.
  if [ -n "${tab:-}" ] && [ "$(sqlite3 "$ro" \
        "SELECT count(*) FROM db_tab WHERE oid='${tab//\'/}';" 2>/dev/null)" = "1" ]; then
    printf '%s\n' "$tab"; return 0
  fi
  return 1
}

# Print "NAME|COUNT" for a tab oid: its display name (e.g. "T2") and the TOTAL
# number of tabs in Wave. Used so `open` can tell the human EXACTLY which tab to
# click — critical because Wave does NOT persist the active-tab switch to the
# state DB (so resolve_live_tab can return a tab the user isn't looking at) and
# there is NO wsh command to move the UI focus. Naming the tab is the only robust
# way to make the freshly-opened block findable. Prints nothing on failure.
tab_describe() {
  local oid="$1" ro name count
  ro=$(wave_db_ro) || return 1
  name=$(sqlite3 "$ro" \
    "SELECT json_extract(data,'\$.name') FROM db_tab WHERE oid='${oid//\'/}';" 2>/dev/null)
  count=$(sqlite3 "$ro" "SELECT count(*) FROM db_tab;" 2>/dev/null)
  [ -n "$name" ] || return 1
  printf '%s|%s\n' "$name" "${count:-1}"
}

case "$sub" in
spawn)
  # Preferred entry point. Reuses the last alive cockpit for this agent/prefix unless
  # --force/--fresh is passed. Never hijacks the generic "cockpit" name (use unique names).
  have_mux
  FORCE=0
  PREFIX=""
  for arg in "$@"; do
    case "$arg" in
      --force|--fresh) FORCE=1 ;;
      -*) echo "unknown flag: $arg (use --force to create a duplicate cockpit)" >&2; exit 2 ;;
      *) PREFIX="$arg" ;;
    esac
  done

  if [ "$FORCE" -eq 0 ] && SESS=$(find_reusable_session "$PREFIX"); then
    remember_session "$SESS"
    audit_log_start "$SESS"
    echo "reusing existing $MUX session '$SESS' (still alive — not spawning a duplicate)"
    if mux_clients "$SESS" | grep -q .; then
      echo "clients already attached — cockpit should still be visible in Wave"
    else
      echo "no client attached — re-opening Wave block"
      "$0" open "$SESS"
    fi
    echo "SESSION=$SESS"
    tty_only "Use this session for all subsequent send/read calls in this workflow." \
             "Pass --force only when you intentionally need a second cockpit window."
    exit 0
  fi

  SESS=$(unique_session_name "$PREFIX")
  create_session "$SESS"
  remember_session "$SESS"
  echo "created fresh $MUX session '$SESS'"
  "$0" open "$SESS"
  echo "SESSION=$SESS"
  tty_only "Use this session for all subsequent send/read calls in this workflow."
  ;;
status)
  have_mux
  PREFIX="${1:-}"
  norm=$(normalize_prefix "$PREFIX")
  echo "agent/prefix key: ${WSH_COCKPIT_AGENT:-${WSH_COCKPIT_PREFIX:-default}}"
  if remembered=$(last_session 2>/dev/null); then
    clients=$(mux_clients "$remembered" | wc -l | tr -d ' ')
    echo "last session: $remembered (alive, ${clients} client(s))"
  else
    f=$(state_file)
    if [ -f "$f" ]; then
      dead=$(tr -d '[:space:]' <"$f")
      echo "last session: ${dead:-?} (dead — $MUX session gone)"
    else
      echo "last session: (none recorded)"
    fi
  fi
  matches=$(mux_list_sessions | grep "^cockpit-${norm}-" || true)
  if [ -n "$matches" ]; then
    echo "matching cockpit-${norm}-* sessions:"
    printf '  %s\n' $matches
  else
    echo "matching cockpit-${norm}-* sessions: (none)"
  fi
  ;;
start)
  have_mux
  REUSE=0
  ARGS=()
  for arg in "$@"; do
    case "$arg" in
      --reuse) REUSE=1 ;;
      *) ARGS+=("$arg") ;;
    esac
  done
  if [ ${#ARGS[@]} -eq 0 ]; then
    SESS=$(unique_session_name "")
    create_session "$SESS"
    remember_session "$SESS"
    echo "created fresh $MUX session '$SESS' (no name given — auto-unique)"
  else
    SESS="${ARGS[0]}"
    if mux_has "$SESS"; then
      if [ "$REUSE" -eq 1 ]; then
        echo "session '$SESS' already exists — reusing it (--reuse)"
        remember_session "$SESS"
      else
        cat >&2 <<MSG
session '$SESS' already exists — refusing to reuse it (another agent or an earlier
cockpit may still be attached).

Use a fresh cockpit instead:
  $0 spawn [prefix]          # recommended: new session + auto-open Wave block
  $0 start                   # auto-unique session name
  $0 start '$SESS' --reuse   # only if you intentionally continue THIS session
MSG
        exit 8
      fi
    else
      create_session "$SESS"
      remember_session "$SESS"
      echo "created $MUX session '$SESS'"
    fi
  fi
  # Rich attach/drive help for a human at a TTY; just the machine line for Claude.
  if [ -t 1 ]; then
    cat <<MSG

Attach in your terminal (or in a Wave block) to watch & type alongside me:

  $(mux_attach_cmd "${SESS}")

I drive it with:
  $0 send '<command>' ${SESS}
  $0 read ${SESS}

Detach anytime with Ctrl-b then d — the session keeps running in the background.

To pop the cockpit open on the user's screen automatically (no manual attach):
  $0 open ${SESS}

SESSION=${SESS}
MSG
  else
    echo "SESSION=${SESS}"
  fi
  ;;
current)
  # Capture in one call: a bare `if last_session` would PRINT the name (spurious
  # line) and then `$(last_session)` would resolve it a second time.
  if s=$(last_session); then
    echo "SESSION=$s"
  else
    echo "no active spawned session for this agent (run: $0 spawn)" >&2
    exit 9
  fi
  ;;
doctor)
  # Read-only diagnostic of the whole cockpit chain: 11 checks, no mkdir/touch/
  # remember_session, no need_session (must run on a machine with nothing spawned
  # yet). Every check that CAN fail is wrapped in `if` or ends `|| true` so a
  # missing tmux/wsh/sqlite3/tmux-server never kills the script under set -e.
  fails=0
  if [ -t 1 ]; then
    DOC_OK=$(printf '\033[1;32m'); DOC_WARN=$(printf '\033[1;33m')
    DOC_FAIL=$(printf '\033[1;31m'); DOC_R=$(printf '\033[0m')
  else
    DOC_OK=""; DOC_WARN=""; DOC_FAIL=""; DOC_R=""
  fi
  doc_line() {  # $1 ok|warn|fail  $2 label  $3 detail
    local st="$1" label="$2" detail="$3" color="$DOC_R"
    case "$st" in
      ok)   color="$DOC_OK" ;;
      warn) color="$DOC_WARN" ;;
      fail) color="$DOC_FAIL"; fails=$((fails + 1)) ;;
    esac
    printf '%s%-4s%s %s — %s\n' "$color" "$st" "$DOC_R" "$label" "$detail"
  }

  HAVE_TMUX=0
  command -v tmux >/dev/null 2>&1 && HAVE_TMUX=1

  # 0. Which mux backend this invocation drives (WSH_MUX).
  if [ "$MUX" = tmux ]; then
    doc_line ok "backend (WSH_MUX)" "tmux (référence, toutes fonctionnalités)"
  else
    doc_line warn "backend (WSH_MUX)" "zellij (expérimental — keys/audit-log/web indisponibles)"
  fi

  # 1. tmux present + version.
  if [ "$HAVE_TMUX" -eq 1 ]; then
    ver=$(tmux -V 2>/dev/null || true)
    doc_line ok "tmux" "${ver:-present}"
  else
    doc_line fail "tmux" "introuvable — brew install tmux"
  fi

  # 2. tmux server reachable (a cold "no server" is normal, not a failure).
  if [ "$HAVE_TMUX" -eq 1 ]; then
    if tmux list-sessions >/dev/null 2>&1; then
      doc_line ok "serveur tmux" "joignable"
    else
      doc_line warn "serveur tmux" "pas de serveur actif (normal si rien n'a encore été spawné)"
    fi
  else
    doc_line warn "serveur tmux" "skip (tmux absent)"
  fi

  # 3. Live cockpit-* sessions: count + per-session attached clients / age.
  if [ "$HAVE_TMUX" -eq 1 ]; then
    sessions=$(tmux list-sessions -F '#{session_name}|#{session_attached}|#{session_created}' 2>/dev/null \
      | grep '^cockpit-' || true)
    if [ -z "$sessions" ]; then
      doc_line ok "sessions cockpit-*" "aucune"
    else
      n=$(printf '%s\n' "$sessions" | grep -c . || true)
      doc_line ok "sessions cockpit-*" "${n:-0} active(s)"
      while IFS='|' read -r nm cl cr; do
        [ -n "$nm" ] || continue
        when=$(date -r "$cr" '+%H:%M:%S' 2>/dev/null || printf '%s' "$cr")
        doc_line ok "  $nm" "${cl:-0} client(s) attaché(s), créée $when"
      done < <(printf '%s\n' "$sessions")
    fi
  else
    doc_line warn "sessions cockpit-*" "skip (tmux absent)"
  fi

  # 4. wsh present (needed for auto-open).
  if command -v wsh >/dev/null 2>&1; then
    doc_line ok "wsh" "présent ($(command -v wsh))"
  else
    doc_line warn "wsh" "absent (mode live dégradé : pas d'auto-open)"
  fi

  # 5. sqlite3 present (needed to read Wave's state DB).
  if command -v sqlite3 >/dev/null 2>&1; then
    doc_line ok "sqlite3" "présent ($(command -v sqlite3))"
  else
    doc_line warn "sqlite3" "absent (lecture DB Wave impossible)"
  fi

  # 6. Wave DB readable + a live tab resolves (reuses resolve_live_tab/tab_describe).
  if TAB=$(resolve_live_tab 2>/dev/null); then
    DESC=$(tab_describe "$TAB" 2>/dev/null || true)
    TNAME="${DESC%%|*}"
    doc_line ok "Wave DB / tab actif" "${TNAME:-$TAB}"
  else
    doc_line warn "Wave DB / tab actif" "résolution impossible (auto-open indisponible — attacher à la main)"
  fi

  # 7. State dir writable + last-session for the current agent still alive.
  if [ -d "$STATE_DIR" ]; then
    if [ -w "$STATE_DIR" ]; then
      doc_line ok "state dir" "$STATE_DIR (inscriptible)"
    else
      doc_line fail "state dir" "$STATE_DIR existe mais n'est pas inscriptible"
    fi
  else
    doc_line warn "state dir" "$STATE_DIR absent (sera créé au prochain spawn/send)"
  fi
  if s=$(last_session 2>/dev/null); then
    doc_line ok "last-session (agent courant)" "$s (vivante)"
  else
    SF=$(state_file)
    if [ -f "$SF" ]; then
      dead=$(tr -d '[:space:]' <"$SF" 2>/dev/null || true)
      doc_line warn "last-session (agent courant)" "${dead:-?} (périmée → prochain spawn recréera)"
    else
      doc_line ok "last-session (agent courant)" "aucune (jamais spawné)"
    fi
  fi

  # 8. Helpers present under $STATE_DIR/helpers with the expected versions.
  HELPER_SEP=$(helper_path sep "$SEP_HELPER_VERSION")
  if [ -f "$HELPER_SEP" ]; then
    doc_line ok "helper sep v$SEP_HELPER_VERSION" "$HELPER_SEP"
  else
    doc_line warn "helper sep v$SEP_HELPER_VERSION" "absent (régénéré au prochain send)"
  fi
  HELPER_STEP=$(helper_path step "$STEP_HELPER_VERSION")
  if [ -f "$HELPER_STEP" ]; then
    doc_line ok "helper step v$STEP_HELPER_VERSION" "$HELPER_STEP"
  else
    doc_line warn "helper step v$STEP_HELPER_VERSION" "absent (régénéré au prochain send)"
  fi

  # 9. Audit logs: dir present, total size, count of files older than 30 days
  # (should be 0 — audit_log_start purges on every session start).
  LOG_DIR="${WSH_LIVE_LOG_DIR:-$HOME/Library/Logs/wsh-cockpit}"
  if [ -d "$LOG_DIR" ]; then
    size=$(du -sh "$LOG_DIR" 2>/dev/null | awk '{print $1}' || true)
    old=$(find "$LOG_DIR" -name '*.log' -type f -mtime +30 2>/dev/null | wc -l | tr -d ' ' || true)
    case "$old" in ''|*[!0-9]*) old=0 ;; esac
    if [ "$old" -gt 0 ]; then
      doc_line warn "logs d'audit" "$LOG_DIR (${size:-?}), $old fichier(s) >30j (purge attendue)"
    else
      doc_line ok "logs d'audit" "$LOG_DIR (${size:-?}), 0 fichier >30j"
    fi
  else
    doc_line ok "logs d'audit" "$LOG_DIR absent (rien loggé pour l'instant)"
  fi

  # 10. Optional extras — never fail on absence, just note it.
  if command -v ttyd >/dev/null 2>&1; then
    doc_line ok "ttyd" "présent ($(command -v ttyd)) — utilisé par la sous-commande 'web'"
  else
    doc_line warn "ttyd" "absent (optionnel, requis pour la sous-commande 'web' : brew install ttyd)"
  fi
  if command -v zellij >/dev/null 2>&1; then
    doc_line ok "zellij" "présent ($(command -v zellij))"
  else
    doc_line warn "zellij" "absent (optionnel)"
  fi

  echo
  if [ "$fails" -gt 0 ]; then
    echo "doctor: $fails check(s) en échec" >&2
    exit 1
  fi
  echo "doctor: ok"
  ;;
web)
  # Browser view of the cockpit pane via ttyd (`brew install ttyd`). LOOPBACK
  # ONLY (-i 127.0.0.1) — ttyd never binds anything but localhost; reaching it
  # from the tailnet is the user's call via `tailscale serve` (see SKILL.md),
  # never `tailscale funnel` (that would expose the pane to the public internet).
  # Read-only by default: no `-W` on ttyd (keyboard input from the browser is
  # ignored) and the tmux client attaches with `-r` (read-only client) so a
  # random visitor with the URL can watch but not type. WSH_WEB_WRITE=1 flips
  # both: adds `-W` to ttyd and drops `-r` from the attach.
  have_mux
  [ "$MUX" = tmux ] || {
    echo "web: tmux-only (needs tmux's read-only attach; zellij ships its own: 'zellij web')" >&2; exit 13; }
  ACTION="${1:?usage: $0 web start|stop|status [session]}"
  shift || true
  case "$ACTION" in
    start|stop|status) ;;
    *) echo "usage: $0 web {start|stop|status} [session]" >&2; exit 2 ;;
  esac
  # Only `start` needs the session alive (it attaches tmux to it). `stop` and
  # `status` must work against a dead/gone session too — e.g. tearing down a
  # web view left over after the cockpit session itself already died.
  SESS=$(resolve_session "${1:-}")
  [ "$ACTION" = start ] && need_session "$SESS"
  PORT="${WSH_WEB_PORT:-7681}"
  case "$PORT" in ''|*[!0-9]*) echo "web: WSH_WEB_PORT must be a positive integer (got '$PORT')" >&2; exit 2 ;; esac
  URL="http://127.0.0.1:${PORT}"
  PIDF=$(web_pid_file "$SESS")

  web_alive_pid() {  # echoes the pid if the pidfile points at a live ttyd process
    [ -f "$PIDF" ] || return 1
    local p; p=$(tr -d '[:space:]' <"$PIDF")
    [ -n "$p" ] || return 1
    if web_pid_is_ttyd "$p"; then
      printf '%s\n' "$p"
      return 0
    else
      # PID exists but isn't ttyd (recycled or wrong process) — treat as dead and clean up
      rm -f "$PIDF" 2>/dev/null || true
      return 1
    fi
  }

  case "$ACTION" in
  start)
    command -v ttyd >/dev/null 2>&1 || {
      echo "ttyd not found — install it on the Mac: brew install ttyd" >&2; exit 3; }
    command -v curl >/dev/null 2>&1 || {
      echo "curl not found — cannot verify the web view came up" >&2; exit 3; }
    if PID=$(web_alive_pid); then
      echo "web view already running for '$SESS' (pid $PID) — $URL"
      exit 0
    fi
    rm -f "$PIDF" 2>/dev/null || true

    TMUX_BIN=$(command -v tmux)
    WRITE="${WSH_WEB_WRITE:-0}"
    ttyd_args=(-p "$PORT" -i 127.0.0.1)
    attach_args=(attach)
    if [ "$WRITE" = "1" ]; then
      ttyd_args+=(-W)
    else
      attach_args+=(-r)
    fi
    attach_args+=(-t "$SESS")

    mkdir -p "$STATE_DIR"
    nohup ttyd "${ttyd_args[@]}" "$TMUX_BIN" "${attach_args[@]}" >/dev/null 2>&1 &
    PID=$!
    disown 2>/dev/null || true
    printf '%s\n' "$PID" >"$PIDF"
    chmod 600 "$PIDF" 2>/dev/null || true

    UP=0
    for _ in 1 2 3 4 5 6; do
      CODE=$(curl -s -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null || true)
      [ "$CODE" = "200" ] && { UP=1; break; }
      sleep 0.5
    done
    if [ "$UP" -ne 1 ]; then
      kill "$PID" 2>/dev/null || true
      rm -f "$PIDF" 2>/dev/null || true
      echo "web view failed to start on ${URL} (ttyd pid ${PID} not answering after 3s)" >&2
      exit 1
    fi
    # curl 200 alone isn't proof OUR ttyd came up: if the port was already taken
    # by another process (e.g. a different session's ttyd), our ttyd fails to
    # bind and dies, while curl still gets 200 from the OTHER process — a false
    # success that would leave the caller thinking THIS session has a working
    # web view when it doesn't. When the port collision is what made curl
    # succeed, it typically does so on the very first attempt (hitting the
    # OTHER process instantly), before our own losing ttyd has even reached its
    # bind() call — empirically ttyd takes ~70-100ms to discover EADDRINUSE and
    # exit. Give it that grace window before trusting `kill -0`.
    sleep 0.3
    if ! kill -0 "$PID" 2>/dev/null; then
      rm -f "$PIDF" 2>/dev/null || true
      echo "web: ttyd died at startup — port ${PORT} already in use? (set WSH_WEB_PORT)" >&2
      exit 1
    fi

    echo "web view started: ${URL} (pid $PID, session '$SESS')"
    if [ "$WRITE" = "1" ]; then
      echo "mode: READ-WRITE (WSH_WEB_WRITE=1) — anyone reaching this URL can type into the pane"
    else
      echo "mode: read-only (default) — set WSH_WEB_WRITE=1 for a writable view"
    fi
    echo "loopback only ; from the tailnet: tailscale serve --bg ${PORT} (never 'funnel' — see SKILL.md)"
    ;;
  stop)
    if PID=$(web_alive_pid); then
      web_teardown "$SESS"
      echo "web view stopped (pid $PID)"
    elif [ -f "$PIDF" ]; then
      web_teardown "$SESS"
      echo "nothing to stop (stale pidfile removed)"
    else
      echo "nothing to stop (no web view running for '$SESS')"
    fi
    ;;
  status)
    if PID=$(web_alive_pid); then
      echo "web view: running (pid $PID, port $PORT) — $URL"
    else
      echo "web view: stopped"
    fi
    ;;
  esac
  ;;
banner)
  # Airy visual step announcement — sources wsh-step.sh's __wsh_banner once, then
  # sends a short call. NOT the default send framing. WSH_STEP_INLINE=1 forces the
  # self-contained one-liner (for an ssh-hopped pane without the helper file).
  have_mux
  TYPE="${1:?usage: wsh-live.sh banner <header|phase|step|done> [args...] [session]}"
  shift || true
  case "$TYPE" in header|phase|step|done) ;; *)
    echo "banner: unknown type '$TYPE' (want header|phase|step|done)" >&2; exit 11 ;;
  esac
  SESS=""
  # Optional session is only recognized when it is the sole remaining argument.
  if [ $# -gt 1 ] && mux_has "${!#}"; then
    SESS="${!#}"
    set -- "${@:1:$#-1}"
  fi
  STEP_SCRIPT="$(cd "$(dirname "$0")" && pwd)/wsh-step.sh"
  [ -f "$STEP_SCRIPT" ] || { echo "missing $STEP_SCRIPT" >&2; exit 10; }
  SESS=$(resolve_session "$SESS"); need_session "$SESS"
  if [ "${WSH_STEP_INLINE:-0}" = "1" ]; then
    CMD=$("$STEP_SCRIPT" cmd "$TYPE" "$@") || { echo "banner build failed for: $TYPE $*" >&2; exit 11; }
  else
    CALL=$(step_build_call "$TYPE" "$@")
    if step_helpers_loaded "$SESS"; then
      CMD="$CALL"
    else
      HELPER=$(step_ensure_helpers)
      HELPER_Q=${HELPER//\'/\'\\\'\'}
      CMD=". '${HELPER_Q}' && ${CALL}"
      step_mark_helpers_loaded "$SESS"
    fi
  fi
  mux_send_line "$SESS" "$CMD"
  if [ -t 1 ]; then echo "banner -> ${SESS}: ${TYPE} $*"; else echo "banner ${TYPE} -> ${SESS}"; fi
  ;;
wait-done)
  # Block until the framed footer for a `send` appears in the pane — never race the next send.
  have_mux
  local_sess=""
  timeout_sec=""
  target_seq=""
  for arg in "$@"; do
    if [ -z "$local_sess" ] && mux_has "$arg"; then
      local_sess="$arg"
    elif [ -z "$timeout_sec" ] && [[ "$arg" =~ ^[0-9]+$ ]]; then
      timeout_sec="$arg"
    elif [ -z "$target_seq" ] && [[ "$arg" =~ ^[0-9]+$ ]]; then
      target_seq="$arg"
    fi
  done
  SESS=$(resolve_session "${local_sess:-}"); need_session "$SESS"
  TIMEOUT="${timeout_sec:-${WSH_WAIT_TIMEOUT:-300}}"
  if [ -z "$target_seq" ]; then
    target_seq=$(cat "$(seq_file "$SESS")" 2>/dev/null || true)
  fi
  [ -n "$target_seq" ] || { echo "no pending send seq for '$SESS' (run send first)" >&2; exit 12; }
  echo "waiting for send #[${target_seq}] in '${SESS}' (timeout ${TIMEOUT}s)..."
  SECONDS=0
  set -- 0.2 0.3 0.5 1
  while [ "$SECONDS" -lt "$TIMEOUT" ]; do
    pane=$(mux_capture "$SESS" 120 | sed $'s/\x1b\\[[0-9;]*m//g')
    if printf '%s\n' "$pane" | grep -qE "└─\\[#${target_seq}\\] exit [0-9]+"; then
      rc=$(printf '%s\n' "$pane" | grep -oE "└─\\[#${target_seq}\\] exit [0-9]+" | tail -1 | grep -oE '[0-9]+$')
      echo "done: #[${target_seq}] exit ${rc} (${SECONDS}s)"
      [ "${rc:-1}" -eq 0 ] && exit 0 || exit "${rc:-1}"
    fi
    if [ $# -gt 0 ]; then sleep "$1"; shift; else sleep 2; fi
  done
  echo "timeout: #[${target_seq}] footer not seen after ${TIMEOUT}s" >&2
  exit 124
  ;;
open)
  # Auto-open a VISIBLE Wave block attached to the shared cockpit, so the user
  # doesn't have to type `tmux attach` themselves. Robust to a stale Wave env.
  have_mux
  SESS=$(resolve_session "${1:-}"); need_session "$SESS"
  if [ "$MUX" = tmux ]; then MUX_BIN=$(command -v tmux); else MUX_BIN=$(zellij_bin); fi
  ATTACH=$(mux_attach_cmd "$SESS")
  command -v wsh >/dev/null 2>&1 || {
    echo "wsh not found — can't auto-open a Wave block. Attach by hand:" >&2
    echo "  ${ATTACH}" >&2; exit 5; }

  if ! TAB=$(resolve_live_tab); then
    cat >&2 <<MSG
could not find a live Wave tab to anchor the block on (stale/empty Wave state).
Ask the user to attach manually in any terminal or Wave block:

  ${ATTACH}
MSG
    exit 6
  fi

  # Anchor on the LIVE tab (overriding any stale WAVETERM_TABID), and exec the
  # mux by ABSOLUTE path because the Wave block's shell lacks the homebrew PATH.
  if [ "$MUX" = tmux ]; then EXEC_CMD="exec '$MUX_BIN' attach -t '$SESS'"
  else EXEC_CMD="exec '$MUX_BIN' attach '$SESS'"; fi
  OUT=$(WAVETERM_TABID="$TAB" wsh run -c "$EXEC_CMD" 2>&1) || true
  NEWID=$(printf '%s' "$OUT" | grep -oE 'block:[0-9a-f-]+' | head -1 | cut -d: -f2)
  if [ -z "$NEWID" ]; then
    cat >&2 <<MSG
wsh run failed to open the attach block:
$OUT
Fallback — ask the user to attach manually:

  ${ATTACH}
MSG
    exit 7
  fi

  # Verify a client actually joined (the attach can fail silently inside the
  # block, e.g. wrong tmux/path); give it a moment, then confirm.
  for _ in 1 2 3 4 5; do
    mux_clients "$SESS" | grep -q . && break
    sleep 1
  done
  if mux_clients "$SESS" | grep -q .; then
    # Resolve the tab's human NAME + total tab count. Wave doesn't persist the
    # active-tab switch and exposes no focus command, so the block can land on a
    # tab the user isn't looking at ("I don't see it"). When more than one tab
    # exists, tell them EXACTLY which named tab to click.
    DESC=$(tab_describe "$TAB" 2>/dev/null || true)
    TNAME="${DESC%%|*}"; TCOUNT="${DESC##*|}"
    echo "opened Wave block ${NEWID} attached to '${SESS}' (on tab ${TNAME:-$TAB})"
    if [ -n "$TNAME" ] && [ "${TCOUNT:-1}" -gt 1 ] 2>/dev/null; then
      echo "👉 the cockpit is on tab «${TNAME}» — click that tab in Wave to see it (you may be on another tab)."
    fi
  else
    echo "block ${NEWID} created on tab ${TAB}, but no client attached to '${SESS}' yet" >&2
    echo "if it stays empty, ask the user to attach manually: ${ATTACH}" >&2
  fi
  ;;
selftest-sep)
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/wsh-live-sep-test.XXXXXX")
  trap 'rm -rf "$tmpdir"' EXIT
  helper="$tmpdir/live-sep-helper.sh"
  sep_helper_defs >"$helper"
  chmod 600 "$helper" 2>/dev/null || true

  failures=0
  run_sep_case() {
    local shell_bin="$1" label="$2" cmd="$3" expect="$4" want_rc="$5"
    local line out rc
    if ! command -v "$shell_bin" >/dev/null 2>&1; then
      echo "skip $label ($shell_bin not found)"
      return 0
    fi
    line=$(sep_wrap "99" "$cmd" "$helper")
    set +e
    out=$("$shell_bin" -c "$line" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne "$want_rc" ]; then
      echo "FAIL $label: rc=$rc want=$want_rc" >&2
      printf '%s\n' "$out" >&2
      failures=$((failures + 1))
      return 0
    fi
    if ! printf '%s\n' "$out" | grep -Fq "$expect"; then
      echo "FAIL $label: missing expected output: $expect" >&2
      printf '%s\n' "$out" >&2
      failures=$((failures + 1))
      return 0
    fi
    if ! printf '%s\n' "$out" | grep -Fq "└─[#99] exit $want_rc"; then
      echo "FAIL $label: missing footer exit $want_rc" >&2
      printf '%s\n' "$out" >&2
      failures=$((failures + 1))
      return 0
    fi
    echo "ok $label"
  }

  for shell_bin in bash zsh; do
    run_sep_case "$shell_bin" "$shell_bin quotes+pipe" \
      "printf \"alpha\\nquote: 'x'\\n\" | sed -n \"2p\"" "quote: 'x'" 0
    run_sep_case "$shell_bin" "$shell_bin group+redirect+subshell" \
      'tmp=/tmp/wsh-v4-selftest.$$; { echo one; echo two; } > "$tmp"; (wc -l < "$tmp"; rm "$tmp")' "2" 0
    run_sep_case "$shell_bin" "$shell_bin variables+logic" \
      'name="Q V"; echo "name=$name sub=$(printf ok)"; false || echo recovered; true && echo chained' "chained" 0
    run_sep_case "$shell_bin" "$shell_bin nonzero" \
      'sh -c "exit 7"' "exit 7" 7
  done

  if [ "$failures" -ne 0 ]; then
    echo "selftest-sep: $failures failure(s)" >&2
    exit 1
  fi
  echo "selftest-sep: ok"
  ;;
selftest-live)
  # End-to-end smoke test on a real, throwaway tmux session — exercises the
  # actual live loop (start → send → wait-done → read → banner → stop) with NO
  # Wave block ever opened (never calls spawn/open). WSH_COCKPIT_AGENT=selftest
  # isolates the last-session state file from whatever agent/prefix is normally
  # driving this cockpit, so this test never clobbers a real workflow's session.
  have_mux
  export WSH_COCKPIT_AGENT=selftest
  SESS="cockpit-selftest-$$"
  SF="$(state_file)"
  SEQF="$(seq_file "$SESS")"
  LIVE_LOG_DIR="${WSH_LIVE_LOG_DIR:-$HOME/Library/Logs/wsh-cockpit}"
  LIVE_LOG_SLUG=$(printf '%s' "$SESS" | tr -cs 'A-Za-z0-9_.-' '_')
  LIVE_LOG_FILE="$LIVE_LOG_DIR/${LIVE_LOG_SLUG}.log"

  # Idempotent cleanup, posed BEFORE the first `start`: `$0 stop` already kills
  # the session and (when it matches the recorded last-session) removes the seq
  # file and $SF itself; the explicit rm's here are a defensive belt-and-braces
  # so a failed/partial run never leaves the selftest state file or its audit
  # log behind, even if `stop` couldn't match for some reason.
  live_selftest_cleanup() {
    "$0" stop "$SESS" >/dev/null 2>&1 || true
    rm -f "$SF" 2>/dev/null || true
    rm -f "$LIVE_LOG_FILE" 2>/dev/null || true
  }
  trap live_selftest_cleanup EXIT

  failures=0
  report_live_case() {  # $1 label  $2 rc (0=ok)  $3 detail (shown on failure)
    if [ "$2" -eq 0 ]; then
      echo "ok $1"
    else
      echo "FAIL $1${3:+: $3}" >&2
      failures=$((failures + 1))
    fi
  }
  run_live_case() {  # $1 label  $2 haystack  $3 needle (fixed string)
    if printf '%s\n' "$2" | grep -Fq "$3"; then
      report_live_case "$1" 0
    else
      report_live_case "$1" 1 "missing '$3' in: $2"
    fi
  }

  # 1. start prints SESSION=$SESS
  set +e
  out=$("$0" start "$SESS" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    run_live_case "1 start" "$out" "SESSION=$SESS"
  else
    report_live_case "1 start" 1 "rc=$rc out=$out"
  fi

  # 2. send + wait-done → rc 0 (no sleep needed: wait-done polls the footer)
  set +e
  "$0" send 'echo LIVE_OK_$((6*7))' "$SESS" >/dev/null 2>&1
  "$0" wait-done "$SESS" 30 >/dev/null 2>&1
  rc=$?
  set -e
  report_live_case "2 send+wait-done rc0" "$rc" "rc=$rc"

  # 3. read shows the command's output AND the framed exit-0 footer for #1
  out=$("$0" read "$SESS" 40 2>&1)
  if printf '%s\n' "$out" | grep -Fq "LIVE_OK_42" \
     && printf '%s\n' "$out" | grep -Fq '└─[#1] exit 0'; then
    report_live_case "3 read" 0
  else
    report_live_case "3 read" 1 "missing LIVE_OK_42 and/or └─[#1] exit 0"
  fi

  # 4. a nonzero exit propagates through wait-done's own exit code EXACTLY
  set +e
  "$0" send 'sh -c "exit 3" 2>&1' "$SESS" >/dev/null 2>&1
  "$0" wait-done "$SESS" 30 >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 3 ]; then
    report_live_case "4 wait-done rc3" 0
  else
    report_live_case "4 wait-done rc3" 1 "rc=$rc want=3"
  fi

  # 5. banner (step) renders — banner never advances the send-seq counter, so
  # the seq file is still 2 going into check 7 below.
  "$0" banner step 9.9 'selftest banner' "$SESS" >/dev/null 2>&1
  sleep 1
  out=$("$0" read "$SESS" 30 2>&1)
  run_live_case "5 banner" "$out" '[9.9]'

  # 6. audit log — only when logging is enabled (WSH_LIVE_LOG default 1) and
  # the backend is tmux (pipe-pane is tmux-only; zellij runs unlogged).
  if [ "${WSH_LIVE_LOG:-1}" = "1" ] && [ "$MUX" = tmux ]; then
    if [ -f "$LIVE_LOG_FILE" ] && grep -Fq "LIVE_OK_42" "$LIVE_LOG_FILE"; then
      report_live_case "6 audit log" 0
    else
      report_live_case "6 audit log" 1 "$LIVE_LOG_FILE missing or lacks LIVE_OK_42"
    fi
  elif [ "$MUX" != tmux ]; then
    echo "skip 6 audit log (backend $MUX — pipe-pane is tmux-only)"
  else
    echo "skip 6 audit log (WSH_LIVE_LOG=0)"
  fi

  # 7. seq file holds 2 — one increment per `send` (step 2 and step 4), the
  # step-5 banner does not touch it.
  seqval=$(cat "$SEQF" 2>/dev/null || true)
  if [ "$seqval" = "2" ]; then
    report_live_case "7 seq file" 0
  else
    report_live_case "7 seq file" 1 "seq=$seqval want=2"
  fi

  # 8. stop kills the session and removes its seq file
  "$0" stop "$SESS" >/dev/null 2>&1 || true
  if mux_has "$SESS"; then
    report_live_case "8 stop" 1 "session '$SESS' still alive"
  elif [ -f "$SEQF" ]; then
    report_live_case "8 stop" 1 "seq file still present: $SEQF"
  else
    report_live_case "8 stop" 0
  fi

  if [ "$failures" -ne 0 ]; then
    echo "selftest-live: $failures failure(s)" >&2
    exit 1
  fi
  echo "selftest-live: ok"
  ;;
send)
  have_mux
  CMD="${1:?usage: wsh-live.sh send '<command>' [session]}"
  SESS=$(resolve_session "${2:-}"); need_session "$SESS"
  # WSH_LIVE_SEP (default 1): frame the command with header/footer banners so the
  # watching human can clearly tell each call + its output apart. Set to 0 to send
  # the raw command verbatim (e.g. when driving a TUI that dislikes extra noise).
  if [ "${WSH_LIVE_SEP:-1}" = "0" ]; then
    LINE="$CMD"
  else
    SEQ=$(sep_next_seq "$SESS")
    if [ "${WSH_LIVE_SEP_REINIT:-0}" = "1" ]; then
      LINE=$(sep_wrap_inline "$SEQ" "$CMD")
    elif sep_helpers_loaded "$SESS"; then
      LINE=$(sep_wrap "$SEQ" "$CMD")
    else
      HELPER=$(sep_ensure_helpers)
      LINE=$(sep_wrap "$SEQ" "$CMD" "$HELPER")
      sep_mark_helpers_loaded "$SESS"
    fi
  fi
  # -l sends the text literally (so a command that happens to read like a tmux
  # key name isn't interpreted); Enter is a separate keypress.
  mux_send_line "$SESS" "$LINE"
  # Terse for Claude (it wrote $CMD, knows it); the seq is what `wait-done` chains on.
  # Echo the full command back only for a human watching the script's own stdout.
  if [ -t 1 ]; then echo "sent${SEQ:+ #$SEQ} -> ${SESS}: $CMD"
  else echo "sent${SEQ:+ #$SEQ} -> ${SESS}"; fi
  ;;
keys)
  have_mux
  K="${1:?usage: wsh-live.sh keys '<tmux-keys>' [session]}"
  SESS=$(resolve_session "${2:-}"); need_session "$SESS"
  [ "$MUX" = tmux ] || {
    echo "keys: tmux-only (raw tmux key names have no zellij equivalent; use send)" >&2; exit 13; }
  # No -l here: tmux key names are meant to be interpreted (C-c, Up, PageUp...).
  # shellcheck disable=SC2086
  tmux send-keys -t "$SESS" $K
  echo "keys -> ${SESS}: $K"
  ;;
read)
  have_mux
  if [ -n "${1:-}" ] && [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    SESS=$(resolve_session "")
    LINES="$1"
  else
    SESS=$(resolve_session "${1:-}")
    LINES="${2:-30}"
  fi
  need_session "$SESS"
  # capture-pane pads the bottom of the screen with blank lines; trim the
  # trailing blanks so output ends at the last real line (the live prompt).
  mux_capture "$SESS" "${LINES}" | awk '
    { l[NR]=$0 }
    END { e=NR; while (e>0 && l[e] ~ /^[[:space:]]*$/) e--; for (i=1;i<=e;i++) print l[i] }'
  ;;
stop)
  have_mux
  # Resolve WITHOUT requiring the session to be alive: resolve_session falls back to
  # the generic "cockpit" once the session is dead (last_session needs has-session),
  # so a no-arg `stop` after a crash would target the wrong name. Prefer the explicit
  # arg, else the RAW remembered name from the state file. Guard the file read with
  # `[ -f ]` — the `<file` redirection failure is reported by the shell itself, NOT
  # caught by tr's `2>/dev/null`, so an absent state file would leak to stderr.
  SF=$(state_file)
  if [ -n "${1:-}" ]; then
    SESS="$1"
  else
    SESS=""; [ -f "$SF" ] && SESS=$(tr -d '[:space:]' <"$SF")
    [ -n "$SESS" ] || SESS="$SESS_DEFAULT"
  fi
  rm -f "$(seq_file "$SESS")" 2>/dev/null || true
  if [ "$MUX" = tmux ]; then
    tmux set-option -u -t "$SESS" "$(sep_helper_option "$SESS")" >/dev/null 2>&1 || true
    tmux set-option -u -t "$SESS" "$(step_helper_option "$SESS")" >/dev/null 2>&1 || true
  fi
  web_teardown "$SESS"
  if mux_kill "$SESS"; then
    echo "killed session '$SESS'"
  else
    echo "no session '$SESS' to kill"
  fi
  # Forget the remembered session if it pointed at the one we just stopped.
  if [ -f "$SF" ] && [ "$(tr -d '[:space:]' <"$SF")" = "$SESS" ]; then
    rm -f "$SF" 2>/dev/null || true
  fi
  ;;
*)
  echo "usage: $0 {spawn|start|open|send|keys|read|stop|current|doctor|status|web|banner|wait-done|selftest-sep|selftest-live} [args]" >&2; exit 2 ;;
esac
