#!/usr/bin/env bash
# lib/web.sh — browser view of the cockpit pane via ttyd (loopback-only).
# Sourced by wsh-live.sh; not meant to be run standalone.

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

# Browser view of the cockpit pane via ttyd (`brew install ttyd`). LOOPBACK
# ONLY (-i 127.0.0.1) — ttyd never binds anything but localhost; reaching it
# from the tailnet is the user's call via `tailscale serve` (see SKILL.md),
# never `tailscale funnel` (that would expose the pane to the public internet).
# Read-only by default: no `-W` on ttyd (keyboard input from the browser is
# ignored) and the tmux client attaches with `-r` (read-only client) so a
# random visitor with the URL can watch but not type. WSH_WEB_WRITE=1 flips
# both: adds `-W` to ttyd and drops `-r` from the attach.
cmd_web() {
  have_mux
  [ "$MUX" = tmux ] || {
    echo "web: tmux-only (needs tmux's read-only attach; zellij ships its own: 'zellij web')" >&2; exit 13; }
  local ACTION
  ACTION="${1:?usage: $0 web start|stop|status [session]}"
  shift || true
  case "$ACTION" in
    start|stop|status) ;;
    *) echo "usage: $0 web {start|stop|status} [session]" >&2; exit 2 ;;
  esac
  # Only `start` needs the session alive (it attaches tmux to it). `stop` and
  # `status` must work against a dead/gone session too — e.g. tearing down a
  # web view left over after the cockpit session itself already died.
  local SESS PORT URL PIDF
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

  local PID TMUX_BIN WRITE ttyd_args attach_args UP CODE
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
}
