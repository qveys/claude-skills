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
#   spawn [prefix] [--force] [--situate] [--pre <host>] [--tab <name>]
#                              open/reuse cockpit: reuse last alive session by default;
#                              --tab is relayed as-is to `open` (see below) whenever
#                              spawn ends up calling it;
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
#   open  [session] [--tab <name>]
#                              AUTO-OPEN a visible Wave block attached to the session;
#                              --tab resolves the Wave tab to anchor on BY NAME (spec
#                              v12 §4, step-1.8) instead of the usual live-tab guess —
#                              bounded to the current WAVETERM_WORKSPACEID, requires
#                              being inside Wave (no arbitrary fallback if not); a
#                              name not found in this workspace warns and falls back
#                              to the normal live-tab resolution; duplicates elect the
#                              first match (pinned tabs, then tab order) and warn
#                              listing every candidate
#   send  '<command>' [sess] [--session NAME|-s NAME]
#                              type a command into the pane and press Enter
#   keys  '<tmux-keys>' [sess] [--session NAME|-s NAME]
#                              send raw tmux keys (C-c, Up, Enter, q ...) verbatim
#   read  [session] [lines] [--session NAME|-s NAME]
#                              print the current pane (default 30 lines back) — free-form
#                              scrollback inspection (TUI/REPL, unframed pane); when the
#                              pane IS framed, prefer `output` below (nothing to guess)
#   output [session] [seq] [--full] [--session NAME|-s NAME]
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
#   stop  [session]            kill the session (or release it, without touching tmux/the
#                              Wave block, when it carries a sticky keep-<slug> marker —
#                              spec v12 §3, step-1.6)
#   release <session>          make a session available again WITHOUT destroying it: an
#                              adopted session (still in $WSH_COCKPIT_ADOPT) retrogrades to a
#                              "released" pré-claim, re-adoptable via étape 2 only; a created/
#                              legacy session's claim is removed outright, re-scannable via
#                              étape 3. I4-enforced (owner-only). Mandatory argument, no
#                              last-session default. Never touches tmux, the Wave block,
#                              keep-<slug>, seq-<slug> or oneshot-ssh-<slug> (spec v12 §3).
#   current                    print the last session created by `spawn` in this shell tree
#   doctor                     read-only diagnostic of the whole cockpit chain
#                              (rc 0/1, never writes anything — safe to run anytime)
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
#   banner {header|phase|step|done} ... [session] [--session NAME|-s NAME]
#                              airy step announcement (no send framing — see wsh-step.sh)
#   step-run <id> '<label>' '<command>' [session] [timeout_sec] [--session NAME|-s NAME]
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
#   wait-done [session] [timeout_sec] [seq] [--print] [--session NAME|-s NAME]
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
#   selftest-guard             own_tmux_session/session_safe_to_reuse cases: own session
#                              refused, non-shell foreground refused, bare shell ok, empty
#                              pane_current_command safe, find_reusable_session never hands
#                              back an unsafe remembered session, start --reuse exit 8;
#                              tmux-only; rc 0/1
#   selftest-claim             claim state-machine primitives (lib/claim.sh): nominal
#                              cycle, A/B race on a pre-claim, anti-rearm content check,
#                              recycled-pid .won residue, rollback vs. a rival definitive
#                              claim, orphan replacement under race, reserved-key refusal,
#                              two-line format readback; pure filesystem, no tmux session
#                              needed; rc 0/1
#   selftest-adopt             registry-at-creation (step-1.3, spec v12 §2 étape 1):
#                              spawn/start pose a creator claim + registered prefix;
#                              A/B/A alternation never misroutes; two distinct prefixes
#                              resolve to two distinct sessions; N>1 of mine with no
#                              prefix and no last-session recorded is an explicit rc=2
#                              (never a silent (N+1)-th cockpit); a start-created session
#                              ("(named)" sentinel) is unreachable via a prefix match;
#                              start refuses a slug-colliding name; reserved-key refusal
#                              + --preopen lift; stop leaves no orphaned claim/prefix
#                              marker; real spawn/start subprocess calls used only where
#                              they exit before ever reaching spawn's open side effect;
#                              adoption via étape 2 (step-1.4) with a real probe run;
#                              étape 3 legacy scan/claim, seq/prefix continuity across it
#                              (step-1.5); release retrogrades an adopted claim to
#                              "released" (re-adoptable via étape 2, probed) and removes a
#                              created claim outright (re-scannable via étape 3); release
#                              usage error and I4 (non-owner) refusal; seq-<slug>
#                              untouched by release; sticky keep-<slug> — adopted-then-
#                              released-then-scanned session — always routes `stop` to
#                              release, never teardown, session/block left alive
#                              (step-1.6); tmux-only; rc 0/1
#   selftest-tab               sql_quote()/resolve_tab_by_name() (step-1.8, spec v12
#                              §4) against a throwaway FIXTURE sqlite DB, never the
#                              real Wave DB: simple resolution; homonym in another
#                              workspace never matches (and that other workspace's
#                              pinnedtabids key is entirely absent, proving the
#                              defensive union stays valid without it); duplicates
#                              elect the pinned one first then array-position order
#                              even with reversed row-insertion order, warning list
#                              has all candidates; tab_count_candidates() (step-1.11.3)
#                              counts candidates correctly at N=1/2/3 — N=2 is the
#                              case the old inline `wc -l` on a no-trailing-newline
#                              string undercounted, leaving the warning silent;
#                              hostile names (quote, %, real
#                              newline, `x'; DROP TABLE db_tab;--`) resolve cleanly
#                              with zero alteration; WAVETERM_WORKSPACEID absent ->
#                              rc=2 (no arbitrary fallback); not found -> rc=3; `wsh`
#                              missing -> rc=1 (no hardcoded AppSupport fallback);
#                              pure function test, no tmux session needed; rc 0/1
#   selftest-wrapper           claude-cockpit.sh end-to-end (step-1.9, spec v12 §1):
#                              "--and"-delimited group parsing; --keep extracted (not
#                              forwarded to spawn) while --tab and every other flag
#                              are relayed verbatim; refuses BEFORE any spawn call
#                              when a value literally contains "--" (superset of
#                              "--and") or when two groups resolve to the same
#                              normalized prefix; each group's spawn call runs
#                              scoped WSH_COCKPIT_AGENT=user-preopen-<n>, never
#                              exported to the wrapper itself or to claude; claude
#                              sees the exact WSH_COCKPIT_ADOPT=sess1,sess2,...
#                              list and WSH_COCKPIT_AGENT=claude-<epoch>-<pid>, never
#                              WSH_COCKPIT_PREFIX nor a user-preopen-<n> key; a
#                              group's genuine spawn failure aborts before claude is
#                              ever launched, earlier-opened cockpits in that same
#                              run left open (no rollback); after claude returns
#                              normally, the exit sweep releases keep-marked
#                              sessions and stops/destroys the rest, with no
#                              orphaned claim/prefix marker left behind. Runs
#                              entirely against a throwaway fake wsh-live.sh (real
#                              tmux session + real claim, no Wave `open`) and a fake
#                              `claude` stub on PATH — never pops a real Wave block,
#                              never launches the real claude; tmux-only; rc 0/1
#   selftest-attach            the block's attach command survives a detach: the
#                              block stays alive, says why it detached, and
#                              re-attaches on Enter — instead of dying with the
#                              attach and leaving a black, key-swallowing dead
#                              terminal; tmux-only; rc 0/1
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
#      tmux by ABSOLUTE path (see mux_block_attach_cmd), and we deliberately do
#      NOT `exec` it: a block that *is* the attach dies with it and leaves a dead
#      terminal — a black screen swallowing every key, prefix included.
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
# shellcheck source=./lib/claim.sh
. "$SCRIPT_DIR/lib/claim.sh"
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
  remote_host=$(printf '%s\n' "$out" | tr -d '\r' | grep -o '^WSH_SITUATE_HOST=.*' | tail -n1 | cut -d= -f2-)
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
  # Strip ANSI color escapes (as wait-done already does) — the zellij
  # backend's dump-screen output can include them, which would otherwise
  # prevent the marker regex below from ever matching.
  pane=$(mux_capture "$sess" 100000 | sed $'s/\x1b\\[[0-9;]*m//g')
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
    # Sized from the cap itself (30/60 at the default 120) so a custom
    # WSH_READ_MAX below 90 still respects its own budget.
    head_n=$((max / 4)); [ "$head_n" -ge 1 ] || head_n=1
    tail_n=$((max / 2)); [ "$tail_n" -ge 1 ] || tail_n=1
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
  PREOPEN=0
  TAB_NAME=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force|--fresh) FORCE=1; shift ;;
      --situate) SITUATE=1; shift ;;
      --pre) PRE_HOST="${2:?usage: spawn --pre <host> (connection string, e.g. qveys@srv1453980)}"; shift 2 ;;
      # Relayed as-is to `open` (spec v12 §4, step-1.8) whenever spawn ends
      # up calling it below — see open's own --tab for the resolution rules.
      --tab) TAB_NAME="${2:?usage: spawn --tab <name> (Wave tab name to anchor the block on)}"; shift 2 ;;
      # Internal only (spec v12 §1): lifts the reserved-key refusal below for
      # the wrapper's own bootstrap spawn (WSH_COCKPIT_AGENT=user-preopen-<n>,
      # set by the caller's environment — this flag never itself sets or
      # exports that key). Not documented for interactive use.
      --preopen) PREOPEN=1; shift ;;
      -*) echo "unknown flag: $1 (use --force to create a duplicate cockpit, --situate to auto-probe host/pwd/whoami, --pre <host> to pre-stage remote helpers before the hop, --tab <name> to anchor on a named Wave tab)" >&2; exit 2 ;;
      *) PREFIX="$1"; shift ;;
    esac
  done

  MYKEY=$(agent_claim_key)
  if claim_key_reserved "$MYKEY" && [ "$PREOPEN" -ne 1 ]; then
    echo "refusing to spawn under reserved agent key '$MYKEY' (reserved for wsh-cockpit's own bootstrap) — set WSH_COCKPIT_AGENT/WSH_COCKPIT_PREFIX to something else" >&2
    exit 2
  fi

  ADOPTED_NOW=0
  if [ "$FORCE" -eq 0 ]; then
    NORM=$(normalize_prefix "$PREFIX")
    RC=0
    SESS=$(find_registry_session "$PREFIX" "$NORM") || RC=$?
    if [ "$RC" -eq 2 ]; then
      echo "ambiguous: more than one of your sessions (registry) matches and none is the last-used one — pass a prefix to disambiguate, or --force for a fresh cockpit" >&2
      exit 2
    fi
    if [ "$RC" -ne 0 ] && try_adopt_session "$PREFIX" "$NORM"; then
      SESS="$ADOPT_RESULT"
      RC=0
      ADOPTED_NOW=1
    fi
    if [ "$RC" -ne 0 ]; then
      RC=0
      SESS=$(find_reusable_session "$PREFIX") || RC=$?
      if [ "$RC" -eq 2 ]; then
        echo "ambiguous: more than one of your sessions (registry) matches and none is the last-used one — pass a prefix to disambiguate, or --force for a fresh cockpit" >&2
        exit 2
      fi
      # find_reusable_session hands back an unclaimed session only via its
      # legacy fallback (a registry hit is always already claimed by ME) —
      # step-1.5, spec v12 §2: entering the registry now (claim + probe) so
      # this parc antérieur session stops being silently shareable.
      if [ "$RC" -eq 0 ] && ! claim_is_claimed "$(session_slug "$SESS")"; then
        if try_legacy_claim "$SESS" "$NORM"; then
          SESS="$LEGACY_RESULT"
          ADOPTED_NOW=1
        else
          RC=1
        fi
      fi
    fi
  else
    RC=1
  fi
  if [ "$RC" -eq 0 ]; then
    remember_session "$SESS"
    audit_log_start "$SESS"
    if [ "$ADOPTED_NOW" -ne 1 ]; then
      echo "reusing existing $MUX session '$SESS' (still alive — not spawning a duplicate)"
    fi
    if mux_clients "$SESS" | grep -q .; then
      echo "clients already attached — cockpit should still be visible in Wave"
    else
      echo "no client attached — re-opening Wave block"
      if [ -n "$TAB_NAME" ]; then "$0" open "$SESS" --tab "$TAB_NAME"
      else "$0" open "$SESS"; fi
    fi
    echo "SESSION=$SESS"
    tty_only "Use this session for all subsequent send/read calls in this workflow." \
             "Pass --force only when you intentionally need a second cockpit window."
    # Both are best-effort by design (pre-push falls back to inline framing,
    # situate tolerates its own probe failing): under set -e a bare
    # `[ ... ] && cmd` here would turn a failed cmd — or even just a false
    # guard as the case's last command — into a non-zero spawn exit.
    if [ -n "$PRE_HOST" ]; then "$0" remote-init --pre "$PRE_HOST" "$SESS" || true; fi
    if [ "$SITUATE" -eq 1 ]; then situate_session "$SESS" || true; fi
    exit 0
  fi

  SESS=$(unique_session_name "$PREFIX")
  create_session "$SESS"
  remember_session "$SESS"
  claim_new_session "$SESS" "$(normalize_prefix "$PREFIX")"
  echo "created fresh $MUX session '$SESS'"
  if [ -n "$TAB_NAME" ]; then "$0" open "$SESS" --tab "$TAB_NAME"
  else "$0" open "$SESS"; fi
  echo "SESSION=$SESS"
  tty_only "Use this session for all subsequent send/read calls in this workflow."
  # Same best-effort rule as the reuse path above — a spawn that created its
  # session must exit 0 even when pre-push/situate degrade.
  if [ -n "$PRE_HOST" ]; then "$0" remote-init --pre "$PRE_HOST" "$SESS" || true; fi
  if [ "$SITUATE" -eq 1 ]; then situate_session "$SESS" || true; fi
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
  PREOPEN=0
  ARGS=()
  for arg in "$@"; do
    case "$arg" in
      --reuse) REUSE=1 ;;
      # Internal only — see spawn's --preopen for the rationale (spec v12 §1).
      --preopen) PREOPEN=1 ;;
      *) ARGS+=("$arg") ;;
    esac
  done

  MYKEY=$(agent_claim_key)
  if claim_key_reserved "$MYKEY" && [ "$PREOPEN" -ne 1 ]; then
    echo "refusing to start under reserved agent key '$MYKEY' (reserved for wsh-cockpit's own bootstrap) — set WSH_COCKPIT_AGENT/WSH_COCKPIT_PREFIX to something else" >&2
    exit 2
  fi

  if [ ${#ARGS[@]} -eq 0 ]; then
    SESS=$(unique_session_name "")
    create_session "$SESS"
    remember_session "$SESS"
    claim_new_session "$SESS" "(named)"
    echo "created fresh $MUX session '$SESS' (no name given — auto-unique)"
  else
    SESS="${ARGS[0]}"
    if mux_has "$SESS"; then
      if [ "$REUSE" -eq 1 ]; then
        # Deliberate: --reuse applies ONLY the identity block (own session,
        # by any alias), NOT session_safe_to_reuse's bare-shell foreground
        # heuristic — --reuse is an explicit "continue THIS session", so a
        # non-shell foreground the caller presumably knows about is theirs
        # to own. spawn's silent reuse keeps both checks.
        rc=0; session_is_own "$SESS" || rc=$?
        if [ "$rc" -eq 2 ]; then
          session_indeterminate_refusal "$SESS"
          exit 8
        fi
        if [ "$rc" -eq 0 ]; then
          session_own_refusal "$SESS"
          exit 8
        fi
        echo "session '$SESS' already exists — reusing it (--reuse)"
        remember_session "$SESS"
      else
        # Same probe before suggesting `--reuse`: pointing the caller at a
        # command line the guard will then refuse (exit 8 again, on their own
        # session) is worse than refusing outright here. rc=2 (identity
        # indeterminable) keeps the generic message — a --reuse retry will
        # explain the indeterminacy itself.
        rc=0; session_is_own "$SESS" || rc=$?
        if [ "$rc" -eq 0 ]; then
          session_own_refusal "$SESS"
          exit 8
        fi
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
      # Slug collision guard (spec v12 §2): adopt-claim-<slug>/prefix-<slug>
      # are keyed by slug, not by the raw session name — two live sessions
      # sharing a slug would corrupt each other's markers. `spawn` can't hit
      # this (unique_session_name's HHMMSS suffix keeps slugs distinct in
      # practice); a caller-chosen `start NAME` can.
      NEWSLUG=$(session_slug "$SESS")
      COLLIDE=""
      while IFS= read -r OTHER; do
        [ -n "$OTHER" ] && [ "$OTHER" != "$SESS" ] || continue
        if [ "$(session_slug "$OTHER")" = "$NEWSLUG" ]; then COLLIDE="$OTHER"; break; fi
      done < <(mux_list_sessions)
      if [ -n "$COLLIDE" ]; then
        echo "refusing to create '$SESS' — its slug collides with live session '$COLLIDE' (claim/prefix markers are keyed by slug); choose a less ambiguous name" >&2
        exit 2
      fi
      create_session "$SESS"
      remember_session "$SESS"
      claim_new_session "$SESS" "(named)"
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
  # --session/-s short-circuits the trailing-argument sniff below — see send) above.
  parse_session_flag "$@"; set -- ${PSF_REST[@]+"${PSF_REST[@]}"}
  TYPE="${1:?usage: wsh-live.sh banner <header|phase|step|done> [args...] [session] (or --session/-s NAME)}"
  shift || true
  case "$TYPE" in header|phase|step|done) ;; *)
    echo "banner: unknown type '$TYPE' (want header|phase|step|done)" >&2; exit 11 ;;
  esac
  SESS=""
  # Optional session is recognized only when it is NOT the sole remaining
  # argument — otherwise `banner header "cockpit-x"` would lose its text.
  # Form first (looks_like_session), existence second (mux_has): a token
  # shaped like a session that no longer exists must reach need_session below
  # and fail loud (exit 4), not fall back to text (plan §2/§3, lot 2 t3).
  # $SESS_FLAG set: skip the sniff entirely, the flag already decided SESS —
  # but a session-shaped last argument NEXT TO the flag is a contradiction,
  # not text: fail loud (flag_conflict_check, exit 2) instead of guessing.
  if [ $# -gt 0 ]; then flag_conflict_check "${!#}"; fi
  if [ -z "$SESS_FLAG" ] && [ $# -gt 1 ] && { looks_like_session "${!#}" || mux_has "${!#}"; }; then
    SESS="${!#}"
    SESS="${SESS#=}"   # target-pane calls downstream (mux_send_line) reject "="
    set -- "${@:1:$#-1}"
  fi
  STEP_SCRIPT="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/wsh-step.sh"
  [ -f "$STEP_SCRIPT" ] || { echo "missing $STEP_SCRIPT" >&2; exit 10; }
  if [ -n "$SESS_FLAG" ]; then SESS=$(resolve_session "$SESS_FLAG")
  else SESS=$(resolve_session "$SESS"); fi
  need_session "$SESS"
  # Own-session guard (Task 2, lot 2) — see send) above for the rationale.
  # `banner` isn't in plan §3's table, but it writes into the pane through
  # this same mux_send_line (it sources the banner helper INSIDE the
  # pane's shell, same as send/step-run) — treated as an omission, not a
  # deliberate exclusion.
  deny_own_session "$SESS" || exit 8
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
  # --session/-s short-circuits the loop below — see send) above.
  parse_session_flag "$@"; set -- ${PSF_REST[@]+"${PSF_REST[@]}"}
  local_sess=""
  timeout_sec=""
  target_seq=""
  PRINT=0
  for arg in "$@"; do
    case "$arg" in --print) PRINT=1 ;; esac
    # Form first, existence second — see banner) above for the rationale.
    # Session-shaped token next to --session: contradiction, fail loud.
    flag_conflict_check "$arg"
    if [ -z "$SESS_FLAG" ] && [ -z "$local_sess" ] && { looks_like_session "$arg" || mux_has "$arg"; }; then
      local_sess="${arg#=}"
    elif [ -z "$timeout_sec" ] && [[ "$arg" =~ ^[0-9]+$ ]]; then
      timeout_sec="$arg"
    elif [ -z "$target_seq" ] && [[ "$arg" =~ ^[0-9]+$ ]]; then
      target_seq="$arg"
    fi
  done
  if [ -n "$SESS_FLAG" ]; then SESS=$(resolve_session "$SESS_FLAG")
  else SESS=$(resolve_session "${local_sess:-}"); fi
  need_session "$SESS"
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
  TAB_NAME=""
  ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --tab) TAB_NAME="${2:?usage: open [session] --tab <name>}"; shift 2 ;;
      *) ARGS+=("$1"); shift ;;
    esac
  done
  SESS=$(resolve_session "${ARGS[0]:-}"); need_session "$SESS"
  if [ "$MUX" = tmux ]; then MUX_BIN=$(command -v tmux); else MUX_BIN=$(zellij_bin); fi
  ATTACH=$(mux_attach_cmd "$SESS")
  command -v wsh >/dev/null 2>&1 || {
    echo "wsh not found — can't auto-open a Wave block. Attach by hand:" >&2
    echo "  ${ATTACH}" >&2; exit 5; }

  TAB=""
  if [ -n "$TAB_NAME" ]; then
    TAB_RC=0
    resolve_tab_by_name "$TAB_NAME" || TAB_RC=$?
    case "$TAB_RC" in
      0)
        TAB="$TAB_BY_NAME_RESULT"
        if [ "$(tab_count_candidates "$TAB_BY_NAME_ALL")" -gt 1 ]; then
          echo "⚠️  multiple tabs named '$TAB_NAME' in this workspace — using the first (pinned, then tab order): $(printf '%s' "$TAB_BY_NAME_ALL" | tr '\n' ' ')" >&2
        fi
        ;;
      2)
        echo "--tab '$TAB_NAME' requires running inside Wave (WAVETERM_WORKSPACEID not set) — refusing to guess a tab" >&2
        exit 6
        ;;
      1)
        echo "--tab '$TAB_NAME': Wave's live state DB is unreachable (wsh/wavepath/sqlite3) — refusing to guess a tab" >&2
        exit 6
        ;;
      3)
        echo "no tab named '$TAB_NAME' in this workspace — falling back to the current/live tab" >&2
        ;;
    esac
  fi

  if [ -z "$TAB" ] && ! TAB=$(resolve_live_tab_cached "$SESS"); then
    cat >&2 <<MSG
