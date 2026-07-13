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
#   spawn [prefix] [--force] [--situate] [--pre <host>]
#                              open/reuse cockpit: reuse last alive session by default;
#                              --force always creates a fresh session + auto-open Wave;
#                              --situate also runs the hostname/pwd/whoami probe
#                              (send + wait-done + read) internally before returning,
#                              so the caller sees where the shell actually is in one call
#                              — and if the probed hostname differs from this Mac's, it
#                              auto-calls `remote-init` (best-effort, falls back to inline
#                              framing with a warning); --pre <host> is the RECOMMENDED
#                              path when the target host is already known: it pre-stages
#                              the helpers on <host> before the pane even ssh-hops there
#                              (shorthand for `remote-init --pre <host>` right after spawn)
#   start [session] [--reuse]  create the session + print the attach command
#   open  [session]            AUTO-OPEN a visible Wave block attached to the session
#   send  '<command>' [sess]   type a command into the pane and press Enter
#   keys  '<tmux-keys>' [sess] send raw tmux keys (C-c, Up, Enter, q ...) verbatim
#   read  [session] [lines]    print the current pane (default 30 lines back) — free-form
#                              scrollback inspection (TUI/REPL, unframed pane); when the
#                              pane IS framed, prefer `output` below (nothing to guess)
#   output [session] [seq] [--full]
#                              print EXACTLY the framed segment for send #<seq> — header
#                              through footer inclusive, delimited by the ┌─[#N]/└─[#N]
#                              exit <code> markers already in the pane, so there is no
#                              line count to guess (default seq = the last one sent, read
#                              from the same counter `send` writes). Capped at WSH_READ_MAX
#                              lines (default 120): a longer segment prints the first ~30 +
#                              a "K lignes omises" note + the last ~60 (the tail carries
#                              errors and the exit code); `--full` disables the cap.
#                              Falls back to a clear stderr message — never a silent guess
#                              — when the segment isn't in the captured scrollback, or the
#                              pane has no markers at all (WSH_LIVE_SEP=0, `keys`, a TUI):
#                              use `read N` there instead.
#   stop  [session]            kill the session
#   current                    print the last session created by `spawn` in this shell tree
#   doctor                     read-only diagnostic of the whole cockpit chain (11 checks,
#                              rc 0/1, never writes anything — safe to run anytime)
#   gc [--dry-run] [--idle=SECONDS]
#                              kill idle, UNATTACHED cockpit-* sessions (orphans left behind
#                              by a crash/forgotten `stop`); default idle threshold is
#                              WSH_LIVE_GC_IDLE (86400s/24h); --dry-run lists only; an
#                              attached session is NEVER a candidate, whatever its age.
#                              Also runs best-effort (silent, non-fatal) at the top of
#                              `spawn`/`start` so orphans self-clean over time.
#   web   {start|stop|status} [session]
#                              browser view of the cockpit pane via ttyd, loopback-only
#                              (brew install ttyd); read-only by default (WSH_WEB_WRITE=1
#                              for a writable view) — see SKILL.md for tailnet exposure
#   banner {header|phase|step|done} ... [session]
#                              airy step announcement (no send framing — see wsh-step.sh)
#   step-run <id> '<label>' '<command>' [session] [timeout_sec]
#                              ONE call = banner step + framed send + wait-done + read:
#                              the visual step announcement and the command it covers,
#                              without the caller having to chain 3 separate round-trips
#   remote-init [session] [host]
#                              call once after an ssh hop lands the pane on a remote host.
#                              With [host]: pushes the sep/step helper files there (via
#                              wsh-push.sh) so send/banner keep using the short sourcing
#                              form, now against the REMOTE path — falls back to inline
#                              framing if the push fails. Without [host]: sticky inline-
#                              only mode (send/banner default to the self-contained blob).
#   remote-init --pre <host> [session]
#                              RECOMMENDED when <host> is known ahead of time: push the
#                              helpers to <host> BEFORE the pane ssh-hops there (no pane
#                              probe involved — $HOME is resolved directly over `tailscale
#                              ssh`), so the FIRST send/banner after the hop already uses
#                              the short remote sourcing form instead of the inline blob.
#                              Same one-hop-only / best-effort-falls-back-to-inline rules.
#   local-init  [session]      revert remote-init — back to local helper-file framing
#   push [session] <local> <remote-path>
#   pull [session] <remote-path> <local>
#                              the ONLY official file transfer path once the pane has
#                              ssh-hopped (never base64/cat through the pane — see
#                              docs/framing-and-transfer.md). Host is resolved from the
#                              session's recorded remote-init/--pre host, never re-asked.
#                              Transport order (announced on stderr): Wave `wsh file cp`
#                              → the session's OpenSSH ControlMaster socket (reuses the
#                              pane's own already-authenticated hop, zero new auth) →
#                              `tailscale ssh` → bare `scp` (last resort, likely a fresh
#                              auth prompt). Shells out to wsh-push.sh; never counts
#                              toward the one-shot-SSH nudge (that only tracks `send`).
#   wait-done [session] [timeout_sec] [seq] [--print]
#                              block until last `send` footer shows exit (before next send);
#                              --print also emits the bounded `output` segment on success —
#                              one call instead of wait-done + output separately (this is
#                              what `step-run` uses under the hood)
#   selftest-live              end-to-end smoke test on a throwaway cockpit-selftest-$$
#                              session (start/send/wait-done/read/banner/remote-init/
#                              local-init/stop, NO Wave block — never calls spawn/open);
#                              rc 0/1
#   selftest-gc                gc_should_kill pure-function cases (fresh/attached/idle) +
#                              a real dry-run-then-real sweep on a throwaway session; rc 0/1
#   selftest-cache             resolve_live_tab_cached hit/miss/invalidation against a real
#                              live tab (skips if none resolvable); rc 0/1
#   selftest-oneshot-ssh       oneshot_ssh_is_inline pattern cases + oneshot_ssh_track
#                              consecutive-count/warning behavior (2nd match warns,
#                              interleaved/interactive resets); pure state-file test,
#                              no tmux session needed; rc 0/1
#   selftest-output            `output` segment extraction on a throwaway session: short
#                              complete segment, long segment truncated head+tail, --full,
#                              explicit seq, wait-done --print, WSH_LIVE_SEP=0 fallback;
#                              rc 0/1
#   selftest-transfer          wsh-push.sh error paths (missing local file, unreachable
#                              host) always run; a push+pull round-trip (text + binary,
#                              checksum-compared) over loopback ssh plus a missing-remote-
#                              file case run opportunistically (skipped with a note if this
#                              Mac doesn't accept passwordless ssh to itself); push/pull's
#                              own "no remote host recorded" error path on a real session;
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
#      WSH_LIVE_GC_IDLE (default 86400)  `gc` idle threshold in seconds; overridden per-call
#                                by --idle=SECONDS
#      WSH_LIVE_SEP=1 (default)   enable send/recv visual framing; =0 for raw shell
#      WSH_READ_MAX (default 120) `output` truncation threshold in lines; longer segments
#                                print head+tail with an omitted-count note; --full bypasses it
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
WSH_READ_MAX="${WSH_READ_MAX:-120}"
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
PUSH_SCRIPT="$SCRIPT_DIR/wsh-push.sh"
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
# shellcheck source=./lib/gc.sh
. "$SCRIPT_DIR/lib/gc.sh"
# shellcheck source=./lib/selftests.sh
. "$SCRIPT_DIR/lib/selftests.sh"

