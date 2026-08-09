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

# -- keep-floor (spec v12 §3, step-1.7) -----------------------------------
# A "keep" session (sticky marker posed at creation, fiche 1.9) is protected
# by AT LEAST 24h of detached-idle time regardless of a shorter --idle the
# caller passed (a manual `gc --idle=0`, or a lower WSH_LIVE_GC_IDLE
# default) — a keep closed by hand (Wave block closed, the natural "I'm
# done" gesture) must not be swept the instant it's briefly unattended.
# Once idle beyond that floor it falls back to whatever --idle was actually
# requested — otherwise deadlock: a session only the user can close would
# never die. No tmux/date calls — pure, directly testable, same rationale
# as gc_should_kill above (see cmd_selftest_gc).
GC_KEEP_FLOOR_IDLE=86400
gc_effective_idle() {  # $1 requested_idle  $2 is_keep ("1"/"0") -> effective idle
  local requested="$1" is_keep="$2"
  if [ "$is_keep" = "1" ] && [ "$requested" -lt "$GC_KEEP_FLOOR_IDLE" ]; then
    printf '%s\n' "$GC_KEEP_FLOOR_IDLE"
  else
    printf '%s\n' "$requested"
  fi
}

# -- marker hygiene pass (spec v12 §3, step-1.7) --------------------------
# teardown_session (lib/session.sh) already cleans up claim + prefix + seq +
# oneshot-ssh + tab + block + cm for the ONE session it kills — but nothing
# runs teardown_session for a keep closed by hand (no `stop` ever called) or
# an adopting agent that crashed mid-transfer. This pass finds those orphans
# across $STATE_DIR, keyed off which session slugs are CURRENTLY alive, and
# cleans anything left behind by a session that no longer exists — without
# ever touching a live session's markers.
#
# Fail-safe ("never act on uncertain state", same rule as cmd_gc's own tmux
# reachability check below): a FAILED or uncertain session listing must
# never be treated as "zero sessions" (which would make every marker on
# disk look orphaned) — mux_list_sessions's rc is the only signal trusted
# here, a transient listing failure leaves the whole pass inert.
#
#   $1 dry_run  ("1" = report only, touch nothing; default "0")
#   $2 scope    optional substring filter on the marker's basename — used
#               ONLY by selftest-gc so it never touches the real user's
#               markers elsewhere in $STATE_DIR; empty (default) = no
#               filter, the real production behaviour.
gc__slug_alive() {  # $1 slug  $2 live_slugs (newline-separated) -> rc 0 if alive
  printf '%s\n' "$2" | grep -Fqx -- "$1"
}
gc__marker_age() {  # $1 path  $2 now -> prints age in seconds, rc 1 on stat failure
  local mtime
  mtime=$(stat -f '%m' "$1" 2>/dev/null) || mtime=$(stat -c '%Y' "$1" 2>/dev/null) || return 1
  printf '%s\n' "$(( $2 - mtime ))"
}
gc_hygiene_pass() {
  local dry_run="${1:-0}" scope="${2:-}" live_raw rc=0
  live_raw=$(mux_list_sessions) || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ -t 1 ]; then
      echo "gc: hygiene skipped — session listing failed (uncertain state, nothing touched)"
    fi
    return 0
  fi

  local now; now=$(date '+%s')
  local live_slugs="" nm
  while IFS= read -r nm; do
    [ -n "$nm" ] || continue
    live_slugs="${live_slugs}$(session_slug "$nm")"$'\n'
  done <<EOF
