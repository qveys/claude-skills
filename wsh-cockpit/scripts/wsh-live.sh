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
#   remote-init [session] [host]
#                              call once after an ssh hop lands the pane on a remote host.
#                              With [host]: pushes the sep/step helper files there (via
#                              wsh-push.sh) so send/banner keep using the short sourcing
#                              form, now against the REMOTE path — falls back to inline
#                              framing if the push fails. Without [host]: sticky inline-
#                              only mode (send/banner default to the self-contained blob).
#   local-init  [session]      revert remote-init — back to local helper-file framing
#   wait-done [session] [timeout_sec] [seq]
#                              block until last `send` footer shows exit (before next send)
#   selftest-live              end-to-end smoke test on a throwaway cockpit-selftest-$$
#                              session (start/send/wait-done/read/banner/remote-init/
#                              local-init/stop, NO Wave block — never calls spawn/open);
#                              rc 0/1
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

# CDPATH= : a matching CDPATH entry makes `cd` PRINT the directory, which would
# be captured into the variable and break the lib/*.sh sourcing below.
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
# shellcheck source=./lib/mux.sh
. "$SCRIPT_DIR/lib/mux.sh"
# shellcheck source=./lib/framing.sh
. "$SCRIPT_DIR/lib/framing.sh"
# shellcheck source=./lib/wave.sh
. "$SCRIPT_DIR/lib/wave.sh"
# shellcheck source=./lib/session.sh
. "$SCRIPT_DIR/lib/session.sh"
# shellcheck source=./lib/doctor.sh
. "$SCRIPT_DIR/lib/doctor.sh"
# shellcheck source=./lib/web.sh
. "$SCRIPT_DIR/lib/web.sh"
# shellcheck source=./lib/selftests.sh
. "$SCRIPT_DIR/lib/selftests.sh"

sub="${1:-}"; shift || true

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
  cmd_doctor
  ;;
web)
  cmd_web "$@"
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
  STEP_SCRIPT="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/wsh-step.sh"
  [ -f "$STEP_SCRIPT" ] || { echo "missing $STEP_SCRIPT" >&2; exit 10; }
  SESS=$(resolve_session "$SESS"); need_session "$SESS"
  # Explicit WSH_STEP_INLINE always wins (one-off override); otherwise fall
  # back to the session's sticky remote-mode flag (see remote-init).
  REMOTE_STEP_PATH=""
  if [ -n "${WSH_STEP_INLINE+x}" ]; then
    USE_INLINE="$WSH_STEP_INLINE"
  elif remote_mode_get "$SESS"; then
    REMOTE_STEP_PATH=$(remote_helper_path_get "$SESS" step)
    if [ -n "$REMOTE_STEP_PATH" ]; then USE_INLINE=0; else USE_INLINE=1; fi
  else
    USE_INLINE=0
  fi
  if [ "$USE_INLINE" = "1" ]; then
    CMD=$("$STEP_SCRIPT" cmd "$TYPE" "$@") || { echo "banner build failed for: $TYPE $*" >&2; exit 11; }
  elif [ -n "$REMOTE_STEP_PATH" ]; then
    # Remote mode with a helper pushed by `remote-init <sess> <host>`: source
    # the REMOTE copy every call — same no-tracking rationale as send/sep above.
    CALL=$(step_build_call "$TYPE" "$@")
    REMOTE_STEP_Q=${REMOTE_STEP_PATH//\'/\'\\\'\'}
    CMD=". '${REMOTE_STEP_Q}' && ${CALL}"
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
remote-init)
  # Call once, right after confirming (via the mandatory situate probe) that
  # the pane has ssh-hopped to a remote host.
  #
  # No [host] given: sticky inline-only mode — send/banner default to the
  # self-contained inline framing for THIS session from then on, no need to
  # repeat WSH_LIVE_SEP_REINIT=1/WSH_STEP_INLINE=1 on every subsequent call.
  #
  # [host] given: try to PUSH the local sep/step helper files to that host
  # (via wsh-push.sh, same connection string `tailscale ssh`/`scp` would
  # accept) so send/banner can use the SAME short sourcing form there too —
  # inline framing becomes the fallback (push unavailable/failed), not the
  # only option. One hop only: hopping again from the remote host to a THIRD
  # host isn't tracked — falls back to inline there, still correct.
  have_mux
  SESS=$(resolve_session "${1:-}"); need_session "$SESS"
  HOST="${2:-}"
  if [ -z "$HOST" ]; then
    remote_mode_set "$SESS" 1
    echo "remote mode ON for '$SESS' — send/banner now default to inline framing (local-init to revert)"
  else
    PUSH_SCRIPT="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/wsh-push.sh"
    PUSHED=0
    if [ ! -f "$PUSH_SCRIPT" ]; then
      echo "warn: missing $PUSH_SCRIPT — falling back to inline-only remote mode" >&2
    else
      # Resolve the remote $HOME through the pane itself (visibly framed, like
      # every other cockpit command) rather than assume a path shape — the
      # remote path is later embedded in single-quoted contexts inside
      # wsh-push.sh's scp/tailscale-ssh fallbacks, where a literal '~' is NOT
      # guaranteed to expand.
      set +e
      WSH_LIVE_SEP_REINIT=1 "$0" send 'printf "WSH_REMOTE_HOME=%s\n" "$HOME"' "$SESS" >/dev/null 2>&1
      "$0" wait-done "$SESS" 30 >/dev/null 2>&1
      HRC=$?
      set -e
      RHOME=""
      if [ "$HRC" -eq 0 ]; then
        RHOME=$("$0" read "$SESS" 40 2>&1 | tr -d '\r' | grep -o 'WSH_REMOTE_HOME=.*' | tail -n1 | cut -d= -f2-)
      fi
      if [ -z "$RHOME" ]; then
        echo "warn: could not resolve \$HOME on '$HOST' — falling back to inline-only remote mode" >&2
      else
        REMOTE_DIR="${RHOME}/.cache/wsh-cockpit/helpers"
        set +e
        WSH_LIVE_SEP_REINIT=1 "$0" send "mkdir -p '${REMOTE_DIR}'" "$SESS" >/dev/null 2>&1
        "$0" wait-done "$SESS" 30 >/dev/null 2>&1
        MKRC=$?
        set -e
        if [ "$MKRC" -ne 0 ]; then
          echo "warn: could not create $REMOTE_DIR on '$HOST' (rc=$MKRC) — falling back to inline-only remote mode" >&2
        else
          LOCAL_SEP=$(sep_ensure_helpers)
          LOCAL_STEP=$(step_ensure_helpers)
          REMOTE_SEP="${REMOTE_DIR}/$(basename "$LOCAL_SEP")"
          REMOTE_STEP="${REMOTE_DIR}/$(basename "$LOCAL_STEP")"
          set +e
          "$PUSH_SCRIPT" "$LOCAL_SEP" "$REMOTE_SEP" "$HOST" >/dev/null 2>&1
          PRC1=$?
          "$PUSH_SCRIPT" "$LOCAL_STEP" "$REMOTE_STEP" "$HOST" >/dev/null 2>&1
          PRC2=$?
          set -e
          if [ "$PRC1" -eq 0 ] && [ "$PRC2" -eq 0 ]; then
            remote_helper_path_set "$SESS" sep "$REMOTE_SEP"
            remote_helper_path_set "$SESS" step "$REMOTE_STEP"
            PUSHED=1
          else
            echo "warn: wsh-push.sh failed to push helpers to '$HOST' (sep rc=$PRC1 step rc=$PRC2) — falling back to inline-only remote mode" >&2
          fi
        fi
      fi
    fi
    remote_mode_set "$SESS" 1
    if [ "$PUSHED" = "1" ]; then
      echo "remote mode ON for '$SESS' — helpers pushed to '$HOST':$REMOTE_DIR; send/banner source them there (local-init to revert)"
    else
      echo "remote mode ON for '$SESS' — inline framing only (helper push to '$HOST' unavailable; local-init to revert)"
    fi
  fi
  ;;