sub="${1:-}"; shift || true

# Used by `spawn --situate`: internalizes the 4-call manual "situate the shell"
# protocol (SKILL.md § "Situer le shell après spawn") into one send/wait-done/read
# sequence, by re-invoking this same script the same way `spawn` already does for
# `open` — no duplication of the send/wait-done/read implementations themselves.
# The probe also carries a grep-able WSH_SITUATE_HOST= marker (in addition to the
# human-readable hostname/pwd/whoami trio) so this function can auto-detect a
# remote hop and flip sticky remote mode ON, without the caller having to notice
# the mismatch itself and issue a separate `remote-init` call.
situate_session() {
  local sess="$1"
  "$0" send 'printf "WSH_SITUATE_HOST=%s\n" "$(hostname)"; pwd; whoami 2>&1' "$sess"
  local rc=0
  "$0" wait-done "$sess" 60 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "situate: wait-done exited $rc (timeout or non-zero probe) — showing pane anyway" >&2
  fi
  local out
  out=$("$0" read "$sess" 20)
  printf '%s\n' "$out"
  local remote_host
  remote_host=$(printf '%s\n' "$out" | tr -d '\r' | grep -o 'WSH_SITUATE_HOST=.*' | tail -n1 | cut -d= -f2-)
  # Only act on a genuine mismatch, and only if nothing (e.g. `spawn --pre
  # <host>`, run just before this) already primed remote mode for real — a
  # session already in remote mode has either been pre-pushed or already had
  # remote-init run on it; situate must not clobber that.
  if [ -n "$remote_host" ] && [ "$remote_host" != "$(hostname)" ] && ! remote_mode_get "$sess"; then
    # `hostname` on macOS returns the Bonjour/mDNS name (foo.local), which
    # `tailscale ssh`/`scp` generally do NOT resolve (they want the bare
    # MagicDNS name, e.g. "foo") — strip a trailing .local so the best-effort
    # push has a real shot instead of failing on a suffix mismatch alone. If
    # the stripped name still isn't reachable, remote-init's own fallback
    # (inline framing + stderr warning) still applies — no hard-fail either way.
    local remote_conn="${remote_host%.local}"
    echo "situate: pane is on '$remote_host' (this Mac is '$(hostname)') — auto-calling remote-init '$remote_conn' (best-effort push; falls back to inline framing with a warning if unreachable)"
    "$0" remote-init "$sess" "$remote_conn"
  fi
}

