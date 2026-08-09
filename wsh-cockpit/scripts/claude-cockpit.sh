#!/usr/bin/env bash
# claude-cockpit.sh — pre-open one or more wsh-cockpit sessions, hand them to
# `claude` as adoptable pre-claims, then sweep them on exit (spec: fiche
# step-1.9). Sibling of wsh-live.sh; not sourced, run directly.
#
# Install (symlink onto an already-PATH'd ~/.local/bin — never edit shell rc):
#   ln -sf "$(cd "$(dirname "$0")" && pwd)/claude-cockpit.sh" ~/.local/bin/claude-cockpit
#
# Usage:
#   claude-cockpit [prefix1] [--keep] [spawn-flags...] \
#     [--and prefix2] [--keep] [spawn-flags...] ... \
#     [-- claude-args...]
#
# Each "--and"-delimited group opens one cockpit: everything in the group
# except --keep is relayed verbatim to `wsh-live.sh spawn` (always with
# --force --preopen appended, so every group is a genuinely fresh session,
# never a silent reuse); --keep poses a sticky keep-<slug> marker on the
# session as soon as it's created, so the exit sweep below releases it
# instead of destroying it. Every group spawns under its own scoped
# WSH_COCKPIT_AGENT=user-preopen-<n> (n = 1-based group index) — set only for
# that one subprocess call, never exported into this wrapper's own
# environment or into claude's.
#
# Refuses BEFORE any group is spawned (clear stderr message, nonzero exit,
# claude never launched) if: (a) any prefix or flag VALUE in a group
# literally contains "--" (a superset check: it also catches "--and", the
# group separator itself — a value shaped like either would be ambiguous
# with the CLI grammar), or (b) two groups resolve to the same normalized
# prefix (normalize_prefix, scoped exactly like the real spawn call below —
# so two prefix-less groups never falsely collide just because they'd both
# fall back to "live" some other way).
#
# Once every group has spawned successfully, `claude` runs in the FOREGROUND
# (never exec — this wrapper must regain control once claude exits) with the
# args following "--" on the command line, WSH_COCKPIT_ADOPT set to the
# ordered comma-joined list of created sessions, and
# WSH_COCKPIT_AGENT=claude-<epoch>-<pid>. WSH_COCKPIT_PREFIX is actively
# absent from claude's environment (and from every scoped spawn call above)
# even if it happens to be set in this wrapper's own inherited environment —
# left in place it would outrank WSH_COCKPIT_AGENT in normalize_prefix's own
# precedence order and misroute every prefix resolution downstream.
#
# If any group's spawn genuinely fails, claude is NEVER launched; cockpits
# already opened by earlier groups in the same run are left open (no
# rollback — close them by hand with `wsh-live.sh stop`).
#
# After claude returns (ANY exit code counts as "normal" here — only an
# actual crash of this wrapper itself skips the sweep), every currently-live
# cockpit-* session still claimed by this run — by claude-<runid> itself
# (successfully adopted during the run) or still sitting under its original
# user-preopen-<n> pre-claim (never adopted) — is swept: released
# (`wsh-live.sh release`) if it carries the keep marker, stopped/destroyed
# (`wsh-live.sh stop`) otherwise. claude-cockpit's own exit code mirrors
# claude's.

set -euo pipefail

STATE_DIR="${WSH_COCKPIT_STATE_DIR:-$HOME/.cache/wsh-cockpit}"
MUX="${WSH_MUX:-tmux}"
# CDPATH= : see wsh-live.sh's own bootstrap comment — a matching CDPATH entry
# makes `cd` PRINT the directory, which would corrupt this assignment.
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
WSH_LIVE="$SCRIPT_DIR/wsh-live.sh"
# shellcheck source=./lib/mux.sh
. "$SCRIPT_DIR/lib/mux.sh"
# shellcheck source=./lib/claim.sh
. "$SCRIPT_DIR/lib/claim.sh"
# shellcheck source=./lib/session.sh
. "$SCRIPT_DIR/lib/session.sh"

have_mux

# -- CLI split: cockpit-side groups vs. claude's own args (first bare "--") --
COCKPIT_ARGS=()
CLAUDE_ARGS=()
SEEN_DASHDASH=0
for arg in "$@"; do
  if [ "$SEEN_DASHDASH" -eq 1 ]; then
    CLAUDE_ARGS+=("$arg")
  elif [ "$arg" = "--" ]; then
    SEEN_DASHDASH=1
  else
    COCKPIT_ARGS+=("$arg")
  fi
done

# -- Group parsing --------------------------------------------------------
# bash 3.2 has no arrays-of-arrays, so instead of building one array of
# per-group arrays up front, each group's tokens are re-derived from
# COCKPIT_ARGS on every pass (validate, then spawn) via this one splitter —
# cheaper than the offset/slice bookkeeping an array-of-arrays substitute
# would need, and avoids the bash-3.2 "unbound variable on empty array"
# pitfall a shared array of variable-length groups would otherwise invite.

