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

# Fresh attached-client count for ONE session, queried at kill time (issue
# #23): cmd_gc's list-sessions snapshot is taken once at the top of the
# sweep and is stale by the time the loop reaches a candidate — a client that
# attached in between must not be killed. Deliberately NOT pure (unlike
# gc_should_kill above): calling tmux is the whole point.
# Matching by NAME only, via list-sessions + awk '$1==n' — never a `-t`
# target: tmux resolves `-t` by exact name, then PREFIX, then fnmatch (and a
# window name of the current session prefixing the target wins over the
# session name — measured tmux 3.8), so `display-message -t <name>` on a dead
# name that is a strict prefix of a LIVING neighbour answers with the
# NEIGHBOUR's attached count, rc 0 — which could get an attached session
# killed. list-sessions has no target resolution: the name must match a live
# session's name, otherwise awk exits 1 (absent -> rc 1 -> kept). The field
# separator is 0x1F (ASCII unit separator), which tmux REJECTS inside session
# names ("invalid session name", measured), so the split is unambiguous for
# ANY valid session name — unlike '|', which a name could legally contain.
# Prints the count and returns 0 on a clean numeric answer; returns 1
# (printing nothing) when the query fails, the session is absent, or the
# answer is non-numeric — callers must read rc 1 as "unverifiable", never as
# "0 attached".
gc_attached_now() {
  local a
  a=$(tmux list-sessions -F $'#{session_name}\x1f#{session_attached}' 2>/dev/null \
      | awk -F $'\x1f' -v n="$1" '$1==n{print $2; f=1} END{exit !f}') || return 1
  case "$a" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$a"
}

# Atomic detach-check + kill for ONE exact session (issue #23).
# gc_attached_now and mux_kill are two tmux clients: a client can attach in
# the gap and still be killed. One if-shell -F evaluates session_attached and
# runs kill-session inside the same server command, so nothing else is
# scheduled between the check and the kill.
#
# Target selection, measured tmux 3.8:
# - `if-shell -t =name` does not expand formats (always the else branch) —
#   a detached session would never be killed.
# - `if-shell -t name` is NOT exact: a window of that name in a neighbour
#   wins, so the attached count can be the neighbour's.
# - `kill-session` with no -t ignores if-shell's -t and kills another session.
# The id comes from list-sessions (no -t resolution, same rule as
# gc_attached_now). if-shell -t "$id" then kills only if THAT id still has
# this exact name AND session_attached == 0. kill-session itself stays
# anchored `-t =name`, so a stale id cannot take a neighbour with it.
# Names outside [A-Za-z0-9_.-] are refused: they would be re-parsed inside
# the tmux command string.
#
# Returns 0 and sets GC_PREKILL_KILLED to the name when THIS call killed it
# (cmd_gc's mux_kill wrapper then reports success without a second kill).
# Returns 2 when the session is still there but was not killed (attached).
# Returns 1 when the session is absent or the answer is unverifiable.
# Prints nothing — the guard below logs the skip.
gc_kill_if_detached() {  # $1 session name
  local s="$1" id fmt out rc=0
  GC_PREKILL_KILLED=
  case "$s" in
    ''|*[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  id=$(tmux list-sessions -F $'#{session_id}\x1f#{session_name}' 2>/dev/null \
      | awk -F $'\x1f' -v n="$s" '$2==n{print $1; f=1} END{exit !f}') || return 1
  case "$id" in '$'[0-9]*) ;; *) return 1 ;; esac
  fmt="#{&&:#{==:#{session_attached},0},#{==:#{session_name},${s}}}"
  out=$(tmux if-shell -F -t "$id" "$fmt" \
        "kill-session -t =${s}" \
        "display-message -p GC_KEEP" 2>/dev/null) || rc=$?
  if [ "$out" = "GC_KEEP" ] && gc_attached_now "$s" >/dev/null; then
    return 2
  fi
  if [ "$rc" -ne 0 ] || [ "$out" = "GC_KEEP" ]; then
    return 1
  fi
  if gc_attached_now "$s" >/dev/null; then return 1; fi
  GC_PREKILL_KILLED=$s
  return 0
}

# Pre-kill guard installed by cmd_gc as teardown_session's
# TEARDOWN_PRE_KILL_GUARD (issue #23): runs IMMEDIATELY before mux_kill.
# On tmux the check and the kill are the single if-shell above — a client
# attaching during teardown's read-only canonicalisation is spared, and so
# is one attaching in the old gap between a fresh list-sessions and
# kill-session. rc 0 = this call already killed the session; rc 1 = keep
# (this function logs the "kept:" line, teardown_session returns 3 and does
# not call mux_kill). A non-tmux mux keeps the old read-only re-check.
gc_pre_kill_guard() {  # $1 session name
  local a rc=0
  if [ "${MUX:-}" = tmux ]; then
    gc_kill_if_detached "$1" || rc=$?
    if [ "$rc" -eq 0 ]; then return 0; fi
    if [ "$rc" -eq 2 ]; then
      a=$(gc_attached_now "$1") || a='?'
      echo "kept: $1 (attached ${a} client(s) at atomic pre-kill — not touched)"
      return 1
    fi
    echo "kept: $1 (attached re-check unverifiable at atomic pre-kill — not touched)"
    return 1
  fi
  a=$(gc_attached_now "$1") || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "kept: $1 (attached re-check unverifiable at pre-kill — not touched)"
    return 1
  fi
  if [ "$a" -gt 0 ]; then
    echo "kept: $1 (attached $a client(s) at pre-kill re-check — not touched)"
    return 1
  fi
  return 0
}