# Resolve $HOME on <host> directly from the agent's own shell — no pane
# involved — via the same one-hop `tailscale ssh` channel wsh-push.sh's own
# remote_size() uses. Needed for pre-push, which runs BEFORE the pane has
# ssh-hopped to <host>, so there is no pane content to frame/read yet.
remote_home_direct() {
  command -v tailscale >/dev/null 2>&1 || return 1
  tailscale ssh "$1" 'printf "%s" "$HOME"' 2>/dev/null
}

# Push local sep/step helper files to <host>:<remote_dir> and record their
# remote paths as sticky tmux session options, so send/banner build the short
# `. '<remote-path>' && ...` sourcing form instead of the inline blob. Shared
# tail for both `remote-init <sess> <host>` (pane already hopped there) and
# pre_push_helpers below (pane hasn't hopped yet) — the two differ only in how
# they resolve $HOME/mkdir the remote dir, not in how they push+register.
push_and_register_helpers() {  # $1 sess $2 host $3 remote_dir -> 0 ok, 1 failed
  local sess="$1" host="$2" remote_dir="$3"
  [ -f "$PUSH_SCRIPT" ] || { echo "warn: missing $PUSH_SCRIPT — cannot push helpers to '$host'" >&2; return 1; }
  local local_sep local_step remote_sep remote_step prc1 prc2 cpath
  local_sep=$(sep_ensure_helpers)
  local_step=$(step_ensure_helpers)
  remote_sep="${remote_dir}/$(basename "$local_sep")"
  remote_step="${remote_dir}/$(basename "$local_step")"
  # --control-path is a no-op when no ControlMaster is alive yet at that
  # socket (e.g. the pane hasn't hopped there yet, or hopped via tailscale
  # ssh) — wsh-push.sh's own fallback chain handles that, see try_control_path.
  cpath=$(control_path_for_session "$sess")
  set +e
  "$PUSH_SCRIPT" --control-path="$cpath" "$local_sep" "$remote_sep" "$host" >/dev/null 2>&1
  prc1=$?
  "$PUSH_SCRIPT" --control-path="$cpath" "$local_step" "$remote_step" "$host" >/dev/null 2>&1
  prc2=$?
  set -e
  if [ "$prc1" -eq 0 ] && [ "$prc2" -eq 0 ]; then
    remote_helper_path_set "$sess" sep "$remote_sep"
    remote_helper_path_set "$sess" step "$remote_step"
    return 0
  fi
  echo "warn: wsh-push.sh failed to push helpers to '$host' (sep rc=$prc1 step rc=$prc2)" >&2
  return 1
}