$live_raw
EOF

  local age_min=300                                # 5 min, anti-race floor
  local won_age_min=$(( 2 * ${WSH_WAIT_TIMEOUT:-300} ))   # 600s default
  local cleaned=0 restored=0 f base slug age pat pid pointed

  # Generic <prefix><slug> families: orphan = slug not alive AND age >=
  # age_min. adopt-claim-*.won-*/.stale-* are excluded here on purpose —
  # their "slug" is not a real session slug (see the dedicated .won pass
  # below); a naive rm here would de-claim a LIVE session.
  for pat in keep- prefix- seq- oneshot-ssh- pane- tab- adopt-claim-; do
    for f in "$STATE_DIR/${pat}"*; do
      [ -e "$f" ] || continue
      base=$(basename "$f")
      case "$base" in *.won-*|*.stale-*) continue ;; esac
      [ -z "$scope" ] || case "$base" in *"$scope"*) ;; *) continue ;; esac
      slug="${base#${pat}}"
      age=$(gc__marker_age "$f" "$now") || continue
      [ "$age" -ge "$age_min" ] || continue
      gc__slug_alive "$slug" "$live_slugs" && continue
      cleaned=$((cleaned + 1))
      if [ "$dry_run" = "1" ]; then
        echo "gc: hygiene would-clean: $base (dead slug, age ${age}s)"
      else
        rm -f "$f" 2>/dev/null || true
        echo "gc: hygiene cleaned: $base (dead slug, age ${age}s)"
      fi
    done
  done

  # block-<slug>: best-effort `wsh deleteblock` before dropping the marker
  # (spec v12 §3 — "pas de rm sec").
  for f in "$STATE_DIR"/block-*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    [ -z "$scope" ] || case "$base" in *"$scope"*) ;; *) continue ;; esac
    slug="${base#block-}"
    age=$(gc__marker_age "$f" "$now") || continue
    [ "$age" -ge "$age_min" ] || continue
    gc__slug_alive "$slug" "$live_slugs" && continue
    cleaned=$((cleaned + 1))
    if [ "$dry_run" = "1" ]; then
      echo "gc: hygiene would-clean: $base (dead slug, age ${age}s)"
    else
      block_id_close_path "$f"
      echo "gc: hygiene cleaned: $base (dead slug, age ${age}s, block closed best-effort)"
    fi
  done

  # cm-<slug>: best-effort `ssh -O exit` on the control socket before
  # dropping the marker (spec v12 §3 — "pas de rm sec"), same primitive
  # teardown_session already uses.
  for f in "$STATE_DIR"/cm-*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    [ -z "$scope" ] || case "$base" in *"$scope"*) ;; *) continue ;; esac
    slug="${base#cm-}"
    age=$(gc__marker_age "$f" "$now") || continue
    [ "$age" -ge "$age_min" ] || continue
    gc__slug_alive "$slug" "$live_slugs" && continue
    cleaned=$((cleaned + 1))
    if [ "$dry_run" = "1" ]; then
      echo "gc: hygiene would-clean: $base (dead slug, age ${age}s)"
    else
      if [ -S "$f" ] && command -v ssh >/dev/null 2>&1; then
        ssh -o ControlPath="$f" -O exit x >/dev/null 2>&1 || true
      fi
      rm -f "$f" 2>/dev/null || true
      echo "gc: hygiene cleaned: $base (dead slug, age ${age}s, ssh control master closed best-effort)"
    fi
  done

  # adopt-dead-warned-<slug>: hygiene by age alone — its slug is EXPECTED to
  # be dead the moment it's written (it only exists for offers that were
  # already refused as not-alive), so it uses the 24h floor, not the 5min
  # anti-race one (spec v12 §3).
  for f in "$STATE_DIR"/adopt-dead-warned-*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    [ -z "$scope" ] || case "$base" in *"$scope"*) ;; *) continue ;; esac
    slug="${base#adopt-dead-warned-}"
    age=$(gc__marker_age "$f" "$now") || continue
    [ "$age" -ge "$GC_KEEP_FLOOR_IDLE" ] || continue
    gc__slug_alive "$slug" "$live_slugs" && continue
    cleaned=$((cleaned + 1))
    if [ "$dry_run" = "1" ]; then
      echo "gc: hygiene would-clean: $base (dead slug, age ${age}s)"
    else
      rm -f "$f" 2>/dev/null || true
      echo "gc: hygiene cleaned: $base (dead slug, age ${age}s)"
    fi
  done

  # last-session-<key>: content-based, NOT slug-based — the filename suffix
  # is an AGENT KEY (state_file), not a session slug, so this is the one
  # family where the file's CONTENT (the session name it points at) decides
  # liveness, never the filename itself.
  for f in "$STATE_DIR"/last-session-*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    [ -z "$scope" ] || case "$base" in *"$scope"*) ;; *) continue ;; esac
    age=$(gc__marker_age "$f" "$now") || continue
    [ "$age" -ge "$age_min" ] || continue
    pointed=$(tr -d '[:space:]' <"$f" 2>/dev/null || true)
    [ -n "$pointed" ] && gc__slug_alive "$(session_slug "$pointed")" "$live_slugs" && continue
    cleaned=$((cleaned + 1))
    if [ "$dry_run" = "1" ]; then
      echo "gc: hygiene would-clean: $base (points to dead/empty session, age ${age}s)"
    else
      rm -f "$f" 2>/dev/null || true
      echo "gc: hygiene cleaned: $base (points to dead/empty session, age ${age}s)"
    fi
  done

  # Dedicated adopt-claim-*.won-<pid> pass (adoptant crashed between rename
  # and write) — CUMULATIVE conditions: pid dead (kill -0 fails) AND age >
  # 2×WSH_WAIT_TIMEOUT (a legitimate probe can run for the full timeout —
  # the 5min generic floor would be exactly the race window). Live session
  # -> restored to pre-claim via the no-clobber ln/rm primitive (fiche 1.2,
  # I1); dead -> dropped. The generic adopt-claim- sweep above deliberately
  # ignores these (case "*.won-*" excluded).
  for f in "$STATE_DIR"/adopt-claim-*.won-*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    [ -z "$scope" ] || case "$base" in *"$scope"*) ;; *) continue ;; esac
    pid=$(claim_read_pid "$f" 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && continue
    age=$(gc__marker_age "$f" "$now") || continue
    [ "$age" -ge "$won_age_min" ] || continue
    slug="${base%.won-${pid}}"
    slug="${slug#adopt-claim-}"
    if gc__slug_alive "$slug" "$live_slugs"; then
      if [ "$dry_run" = "1" ]; then
        restored=$((restored + 1))
        echo "gc: hygiene would-restore: $base -> pre-claim (dead pid, age ${age}s, session alive)"
      elif claim_rollback "$slug" "$pid" >/dev/null 2>&1; then
        restored=$((restored + 1))
        echo "gc: hygiene restored: $base -> pre-claim (dead pid, age ${age}s, session alive)"
      fi
    else
      cleaned=$((cleaned + 1))
      if [ "$dry_run" = "1" ]; then
        echo "gc: hygiene would-clean: $base (dead pid, age ${age}s, session dead)"
      else
        rm -f "$f" 2>/dev/null || true
        echo "gc: hygiene cleaned: $base (dead pid, age ${age}s, session dead)"
      fi
    fi
  done

  if [ "$dry_run" = "1" ]; then
    echo "gc: hygiene dry-run — ${cleaned} would be cleaned, ${restored} would be restored"
  else
    echo "gc: hygiene — ${cleaned} cleaned, ${restored} restored"
  fi
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

  # Marker hygiene runs before the tmux-only bail-out below: it is
  # mux-generic (mux_list_sessions, tmux OR zellij) and independent of the
  # session-kill sweep that follows.
  gc_hygiene_pass "$DRY_RUN"

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

  local nm att act killed=0 kept=0 wouldkill=0 eff_idle is_keep
  while IFS='|' read -r nm att act; do
    [ -n "$nm" ] || continue
    is_keep=0
    if keep_is_set "$nm"; then
      is_keep=1
    fi
    eff_idle=$(gc_effective_idle "$IDLE" "$is_keep")
    if gc_should_kill "$now" "$act" "$att" "$eff_idle"; then
      rc=0; session_is_own "$nm" || rc=$?
      if [ "$rc" -eq 0 ]; then
        kept=$((kept + 1))
        echo "kept: $nm (own session — never a GC candidate)"
      elif [ "$DRY_RUN" -eq 1 ]; then
        wouldkill=$((wouldkill + 1))
        echo "would-kill: $nm (idle $((now - act))s >= ${eff_idle}s)"
      elif teardown_session "$nm"; then
        killed=$((killed + 1))
        echo "killed: $nm (idle $((now - act))s >= ${eff_idle}s)"
      elif ! mux_has "$nm"; then
        # teardown_session failed because the session is already gone -- a
        # concurrent gc/stop (e.g. spawn's background auto-sweep, or another
        # agent's own gc) won the race. The outcome we wanted still holds, so
        # it counts as killed rather than vanishing from both tallies.
        killed=$((killed + 1))
        echo "killed: $nm (already gone -- raced with a concurrent sweep)"
      else
        echo "gc: failed to kill '$nm' (still present)" >&2
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