# cmd_gc kills inside gc_pre_kill_guard (one if-shell). teardown_session still
# calls mux_kill afterwards and treats a failed kill of a session that is
# already gone as "raced". The wrapper turns that expected second call into
# success so the sweep reports a normal kill and still runs cleanup.
# Installed only for the sweep, then restored — `stop` keeps plain mux_kill.
gc_mux_kill_wrap_install() {
  if ! declare -F mux_kill_before_gc >/dev/null 2>&1; then
    eval "$(declare -f mux_kill | sed '1s/^mux_kill /mux_kill_before_gc /')"
  fi
  # shellcheck disable=SC2329  # replaces mux_kill for the sweep; teardown_session calls it
  mux_kill() {
    local s="${1#=}"
    if [ -n "${GC_PREKILL_KILLED:-}" ] && [ "$GC_PREKILL_KILLED" = "$s" ]; then
      GC_PREKILL_KILLED=
      return 0
    fi
    mux_kill_before_gc "$@"
  }
}
gc_mux_kill_wrap_restore() {
  if declare -F mux_kill_before_gc >/dev/null 2>&1; then
    eval "$(declare -f mux_kill_before_gc | sed '1s/^mux_kill_before_gc /mux_kill /')"
  fi
  GC_PREKILL_KILLED=
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

  local nm att act killed=0 kept=0 wouldkill=0 eff_idle is_keep fresh_att fresh_rc
  # Installed as teardown_session's pre-kill hook for the whole sweep (bash
  # dynamic scoping: teardown_session sees this local). `stop` never sets it
  # and keeps its explicit kill semantics. teardown_session's order is
  # guard -> kill -> cleanup. On tmux the guard's if-shell both re-checks
  # and kills (issue #23): a client attaching during teardown's read-only
  # canonicalisation, or in the gap after the snapshot re-check below, is
  # not killed. A refused kill leaves ZERO state modified.
  # shellcheck disable=SC2034  # read via ${TEARDOWN_PRE_KILL_GUARD:-} in lib/session.sh (bash dynamic scoping)
  local TEARDOWN_PRE_KILL_GUARD="gc_pre_kill_guard"
  gc_mux_kill_wrap_install
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
      else
        # TOCTOU re-check (issue #23): $att is from the one-shot snapshot at
        # the top of this sweep — while the loop was tearing down earlier
        # candidates, a client may have attached to THIS session. Query its
        # attached count FRESH before teardown: >0, or a failed / ambiguous
        # query, means keep it. The kill itself re-checks again inside one
        # tmux if-shell (gc_pre_kill_guard) — this read and that kill are
        # not the same process. Fail-safe: never kill on uncertain state,
        # same rule as the hygiene pass above.
        fresh_att=""; fresh_rc=0
        fresh_att=$(gc_attached_now "$nm") || fresh_rc=$?
        if [ "$fresh_rc" -ne 0 ]; then
          kept=$((kept + 1))
          echo "kept: $nm (attached re-check unverifiable before kill — not touched)"
        elif [ "$fresh_att" -gt 0 ]; then
          kept=$((kept + 1))
          echo "kept: $nm (attached $fresh_att client(s) at re-check, snapshot said $att)"
        else
          rc=0; teardown_session "$nm" || rc=$?
          if [ "$rc" -eq 0 ]; then
            killed=$((killed + 1))
            echo "killed: $nm (idle $((now - act))s >= ${eff_idle}s)"
          elif ! mux_has "$nm"; then
            # teardown_session returned 3 with the session already gone -- a
            # concurrent gc/stop (e.g. spawn's background auto-sweep, or another
            # agent's own gc) won the race. The outcome we wanted still holds, so
            # it counts as killed rather than vanishing from both tallies.
            # (teardown_session's guard->kill->cleanup order guarantees it
            # modified nothing on that path.)
            killed=$((killed + 1))
            echo "killed: $nm (already gone -- raced with a concurrent sweep)"
          elif [ "$rc" -eq 3 ]; then
            # pre-kill guard refused the kill (attached/unverifiable right
            # before mux_kill, session still present) — it already logged the
            # "kept:" line; nothing was modified.
            kept=$((kept + 1))
          else
            echo "gc: failed to kill '$nm' (still present)" >&2
          fi
        fi
      fi
    else
      kept=$((kept + 1))
    fi
  done < <(printf '%s\n' "$sessions")
  gc_mux_kill_wrap_restore

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "gc: dry-run — ${wouldkill} would be killed, ${kept} kept (idle threshold ${IDLE}s)"
  else
    echo "gc: ${killed} killed, ${kept} kept (idle threshold ${IDLE}s)"
  fi
}