# Used by `spawn --pre <host>`: pre-stage the sep/step helper files on <host>
# BEFORE the pane has ssh-hopped there (unlike `remote-init <sess> <host>`,
# which requires the hop to already have happened so it can resolve $HOME
# through the pane). $HOME/mkdir are resolved directly via tailscale ssh
# instead — there is no pane content to visibly frame yet, so this is closer
# in spirit to wsh-push.sh's own agent-side file transfer than to a `send`.
# Once the pane actually lands on <host> later, send/banner are immediately
# ready with short remote sourcing — no extra remote-init round-trip needed.
pre_push_helpers() {  # $1 sess $2 host -> 0 staged, 1 skipped/failed
  local sess="$1" host="$2" rhome
  # Record the host now: the caller already knows the pane is ABOUT to hop
  # there (that's the whole point of --pre), so push/pull can resolve it
  # afterwards regardless of whether the best-effort helper pre-stage below
  # succeeds.
  remote_host_set "$sess" "$host"
  rhome=$(remote_home_direct "$host") || true
  if [ -z "$rhome" ]; then
    echo "warn: could not resolve \$HOME on '$host' directly (tailscale ssh unavailable/failed) — skipping pre-push; remote-init after the hop still works" >&2
    return 1
  fi
  local remote_dir="${rhome}/.cache/wsh-cockpit/helpers"
  if ! tailscale ssh "$host" "mkdir -p '${remote_dir}'" >/dev/null 2>&1; then
    echo "warn: could not create $remote_dir on '$host' — skipping pre-push" >&2
    return 1
  fi
  if push_and_register_helpers "$sess" "$host" "$remote_dir"; then
    remote_mode_set "$sess" 1 >/dev/null 2>&1 || true
    echo "pre-push: helpers staged on '$host':$remote_dir for session '$sess' — remote mode ON, ready before the hop"
    return 0
  fi
  return 1
}

# Shared engine for the `push`/`pull` subcommands: resolves the session's
# recorded remote host (set by remote-init/--pre — the caller never repeats
# it) and hands off to wsh-push.sh with that session's ControlPath, so an
# already-authenticated OpenSSH hop (see SKILL.md's ControlMaster hop command)
# is reused instead of opening a fresh connection. Does NOT touch `send` or
# oneshot_ssh_track — these are agent-shell calls, never typed into the pane,
# so they never count toward (or trigger) the one-shot SSH nudge.
# $1 direction (push|pull) $2 sess $3 local-path $4 remote-path
cmd_transfer() {
  local dir="$1" sess="$2" local_arg="$3" remote_arg="$4" host cpath
  host=$(remote_host_get "$sess")
  if [ -z "$host" ]; then
    echo "$0 $dir: no remote host recorded for session '$sess' — run remote-init/--pre <host> first (if the pane never left this Mac, use plain cp instead)" >&2
    exit 2
  fi
  [ -f "$PUSH_SCRIPT" ] || { echo "$0 $dir: missing $PUSH_SCRIPT" >&2; exit 3; }
  cpath=$(control_path_for_session "$sess")
  if [ "$dir" = pull ]; then
    "$PUSH_SCRIPT" --pull --control-path="$cpath" "$local_arg" "$remote_arg" "$host"
  else
    "$PUSH_SCRIPT" --control-path="$cpath" "$local_arg" "$remote_arg" "$host"
  fi
}