# Split COCKPIT_ARGS on literal "--and" tokens, calling "$1" once per group
# as "$1" <group-index, 1-based> <group's own tokens...>. Always calls at
# least once: a bare `claude-cockpit -- ...` is one implicit empty group
# (no prefix, no flags) — normalize_prefix's own fallback chain still
# resolves it to something sane (the scoped WSH_COCKPIT_AGENT for that
# group).
for_each_group() {
  local cb="$1" n=0 tok
  local -a grp=()
  for tok in ${COCKPIT_ARGS[@]+"${COCKPIT_ARGS[@]}"}; do
    if [ "$tok" = "--and" ]; then
      n=$((n + 1))
      "$cb" "$n" ${grp[@]+"${grp[@]}"}
      grp=()
    else
      grp+=("$tok")
    fi
  done
  n=$((n + 1))
  "$cb" "$n" ${grp[@]+"${grp[@]}"}
}

# Parse one group's raw tokens ($@) into PG_PREFIX / PG_KEEP / PG_RELAY[].
# Grammar: [prefix] [--keep] [+ any spawn flag, relayed as-is]. The prefix,
# when present, is always the group's very first token — never re-guessed
# from a later bare-looking token, which could just as well be a flag's
# OWN value (e.g. --pre's host, --tab's name).
parse_group() {
  PG_PREFIX=""
  PG_KEEP=0
  PG_RELAY=()
  local first=1 tok
  for tok in "$@"; do
    if [ "$first" -eq 1 ]; then
      first=0
      case "$tok" in
        -*) : ;;
        *) PG_PREFIX="$tok"; continue ;;
      esac
    fi
    if [ "$tok" = "--keep" ]; then
      PG_KEEP=1
    else
      PG_RELAY+=("$tok")
    fi
  done
}

# The normalized prefix a group's spawn call will actually resolve to — same
# scoping (WSH_COCKPIT_AGENT=user-preopen-<n>, WSH_COCKPIT_PREFIX absent) the
# real spawn call below uses, so the collision check can't diverge from what
# spawn itself would do.
group_norm_prefix() {  # $1 n  $2 raw prefix -> prints normalized prefix
  ( unset WSH_COCKPIT_PREFIX
    WSH_COCKPIT_AGENT="user-preopen-$1" normalize_prefix "$2" )
}

# -- Pass 1: validate every group BEFORE any spawn call ----------------------
# Known spawn flag NAMES are whitelisted by exact match; every OTHER token
# (the prefix itself, and every flag's VALUE) is checked for containing "--"
# — deliberately not narrower ("--and" only): a value shaped like the group
# separator itself is just as ambiguous with this CLI's grammar.
GROUP_COUNT=0
GROUP_NORM=()
validate_group() {
  local n="$1"; shift
  parse_group "$@"
  GROUP_COUNT="$n"
  local tok
  for tok in "$PG_PREFIX" ${PG_RELAY[@]+"${PG_RELAY[@]}"}; do
    case "$tok" in
      ""|--force|--fresh|--situate|--pre|--tab|--preopen) continue ;;
    esac
    case "$tok" in
      *--*)
        echo "claude-cockpit: group $n: value '$tok' literally contains '--' (ambiguous with the --and group separator) — rename it" >&2
        exit 2
        ;;
    esac
  done
  GROUP_NORM[$n]=$(group_norm_prefix "$n" "$PG_PREFIX")
}
for_each_group validate_group

n=1
while [ "$n" -le "$GROUP_COUNT" ]; do
  m=$((n + 1))
  while [ "$m" -le "$GROUP_COUNT" ]; do
    if [ "${GROUP_NORM[$n]}" = "${GROUP_NORM[$m]}" ]; then
      echo "claude-cockpit: groups $n and $m both resolve to prefix '${GROUP_NORM[$n]}' — give one of them an explicit, distinct prefix" >&2
      exit 2
    fi
    m=$((m + 1))
  done
  n=$((n + 1))
done

# -- Pass 2: spawn every group, scoped, in order ------------------------------
ALL_SESSIONS=()
spawn_group() {
  local n="$1"; shift
  parse_group "$@"
  local agent_key="user-preopen-$n" out rc=0
  # PG_PREFIX is a positional argument to `spawn`, not a flag — parse_group
  # strips it out of PG_RELAY specifically so it isn't double-counted by the
  # "--" substring scan above, but it still has to be relayed itself; spawn's
  # own parser treats any non-flag token as the prefix regardless of position,
  # so it's prepended here for clarity, not out of necessity.
  local -a relay=()
  [ -n "$PG_PREFIX" ] && relay+=("$PG_PREFIX")
  relay+=(${PG_RELAY[@]+"${PG_RELAY[@]}"})
  out=$(env -u WSH_COCKPIT_PREFIX WSH_COCKPIT_AGENT="$agent_key" \
        "$WSH_LIVE" spawn ${relay[@]+"${relay[@]}"} --force --preopen 2>&1) || rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    echo "claude-cockpit: group $n (prefix '${PG_PREFIX:-<none>}') failed to spawn — aborting before launching claude; cockpits already opened by earlier groups in this run are left as-is" >&2
    exit 1
  fi
  local sess
  sess=$(printf '%s\n' "$out" | sed -n 's/^SESSION=//p' | tail -n1)
  if [ -z "$sess" ]; then
    echo "claude-cockpit: group $n spawned but printed no SESSION= line — aborting" >&2
    exit 1
  fi
  ALL_SESSIONS+=("$sess")
  if [ "$PG_KEEP" -eq 1 ]; then
    mkdir -p "$STATE_DIR"
    : >"$(keep_file "$sess")"
  fi
}
for_each_group spawn_group

