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
  # Non-negotiable guard: an attached session is never a GC candidate,
  # regardless of age — mirrors the "never touch a session in use" spirit of
  # the own_tmux_session guard elsewhere in this skill.
  [ "$attached" = "0" ] || return 1
  local age=$((now - activity))
  [ "$age" -ge "$idle" ]
}

# wsh-live.sh gc [--dry-run] [--idle=SECONDS]
#   --idle=SECONDS   override WSH_LIVE_GC_IDLE (default 86400 = 24h)
#   --dry-run        list what WOULD be killed; touches nothing
cmd_gc() {
  local DRY_RUN=0 IDLE="${WSH_LIVE_GC_IDLE:-86400}"
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      --idle=*) IDLE="${arg#--idle=}" ;;
      *) echo "gc: unknown arg '$arg' (usage: $0 gc [--dry-run] [--idle=SECONDS])" >&2; exit 2 ;;
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
  sessions=$(printf '%s\n' "$sessions" | grep '^cockpit-' || true)

  local nm att act killed=0 kept=0 wouldkill=0
  while IFS='|' read -r nm att act; do
    [ -n "$nm" ] || continue
    if gc_should_kill "$now" "$act" "$att" "$IDLE"; then
      if [ "$DRY_RUN" -eq 1 ]; then
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