# Used by `step-run`: internalizes the "announce then run" protocol (SKILL.md
# § "Annonces d'étapes aérées" — banner step, then send, then wait-done) into
# one call, by re-invoking this same script for each piece — no duplication of
# the banner/send/wait-done/read implementations themselves (same technique as
# situate_session above). Unlike situate_session, the command's real exit code
# is propagated: the caller needs to know whether the step it just ran succeeded.
step_run() {
  local id="$1" label="$2" cmd="$3" sess="$4" timeout="$5"
  "$0" banner step "$id" "$label" "$sess"
  "$0" send "$cmd" "$sess"
  local rc=0
  # --print folds the bounded `output` segment into this same wait-done call —
  # one round-trip instead of wait-done + a separate read/output.
  "$0" wait-done "$sess" "$timeout" --print || rc=$?
  return "$rc"
}

# Used by `output` and `wait-done --print`: extract EXACTLY the framed segment
# for send #<seq> — header through footer inclusive — instead of a `read N`
# guess. $1 sess $2 seq $3 full (0/1, bypasses the WSH_READ_MAX truncation).
# Prints the segment on stdout; rc 0 if found, 1 (with a clear stderr message,
# never a silent guess) if the markers aren't in the captured scrollback.
cmd_output() {
  local sess="$1" seq="$2" full="$3"
  local pane segment total_lines max head_n tail_n omitted line tail_start
  local -a seg_lines
  # tmux clamps -S to the actual history available, so a generous ask here is
  # safe and cheap (local capture) — the whole point of `output` is to never
  # guess a line count, including for the scrollback lookback itself.
  pane=$(mux_capture "$sess" 100000)
  # `|| true`: awk deliberately exits 1 when the markers aren't found (see
  # END below) — under `set -e` that would abort the whole script right here,
  # before the explicit not-found message below ever gets a chance to print.
  segment=$(printf '%s\n' "$pane" | awk -v seq="$seq" '
    $0 ~ ("┌─\\[#" seq "\\]") { start=1; buf="" }
    start        { buf = buf $0 "\n" }
    $0 ~ ("└─\\[#" seq "\\] exit [0-9]+") && start { printf "%s", buf; found=1; exit }
    END          { exit(found ? 0 : 1) }
  ') || true
  if [ -z "$segment" ]; then
    echo "output: segment for send #${seq} not found in '${sess}' scrollback (it rolled off capture-pane's history, or that send never completed) — retry with 'read N' for a raw snapshot" >&2
    return 1
  fi
  # Bash-3.2-compatible line split — no mapfile/readarray (macOS ships bash
  # 3.2 as /bin/bash; this script has to run there, not just under a newer
  # brew bash). Trim the one trailing newline `buf` always ends with first,
  # or the here-string's own appended newline would read as a spurious blank
  # final element.
  segment="${segment%$'\n'}"
  seg_lines=()
  while IFS= read -r line; do
    seg_lines+=("$line")
  done <<<"$segment"
  total_lines=${#seg_lines[@]}
  max="$WSH_READ_MAX"
  if [ "$full" -eq 1 ] || [ "$total_lines" -le "$max" ]; then
    printf '%s\n' "${seg_lines[@]}"
  else
    head_n=30; tail_n=60
    omitted=$((total_lines - head_n - tail_n))
    tail_start=$((total_lines - tail_n))
    printf '%s\n' "${seg_lines[@]:0:head_n}"
    printf -- '… %s lignes omises — relire avec « output --full » ou « read N » …\n' "$omitted"
    printf '%s\n' "${seg_lines[@]:tail_start:tail_n}"
  fi
}

case "$sub" in
spawn)
  # Preferred entry point. Reuses the last alive cockpit for this agent/prefix unless
  # --force/--fresh is passed. Never hijacks the generic "cockpit" name (use unique names).
  have_mux
  # Best-effort orphan sweep (default idle threshold) on every spawn — silent,
  # non-fatal, and genuinely non-blocking: launched as a DETACHED background
  # job inside a subshell (the subshell itself returns immediately once the
  # job is started), so a stray `exit`/slow tmux call inside cmd_gc can
  # neither abort THIS session's creation nor delay it.
  ( cmd_gc >/dev/null 2>&1 & ) || true
  FORCE=0
  SITUATE=0
  PREFIX=""
  PRE_HOST=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force|--fresh) FORCE=1; shift ;;
      --situate) SITUATE=1; shift ;;
      --pre) PRE_HOST="${2:?usage: spawn --pre <host> (connection string, e.g. qveys@srv1453980)}"; shift 2 ;;
      -*) echo "unknown flag: $1 (use --force to create a duplicate cockpit, --situate to auto-probe host/pwd/whoami, --pre <host> to pre-stage remote helpers before the hop)" >&2; exit 2 ;;
      *) PREFIX="$1"; shift ;;
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
    [ -n "$PRE_HOST" ] && "$0" remote-init --pre "$PRE_HOST" "$SESS"
    [ "$SITUATE" -eq 1 ] && situate_session "$SESS"
    exit 0
  fi

  SESS=$(unique_session_name "$PREFIX")
  create_session "$SESS"
  remember_session "$SESS"
  echo "created fresh $MUX session '$SESS'"
  "$0" open "$SESS"
  echo "SESSION=$SESS"
  tty_only "Use this session for all subsequent send/read calls in this workflow."
  [ -n "$PRE_HOST" ] && "$0" remote-init --pre "$PRE_HOST" "$SESS"
  [ "$SITUATE" -eq 1 ] && situate_session "$SESS"
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
  # Best-effort orphan sweep, same rationale as spawn's (see comment there) —
  # also launched as a detached background job, never blocking `start`.
  ( cmd_gc >/dev/null 2>&1 & ) || true
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
gc)
  cmd_gc "$@"
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
  PRINT=0
  for arg in "$@"; do
    case "$arg" in --print) PRINT=1 ;; esac
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
      # --print: fold `output`'s bounded segment into this same call — see
      # cmd_output above. `|| true` so a (theoretical) extraction failure here
      # never masks the real command's exit code below.
      if [ "$PRINT" -eq 1 ]; then
        cmd_output "$SESS" "$target_seq" 0 || true
      fi
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

  if ! TAB=$(resolve_live_tab_cached "$SESS"); then
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
  block_id_store "$SESS" "$NEWID"

  # Verify a client actually joined (the attach can fail silently inside the
  # block, e.g. wrong tmux/path); poll adaptively instead of a flat 5x1s wait —
  # same growing-interval style as wait-done — so a fast attach returns almost
  # instantly while a slow one still gets ~6s before we give up.
  SECONDS=0
  set -- 0.2 0.3 0.5 1
  while [ "$SECONDS" -lt 6 ]; do
    mux_clients "$SESS" | grep -q . && break
    if [ $# -gt 0 ]; then sleep "$1"; shift; else sleep 1; fi
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
  #
  # --pre <host> [session]: the PRE-hop variant — push the helpers to <host>
  # BEFORE the pane has ssh-hopped there (recommended whenever the host is
  # known ahead of time: it removes the round trip through the pane entirely,
  # since $HOME is resolved directly over `tailscale ssh` — see
  # pre_push_helpers/remote_home_direct). Same one-hop-only / best-effort
  # fallback-to-inline semantics as the post-hop form above.
  have_mux
  if [ "${1:-}" = "--pre" ]; then
    shift
    HOST="${1:?usage: remote-init --pre <host> [session]}"; shift || true
    SESS=$(resolve_session "${1:-}"); need_session "$SESS"
    pre_push_helpers "$SESS" "$HOST"
    exit $?
  fi
  SESS=$(resolve_session "${1:-}"); need_session "$SESS"
  HOST="${2:-}"
  if [ -z "$HOST" ]; then
    # remote_mode_set only prints "remote mode ON" once it actually flipped the
    # sticky tmux option; under zellij it's a no-op (its own stderr note
    # explains why), so gate the success line on its exit status instead of
    # claiming a behavior change that won't happen.
    if remote_mode_set "$SESS" 1; then
      echo "remote mode ON for '$SESS' — send/banner now default to inline framing (local-init to revert)"
    fi
  else
    PUSHED=0
    # Record the host now: the pane HAS hopped there (this is the post-hop
    # form), regardless of whether the best-effort helper push below
    # succeeds — push/pull need this to resolve a target without asking again.
    remote_host_set "$SESS" "$HOST"
    # Resolve the remote $HOME through the pane itself (visibly framed, like
    # every other cockpit command) rather than assume a path shape — the
    # remote path is later embedded in single-quoted contexts inside
    # wsh-push.sh's scp/tailscale-ssh fallbacks, where a literal '~' is NOT
    # guaranteed to expand. (`spawn --pre <host>` resolves $HOME differently —
    # directly via tailscale ssh — because it runs before any hop exists; see
    # remote_home_direct.)
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
      elif push_and_register_helpers "$SESS" "$HOST" "$REMOTE_DIR"; then
        PUSHED=1
      fi
    fi
    if remote_mode_set "$SESS" 1; then
      if [ "$PUSHED" = "1" ]; then
        echo "remote mode ON for '$SESS' — helpers pushed to '$HOST':$REMOTE_DIR; send/banner source them there (local-init to revert)"
      else
        echo "remote mode ON for '$SESS' — inline framing only (helper push to '$HOST' unavailable; local-init to revert)"
      fi
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
  remote_helper_path_clear "$SESS" sep
  remote_helper_path_clear "$SESS" step
  remote_host_clear "$SESS"
  # Same as remote-init: only claim "remote mode OFF" when the sticky tmux
  # option was actually cleared — under zellij this is a no-op (its own
  # stderr note explains why) and the session was never in remote mode.
  if remote_mode_set "$SESS" 0; then
    echo "remote mode OFF for '$SESS' — send/banner back to local helper-file framing"
  fi
  ;;
selftest-sep)
  cmd_selftest_sep
  ;;