# -- Launch claude, adopting every pre-opened session -------------------------
RUNID="$(date +%s)-$$"
AGENT_KEY="claude-$RUNID"
ADOPT_LIST=""
for s in ${ALL_SESSIONS[@]+"${ALL_SESSIONS[@]}"}; do
  ADOPT_LIST="${ADOPT_LIST:+$ADOPT_LIST,}$s"
done

# True if $1 is one of THIS run's own spawned sessions (ALL_SESSIONS) —
# guards the user-preopen-* sweep branch below against a same-named pre-claim
# key from a DIFFERENT, concurrent run (step-1.11.1, audit finding E1): those
# keys are indexed by group number, not by run, so two parallel runs' first
# groups both produce "user-preopen-1". bash 3.2 has no associative arrays,
# hence the linear scan. Defined here, BEFORE claude is launched, because the
# trap installed below must be armed before the one command that could be
# interrupted.
session_in_this_run() {
  local target="$1" s
  for s in ${ALL_SESSIONS[@]+"${ALL_SESSIONS[@]}"}; do
    [ "$s" = "$target" ] && return 0
  done
  return 1
}

# -- Exit sweep: release keep-marked sessions, stop the rest -----------------
# Enumeration modeled on gc.sh's cmd_gc: live cockpit-* sessions, each
# checked against its OWN current claim owner (mux_list_sessions ->
# session_slug -> claim_read_key) — not a raw glob over $STATE_DIR's marker
# files, which would surface dead-session residue this sweep has no business
# touching (that's gc's hygiene pass, a different concern). A session's
# owner key here is read fresh, not assumed: it is either still its original
# user-preopen-<n> pre-claim (never adopted during claude's run) or has since
# become AGENT_KEY (claude adopted it). Either way the session is part of
# THIS run's adopt pool: ADOPT_LIST is built from every session this run
# spawned (ALL_SESSIONS), not just the ones claude actually adopted — so
# WSH_COCKPIT_ADOPT="$ADOPT_LIST" is passed on BOTH release calls below.
# release_session's own WSH_COCKPIT_ADOPT-membership branch then retrogrades
# the claim to "released" (re-adoptable via étape 2 only) rather than
# removing it outright to ABSENT, which would fall back to the less-safe
# étape 3 legacy scan. The user-preopen-* branch is further narrowed to
# sessions THIS run actually spawned: that pre-claim key alone doesn't prove
# ownership across runs.
#
# Wrapped in a function and armed as a trap (EXIT/INT/TERM), not run as
# straight-line code after `claude`, because a foreground Ctrl-C delivers
# SIGINT to this whole process group: bash itself receives it, and
# straight-line code placed after the `claude` call would never run — every
# pre-opened cockpit would leak until the next `gc` pass. EXIT_SWEEP_DONE is
# a plain flag (bash 3.2: no associative arrays) guarding idempotency; the
# INT/TERM handlers don't run the sweep themselves, they just `exit` with the
# conventional signal exit code, which re-triggers the EXIT trap below.
EXIT_SWEEP_DONE=0
run_exit_sweep() {
  [ "$EXIT_SWEEP_DONE" -eq 0 ] || return 0
  EXIT_SWEEP_DONE=1
  local s slug owner
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    slug=$(session_slug "$s")
    owner=$(claim_read_key "$(claim_path "$slug")" 2>/dev/null || true)
    case "$owner" in
      "$AGENT_KEY") ;;
      user-preopen-*) session_in_this_run "$s" || continue ;;
      *) continue ;;
    esac
    if keep_is_set "$s"; then
      if ! env -u WSH_COCKPIT_PREFIX WSH_COCKPIT_AGENT="$owner" WSH_COCKPIT_ADOPT="$ADOPT_LIST" "$WSH_LIVE" release "$s"; then
        echo "claude-cockpit: warning: could not release '$s'" >&2
      fi
    else
      if ! env -u WSH_COCKPIT_PREFIX "$WSH_LIVE" stop "$s"; then
        echo "claude-cockpit: warning: could not stop '$s'" >&2
      fi
    fi
  done < <(mux_list_sessions | grep '^cockpit-' || true)
}
trap run_exit_sweep EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CLAUDE_RC=0
env -u WSH_COCKPIT_PREFIX WSH_COCKPIT_AGENT="$AGENT_KEY" WSH_COCKPIT_ADOPT="$ADOPT_LIST" \
  claude ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"} || CLAUDE_RC=$?

exit "$CLAUDE_RC"