could not find a live Wave tab to anchor the block on (stale/empty Wave state).
Ask the user to attach manually in any terminal or Wave block:

  ${ATTACH}
MSG
    exit 6
  fi

  # Anchor on the LIVE tab (overriding any stale WAVETERM_TABID), and run the mux
  # by ABSOLUTE path because the Wave block's shell lacks the homebrew PATH.
  EXEC_CMD=$(mux_block_attach_cmd "$SESS" "$MUX_BIN")
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
      RHOME=$("$0" read "$SESS" 40 2>&1 | tr -d '\r' | grep -o '^WSH_REMOTE_HOME=.*' | tail -n1 | cut -d= -f2-)
    fi
    if [ -z "$RHOME" ]; then
      echo "warn: could not resolve \$HOME on '$HOST' — falling back to inline-only remote mode" >&2
    else
      REMOTE_DIR="${RHOME}/.cache/wsh-cockpit/helpers"
      # $RHOME can legally contain a single quote; escape it before embedding
      # inside the single-quoted `mkdir -p` sent to the remote pane.
      REMOTE_DIR_Q=${REMOTE_DIR//\'/\'\\\'\'}
      set +e
      WSH_LIVE_SEP_REINIT=1 "$0" send "mkdir -p '${REMOTE_DIR_Q}'" "$SESS" >/dev/null 2>&1
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
selftest-guard)
  cmd_selftest_guard
  ;;