selftest-live)
  cmd_selftest_live
  ;;
selftest-gc)
  cmd_selftest_gc
  ;;
selftest-cache)
  cmd_selftest_cache
  ;;
selftest-oneshot-ssh)
  cmd_selftest_oneshot_ssh
  ;;
selftest-output)
  cmd_selftest_output
  ;;
selftest-transfer)
  cmd_selftest_transfer
  ;;
push)
  have_mux
  SESS=$(resolve_session "${1:-}"); shift || true; need_session "$SESS"
  LOCAL="${1:?usage: wsh-live.sh push [session] <local> <remote-path>}"; shift || true
  REMOTE="${1:?usage: wsh-live.sh push [session] <local> <remote-path>}"; shift || true
  cmd_transfer push "$SESS" "$LOCAL" "$REMOTE"
  ;;
pull)
  have_mux
  SESS=$(resolve_session "${1:-}"); shift || true; need_session "$SESS"
  REMOTE="${1:?usage: wsh-live.sh pull [session] <remote-path> <local>}"; shift || true
  LOCAL="${1:?usage: wsh-live.sh pull [session] <remote-path> <local>}"; shift || true
  cmd_transfer pull "$SESS" "$LOCAL" "$REMOTE"
  ;;
send)
  have_mux
  CMD="${1:?usage: wsh-live.sh send '<command>' [session]}"
  SESS=$(resolve_session "${2:-}"); need_session "$SESS"
  # One-shot-SSH-in-a-row nudge (stderr only, never blocking) — see lib/session.sh.
  oneshot_ssh_track "$SESS" "$CMD"
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
output)
  # Marker-bounded read: no lines-to-guess, see cmd_output above.
  have_mux
  FULL=0
  local_sess=""
  target_seq=""
  for arg in "$@"; do
    case "$arg" in --full) FULL=1 ;; esac
    if [ -z "$local_sess" ] && mux_has "$arg"; then
      local_sess="$arg"
    elif [ -z "$target_seq" ] && [[ "$arg" =~ ^[0-9]+$ ]]; then
      target_seq="$arg"
    fi
  done
  SESS=$(resolve_session "${local_sess:-}"); need_session "$SESS"
  if [ "${WSH_LIVE_SEP:-1}" = "0" ]; then
    echo "output: WSH_LIVE_SEP=0 — this pane has no ┌─[#N]/└─[#N] markers to extract; use 'read N' for a raw scrollback snapshot" >&2
    exit 13
  fi
  if [ -z "$target_seq" ]; then
    target_seq=$(cat "$(seq_file "$SESS")" 2>/dev/null || true)
  fi
  [ -n "$target_seq" ] || { echo "output: no framed send recorded for '$SESS' yet (run send first, or use 'read N' for a raw snapshot)" >&2; exit 12; }
  cmd_output "$SESS" "$target_seq" "$FULL"
  ;;
