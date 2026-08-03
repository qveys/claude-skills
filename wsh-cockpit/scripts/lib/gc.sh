#!/usr/bin/env bash
# lib/gc.sh — idle-sweep garbage collection for orphaned cockpit-* sessions.
# Sourced by wsh-live.sh; not meant to be run standalone.
#
# `live` sessions are only ever removed by an explicit `stop` — if that call
# never happens (crash, forgotten cockpit, agent that exits without cleaning
# up), the tmux session leaks forever. `gc` is a periodic/on-demand sweep:
# anything named cockpit-* that has been idle (no pane activity) for at least
# the threshold AND has no client attached gets torn down via the same
# teardown_session() that `stop` uses (lib/session.sh).

# Pure decision: should THIS session be GC'd? No tmux/date calls inside — a
# small, directly-testable function (see cmd_selftest_gc) that doesn't need a
# real aged tmux session to exercise (tmux gives no way to force
# session_created/session_activity into the past).
#   $1 now              epoch seconds "now"
#   $2 session_activity  epoch seconds of last pane activity
#   $3 session_attached  tmux's own attached-client count ("0" = nobody attached)
#   $4 idle_threshold    seconds
# Returns 0 (yes — kill it) or 1 (no — keep it).
gc_should_kill() {
  local now="$1" activity="$2" attached="$3" idle="$4"
  # This checks idle age and the attached-client count ONLY — it does NOT
  # know or care whether the session being evaluated is the one the sweep
  # itself is running inside. Measured, before Task 1 (lot 2): `gc --idle=0`
  # run from inside a detached cockpit-* session killed that session out
  # from under itself (see docs/gotchas.md history). The own-session guard
  # now lives in cmd_gc below, not here: a probe before the loop refuses
  # the WHOLE sweep outright when identity is indeterminable ($TMUX set,
  # $TMUX_PANE unset), and a per-candidate session_is_own check inside the
  # loop skips (kept, not an error) any candidate that IS the caller's own
  # session. Keeping that guard out of gc_should_kill is deliberate: this
  # function stays pure (no tmux/date calls), which is what makes it
  # directly testable with fabricated timestamps (see cmd_selftest_gc).
  [ "$attached" = "0" ] || return 1
  local age=$((now - activity))
  [ "$age" -ge "$idle" ]
}

# wsh-live.sh gc [--dry-run] [--idle=SECONDS] [--only-session=NAME]
#   --idle=SECONDS        override WSH_LIVE_GC_IDLE (default 86400 = 24h)
#   --dry-run             list what WOULD be killed; touches nothing
#   --only-session=NAME   restrict the sweep to exactly this cockpit-* session
#                         instead of all of them — used by selftest-gc so it
#                         never touches unrelated sessions on a dev machine
cmd_gc() {
  local DRY_RUN=0 IDLE="${WSH_LIVE_GC_IDLE:-86400}" ONLY_SESSION=""
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      --idle=*) IDLE="${arg#--idle=}" ;;
      --only-session=*) ONLY_SESSION="${arg#--only-session=}" ;;
      *) echo "gc: unknown arg '$arg' (usage: $0 gc [--dry-run] [--idle=SECONDS] [--only-session=NAME])" >&2; exit 2 ;;
    esac
  done
  case "$IDLE" in ''|*[!0-9]*)
    echo "gc: --idle must be a non-negative integer of seconds (got '$IDLE')" >&2; exit 2 ;;
  esac

  # Fail-safe, same spirit as tmux-wave-gc.sh: never act on uncertain state.
  # gc only understands tmux's per-session attached/activity fields (no
  # zellij equivalent, same precedent as `keys`/`web` refusing explicitly) —
  # and an unreachable/absent tmux server just means nothing to sweep yet,
  # not an error. Both cases return 0 quietly rather than have_mux's hard exit,
  # because `gc` is also called best-effort from spawn/start on every session
  # creation and must never make THAT fail.
  if [ "$MUX" != tmux ] || ! command -v tmux >/dev/null 2>&1; then
    [ -t 1 ] && echo "gc: skipped (tmux-only — no zellij session_attached/session_activity equivalent)"
    return 0
  fi
  local now sessions
  now=$(date '+%s')
  if ! sessions=$(tmux list-sessions -F '#{session_name}|#{session_attached}|#{session_activity}' 2>/dev/null); then
    [ -t 1 ] && echo "gc: no tmux server reachable — nothing to sweep"
    return 0
  fi

  # Own-session guard (Task 1, lot 2), probed ONCE here rather than inside
  # the loop below: own_tmux_session's rc=2 ($TMUX set, $TMUX_PANE unset —
  # identity indeterminable) fires before session_is_own ever compares a
  # name, so it would be identical for every candidate in the loop. A REAL
  # sweep that cannot verify its own identity refuses outright — this is
  # exactly the state that used to let `gc --idle=0` kill its own detached
  # session (docs/gotchas.md). --dry-run never destroys anything regardless
  # of identity, so it skips this probe and keeps listing normally — the
  # per-candidate check further down still runs for it, it just can't
  # distinguish rc=1 from rc=2 there, which is harmless since dry-run only
  # prints.
  local rc
  if [ "$DRY_RUN" -eq 0 ]; then
    rc=0; session_is_own "cockpit-gc-probe-nonexistent" || rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "gc: cannot verify own session (\$TMUX set but \$TMUX_PANE unset) — nothing destroyed" >&2
      return 0
    fi
  fi

  sessions=$(printf '%s\n' "$sessions" | grep '^cockpit-' || true)
  if [ -n "$ONLY_SESSION" ]; then
    sessions=$(printf '%s\n' "$sessions" | awk -F'|' -v n="$ONLY_SESSION" '$1==n' || true)
  fi

  local nm att act killed=0 kept=0 wouldkill=0
  while IFS='|' read -r nm att act; do
    [ -n "$nm" ] || continue
    if gc_should_kill "$now" "$act" "$att" "$IDLE"; then
      rc=0; session_is_own "$nm" || rc=$?
      if [ "$rc" -eq 0 ]; then
        kept=$((kept + 1))
        echo "kept: $nm (own session — never a GC candidate)"
      elif [ "$DRY_RUN" -eq 1 ]; then
        wouldkill=$((wouldkill + 1))
        echo "would-kill: $nm (idle $((now - act))s >= ${IDLE}s)"
      elif teardown_session "$nm"; then
        killed=$((killed + 1))
        echo "killed: $nm (idle $((now - act))s >= ${IDLE}s)"
      else
        echo "gc: failed to kill '$nm' (already gone?)" >&2
      fi
    else
      kept=$((kept + 1))
    fi
  done < <(printf '%s\n' "$sessions")

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "gc: dry-run — ${wouldkill} would be killed, ${kept} kept (idle threshold ${IDLE}s)"
  else
    echo "gc: ${killed} killed, ${kept} kept (idle threshold ${IDLE}s)"
  fi
}