selftest-claim)
  cmd_selftest_claim
  ;;
selftest-adopt)
  cmd_selftest_adopt
  ;;
selftest-tab)
  cmd_selftest_tab
  ;;
selftest-wrapper)
  cmd_selftest_wrapper
  ;;
selftest-attach)
  cmd_selftest_attach
  ;;
push)
  have_mux
  # [session] is genuinely optional: with only <local> <remote-path> the
  # remembered last session is used (same convention as send/read) — a 3-arg
  # call always names the session first, so a path can never be mistaken for one.
  if [ $# -ge 3 ]; then SESS=$(resolve_session "$1"); shift; else SESS=$(resolve_session ""); fi
  need_session "$SESS"
  LOCAL="${1:?usage: wsh-live.sh push [session] <local> <remote-path>}"; shift || true
  REMOTE="${1:?usage: wsh-live.sh push [session] <local> <remote-path>}"; shift || true
  cmd_transfer push "$SESS" "$LOCAL" "$REMOTE"
  ;;
pull)
  have_mux
  if [ $# -ge 3 ]; then SESS=$(resolve_session "$1"); shift; else SESS=$(resolve_session ""); fi
  need_session "$SESS"
  REMOTE="${1:?usage: wsh-live.sh pull [session] <remote-path> <local>}"; shift || true
  LOCAL="${1:?usage: wsh-live.sh pull [session] <remote-path> <local>}"; shift || true
  cmd_transfer pull "$SESS" "$LOCAL" "$REMOTE"
  ;;
send)
  have_mux
  # --session/-s short-circuits the positional [session] slot below (plan §2
  # point tranché 1, lot 2 t3) — see lib/session.sh:parse_session_flag.
  parse_session_flag "$@"; set -- ${PSF_REST[@]+"${PSF_REST[@]}"}
  CMD="${1:?usage: wsh-live.sh send '<command>' [session] (or --session/-s NAME)}"
  if [ -n "$SESS_FLAG" ]; then SESS=$(resolve_session "$SESS_FLAG")
  else SESS=$(resolve_session "${2:-}"); fi
  need_session "$SESS"
  # Own-session guard (Task 2, lot 2): send/keys/step-run/banner all reach
  # mux_send_line/send-keys on a raw, caller-supplied session name — same
  # hazard class as stop/gc (Task 1, lot 2), but here the effect is WRITE,
  # not destruction (plan §3: guard follows effect class). Against your own
  # pane, "send" doesn't run a command, it TYPES into whatever's running
  # there — against an interactive foreground (a live CLI REPL, most
  # dangerously another Claude Code session) the text gets SUBMITTED as a
  # new prompt instead of executing (measured, see docs/gotchas.md); worse,
  # since the caller's own shell is still the foreground reader of that
  # pane, the typed text just queues silently until the caller's own
  # process eventually returns control — `step-run`'s wait-done then times
  # out (rc=124) rather than ever seeing the real result. Unlike `stop`,
  # there is no "kept, continue" here: each of these 4 sites targets
  # exactly the one session it was given, so refusal is outright (exit 8,
  # same family as `stop`/`start --reuse`). READ paths (read/output/
  # wait-done) stay unguarded on purpose (plan §3: lecture = libre).
  # `banner` writes via this same mux_send_line (it sources the banner
  # helper INSIDE the pane's shell) even though plan §3's table doesn't
  # list it — treated as an omission, not a deliberate exclusion, so it
  # gets the guard too (see banner) below). keys/step-run/banner repeat
  # only the one-line call, not this rationale.
  deny_own_session "$SESS" || exit 8
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
  # --session/-s short-circuits the positional [session] slot — see send) above.
  parse_session_flag "$@"; set -- ${PSF_REST[@]+"${PSF_REST[@]}"}
  K="${1:?usage: wsh-live.sh keys '<tmux-keys>' [session] (or --session/-s NAME)}"
  if [ -n "$SESS_FLAG" ]; then SESS=$(resolve_session "$SESS_FLAG")
  else SESS=$(resolve_session "${2:-}"); fi
  need_session "$SESS"
  # Own-session guard (Task 2, lot 2) — see send) above for the rationale.
  deny_own_session "$SESS" || exit 8
  [ "$MUX" = tmux ] || {
    echo "keys: tmux-only (raw tmux key names have no zellij equivalent; use send)" >&2; exit 13; }
  # No -l here: tmux key names are meant to be interpreted (C-c, Up, PageUp...).
  # shellcheck disable=SC2086
  tmux send-keys -t "$SESS" $K
  echo "keys -> ${SESS}: $K"
  ;;