step-run)
  # ONE call for "announce the step, run the command, wait for it to finish" —
  # the protocol SKILL.md mandates per step, previously always 2-3 separate
  # tool calls (banner, send, wait-done). <id>/<label> match `banner step`'s
  # own two fields (e.g. "1.1" / "openclaw doctor").
  have_mux
  ID="${1:?usage: wsh-live.sh step-run <id> '<label>' '<command>' [session] [timeout_sec]}"
  shift || true
  LABEL="${1:?usage: wsh-live.sh step-run <id> '<label>' '<command>' [session] [timeout_sec]}"
  shift || true
  CMD="${1:?usage: wsh-live.sh step-run <id> '<label>' '<command>' [session] [timeout_sec]}"
  shift || true
  run_sess=""
  run_timeout=""
  for arg in "$@"; do
    if [ -z "$run_sess" ] && mux_has "$arg"; then
      run_sess="$arg"
    elif [ -z "$run_timeout" ] && [[ "$arg" =~ ^[0-9]+$ ]]; then
      run_timeout="$arg"
    fi
  done
  SESS=$(resolve_session "${run_sess:-}"); need_session "$SESS"
  TIMEOUT="${run_timeout:-${WSH_WAIT_TIMEOUT:-300}}"
  step_run "$ID" "$LABEL" "$CMD" "$SESS" "$TIMEOUT"
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
  # Actual kill + state cleanup (seq file, sep/step helper options, web view,
  # last-session pointer) lives in teardown_session (lib/session.sh) — shared
  # with `gc`, which needs the exact same per-session cleanup on a sweep.
  if teardown_session "$SESS"; then
    echo "killed session '$SESS'"
  else
    echo "no session '$SESS' to kill"
  fi
  ;;
*)
  echo "usage: $0 {spawn|start|open|send|keys|read|output|push|pull|stop|current|doctor|gc|status|web|banner|step-run|remote-init|local-init|wait-done|selftest-sep|selftest-live|selftest-gc|selftest-cache|selftest-oneshot-ssh|selftest-output|selftest-transfer} [args]" >&2; exit 2 ;;
esac