local-init)
  # Revert a session back to local (helper-file-sourcing) framing — e.g. after
  # `exit`ing an ssh hop back to the Mac's own shell in the same pane. Clears
  # the sticky flag AND any recorded remote helper paths from a hosted
  # remote-init, so a later no-arg remote-init on the same session starts clean.
  have_mux
  SESS=$(resolve_session "${1:-}"); need_session "$SESS"
  remote_mode_set "$SESS" 0
  remote_helper_path_clear "$SESS" sep
  remote_helper_path_clear "$SESS" step
  echo "remote mode OFF for '$SESS' — send/banner back to local helper-file framing"
  ;;
selftest-sep)
  cmd_selftest_sep
  ;;
selftest-live)
  cmd_selftest_live
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
    # Explicit WSH_LIVE_SEP_REINIT always wins (one-off override); otherwise
    # fall back to the session's sticky remote-mode flag (see remote-init).
    REMOTE_SEP_PATH=""
    if [ -n "${WSH_LIVE_SEP_REINIT+x}" ]; then
      USE_INLINE="$WSH_LIVE_SEP_REINIT"
    elif remote_mode_get "$SESS"; then
      REMOTE_SEP_PATH=$(remote_helper_path_get "$SESS" sep)
      if [ -n "$REMOTE_SEP_PATH" ]; then USE_INLINE=0; else USE_INLINE=1; fi
    else
      USE_INLINE=0
    fi
    if [ "$USE_INLINE" = "1" ]; then
      LINE=$(sep_wrap_inline "$SEQ" "$CMD")
    elif [ -n "$REMOTE_SEP_PATH" ]; then
      # Remote mode with a helper pushed by `remote-init <sess> <host>`:
      # source the REMOTE copy every send — no "loaded once" tracking for
      # this case (sourcing a small file is cheap; skipping that state saves
      # a second bug surface for no real gain).
      LINE=$(sep_wrap "$SEQ" "$CMD" "$REMOTE_SEP_PATH")
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
  echo "usage: $0 {spawn|start|open|send|keys|read|stop|current|doctor|status|web|banner|remote-init|local-init|wait-done|selftest-sep|selftest-live} [args]" >&2; exit 2 ;;
esac