read)
  have_mux
  # --session/-s short-circuits the positional [session] slot — see send) above.
  parse_session_flag "$@"; set -- ${PSF_REST[@]+"${PSF_REST[@]}"}
  if [ -n "$SESS_FLAG" ]; then
    SESS=$(resolve_session "$SESS_FLAG")
    LINES="${1:-30}"
  elif [ -n "${1:-}" ] && [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    SESS=$(resolve_session "")
    LINES="$1"
  else
    SESS=$(resolve_session "${1:-}")
    LINES="${2:-30}"
  fi
  # Single validation point for every branch above: a non-numeric LINES
  # (read --session NAME foo / read NAME foo) would reach capture-pane as an
  # invalid -S argument and fail confusingly — usage error instead.
  [[ "$LINES" =~ ^[0-9]+$ ]] || {
    echo "read: lines must be a positive integer, got '$LINES'" >&2; exit 2; }
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
  # --session/-s short-circuits the loop below — see send) above.
  parse_session_flag "$@"; set -- ${PSF_REST[@]+"${PSF_REST[@]}"}
  FULL=0
  local_sess=""
  target_seq=""
  for arg in "$@"; do
    case "$arg" in --full) FULL=1 ;; esac
    # Form first, existence second — see banner) above for the rationale.
    # Session-shaped token next to --session: contradiction, fail loud.
    flag_conflict_check "$arg"
    if [ -z "$SESS_FLAG" ] && [ -z "$local_sess" ] && { looks_like_session "$arg" || mux_has "$arg"; }; then
      local_sess="${arg#=}"
    elif [ -z "$target_seq" ] && [[ "$arg" =~ ^[0-9]+$ ]]; then
      target_seq="$arg"
    fi
  done
  if [ -n "$SESS_FLAG" ]; then SESS=$(resolve_session "$SESS_FLAG")
  else SESS=$(resolve_session "${local_sess:-}"); fi
  need_session "$SESS"
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
  # --session/-s short-circuits the loop below — see send) above.
  parse_session_flag "$@"; set -- ${PSF_REST[@]+"${PSF_REST[@]}"}
  ID="${1:?usage: wsh-live.sh step-run <id> '<label>' '<command>' [session] [timeout_sec] (or --session/-s NAME)}"
  shift || true
  LABEL="${1:?usage: wsh-live.sh step-run <id> '<label>' '<command>' [session] [timeout_sec]}"
  shift || true
  CMD="${1:?usage: wsh-live.sh step-run <id> '<label>' '<command>' [session] [timeout_sec]}"
  shift || true
  run_sess=""
  run_timeout=""
  for arg in "$@"; do
    # Form first, existence second — see banner) above for the rationale.
    # Session-shaped token next to --session: contradiction, fail loud.
    flag_conflict_check "$arg"
    if [ -z "$SESS_FLAG" ] && [ -z "$run_sess" ] && { looks_like_session "$arg" || mux_has "$arg"; }; then
      run_sess="${arg#=}"
    elif [ -z "$run_timeout" ] && [[ "$arg" =~ ^[0-9]+$ ]]; then
      run_timeout="$arg"
    fi
  done
  if [ -n "$SESS_FLAG" ]; then SESS=$(resolve_session "$SESS_FLAG")
  else SESS=$(resolve_session "${run_sess:-}"); fi
  need_session "$SESS"
  # Own-session guard (Task 2, lot 2) — see send) above for the rationale.
  # Caught HERE, before step_run() ever fires its internal banner/send/
  # wait-done subcalls: those would otherwise queue into the caller's own
  # pane and wait-done would time out (rc=124) rather than ever refuse.
  deny_own_session "$SESS" || exit 8
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
  # Own-session guard (Task 1, lot 2): stop is the other place a raw
  # caller-supplied session name reaches a destructive call, alongside
  # start --reuse above — and unlike that reuse path this one is
  # unconditional, no --force escape hatch. Lives HERE, not inside
  # resolve_session/teardown_session: resolve_session must stay
  # mux-agnostic (also used by send/read/current, which never destroy
  # anything), and teardown_session is shared with `gc`, which gets its
  # OWN guard below in lib/gc.sh — deliberately different in kind: a sweep
  # skips its own session and continues on the rest, `stop` refuses
  # outright since it only ever targets the one session it was given
  # (plan §3 bis: guard placement follows effect class, not call site).
  rc=0; session_is_own "$SESS" || rc=$?
  if [ "$rc" -eq 2 ]; then
    session_indeterminate_refusal "$SESS"
    exit 8
  fi
  if [ "$rc" -eq 0 ]; then
    session_own_refusal "$SESS"
    exit 8
  fi
  # Sticky keep (spec v12 §3, step-1.6): a session marked keep-<slug> must
  # never be destroyed by `stop` — no matter which key currently owns its
  # claim — only released, so a future adoption/scan can pick it back up.
  # Checked BEFORE the destroy path below; un-keeping a session is fiche
  # 1.9's job (posing the marker), not this dispatch's.
  # Actual kill + state cleanup (seq file, sep/step helper options, web view,
  # last-session pointer) lives in teardown_session (lib/session.sh) — shared
  # with `gc`, which needs the exact same per-session cleanup on a sweep.
  if keep_is_set "$SESS"; then
    if release_session "$SESS"; then
      echo "released session '$SESS' (keep)"
    else
      echo "cannot release '$SESS': not the owning agent" >&2
      exit 8
    fi
  elif teardown_session "$SESS"; then
    echo "killed session '$SESS'"
  else
    echo "no session '$SESS' to kill"
  fi
  ;;
release)
  have_mux
  # Mandatory argument, deliberately NO last-session default (spec v12 §3):
  # a shared-key sub-agent that forgets the argument must not silently
  # release whatever session it last touched.
  SESS="${1:?usage: $0 release <session>}"
  need_session "$SESS"
  if release_session "$SESS"; then
    echo "released session '$SESS'"
  else
    echo "cannot release '$SESS': not the owning agent" >&2
    exit 8
  fi
  ;;
*)
  echo "usage: $0 {spawn|start|open|send|keys|read|output|push|pull|stop|release|current|doctor|gc|status|web|banner|step-run|remote-init|local-init|wait-done|selftest-sep|selftest-live|selftest-gc|selftest-cache|selftest-oneshot-ssh|selftest-output|selftest-transfer|selftest-guard|selftest-claim|selftest-adopt|selftest-tab|selftest-wrapper|selftest-attach} [args]" >&2; exit 2 ;;
esac
