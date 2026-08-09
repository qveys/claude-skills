#!/usr/bin/env bash
# lib/selftests.sh — selftest-sep and selftest-live subcommands.
# Sourced by wsh-live.sh; not meant to be run standalone.

cmd_selftest_sep() {
  # tmpdir is deliberately NOT local: the EXIT trap fires after this function
  # returns (at script exit), and a `local` var is out of scope by then —
  # under `set -u` that reads as "unbound variable", not "empty".
  local helper
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/wsh-live-sep-test.XXXXXX")
  trap 'rm -rf "$tmpdir"' EXIT
  helper="$tmpdir/live-sep-helper.sh"
  sep_helper_defs >"$helper"
  chmod 600 "$helper" 2>/dev/null || true

  local failures=0
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
}

# End-to-end smoke test on a real, throwaway tmux session — exercises the
# actual live loop (start → send → wait-done → read → banner → stop) with NO
# Wave block ever opened (never calls spawn/open). WSH_COCKPIT_AGENT=selftest
# isolates the last-session state file from whatever agent/prefix is normally
# driving this cockpit, so this test never clobbers a real workflow's session.
cmd_selftest_live() {
  have_mux
  export WSH_COCKPIT_AGENT=selftest
  # SESS, SF, LIVE_LOG_FILE are deliberately NOT local: live_selftest_cleanup
  # runs from the EXIT trap after this function has already returned (at
  # script exit), and a `local` var is out of scope by then — under `set -u`
  # that reads as "unbound variable", not "empty".
  local SEQF LIVE_LOG_DIR LIVE_LOG_SLUG
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

  local failures=0
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
  local out rc
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
  local seqval
  seqval=$(cat "$SEQF" 2>/dev/null || true)
  if [ "$seqval" = "2" ]; then
    report_live_case "7 seq file" 0
  else
    report_live_case "7 seq file" 1 "seq=$seqval want=2"
  fi

  # 8. default (no remote-init called yet, no env var): the very first send
  # back in step 2 must have used the short helper-sourcing form — reread the
  # scrollback (200 lines is well past steps 2-5's framing) and look for the
  # literal `. '<helper-path>' && __wsh '1' ...` line it typed.
  local helper_sep
  helper_sep=$(helper_path sep "$SEP_HELPER_VERSION")
  out=$("$0" read "$SESS" 200 2>&1 | tr -d '\r')
  if printf '%s' "$out" | tr -d '\n' | grep -Fq ". '${helper_sep}' && __wsh '1' 'echo LIVE_OK_"; then
    report_live_case "8 default sources helper" 0
  else
    report_live_case "8 default sources helper" 1 "expected sourcing form for #1 not found"
  fi

  # 9. remote-init (no host) flips send to inline framing for THIS session
  # even with NO env var set — confirms the sticky tmux-option flag drives
  # it, not the env var fallback path. Marker is a plain literal (no
  # arithmetic): the TYPED line is unevaluated shell text, so an arithmetic
  # expression like $((3*3)) would show up as literal "$((3*3))", not "9",
  # until it actually runs — a plain string sidesteps that trap entirely.
  # tmux-only: remote_mode_set is a no-op under zellij (no per-session option
  # store), so this assertion doesn't apply there — skip it like check 6.
  if [ "$MUX" != tmux ]; then
    echo "skip 9 remote-init inline (backend $MUX — no per-session option store)"
  else
    unset WSH_LIVE_SEP_REINIT WSH_STEP_INLINE 2>/dev/null || true
    set +e
    "$0" remote-init "$SESS" >/dev/null 2>&1
    "$0" send 'echo RI_INLINE_MARK' "$SESS" >/dev/null 2>&1
    "$0" wait-done "$SESS" 30 >/dev/null 2>&1
    rc=$?
    set -e
    out=$("$0" read "$SESS" 60 2>&1 | tr -d '\r')
    local flat9; flat9=$(printf '%s' "$out" | tr -d '\n')
    if [ "$rc" -eq 0 ] \
       && printf '%s' "$flat9" | grep -Fq '__wc=' \
       && printf '%s' "$out" | grep -Fq 'RI_INLINE_MARK'; then
      report_live_case "9 remote-init inline" 0
    else
      report_live_case "9 remote-init inline" 1 "rc=$rc missing inline __wc= marker and/or RI_INLINE_MARK"
    fi
  fi

  # 10. local-init reverts THIS session back to the short __wsh-call form —
  # match the exact literal line sep_wrap emits for THIS send (a distinct
  # marker text), so leftover inline text from step 9's scrollback can't
  # produce a false pass. Same tmux-only limitation as check 9.
  if [ "$MUX" != tmux ]; then
    echo "skip 10 local-init reverts (backend $MUX — no per-session option store)"
  else
    set +e
    "$0" local-init "$SESS" >/dev/null 2>&1
    "$0" send 'echo RI_LOCAL_MARK' "$SESS" >/dev/null 2>&1
    "$0" wait-done "$SESS" 30 >/dev/null 2>&1
    rc=$?
    set -e
    out=$("$0" read "$SESS" 60 2>&1 | tr -d '\r')
    if [ "$rc" -eq 0 ] \
       && printf '%s' "$out" | tr -d '\n' | grep -Eq "__wsh '[0-9]+' 'echo RI_LOCAL_MARK'"; then
      report_live_case "10 local-init reverts" 0
    else
      report_live_case "10 local-init reverts" 1 "rc=$rc expected short-form __wsh call for RI_LOCAL_MARK not found"
    fi
  fi

  # 11. step-run combines banner-step + framed send + wait-done into ONE call:
  # the pane must show both the step banner's label AND the framed command's
  # output, and step-run's own exit code must be the command's real rc (3) —
  # not wait-done's or read's.
  set +e
  "$0" step-run '11' 'step-run selftest' 'sh -c "echo STEP_RUN_OK; exit 3"' "$SESS" 30 >/dev/null 2>&1
  rc=$?
  set -e
  out=$("$0" read "$SESS" 60 2>&1 | tr -d '\r')
  if [ "$rc" -eq 3 ] \
     && printf '%s' "$out" | grep -Fq 'step-run selftest' \
     && printf '%s' "$out" | grep -Fq 'STEP_RUN_OK'; then
    report_live_case "11 step-run" 0
  else
    report_live_case "11 step-run" 1 "rc=$rc want=3, missing step banner label and/or command output"
  fi

  # 12. stop kills the session and removes its seq file
  "$0" stop "$SESS" >/dev/null 2>&1 || true
  if mux_has "$SESS"; then
    report_live_case "12 stop" 1 "session '$SESS' still alive"
  elif [ -f "$SEQF" ]; then
    report_live_case "12 stop" 1 "seq file still present: $SEQF"
  else
    report_live_case "12 stop" 0
  fi

  if [ "$failures" -ne 0 ]; then
    echo "selftest-live: $failures failure(s)" >&2
    exit 1
  fi
  echo "selftest-live: ok"
}

# gc smoke test: exercises gc_should_kill (lib/gc.sh) directly with fabricated
# timestamps — tmux gives no way to force session_created/session_activity
# into the past, so the pure decision function is what makes cases 1-3
# testable without a real aged session. Cases 4-5 then confirm the real `gc`
# subcommand end-to-end (dry-run vs. real sweep) on one throwaway,
# NEVER-attached tmux session — never calls spawn/open, matches selftest-live.
cmd_selftest_gc() {
  have_mux
  if [ "$MUX" != tmux ]; then
    echo "selftest-gc: skip (tmux-only backend — gc has no zellij equivalent)"
    return 0
  fi
  # SESS is deliberately NOT local: live_selftest_gc_cleanup runs from the
  # EXIT trap after this function has already returned — same rationale as
  # cmd_selftest_live's SESS/SF/LIVE_LOG_FILE.
  SESS="cockpit-selftest-gc-$$"
  local now rc failures=0
  now=$(date '+%s')

  report_gc_case() {  # $1 label  $2 rc (0=ok)  $3 detail (shown on failure)
    if [ "$2" -eq 0 ]; then
      echo "ok $1"
    else
      echo "FAIL $1${3:+: $3}" >&2
      failures=$((failures + 1))
    fi
  }

  # 1. a freshly-created session (age ~0) is NOT a candidate at the default threshold.
  set +e
  gc_should_kill "$now" "$now" "0" "${WSH_LIVE_GC_IDLE:-86400}"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then report_gc_case "1 fresh session kept" 0
  else report_gc_case "1 fresh session kept" 1 "gc_should_kill said kill for age~0"; fi

  # 2. an ATTACHED session is never a candidate, even maximally idle with --idle=0
  # — the non-negotiable safety guard.
  set +e
  gc_should_kill "$now" "$((now - 999999))" "1" "0"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then report_gc_case "2 attached session never killed" 0
  else report_gc_case "2 attached session never killed" 1 "gc_should_kill said kill for an attached session"; fi

  # 3. an unattached, sufficiently idle session IS a candidate.
  set +e
  gc_should_kill "$now" "$((now - 999999))" "0" "0"
  rc=$?
  set -e
  report_gc_case "3 idle unattached session is a candidate" "$rc"

  # 4-5. real session, real subcommand: --dry-run never kills; a real sweep does.
  # --only-session narrows the sweep to THIS throwaway session — without it,
  # `gc --idle=0` would sweep every unattached cockpit-* session on the
  # machine, including a developer's own detached cockpits. SESS2/SESS3 are
  # step-1.7's own throwaway sessions (hygiene .won-restore / keep-floor
  # cases below); also NOT local, same rationale as SESS.
  HYGPFX="selftestgc$$"
  SESS2="cockpit-${HYGPFX}-hyg2"
  SESS3="cockpit-${HYGPFX}-hyg3"
  live_selftest_gc_cleanup() {
    "$0" stop "$SESS" >/dev/null 2>&1 || true
    "$0" stop "$SESS2" >/dev/null 2>&1 || true
    "$0" stop "$SESS3" >/dev/null 2>&1 || true
    rm -f "$STATE_DIR"/*"$HYGPFX"* 2>/dev/null || true
  }
  trap live_selftest_gc_cleanup EXIT
  create_session "$SESS"   # detached by construction — never attached

  set +e
  "$0" gc --dry-run --idle=0 --only-session="$SESS" >/dev/null 2>&1
  set -e
  if mux_has "$SESS"; then report_gc_case "4 dry-run keeps session" 0
  else report_gc_case "4 dry-run keeps session" 1 "session was killed despite --dry-run"; fi

  set +e
  "$0" gc --idle=0 --only-session="$SESS" >/dev/null 2>&1
  set -e
  if mux_has "$SESS"; then report_gc_case "5 real sweep kills idle session" 1 "session still alive after gc --idle=0"
  else report_gc_case "5 real sweep kills idle session" 0; fi

  # -- step-1.7: marker hygiene pass + keep-floor (spec v12 §3) -----------
  # gc_hygiene_pass is called DIRECTLY as a function (not through the `gc`
  # subcommand) so every case can pass a dedicated $HYGPFX scope — its
  # basename-substring filter (gc.sh) means these cases can NEVER touch a
  # real marker of the user's, even if the real $STATE_DIR already has
  # unrelated orphans sitting in it (this test does not use an isolated
  # STATE_DIR/HOME, per the codebase's established convention of dedicated
  # slugs/prefixes against the real one instead).
  mkdir -p "$STATE_DIR"

  # A pid that has just exited: reliably dead, without the ambient risk of
  # a hardcoded large number colliding with a real process on the machine.
  gc_dead_pid() { ( : ) & local p=$!; wait "$p" 2>/dev/null || true; printf '%s\n' "$p"; }
  # Backdate a marker's mtime by N minutes (macOS/BSD touch — this project
  # targets Darwin only, see CONVENTIONS.md).
  gc_backdate() { touch -t "$(date -v-"${2:-10}"M '+%Y%m%d%H%M.%S')" "$1"; }

  # 6. a fresh marker (age ~0) is NEVER eaten, even for a slug that is dead.
  slug6="${HYGPFX}-fresh"
  kf6="$STATE_DIR/keep-$slug6"
  : >"$kf6"
  set +e
  gc_hygiene_pass 0 "$HYGPFX" >/dev/null 2>&1
  set -e
  if [ -e "$kf6" ]; then report_gc_case "6 fresh marker never eaten even if slug is dead" 0
  else report_gc_case "6 fresh marker never eaten even if slug is dead" 1 "fresh keep-$slug6 was removed"; fi

  # 7. a full orphaned marker family (dead slug, old) is swept: claim, keep,
  # prefix, seq, oneshot-ssh, tab, pane, block, cm.
  slug7="${HYGPFX}-fam"
  f7_claim="$STATE_DIR/adopt-claim-$slug7"
  f7_keep="$STATE_DIR/keep-$slug7"
  f7_prefix="$STATE_DIR/prefix-$slug7"
  f7_seq="$STATE_DIR/seq-$slug7"
  f7_oneshot="$STATE_DIR/oneshot-ssh-$slug7"
  f7_tab="$STATE_DIR/tab-$slug7"
  f7_pane="$STATE_DIR/pane-$slug7"
  f7_block="$STATE_DIR/block-$slug7"
  f7_cm="$STATE_DIR/cm-$slug7"
  printf 'default\n1\n' >"$f7_claim"
  : >"$f7_keep"; : >"$f7_prefix"; : >"$f7_seq"; : >"$f7_oneshot"
  : >"$f7_tab"; : >"$f7_pane"; printf 'not-a-real-block-id\n' >"$f7_block"
  : >"$f7_cm"   # not a socket — hygiene must rm it directly, never `ssh -O exit` it
  for f7 in "$f7_claim" "$f7_keep" "$f7_prefix" "$f7_seq" "$f7_oneshot" "$f7_tab" "$f7_pane" "$f7_block" "$f7_cm"; do
    gc_backdate "$f7" 10
  done
  set +e
  gc_hygiene_pass 0 "$HYGPFX" >/dev/null 2>&1
  set -e
  rc=0
  for f7 in "$f7_claim" "$f7_keep" "$f7_prefix" "$f7_seq" "$f7_oneshot" "$f7_tab" "$f7_pane" "$f7_block" "$f7_cm"; do
    [ -e "$f7" ] && rc=1
  done
  report_gc_case "7 orphaned marker family swept (claim/keep/prefix/seq/oneshot-ssh/tab/pane/block/cm)" "$rc" "some markers of dead slug '$slug7' survived"

  # 8. last-session-<key>: content-based, not slug-based (state_file's
  # suffix is an AGENT KEY, never a session slug) — pointing at a dead
  # session, old enough, gets swept.
  f8="$STATE_DIR/last-session-${HYGPFX}key8"
  printf 'cockpit-%s-neverlive\n' "$HYGPFX" >"$f8"
  gc_backdate "$f8" 10
  set +e
  gc_hygiene_pass 0 "$HYGPFX" >/dev/null 2>&1
  set -e
  if [ -e "$f8" ]; then report_gc_case "8 last-session pointing at a dead session swept" 1 "$f8 survived"
  else report_gc_case "8 last-session pointing at a dead session swept" 0; fi

  # 9. last-session-<key> pointing at a LIVE session is kept, regardless of age.
  create_session "$SESS2"
  f9="$STATE_DIR/last-session-${HYGPFX}key9"
  printf '%s\n' "$SESS2" >"$f9"
  gc_backdate "$f9" 10
  set +e
  gc_hygiene_pass 0 "$HYGPFX" >/dev/null 2>&1
  set -e
  if [ -e "$f9" ] && [ "$(cat "$f9")" = "$SESS2" ]; then report_gc_case "9 last-session pointing at a live session kept" 0
  else report_gc_case "9 last-session pointing at a live session kept" 1 "$f9 was removed or altered"; fi

  # 10. .won of a dead pid, old enough, LIVE session -> restored to pre-claim
  # (no-clobber ln/rm, fiche 1.2 I1).
  slug10=$(session_slug "$SESS2")
  pid10=$(gc_dead_pid)
  won10=$(claim_won_path "$slug10" "$pid10")
  printf 'user-preopen-1\n%s\n' "$pid10" >"$won10"
  gc_backdate "$won10" 11
  set +e
  gc_hygiene_pass 0 "$HYGPFX" >/dev/null 2>&1
  set -e
  claim10="$(claim_path "$slug10")"
  if [ ! -e "$won10" ] && [ -f "$claim10" ] && [ "$(claim_read_key "$claim10")" = "user-preopen-1" ]; then
    report_gc_case "10 dead-pid .won restored to pre-claim (session alive)" 0
  else
    report_gc_case "10 dead-pid .won restored to pre-claim (session alive)" 1 "won=$([ -e "$won10" ] && echo present || echo gone) claim=$([ -f "$claim10" ] && echo present || echo absent)"
  fi
  rm -f "$claim10" 2>/dev/null || true

  # 11. .won of a dead pid, old enough, DEAD session -> purged.
  slug11="${HYGPFX}-wonpurge"
  pid11=$(gc_dead_pid)
  won11=$(claim_won_path "$slug11" "$pid11")
  mkdir -p "$STATE_DIR"
  printf 'released\n%s\n' "$pid11" >"$won11"
  gc_backdate "$won11" 11
  set +e
  gc_hygiene_pass 0 "$HYGPFX" >/dev/null 2>&1
  set -e
  if [ -e "$won11" ]; then report_gc_case "11 dead-pid .won purged (session dead)" 1 "$won11 survived"
  else report_gc_case "11 dead-pid .won purged (session dead)" 0; fi

  # 12. .won too young (< 2*WSH_WAIT_TIMEOUT) is left alone even for a dead
  # pid and a dead session — a legitimate probe can run the full timeout.
  slug12="${HYGPFX}-wonyoung"
  pid12=$(gc_dead_pid)
  won12=$(claim_won_path "$slug12" "$pid12")
  mkdir -p "$STATE_DIR"
  printf 'released\n%s\n' "$pid12" >"$won12"
  gc_backdate "$won12" 1
  set +e
  gc_hygiene_pass 0 "$HYGPFX" >/dev/null 2>&1
  set -e
  if [ -e "$won12" ]; then report_gc_case "12 young dead-pid .won left alone" 0
  else report_gc_case "12 young dead-pid .won left alone" 1 "$won12 was removed"; fi

  # 13. .won of a LIVE pid ($$, this very process) is left alone even old
  # and even for a dead session — pid-alive always blocks the dedicated pass.
  slug13="${HYGPFX}-wonlivepid"
  won13=$(claim_won_path "$slug13" "$$")
  mkdir -p "$STATE_DIR"
  printf 'released\n%s\n' "$$" >"$won13"
  gc_backdate "$won13" 11
  set +e
  gc_hygiene_pass 0 "$HYGPFX" >/dev/null 2>&1
  set -e
  if [ -e "$won13" ]; then report_gc_case "13 live-pid .won left alone" 0
  else report_gc_case "13 live-pid .won left alone" 1 "$won13 was removed despite a live pid"; fi
  rm -f "$won13" 2>/dev/null || true

  # 14. session listing failure -> the whole pass is inert (never treats a
  # failed/uncertain listing as "zero sessions"). tmux is hidden from PATH
  # for exactly this one call — same idiom as selftest-adopt's NOWSH_PATH.
  slug14="${HYGPFX}-listfail"
  kf14="$STATE_DIR/keep-$slug14"
  : >"$kf14"
  gc_backdate "$kf14" 10
  save_path14="$PATH"
  PATH="/usr/bin:/bin:/usr/sbin:/sbin"
  set +e
  gc_hygiene_pass 0 "$HYGPFX" >/dev/null 2>&1
  set -e
  PATH="$save_path14"
  if [ -e "$kf14" ]; then report_gc_case "14 listing failure leaves hygiene inert" 0
  else report_gc_case "14 listing failure leaves hygiene inert" 1 "$kf14 was removed despite an unreachable listing"; fi

  # 15-17. gc_effective_idle (pure): keep-floor arithmetic in isolation.
  val=$(gc_effective_idle 0 1)
  if [ "$val" = "86400" ]; then report_gc_case "15 gc_effective_idle floors a keep session at 24h" 0
  else report_gc_case "15 gc_effective_idle floors a keep session at 24h" 1 "got $val, want 86400"; fi

  val=$(gc_effective_idle 999999 1)
  if [ "$val" = "999999" ]; then report_gc_case "16 gc_effective_idle never LOWERS an already-high idle" 0
  else report_gc_case "16 gc_effective_idle never LOWERS an already-high idle" 1 "got $val, want 999999"; fi

  val=$(gc_effective_idle 0 0)
  if [ "$val" = "0" ]; then report_gc_case "17 gc_effective_idle leaves a non-keep session untouched" 0
  else report_gc_case "17 gc_effective_idle leaves a non-keep session untouched" 1 "got $val, want 0"; fi

  # 18-19. gc_should_kill composed with gc_effective_idle: the keep-floor
  # actually protects (young) and actually expires (>24h) — real tmux gives
  # no way to force session_activity into the past, so this is proven the
  # same pure way as gc_should_kill's own cases 1-3 above.
  set +e
  gc_should_kill "$now" "$((now - 100))" "0" "$(gc_effective_idle 0 1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then report_gc_case "18 keep session, idle=0, young detached: floor keeps it" 0
  else report_gc_case "18 keep session, idle=0, young detached: floor keeps it" 1 "killed despite the 24h floor"; fi

  set +e
  gc_should_kill "$now" "$((now - 90000))" "0" "$(gc_effective_idle 0 1)"
  rc=$?
  set -e
  report_gc_case "19 keep session detached past 24h falls back to normal sweep" "$rc"

  # 20. end-to-end wiring proof: a REAL keep session survives a real
  # `gc --idle=0` sweep (cf. case 5's non-keep session, which does not).
  create_session "$SESS3"
  mkdir -p "$STATE_DIR"
  : >"$(keep_file "$SESS3")"
  set +e
  "$0" gc --idle=0 --only-session="$SESS3" >/dev/null 2>&1
  set -e
  if mux_has "$SESS3"; then report_gc_case "20 keep session survives a real gc --idle=0 sweep" 0
  else report_gc_case "20 keep session survives a real gc --idle=0 sweep" 1 "keep session was killed despite the sticky marker"; fi

  if [ "$failures" -ne 0 ]; then
    echo "selftest-gc: $failures failure(s)" >&2
    exit 1
  fi
  echo "selftest-gc: ok"
}

# Cache smoke test: exercises resolve_live_tab_cached (lib/wave.sh) against
# whatever live tab this machine can actually resolve right now — skipped
# entirely if none can be, same spirit as selftest-gc's tmux-only skip. Never
# calls spawn/open; uses a throwaway session name purely as a cache key, so
# teardown_session at the end only needs to clean up the cache file it wrote.
cmd_selftest_cache() {
  local failures=0 SESS CF TAB1 TAB2 TAB3 TAB4

  report_cache_case() {  # $1 label  $2 rc (0=ok)  $3 detail (shown on failure)
    if [ "$2" -eq 0 ]; then
      echo "ok $1"
    else
      echo "FAIL $1${3:+: $3}" >&2
      failures=$((failures + 1))
    fi
  }

  if ! command -v sqlite3 >/dev/null 2>&1 || ! TAB1=$(resolve_live_tab 2>/dev/null); then
    echo "selftest-cache: skip (no live Wave tab resolvable — nothing to validate)"
    return 0
  fi

  SESS="cockpit-selftest-cache-$$"
  CF=$(tab_cache_file "$SESS")
  rm -f "$CF" 2>/dev/null || true

  # 1. miss: no cache file yet — resolves live and populates the cache.
  TAB2=$(resolve_live_tab_cached "$SESS" 2>/dev/null || true)
  if [ "$TAB2" = "$TAB1" ] && [ -f "$CF" ] && [ "$(tr -d '[:space:]' <"$CF")" = "$TAB1" ]; then
    report_cache_case "1 miss populates cache" 0
  else
    report_cache_case "1 miss populates cache" 1 "got '$TAB2', cache file '$CF' missing or mismatched"
  fi

  # 2. hit: same tab returned, purely from the cache file.
  TAB3=$(resolve_live_tab_cached "$SESS" 2>/dev/null || true)
  if [ "$TAB3" = "$TAB1" ]; then
    report_cache_case "2 hit returns cached tab" 0
  else
    report_cache_case "2 hit returns cached tab" 1 "got '$TAB3' want '$TAB1'"
  fi

  # 3. invalidation: a poisoned/stale entry is detected (validation query) and
  # transparently re-resolved, overwriting the cache with the real tab again.
  printf '%s\n' "nonexistent-oid-$$" >"$CF"
  TAB4=$(resolve_live_tab_cached "$SESS" 2>/dev/null || true)
  if [ "$TAB4" = "$TAB1" ] && [ "$(tr -d '[:space:]' <"$CF" 2>/dev/null)" = "$TAB1" ]; then
    report_cache_case "3 stale cache entry is revalidated" 0
  else
    report_cache_case "3 stale cache entry is revalidated" 1 "got '$TAB4', cache now '$(cat "$CF" 2>/dev/null)'"
  fi

  # 4. teardown_session (stop/gc's shared cleanup) drops the cache file.
  teardown_session "$SESS" >/dev/null 2>&1 || true
  if [ -f "$CF" ]; then
    report_cache_case "4 teardown_session invalidates cache" 1 "cache file still present: $CF"
  else
    report_cache_case "4 teardown_session invalidates cache" 0
  fi

  rm -f "$CF" 2>/dev/null || true

  # 5. block-id state: teardown_session closes a stubbed block-id best-effort,
  # even with no real Wave block behind it — `wsh deleteblock` on a fake id
  # just returns "not found", swallowed by block_id_close's `|| true`. Proves
  # the auto-close path can't break teardown_session outside a real Wave env.
  local BF
  BF=$(block_id_file "$SESS")
  block_id_store "$SESS" "not-a-real-block-$$"
  if [ -f "$BF" ]; then
    report_cache_case "5a block_id_store writes state" 0
  else
    report_cache_case "5a block_id_store writes state" 1 "no state file at $BF"
  fi
  teardown_session "$SESS" >/dev/null 2>&1 || true
  if [ -f "$BF" ]; then
    report_cache_case "5b teardown_session closes block-id state" 1 "state file still present: $BF"
  else
    report_cache_case "5b teardown_session closes block-id state" 0
  fi

  if [ "$failures" -ne 0 ]; then
    echo "selftest-cache: $failures failure(s)" >&2
    exit 1
  fi
  echo "selftest-cache: ok"
}

# One-shot-SSH nudge test: pure-function pattern matching (lib/session.sh's
# oneshot_ssh_is_inline) plus the consecutive-count/warning behavior of
# oneshot_ssh_track, exercised directly against its state file — no tmux
# session needed (the tracker only touches $STATE_DIR), same spirit as
# selftest-gc's pure gc_should_kill cases.
cmd_selftest_oneshot_ssh() {
  # SESS, F are deliberately NOT local: the EXIT trap below fires after this
  # function returns (at script exit), and a `local` var is out of scope by
  # then — under `set -u` that reads as "unbound variable", not "empty" (same
  # rationale as cmd_selftest_live's SESS/SF).
  local failures=0
  SESS="selftest-ssh-guard-$$"
  F=$(oneshot_ssh_file "$SESS")

  report_oneshot_case() {  # $1 label  $2 rc (0=ok)  $3 detail (shown on failure)
    if [ "$2" -eq 0 ]; then
      echo "ok $1"
    else
      echo "FAIL $1${3:+: $3}" >&2
      failures=$((failures + 1))
    fi
  }

  rm -f "$F" 2>/dev/null || true
  trap 'rm -f "$F" 2>/dev/null || true' EXIT

  # 1. matches: ssh host '<cmd>' (single-quoted inline command)
  if oneshot_ssh_is_inline "ssh srv1453980 'uname -a 2>&1'"; then
    report_oneshot_case "1 matches ssh inline single-quote" 0
  else
    report_oneshot_case "1 matches ssh inline single-quote" 1
  fi

  # 2. matches: tailscale ssh host "<cmd>" (double-quoted inline command)
  if oneshot_ssh_is_inline 'tailscale ssh macbook-openclaw "ls -l ~/.openclaw 2>&1"'; then
    report_oneshot_case "2 matches tailscale ssh inline double-quote" 0
  else
    report_oneshot_case "2 matches tailscale ssh inline double-quote" 1
  fi

  # 3. does NOT match a bare interactive hop (no inline command) — this is the
  # persistent-session shape the nudge wants to encourage, not flag.
  if oneshot_ssh_is_inline 'ssh srv1453980'; then
    report_oneshot_case "3 no match on interactive ssh" 1 "flagged a bare interactive hop"
  else
    report_oneshot_case "3 no match on interactive ssh" 0
  fi

  # 4. does NOT match `wsh ssh -n host` (opens a Wave connection, different verb)
  if oneshot_ssh_is_inline 'wsh ssh -n srv1453980'; then
    report_oneshot_case "4 no match on wsh ssh -n" 1 "flagged a Wave connection open"
  else
    report_oneshot_case "4 no match on wsh ssh -n" 0
  fi

  # 5. does NOT match scp/rsync
  if oneshot_ssh_is_inline "scp file.txt srv1453980:/tmp/" || oneshot_ssh_is_inline "rsync -av ./dir/ srv1453980:/tmp/dir/"; then
    report_oneshot_case "5 no match on scp/rsync" 1 "flagged a file transfer"
  else
    report_oneshot_case "5 no match on scp/rsync" 0
  fi

  # 6. two one-shots in a row: silent on the 1st, warns on the 2nd.
  local err1 err2
  err1=$(oneshot_ssh_track "$SESS" "ssh srv1 'uptime 2>&1'" 2>&1 >/dev/null)
  err2=$(oneshot_ssh_track "$SESS" "ssh srv2 'df -h 2>&1'" 2>&1 >/dev/null)
  if [ -z "$err1" ] && printf '%s' "$err2" | grep -q 'persistent session'; then
    report_oneshot_case "6 warns on 2nd consecutive one-shot" 0
  else
    report_oneshot_case "6 warns on 2nd consecutive one-shot" 1 "err1='$err1' err2='$err2'"
  fi

  # 7. interleaved with a non-matching send resets the counter — the next
  # one-shot is treated as the 1st again (no warning).
  rm -f "$F" 2>/dev/null || true
  oneshot_ssh_track "$SESS" "ssh srv1 'uptime 2>&1'" >/dev/null 2>&1
  oneshot_ssh_track "$SESS" "echo hi 2>&1" >/dev/null 2>&1
  local err3
  err3=$(oneshot_ssh_track "$SESS" "ssh srv2 'df -h 2>&1'" 2>&1 >/dev/null)
  if [ -z "$err3" ]; then
    report_oneshot_case "7 interleaved resets counter (no warning)" 0
  else
    report_oneshot_case "7 interleaved resets counter (no warning)" 1 "err3='$err3'"
  fi

  # 8. a bare interactive hop also resets the counter (not just a non-SSH send).
  rm -f "$F" 2>/dev/null || true
  oneshot_ssh_track "$SESS" "ssh srv1 'uptime 2>&1'" >/dev/null 2>&1
  oneshot_ssh_track "$SESS" "ssh srv1" >/dev/null 2>&1
  local err4
  err4=$(oneshot_ssh_track "$SESS" "ssh srv2 'df -h 2>&1'" 2>&1 >/dev/null)
  if [ -z "$err4" ]; then
    report_oneshot_case "8 interactive hop resets counter (no warning)" 0
  else
    report_oneshot_case "8 interactive hop resets counter (no warning)" 1 "err4='$err4'"
  fi

  rm -f "$F" 2>/dev/null || true

  if [ "$failures" -ne 0 ]; then
    echo "selftest-oneshot-ssh: $failures failure(s)" >&2
    exit 1
  fi
  echo "selftest-oneshot-ssh: ok"
}

# push/pull smoke test. Deterministic error paths (missing local file,
# unreachable host) need no real remote and always run. The round-trip +
# missing-remote-file cases exercise wsh-push.sh's real fallback chain over
# loopback ssh (the "transport local simulable" — same Mac talking to itself
# via bare scp, since there's no live Wave route or ControlMaster to itself
# and `tailscale ssh` to "localhost" isn't a tailnet peer) and are skipped
# with a note when this Mac doesn't accept passwordless ssh to itself
# (Remote Login off / no matching key) — same "skip if infra unavailable"
# spirit as selftest-cache. The final case exercises wsh-live.sh's own
# `push` subcommand end-to-end against a real (Wave-less) tmux session,
# proving the "no remote host recorded" error path — never calls spawn/open.
cmd_selftest_transfer() {
  local failures=0
  report_transfer_case() {  # $1 label  $2 rc (0=ok)  $3 detail (shown on failure)
    if [ "$2" -eq 0 ]; then
      echo "ok $1"
    else
      echo "FAIL $1${3:+: $3}" >&2
      failures=$((failures + 1))
    fi
  }

  # tmpdir is deliberately NOT local: later traps in this function (and the
  # EXIT trap that ends up registered when the function returns) fire after
  # this function has already returned — a `local` var is out of scope by
  # then, and under `set -u` that reads as "unbound variable", not "empty"
  # (same rationale as cmd_selftest_sep's tmpdir).
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/wsh-transfer-test.XXXXXX")
  trap 'rm -rf "$tmpdir"' EXIT

  # 1. push: missing local file -> exit 2, clear message.
  local err rc
  set +e
  err=$("$PUSH_SCRIPT" "$tmpdir/does-not-exist.txt" "/tmp/wsh-transfer-selftest-absent" "192.0.2.1" 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q 'not found'; then
    report_transfer_case "1 push missing local file" 0
  else
    report_transfer_case "1 push missing local file" 1 "rc=$rc err=$err"
  fi

  # 2. push: unreachable host (RFC 5737 TEST-NET-1, guaranteed unroutable) ->
  # all transports fail -> exit 3, clear message. WSH_PUSH_SSH_TIMEOUT keeps
  # the scp fallback's ConnectTimeout short so this doesn't hang the selftest.
  printf 'hello\n' >"$tmpdir/src.txt"
  set +e
  err=$(WSH_PUSH_SSH_TIMEOUT=3 "$PUSH_SCRIPT" "$tmpdir/src.txt" "/tmp/wsh-transfer-selftest-$$" "192.0.2.1" 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -eq 3 ] && printf '%s' "$err" | grep -q 'failed'; then
    report_transfer_case "2 push unreachable host" 0
  else
    report_transfer_case "2 push unreachable host" 1 "rc=$rc err=$err"
  fi

  # 3-5. opportunistic: push+pull round-trip (text + binary, checksum
  # compared) and a missing-remote-file pull, all over loopback ssh.
  if command -v ssh >/dev/null 2>&1 && command -v scp >/dev/null 2>&1 \
     && ssh -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=no "$(whoami)@localhost" true >/dev/null 2>&1; then
    # conn/rdir are deliberately NOT local: transfer_selftest_loopback_cleanup
    # is registered as the EXIT trap below and must still see them if the
    # script aborts (set -e) before this function returns — same rationale as
    # cmd_selftest_live's SESS/SF/LIVE_LOG_FILE.
    conn="$(whoami)@localhost"
    rdir="/tmp/wsh-transfer-selftest-$$"
    ssh -o BatchMode=yes "$conn" "mkdir -p '$rdir'" >/dev/null 2>&1
    transfer_selftest_loopback_cleanup() {
      ssh -o BatchMode=yes "$conn" "rm -rf '$rdir'" >/dev/null 2>&1 || true
    }
    trap 'transfer_selftest_loopback_cleanup; rm -rf "$tmpdir"' EXIT

    # 3. text file round-trip: push, pull back, checksums match.
    printf 'hello wsh-cockpit push/pull\nligne 2\n' >"$tmpdir/text-src.txt"
    set +e
    "$PUSH_SCRIPT" "$tmpdir/text-src.txt" "$rdir/text.txt" "$conn" >/dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      set +e
      "$PUSH_SCRIPT" --pull "$tmpdir/text-out.txt" "$rdir/text.txt" "$conn" >/dev/null 2>&1
      rc=$?
      set -e
      if [ "$rc" -eq 0 ] && [ -f "$tmpdir/text-out.txt" ] \
         && [ "$(cksum <"$tmpdir/text-src.txt")" = "$(cksum <"$tmpdir/text-out.txt")" ]; then
        report_transfer_case "3 text round-trip checksum match" 0
      else
        report_transfer_case "3 text round-trip checksum match" 1 "pull rc=$rc"
      fi
    else
      report_transfer_case "3 text round-trip checksum match" 1 "push rc=$rc"
    fi

    # 4. binary file round-trip: same, with random bytes.
    dd if=/dev/urandom of="$tmpdir/bin-src.bin" bs=1024 count=8 >/dev/null 2>&1
    set +e
    "$PUSH_SCRIPT" "$tmpdir/bin-src.bin" "$rdir/bin.bin" "$conn" >/dev/null 2>&1
    rc=$?
    "$PUSH_SCRIPT" --pull "$tmpdir/bin-out.bin" "$rdir/bin.bin" "$conn" >/dev/null 2>&1
    local rc2=$?
    set -e
    if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && [ -f "$tmpdir/bin-out.bin" ] \
       && [ "$(cksum <"$tmpdir/bin-src.bin")" = "$(cksum <"$tmpdir/bin-out.bin")" ]; then
      report_transfer_case "4 binary round-trip checksum match" 0
    else
      report_transfer_case "4 binary round-trip checksum match" 1 "push rc=$rc pull rc=$rc2"
    fi

    # 5. pull: remote file absent -> nonzero exit, clear message, and NO
    # truncated file left behind at the local destination.
    set +e
    err=$("$PUSH_SCRIPT" --pull "$tmpdir/absent-out.txt" "$rdir/does-not-exist.txt" "$conn" 2>&1 >/dev/null)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ] && [ ! -e "$tmpdir/absent-out.txt" ]; then
      report_transfer_case "5 pull missing remote file" 0
    else
      report_transfer_case "5 pull missing remote file" 1 "rc=$rc err=$err"
    fi

    transfer_selftest_loopback_cleanup
  else
    echo "skip 3-5 round-trip+missing-file (no passwordless loopback ssh — Remote Login likely off on this Mac)"
  fi

  # 6. wsh-live.sh push errors clearly when the session has no remote host
  # recorded (remote-init/--pre never ran) — real tmux session, no Wave block.
  have_mux
  # SESS is deliberately NOT local: transfer_selftest_session_cleanup runs
  # from the EXIT trap after this function has already returned (at script
  # exit), and a `local` var is out of scope by then — under `set -u` that
  # reads as "unbound variable", not "empty" (same rationale as
  # cmd_selftest_live's SESS/SF/LIVE_LOG_FILE).
  SESS="cockpit-selftest-transfer-$$"
  transfer_selftest_session_cleanup() { "$0" stop "$SESS" >/dev/null 2>&1 || true; }
  trap 'transfer_selftest_session_cleanup; rm -rf "$tmpdir"' EXIT
  create_session "$SESS"
  set +e
  err=$("$0" push "$SESS" "$tmpdir/src.txt" "/tmp/x" 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -q 'no remote host recorded'; then
    report_transfer_case "6 push without remote-init errors clearly" 0
  else
    report_transfer_case "6 push without remote-init errors clearly" 1 "rc=$rc err=$err"
  fi
  transfer_selftest_session_cleanup

  if [ "$failures" -ne 0 ]; then
    echo "selftest-transfer: $failures failure(s)" >&2
    exit 1
  fi
  echo "selftest-transfer: ok"
}

# `output` smoke test: exercises the marker-bounded segment extraction (see
# cmd_output in wsh-live.sh) on a real, throwaway tmux session — a short
# complete segment, a long segment truncated head+tail with an omitted-count
# note, --full bypassing the cap, an explicit older seq, wait-done --print,
# and the WSH_LIVE_SEP=0 fallback (no markers to extract). Mirrors
# selftest-live's shape; never calls spawn/open.
cmd_selftest_output() {
  have_mux
  export WSH_COCKPIT_AGENT=selftest
  # SESS, SESS2, SF are deliberately NOT local: live_selftest_output_cleanup
  # runs from the EXIT trap after this function returns (at script exit),
  # and a `local` var is out of scope by then — same rationale as
  # cmd_selftest_live's SESS/SF/LIVE_LOG_FILE.
  SESS="cockpit-selftest-output-$$"
  SESS2="cockpit-selftest-output-unframed-$$"
  SF="$(state_file)"

  live_selftest_output_cleanup() {
    "$0" stop "$SESS" >/dev/null 2>&1 || true
    "$0" stop "$SESS2" >/dev/null 2>&1 || true
    rm -f "$SF" 2>/dev/null || true
  }
  trap live_selftest_output_cleanup EXIT

  local failures=0
  report_output_case() {  # $1 label  $2 rc (0=ok)  $3 detail (shown on failure)
    if [ "$2" -eq 0 ]; then
      echo "ok $1"
    else
      echo "FAIL $1${3:+: $3}" >&2
      failures=$((failures + 1))
    fi
  }

  "$0" start "$SESS" >/dev/null 2>&1

  # 1. short complete segment: header, command output, and footer all present.
  "$0" send 'echo OUTPUT_SHORT_OK' "$SESS" >/dev/null 2>&1
  "$0" wait-done "$SESS" 30 >/dev/null 2>&1
  local out1
  out1=$("$0" output "$SESS" 2>&1)
  if printf '%s\n' "$out1" | grep -Fq '┌─[#1]' \
     && printf '%s\n' "$out1" | grep -Fq 'OUTPUT_SHORT_OK' \
     && printf '%s\n' "$out1" | grep -Fq '└─[#1] exit 0'; then
    report_output_case "1 short segment complete" 0
  else
    report_output_case "1 short segment complete" 1 "$out1"
  fi

  # 2. a long segment (seq 1 500 -> 500+ lines) is truncated head+tail with an
  # omitted-count note; the footer (exit code) still survives in the tail.
  "$0" send 'seq 1 500' "$SESS" >/dev/null 2>&1
  "$0" wait-done "$SESS" 30 >/dev/null 2>&1
  local out2 lines2
  out2=$("$0" output "$SESS" 2>&1)
  lines2=$(printf '%s\n' "$out2" | wc -l | tr -d ' ')
  if printf '%s\n' "$out2" | grep -q 'lignes omises' \
     && printf '%s\n' "$out2" | grep -Fq '└─[#2] exit 0' \
     && [ "$lines2" -le "$((WSH_READ_MAX + 5))" ]; then
    report_output_case "2 long segment truncated head+tail" 0
  else
    report_output_case "2 long segment truncated head+tail" 1 "lines=$lines2 out=$out2"
  fi

  # 3. --full disables the cap: the same #2 segment, uncapped, is well past
  # the 500 lines `seq 1 500` printed and carries no omission note.
  local out3 lines3
  out3=$("$0" output "$SESS" 2 --full 2>&1)
  lines3=$(printf '%s\n' "$out3" | wc -l | tr -d ' ')
  if ! printf '%s\n' "$out3" | grep -q 'lignes omises' && [ "$lines3" -gt 500 ]; then
    report_output_case "3 --full bypasses the cap" 0
  else
    report_output_case "3 --full bypasses the cap" 1 "lines=$lines3"
  fi

  # 4. an explicit seq targets an OLDER send (#1), not the latest (#2).
  local out4
  out4=$("$0" output "$SESS" 1 2>&1)
  if printf '%s\n' "$out4" | grep -Fq 'OUTPUT_SHORT_OK' \
     && ! printf '%s\n' "$out4" | grep -Fq '└─[#2]'; then
    report_output_case "4 explicit seq targets an older send" 0
  else
    report_output_case "4 explicit seq targets an older send" 1 "$out4"
  fi

  # 5. wait-done --print = wait-done + output folded into ONE call.
  "$0" send 'echo PRINT_COMBO_OK' "$SESS" >/dev/null 2>&1
  local out5 rc5
  set +e
  out5=$("$0" wait-done "$SESS" 30 --print 2>&1)
  rc5=$?
  set -e
  if [ "$rc5" -eq 0 ] && printf '%s\n' "$out5" | grep -Fq 'PRINT_COMBO_OK' \
     && printf '%s\n' "$out5" | grep -Fq '└─[#3] exit 0'; then
    report_output_case "5 wait-done --print" 0
  else
    report_output_case "5 wait-done --print" 1 "rc=$rc5 out=$out5"
  fi

  # 6. unframed pane (WSH_LIVE_SEP=0): no markers to extract — a clear
  # stderr fallback pointing at `read N`, never a guessed/truncated read
  # passed off as the real thing. Fresh session, no framed send ever made.
  "$0" start "$SESS2" >/dev/null 2>&1
  local err6 rc6
  set +e
  err6=$(WSH_LIVE_SEP=0 "$0" output "$SESS2" 2>&1 >/dev/null)
  rc6=$?
  set -e
  if [ "$rc6" -ne 0 ] && printf '%s' "$err6" | grep -q 'WSH_LIVE_SEP=0'; then
    report_output_case "6 WSH_LIVE_SEP=0 falls back cleanly" 0
  else
    report_output_case "6 WSH_LIVE_SEP=0 falls back cleanly" 1 "rc=$rc6 err=$err6"
  fi

  "$0" stop "$SESS" >/dev/null 2>&1 || true
  "$0" stop "$SESS2" >/dev/null 2>&1 || true

  if [ "$failures" -ne 0 ]; then
    echo "selftest-output: $failures failure(s)" >&2
    exit 1
  fi
  echo "selftest-output: ok"
}

cmd_selftest_guard() {
  have_mux
  if [ "$MUX" != tmux ]; then
    echo "selftest-guard: skip (tmux-only — the guard rests on tmux display-message)"
    return 0
  fi
  # M4 (docs/gotchas.md): this runs on the DEFAULT tmux server, not an
  # isolated one — case 10 groups a throwaway session onto whatever real
  # session is currently running this selftest. Warn up front so a reader
  # of the output (not just the source) sees it before it happens.
  echo "selftest-guard: note — runs on the default tmux server; case 10 briefly groups a throwaway session onto this call's own live session (see docs/gotchas.md)"
  # NOT local: cleanup runs from the EXIT trap after this function returned
  # (same rationale as cmd_selftest_gc's SESS).
  GUARD_BUSY="cockpit-selftest-guard-busy-$$"
  GUARD_IDLE="cockpit-selftest-guard-idle-$$"
  GUARD_KEY="selftest-guard-$$"
  GUARD_GROUP="cockpit-selftest-guard-group-$$"
  GUARD_DECOY="cockpit-selftest-guard-decoy-$$"
  GUARD_PANES="cockpit-selftest-guard-panes-$$"
  GUARD_T6_PREFIX="cockpit-t6anchor-$$"
  GUARD_T6_SESS="${GUARD_T6_PREFIX}-1"
  GUARD_NB_PREFIX="cockpit-t7nb-$$"
  GUARD_NB_SESS="${GUARD_NB_PREFIX}-full"
  GUARD_INDET="cockpit-selftest-guard-indet-$$"
  GUARD_GCOWN="cockpit-selftest-guard-gcown-$$"
  GUARD_GCOTHER="cockpit-selftest-guard-gcother-$$"
  GUARD_W2="cockpit-selftest-guard-w2-$$"
  # Case 23 runs gc via send-keys (see below) — the only way to observe its
  # rc from outside that pane is to have the sent command write it to a
  # file itself. Dedicated to this one case, cleaned by the trap below.
  GUARD_GCOWN_RCFILE="${TMPDIR:-/tmp}/wsh-cockpit-selftest-guard-gcown-rc.$$"
  # Task 3, lot 2 (cases 30-36): form-first discrimination + --session flag.
  # GUARD_T3_ALIVE is remembered as the last session under GUARD_T3_KEY so
  # cases 31/32 can tell the fix apart from the pre-fix bug: silently
  # dropping the dead-shaped token used to fall back to this remembered
  # session (rc != 4) instead of failing loud on the token itself. GUARD_T3_DEAD
  # is a name that LOOKS like a session (matches looks_like_session) but is
  # never created. GUARD_T3_KEY2 is a separate, never-remembered key so case
  # 33 resolves to SESS_DEFAULT untainted by GUARD_T3_ALIVE.
  GUARD_T3_ALIVE="cockpit-selftest-guard-t3-$$"
  GUARD_T3_DEAD="cockpit-selftest-guard-mort-$$"
  GUARD_T3_KEY="selftest-guard-t3-$$"
  GUARD_T3_KEY2="selftest-guard-t3b-$$"
  # Case 42 (CodeRabbit review): a registry hit (find_registry_session,
  # spawn's étape 1) claimed under a dedicated fresh key, never reused by
  # any other case here.
  GUARD_REGBUSY="cockpit-selftest-guard-regbusy-$$"
  GUARD_REGKEY="selftest-guard-reg-$$"
  local rc failures=0 own cmd tries found pfx resolved panes pane_count active active_count present mode host sep err rcline gcrc reg42 rc42

  report_guard_case() {  # $1 label  $2 rc (0=ok)  $3 detail (shown on failure)
    if [ "$2" -eq 0 ]; then
      echo "ok $1"
    else
      echo "FAIL $1${3:+: $3}" >&2
      failures=$((failures + 1))
    fi
  }

  # Anchored with "=" (exact-name match only): without it, kill-session
  # resolves -t by exact match, then prefix, then fnmatch — a stray session
  # whose name only PREFIXES one of these could be killed by mistake. See
  # cases 9-10 below for the same hazard hitting session_safe_to_reuse.
  selftest_guard_cleanup() {
    tmux kill-session -t "=$GUARD_BUSY" 2>/dev/null || true
    tmux kill-session -t "=$GUARD_IDLE" 2>/dev/null || true
    tmux kill-session -t "=$GUARD_GROUP" 2>/dev/null || true
    tmux kill-session -t "=$GUARD_DECOY" 2>/dev/null || true
    tmux kill-session -t "=$GUARD_PANES" 2>/dev/null || true
    tmux kill-session -t "=$GUARD_T6_SESS" 2>/dev/null || true
    tmux kill-session -t "=$GUARD_NB_SESS" 2>/dev/null || true
    tmux kill-session -t "=$GUARD_INDET" 2>/dev/null || true
    tmux kill-session -t "=$GUARD_GCOWN" 2>/dev/null || true
    tmux kill-session -t "=$GUARD_GCOTHER" 2>/dev/null || true
    tmux kill-session -t "=$GUARD_W2" 2>/dev/null || true
    tmux kill-session -t "=$GUARD_T3_ALIVE" 2>/dev/null || true
    tmux kill-session -t "=$GUARD_REGBUSY" 2>/dev/null || true
    rm -f "$GUARD_GCOWN_RCFILE" 2>/dev/null || true
    rm -f "$(seq_file "$GUARD_W2")" 2>/dev/null || true
    rm -f "$(seq_file "$GUARD_T3_ALIVE")" 2>/dev/null || true
    rm -f "$STATE_DIR/last-session-$GUARD_KEY" 2>/dev/null || true
    rm -f "$STATE_DIR/last-session-$GUARD_T3_KEY" 2>/dev/null || true
    rm -f "$(claim_path "$(session_slug "$GUARD_REGBUSY")")" 2>/dev/null || true
  }
  trap selftest_guard_cleanup EXIT

  # 1. outside tmux, own_tmux_session must fail cleanly with rc == 1
  #    precisely — not just "rc != 0", which a missing/renamed function
  #    (rc=127) would also satisfy.
  set +e
  ( unset TMUX; own_tmux_session >/dev/null 2>&1 )
  rc=$?
  set -e
  if [ "$rc" -eq 1 ]; then report_guard_case "1 own_tmux_session outside tmux -> rc==1" 0
  else report_guard_case "1 own_tmux_session outside tmux -> rc==1" 1 "rc=$rc (expected 1)"; fi

  # 2+3. only meaningful when THIS test itself runs inside tmux.
  if [ -n "${TMUX:-}" ]; then
    set +e; own=$(own_tmux_session); rc=$?; set -e
    if [ "$rc" -eq 0 ] && [ -n "$own" ]; then report_guard_case "2 own_tmux_session names current session" 0
    else report_guard_case "2 own_tmux_session names current session" 1 "rc=$rc own='$own'"; fi
    set +e; session_safe_to_reuse "$own" 2>/dev/null; rc=$?; set -e
    if [ "$rc" -ne 0 ]; then report_guard_case "3 own session refused" 0
    else report_guard_case "3 own session refused" 1 "rc=0 on '$own'"; fi
  else
    echo "note: cases 2-3 skipped (not inside tmux)"
  fi

  # 4. a session whose foreground is NOT a bare shell is refused.
  tmux new-session -d -s "$GUARD_BUSY" 'exec top'
  tries=0; cmd=""
  while [ "$tries" -lt 20 ]; do
    cmd=$(mux_pane_command "$GUARD_BUSY")
    [ "$cmd" = top ] && break
    tries=$((tries + 1)); sleep 0.2
  done
  set +e; session_safe_to_reuse "$GUARD_BUSY" 2>/dev/null; rc=$?; set -e
  if [ "$rc" -ne 0 ]; then report_guard_case "4 non-shell foreground refused" 0
  else report_guard_case "4 non-shell foreground refused" 1 "rc=0 (cmd='$cmd')"; fi

  # 5. a bare-shell session is accepted.
  tmux new-session -d -s "$GUARD_IDLE"
  set +e; session_safe_to_reuse "$GUARD_IDLE" 2>/dev/null; rc=$?; set -e
  if [ "$rc" -eq 0 ]; then report_guard_case "5 bare shell accepted" 0
  else report_guard_case "5 bare shell accepted" 1 "rc=$rc"; fi

  # 6. empty pane_current_command (zellij / transient) = unverifiable-but-SAFE.
  set +e
  ( mux_pane_command() { printf ''; }; session_safe_to_reuse "$GUARD_IDLE" 2>/dev/null )
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then report_guard_case "6 empty pane command treated safe" 0
  else report_guard_case "6 empty pane command treated safe" 1 "rc=$rc"; fi

  # 7. find_reusable_session must NOT hand back a remembered-but-unsafe session.
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$GUARD_BUSY" > "$STATE_DIR/last-session-$GUARD_KEY"
  set +e
  found=$( WSH_COCKPIT_AGENT="$GUARD_KEY"; export WSH_COCKPIT_AGENT
           find_reusable_session "selftest-guard-none" 2>/dev/null )
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [ -z "$found" ]; then report_guard_case "7 unsafe remembered session not reused" 0
  else report_guard_case "7 unsafe remembered session not reused" 1 "rc=$rc found='$found'"; fi

  # 8. start --reuse on the caller's own session must refuse with exit 8.
  #    Confined under GUARD_KEY so the red phase can never pollute the real
  #    agent state (remember_session on the caller's own session is exactly
  #    the original incident).
  if [ -n "${TMUX:-}" ]; then
    own=$(tmux display-message -p '#S')
    set +e
    WSH_COCKPIT_AGENT="$GUARD_KEY" "$SCRIPT_DIR/wsh-live.sh" start "$own" --reuse >/dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 8 ]; then report_guard_case "8 start --reuse refuses own session (exit 8)" 0
    else report_guard_case "8 start --reuse refuses own session (exit 8)" 1 "rc=$rc (expected 8)"; fi
  else
    echo "note: case 8 skipped (not inside tmux)"
  fi

  # 9. alias by prefix: tmux resolves -t by exact name, then prefix, then
  #    fnmatch — a strict prefix of the caller's own session name that
  #    still resolves (unambiguously) to that same session must be refused
  #    just like the exact name (case 3). Skip if the prefix is empty or
  #    resolves ambiguously/not-at-all in this environment: no proof either
  #    way, not a failure.
  if [ -n "${TMUX:-}" ]; then
    own=$(own_tmux_session)
    pfx=${own%?}
    resolved=$(tmux display-message -p -t "$pfx" '#{session_name}' 2>/dev/null || true)
    if [ -z "$pfx" ] || [ "$resolved" != "$own" ]; then
      echo "note: case 9 skipped (prefix '$pfx' of '$own' resolved to '$resolved', not unambiguous)"
    else
      set +e; session_safe_to_reuse "$pfx" 2>/dev/null; rc=$?; set -e
      if [ "$rc" -ne 0 ]; then report_guard_case "9 prefix alias of own session refused" 0
      else report_guard_case "9 prefix alias of own session refused" 1 "rc=0 on prefix '$pfx' (resolves to own session '$own')"; fi
    fi
  else
    echo "note: case 9 skipped (not inside tmux)"
  fi

  # 10. grouped session: `tmux new-session -t <own>` creates a session with
  #     a DIFFERENT name that shares the caller's pane (Wave wraps blocks
  #     this way) — session_safe_to_reuse must catch the shared pane, not
  #     just a name match. Skip if the grouped session can't be created.
  #
  #     Gotcha discovered empirically on this machine (tmux 3.7b): unqualified
  #     `tmux display-message -p '#S'` (what own_tmux_session() calls) does
  #     NOT stay pinned to the session's original name once a grouped session
  #     shares its pane — it drifts to the MOST RECENTLY CREATED session
  #     within that share group. So right after `new-session -t "$own"
  #     -s "$GUARD_GROUP"`, own_tmux_session() already returns "$GUARD_GROUP"
  #     itself, and the pre-existing exact-name check would match BY
  #     ACCIDENT — passing whether or not session_is_own's new pane-identity
  #     check exists. A throwaway decoy grouped session created right after
  #     shifts that drift away from GUARD_GROUP (confirmed: current becomes
  #     the decoy), so the exact-name AND canonical-name checks both
  #     genuinely fail here and only the pane-membership check
  #     (mux_session_panes contains $TMUX_PANE) can still catch it.
  if [ -n "${TMUX:-}" ]; then
    own=$(own_tmux_session)
    set +e
    tmux new-session -d -s "$GUARD_GROUP" -t "=$own" 2>/dev/null
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      echo "note: case 10 skipped (could not create a grouped session on '$own')"
    else
      set +e
      tmux new-session -d -s "$GUARD_DECOY" -t "=$own" 2>/dev/null
      set -e
      set +e; session_safe_to_reuse "$GUARD_GROUP" 2>/dev/null; rc=$?; set -e
      if [ "$rc" -ne 0 ]; then report_guard_case "10 grouped session sharing own pane refused" 0
      else report_guard_case "10 grouped session sharing own pane refused" 1 "rc=0 on '$GUARD_GROUP' (own_tmux_session now resolves to '$(own_tmux_session 2>/dev/null || true)')"; fi
      # Kill both grouped sessions right away (not just at the end via the
      # EXIT trap): leaving GUARD_GROUP alive would keep dragging
      # own_tmux_session's drift (see block comment above) into the cases
      # that follow, which need a clean read of the caller's real session.
      tmux kill-session -t "=$GUARD_DECOY" 2>/dev/null || true
      tmux kill-session -t "=$GUARD_GROUP" 2>/dev/null || true
    fi
  else
    echo "note: case 10 skipped (not inside tmux)"
  fi

  # 11. `=NAME` alias: tmux honours `=` as an exact-match anchor for
  #     target-SESSION commands (has-session) but NOT for target-PANE ones
  #     (display-message, capture-pane) — those silently return empty with
  #     rc=0 instead of erroring. session_is_own strips the leading "="
  #     (`${raw#=}`) before any lookup precisely so this case passes: were
  #     that strip ever lost, mux_session_name/mux_session_panes would go
  #     blind on "=<own>", the guard would fall through every check and
  #     report 0 (reusable), and mux_kill — which DOES honour "=" — would
  #     then tear down the caller's own session. Assert rc==1 exactly (the
  #     refusal path), not just !=0: a missing/renamed function's rc=127
  #     must not pass for the wrong reason.
  if [ -n "${TMUX:-}" ]; then
    own=$(own_tmux_session)
    set +e; session_safe_to_reuse "=$own" 2>/dev/null; rc=$?; set -e
    if [ "$rc" -eq 1 ]; then report_guard_case "11 =own alias refused" 0
    else report_guard_case "11 =own alias refused" 1 "rc=$rc (expected 1) on '=$own' (mux_session_name/mux_session_panes are blind to a '=' target-pane)"; fi
  else
    echo "note: case 11 skipped (not inside tmux)"
  fi

  # 12. pane-membership primitive: mux_pane_id only ever reports a target's
  #     ACTIVE pane — a caller sitting in a NON-active pane of a multi-pane
  #     session would be invisible to a check built on mux_pane_id alone.
  #     mux_session_panes must enumerate ALL panes so session_is_own can
  #     test membership instead of identity. This covers only the
  #     primitive (mux_session_panes sees both panes where mux_pane_id
  #     sees one) — NOT the end-to-end "caller sits in a non-active pane
  #     of the target" scenario, which would require splitting the LIVE
  #     window the user is watching. Do not do that here.
  if [ -n "${TMUX:-}" ]; then
    set +e
    tmux new-session -d -s "$GUARD_PANES" 2>/dev/null
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      echo "note: case 12 skipped (could not create '$GUARD_PANES')"
    else
      # split-window is a target-PANE/window command, not target-session —
      # unlike list-panes just below, "=" is NOT honoured here (measured:
      # "can't find pane" on this tmux, swallowed by `|| true` the first
      # time this test was written, which silently left the session at
      # ONE pane and made the case fail for the wrong reason).
      tmux split-window -d -t "$GUARD_PANES" 2>/dev/null || true
      set +e
      panes=$(mux_session_panes "$GUARD_PANES" 2>/dev/null)
      active=$(mux_pane_id "$GUARD_PANES" 2>/dev/null)
      set -e
      pane_count=$(printf '%s\n' "$panes" | grep -c . || true)
      active_count=$(printf '%s\n' "$active" | grep -c . || true)
      if [ "$pane_count" -eq 2 ] && [ "$active_count" -eq 1 ]; then
        report_guard_case "12 mux_session_panes sees both panes, mux_pane_id only the active one" 0
      else
        report_guard_case "12 mux_session_panes sees both panes, mux_pane_id only the active one" 1 "panes='$panes' (count=$pane_count) active='$active' (count=$active_count)"
      fi
      tmux kill-session -t "=$GUARD_PANES" 2>/dev/null || true
    fi
  else
    echo "note: case 12 skipped (not inside tmux)"
  fi

  # 13-18. mux_has/mux_kill anchor targets with "=" (exact match) — Task 6.
  # tmux's default target resolution tries exact name, THEN session-name
  # prefix, THEN fnmatch, in that order; unanchored, a bare prefix or glob
  # silently resolves to a DIFFERENT, unrelated session. That is what let a
  # dead remembered session "come back to life" via a same-prefixed homonym
  # (session.sh:42) and what would let mux_kill tear down the wrong sibling
  # session on a prefix collision. What each check asserts varies by case:
  # 13/16 (mux_has must REJECT) and 17 (mux_kill must SPARE) assert BOTH the
  # rc AND the session's real presence via mux_list_sessions — rc alone
  # would let rc=127 (function missing/renamed) pass for the wrong reason.
  # 14/15 (mux_has must ACCEPT) assert rc == 0 only — a missing function's
  # rc=127 already fails that check on its own, so state isn't needed there.
  # 18 (mux_kill must still ACTUALLY kill) asserts BOTH rc == 0 AND the
  # session's real absence — the positive control that proves 17's "sibling
  # spared" result isn't just mux_kill failing on everything (see
  # task-6b-report.md for the RED proof that 18 catches that).
  if [ -n "${TMUX:-}" ]; then
    set +e
    tmux new-session -d -s "$GUARD_T6_SESS" 2>/dev/null
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      echo "note: cases 13-18 skipped (could not create '$GUARD_T6_SESS')"
    else
      # 13 (RED case A). "$GUARD_T6_PREFIX" is a STRICT prefix of
      # "$GUARD_T6_SESS" (not the name itself) — must NOT resolve.
      set +e; mux_has "$GUARD_T6_PREFIX" 2>/dev/null; rc=$?; set -e
      present=no
      mux_list_sessions | grep -Fqx -- "$GUARD_T6_SESS" && present=yes
      if [ "$rc" -ne 0 ] && [ "$present" = yes ]; then
        report_guard_case "13 mux_has: strict prefix does not resolve" 0
      else
        report_guard_case "13 mux_has: strict prefix does not resolve" 1 "rc=$rc (expected !=0), session present=$present (expected yes)"
      fi

      # 14. Exact name still resolves — non-regression.
      set +e; mux_has "$GUARD_T6_SESS" 2>/dev/null; rc=$?; set -e
      if [ "$rc" -eq 0 ]; then
        report_guard_case "14 mux_has: exact name resolves" 0
      else
        report_guard_case "14 mux_has: exact name resolves" 1 "rc=$rc"
      fi

      # 15. Caller-supplied "=name" must still resolve — mux_has must strip
      # any leading "=" before re-anchoring (double "==" matches nothing),
      # same guard session_is_own already applies (lib/session.sh). This
      # contract is proven under tmux only: zellij's mux_has/mux_kill
      # branches don't strip a leading "=" the way the tmux branch does, so
      # under zellij `mux_has "=X"` would be false for a live session X. The
      # divergence stays silent because this whole case (and cmd_selftest_guard
      # entirely) never runs under zellij — see the `[ "$MUX" != tmux ]`
      # early return at the top of this function.
      set +e; mux_has "=$GUARD_T6_SESS" 2>/dev/null; rc=$?; set -e
      if [ "$rc" -eq 0 ]; then
        report_guard_case "15 mux_has: caller-anchored name still resolves" 0
      else
        report_guard_case "15 mux_has: caller-anchored name still resolves" 1 "rc=$rc"
      fi

      # 16 (RED case, fnmatch). A glob pattern must NOT resolve either —
      # session still alive at this point, so a false pass here could only
      # come from fnmatch fallback, not from the session being absent.
      set +e; mux_has "${GUARD_T6_PREFIX}*" 2>/dev/null; rc=$?; set -e
      present=no
      mux_list_sessions | grep -Fqx -- "$GUARD_T6_SESS" && present=yes
      if [ "$rc" -ne 0 ] && [ "$present" = yes ]; then
        report_guard_case "16 mux_has: fnmatch pattern does not resolve" 0
      else
        report_guard_case "16 mux_has: fnmatch pattern does not resolve" 1 "rc=$rc (expected !=0), session present=$present (expected yes)"
      fi

      # 17 (RED case D). mux_kill on the strict prefix must NOT kill this
      # sibling session — check BOTH that mux_kill itself reports failure
      # (rc != 0: a rejected/no-op target, not a silent success) AND that
      # the session is STILL LISTED afterwards. rc alone was not enough: a
      # missing/renamed mux_kill (rc=127, message swallowed by 2>&1) would
      # leave the session present and pass for the wrong reason.
      set +e; mux_kill "$GUARD_T6_PREFIX" >/dev/null 2>&1; rc=$?; set -e
      present=no
      mux_list_sessions | grep -Fqx -- "$GUARD_T6_SESS" && present=yes
      if [ "$rc" -ne 0 ] && [ "$present" = yes ]; then
        report_guard_case "17 mux_kill: strict prefix spares sibling session" 0
      else
        report_guard_case "17 mux_kill: strict prefix spares sibling session" 1 "rc=$rc (expected !=0), session '$GUARD_T6_SESS' present=$present (expected yes)"
      fi

      # 18 (positive control for 13-17, esp. 17). mux_kill on the EXACT name
      # must still kill: proves mux_kill isn't just "always fails" — which
      # would make case 17 pass for the wrong reason. Asserts BOTH rc == 0
      # AND the session's real absence from mux_list_sessions afterwards.
      set +e; mux_kill "$GUARD_T6_SESS" >/dev/null 2>&1; rc=$?; set -e
      present=no
      mux_list_sessions | grep -Fqx -- "$GUARD_T6_SESS" && present=yes
      if [ "$rc" -eq 0 ] && [ "$present" = no ]; then
        report_guard_case "18 mux_kill: exact name still kills" 0
      else
        report_guard_case "18 mux_kill: exact name still kills" 1 "rc=$rc (expected 0), session '$GUARD_T6_SESS' present=$present (expected no)"
      fi

      # Safety-net cleanup regardless of outcome above (kept out of
      # selftest_guard_cleanup's anchored kill so a failure in 17/18 can't
      # leave an orphan behind either) — harmless no-op if 18 already killed it.
      tmux kill-session -t "=$GUARD_T6_SESS" 2>/dev/null || true
    fi
  else
    echo "note: cases 13-18 skipped (not inside tmux)"
  fi

  # 19 (I2, Task 7). `stop` hands its raw argument straight to
  # teardown_session with no mux_has check of its own — before the fix,
  # its six unanchored `tmux set-option -u -t "$sess"` calls resolved a bare
  # PREFIX just like `set-option` always does (see docs/gotchas.md), so a
  # prefix that only happens to match a live NEIGHBOUR session silently
  # wiped that neighbour's remote-mode options while the anchored
  # `mux_kill` right after correctly refused to kill anything. Reproduces
  # the end-to-end measurement in task-7-brief.md I2: arm a session with
  # all three option kinds teardown_session clears, call teardown_session
  # with a STRICT prefix of its name (never the name itself), then assert
  # the neighbour is both still ALIVE and all three options are UNCHANGED.
  if [ -n "${TMUX:-}" ]; then
    set +e
    tmux new-session -d -s "$GUARD_NB_SESS" 2>/dev/null
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      echo "note: case 19 skipped (could not create '$GUARD_NB_SESS')"
    else
      remote_mode_set "$GUARD_NB_SESS" 1
      remote_host_set "$GUARD_NB_SESS" "selftest-guard-nb-host"
      remote_helper_path_set "$GUARD_NB_SESS" sep "/selftest/guard/nb/sep-path"
      set +e; teardown_session "$GUARD_NB_PREFIX" >/dev/null 2>&1; set -e
      present=no
      mux_list_sessions | grep -Fqx -- "$GUARD_NB_SESS" && present=yes
      mode=$( (remote_mode_get "$GUARD_NB_SESS") && echo 1 || echo "" )
      host=$(remote_host_get "$GUARD_NB_SESS")
      sep=$(remote_helper_path_get "$GUARD_NB_SESS" sep)
      if [ "$present" = yes ] && [ "$mode" = 1 ] && [ "$host" = "selftest-guard-nb-host" ] && [ "$sep" = "/selftest/guard/nb/sep-path" ]; then
        report_guard_case "19 teardown_session: prefix arg spares a neighbour session's options" 0
      else
        report_guard_case "19 teardown_session: prefix arg spares a neighbour session's options" 1 "present=$present mode='$mode' host='$host' sep='$sep' (expected yes/1/selftest-guard-nb-host/…/sep-path)"
      fi
      tmux kill-session -t "=$GUARD_NB_SESS" 2>/dev/null || true
    fi
  else
    echo "note: case 19 skipped (not inside tmux)"
  fi

  # 20 (Task 8, C1, RED-first). $TMUX set but $TMUX_PANE unset: own identity
  # is indeterminable (M-a — anchoring on $TMUX_PANE doesn't help, the
  # session drifts the same either way), so the guard must refuse outright
  # rather than fall back to an arbitrary session comparison. Before the
  # fix: own_tmux_session still returned 0 (display-message picks *some*
  # session), and session_safe_to_reuse on a harmless bare-shell session
  # that is NOT the caller's own also returned 0 (reusable) — a false
  # negative caused by comparing against that arbitrary pick. GUARD_INDET is
  # a fresh bare-shell session, unrelated to the caller, used only as a
  # harmless target here.
  if [ -n "${TMUX:-}" ]; then
    set +e
    tmux new-session -d -s "$GUARD_INDET" 2>/dev/null
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      echo "note: case 20 skipped (could not create '$GUARD_INDET')"
    else
      set +e; ( unset TMUX_PANE; own_tmux_session >/dev/null 2>&1 ); rc=$?; set -e
      if [ "$rc" -eq 2 ]; then
        report_guard_case "20a own_tmux_session with \$TMUX_PANE unset -> rc==2" 0
      else
        report_guard_case "20a own_tmux_session with \$TMUX_PANE unset -> rc==2" 1 "rc=$rc (expected 2)"
      fi
      set +e; ( unset TMUX_PANE; session_safe_to_reuse "$GUARD_INDET" ) 2>/dev/null; rc=$?; set -e
      if [ "$rc" -ne 0 ]; then
        report_guard_case "20b session_safe_to_reuse refuses a harmless session when \$TMUX_PANE is unset" 0
      else
        report_guard_case "20b session_safe_to_reuse refuses a harmless session when \$TMUX_PANE is unset" 1 "rc=0 on harmless '$GUARD_INDET'"
      fi
      tmux kill-session -t "=$GUARD_INDET" 2>/dev/null || true
    fi
  else
    echo "note: case 20 skipped (not inside tmux)"
  fi

  # 21 (Task 8, C2, RED-first). session_safe_to_reuse must strip a leading
  # "=" anchor like session_is_own does: check 2 feeds its argument to
  # mux_pane_command (display-message, blind to "=" — empty, rc=0), so an
  # anchored "=name" left unstripped was classed unverifiable-but-safe and
  # skipped the foreground check entirely (measured: rc=0 on a session
  # running `top` — see task-8-report.md). Reuses GUARD_BUSY (created in
  # case 4, foreground `top`, still alive until selftest_guard_cleanup).
  set +e; session_safe_to_reuse "=$GUARD_BUSY" 2>/dev/null; rc=$?; set -e
  if [ "$rc" -eq 1 ]; then
    report_guard_case "21 anchored =name still hits the foreground check" 0
  else
    report_guard_case "21 anchored =name still hits the foreground check" 1 "rc=$rc (expected 1) on '=$GUARD_BUSY' (foreground top)"
  fi

  # 22 (Task 1, lot 2, stop). `stop <own session>` must refuse instead of
  # killing the caller out from under itself — mirrors case 8 (start
  # --reuse) but guards the stop) block instead of start's REUSE bypass.
  # Confined under GUARD_KEY like case 8: WSH_COCKPIT_AGENT only matters to
  # `stop` for the state-file cleanup at the tail of teardown_session, but
  # keeping the same confinement pattern as case 8 avoids re-diverging.
  # WARNING FOR ANYONE RUNNING THIS BY HAND: before the guard exists, this
  # case actually KILLS the tmux session it runs inside — never run
  # selftest-guard from your real controlling terminal (see the module-wide
  # note this function prints, and docs/gotchas.md).
  if [ -n "${TMUX:-}" ]; then
    own=$(own_tmux_session)
    set +e
    WSH_COCKPIT_AGENT="$GUARD_KEY" "$SCRIPT_DIR/wsh-live.sh" stop "$own" >/dev/null 2>&1
    rc=$?
    set -e
    present=no
    mux_list_sessions | grep -Fqx -- "$own" && present=yes
    if [ "$rc" -eq 8 ] && [ "$present" = yes ]; then
      report_guard_case "22 stop refuses own session (exit 8), session still alive" 0
    else
      report_guard_case "22 stop refuses own session (exit 8), session still alive" 1 "rc=$rc (expected 8), present=$present (expected yes)"
    fi
  else
    echo "note: case 22 skipped (not inside tmux)"
  fi

  # 23 (Task 1, lot 2, gc — RED case). `gc --idle=0` run FROM INSIDE a
  # detached cockpit-* session must not kill that session out from under
  # itself. Unlike case 22, this can't be exercised by calling wsh-live.sh
  # as a plain subprocess of THIS shell: own_tmux_session reads $TMUX/
  # $TMUX_PANE from the calling process's own environment, which would
  # still point at whatever session is running selftest-guard itself, not
  # at GUARD_GCOWN. `send-keys` runs the command as a child of GUARD_GCOWN's
  # own pane instead, so its $TMUX_PANE is genuinely GUARD_GCOWN's — the
  # only way to reproduce "gc sweeping its own session" honestly. Target is
  # NOT anchored with "=": send-keys is a target-PANE command and rejects a
  # leading "=" outright (measured — "can't find pane: =cockpit-...").
  #
  # Presence alone is not enough: if the sent command breaks silently (bad
  # cd, a typo on --only-session=, wsh-live.sh not found -> rc=127), the
  # session would also survive, and this case would report ok for the wrong
  # reason. The rc has to be observed too — the only way to get it out of
  # GUARD_GCOWN's pane is to have the sent command write it to a file
  # itself (GUARD_GCOWN_RCFILE), polled the same way as presence below.
  if [ -n "${TMUX:-}" ]; then
    set +e
    tmux new-session -d -s "$GUARD_GCOWN" 2>/dev/null
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      echo "note: case 23 skipped (could not create '$GUARD_GCOWN')"
    else
      rm -f "$GUARD_GCOWN_RCFILE"
      tmux send-keys -t "$GUARD_GCOWN" \
        "cd '$(dirname "$SCRIPT_DIR")' && WSH_COCKPIT_AGENT='$GUARD_KEY' scripts/wsh-live.sh gc --idle=0 --only-session='$GUARD_GCOWN'; echo RC=\$? > '$GUARD_GCOWN_RCFILE'" Enter
      tries=0; present=yes; rcline=""
      while [ "$tries" -lt 30 ]; do
        mux_list_sessions | grep -Fqx -- "$GUARD_GCOWN" || { present=no; break; }
        if [ -s "$GUARD_GCOWN_RCFILE" ]; then
          rcline=$(cat "$GUARD_GCOWN_RCFILE")
          break
        fi
        tries=$((tries + 1)); sleep 0.5
      done
      gcrc="${rcline#RC=}"
      if [ "$present" = yes ] && [ "$gcrc" = "0" ]; then
        report_guard_case "23 gc --idle=0 spares the session it runs inside" 0
      else
        report_guard_case "23 gc --idle=0 spares the session it runs inside" 1 "present=$present (expected yes), rc='$gcrc' (expected 0, '$rcline')"
      fi
      tmux kill-session -t "=$GUARD_GCOWN" 2>/dev/null || true
    fi
  else
    echo "note: case 23 skipped (not inside tmux)"
  fi

  # 24 (Task 1, lot 2, gc — positive control). A session that is genuinely
  # NOT the caller's own must still be swept normally: the own-session skip
  # added for case 23 must not neutralise gc for everyone else. Calls
  # cmd_gc directly in-process, same as cmd_selftest_gc's own cases 4-5 —
  # no send-keys needed here, this session is never the caller's own so
  # there is no self-kill hazard to isolate against.
  if [ -n "${TMUX:-}" ]; then
    set +e
    tmux new-session -d -s "$GUARD_GCOTHER" 2>/dev/null
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      echo "note: case 24 skipped (could not create '$GUARD_GCOTHER')"
    else
      set +e
      cmd_gc --idle=0 --only-session="$GUARD_GCOTHER" >/dev/null 2>&1
      rc=$?
      set -e
      present=no
      mux_list_sessions | grep -Fqx -- "$GUARD_GCOTHER" && present=yes
      if [ "$rc" -eq 0 ] && [ "$present" = no ]; then
        report_guard_case "24 gc still kills a genuinely non-own idle session" 0
      else
        report_guard_case "24 gc still kills a genuinely non-own idle session" 1 "rc=$rc (expected 0), session present=$present (expected no)"
      fi
      tmux kill-session -t "=$GUARD_GCOTHER" 2>/dev/null || true
    fi
  else
    echo "note: case 24 skipped (not inside tmux)"
  fi

  # 25 (Task 2, lot 2, send). `send` on the caller's own session must refuse
  # (exit 8) instead of typing the command straight into its own pane —
  # against an interactive foreground (a live CLI REPL) that text is
  # SUBMITTED as a new prompt instead of executing, exactly the incident
  # `gotchas.md` already documents for spawn's silent reuse, here reachable
  # through send's positional [session] argument instead of a remembered
  # one. Guard placement follows plan §3: WRITE paths (send/keys/step-run/
  # banner) refuse outright like `stop` (case 22); READ paths (read/output/
  # wait-done) stay unguarded on purpose. Cases 26-28 point back here for
  # the rationale instead of repeating it. Confined under GUARD_KEY like
  # cases 8/22, so a red run can't pollute the real agent's state.
  # WARNING FOR ANYONE RUNNING THIS BY HAND: before the guard exists, this
  # case actually TYPES 'echo lot2-guard-marker' into the tmux session
  # running this very selftest — an inert marker either way, but real:
  # never run selftest-guard from a terminal you'd notice text appearing
  # in (see the module-wide note this function prints, and docs/gotchas.md).
  if [ -n "${TMUX:-}" ]; then
    own=$(own_tmux_session)
    set +e
    err=$(WSH_COCKPIT_AGENT="$GUARD_KEY" "$SCRIPT_DIR/wsh-live.sh" send 'echo lot2-guard-marker' "$own" 2>&1 >/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 8 ] && printf '%s' "$err" | grep -q refusing; then
      report_guard_case "25 send refuses own session (exit 8)" 0
    else
      report_guard_case "25 send refuses own session (exit 8)" 1 "rc=$rc (expected 8), stderr='$err'"
    fi
  else
    echo "note: case 25 skipped (not inside tmux)"
  fi

  # 26 (Task 2, lot 2, keys). Same guard, `keys)` block — see case 25.
  if [ -n "${TMUX:-}" ]; then
    own=$(own_tmux_session)
    set +e
    err=$(WSH_COCKPIT_AGENT="$GUARD_KEY" "$SCRIPT_DIR/wsh-live.sh" keys 'C-c' "$own" 2>&1 >/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 8 ] && printf '%s' "$err" | grep -q refusing; then
      report_guard_case "26 keys refuses own session (exit 8)" 0
    else
      report_guard_case "26 keys refuses own session (exit 8)" 1 "rc=$rc (expected 8), stderr='$err'"
    fi
  else
    echo "note: case 26 skipped (not inside tmux)"
  fi

  # 27 (Task 2, lot 2, step-run). Same guard, `step-run)` block — see case 25.
  if [ -n "${TMUX:-}" ]; then
    own=$(own_tmux_session)
    set +e
    err=$(WSH_COCKPIT_AGENT="$GUARD_KEY" "$SCRIPT_DIR/wsh-live.sh" step-run 1 'probe' 'true' "$own" 2>&1 >/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 8 ] && printf '%s' "$err" | grep -q refusing; then
      report_guard_case "27 step-run refuses own session (exit 8)" 0
    else
      report_guard_case "27 step-run refuses own session (exit 8)" 1 "rc=$rc (expected 8), stderr='$err'"
    fi
  else
    echo "note: case 27 skipped (not inside tmux)"
  fi

  # 28 (Task 2, lot 2, banner). Same guard, `banner)` block — see case 25.
  # `banner` recognizes its trailing [session] argument only when it is NOT
  # the sole remaining positional argument (wsh-live.sh: `[ $# -gt 1 ] &&
  # mux_has "${!#}"`) — the 'probe' text ahead of $own keeps this call two
  # args deep so the call actually reaches the guard instead of silently
  # missing it and falling back to the remembered session.
  if [ -n "${TMUX:-}" ]; then
    own=$(own_tmux_session)
    set +e
    err=$(WSH_COCKPIT_AGENT="$GUARD_KEY" "$SCRIPT_DIR/wsh-live.sh" banner step 'probe' "$own" 2>&1 >/dev/null)
    rc=$?
    set -e
    if [ "$rc" -eq 8 ] && printf '%s' "$err" | grep -q refusing; then
      report_guard_case "28 banner refuses own session (exit 8)" 0
    else
      report_guard_case "28 banner refuses own session (exit 8)" 1 "rc=$rc (expected 8), stderr='$err'"
    fi
  else
    echo "note: case 28 skipped (not inside tmux)"
  fi

  # 29 (Task 2, lot 2, positive control). A genuinely THIRD-PARTY session
  # must still accept `send` normally — the guard added for cases 25-28
  # must not neutralise writes to everyone else. GUARD_W2 is a fresh
  # disposable session, unrelated to the caller; poll `mux_capture` (not
  # just the rc) so this proves the command actually RAN in that pane, not
  # merely that `send` returned 0. The seq-file `send` writes for GUARD_W2
  # is keyed by session name, not by WSH_COCKPIT_AGENT (see lib/session.sh
  # seq_file), so it needs its own cleanup — added to selftest_guard_cleanup
  # above, not covered by the generic last-session-$GUARD_KEY removal.
  if [ -n "${TMUX:-}" ]; then
    set +e
    tmux new-session -d -s "$GUARD_W2" 2>/dev/null
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      echo "note: case 29 skipped (could not create '$GUARD_W2')"
    else
      set +e
      WSH_COCKPIT_AGENT="$GUARD_KEY" "$SCRIPT_DIR/wsh-live.sh" send 'echo lot2-w2-ok' "$GUARD_W2" >/dev/null 2>&1
      rc=$?
      set -e
      tries=0; found=no
      while [ "$tries" -lt 20 ]; do
        mux_capture "$GUARD_W2" 50 | grep -q lot2-w2-ok && { found=yes; break; }
        tries=$((tries + 1)); sleep 0.5
      done
      if [ "$rc" -eq 0 ] && [ "$found" = yes ]; then
        report_guard_case "29 send still writes to a genuinely non-own session" 0
      else
        report_guard_case "29 send still writes to a genuinely non-own session" 1 "rc=$rc (expected 0), found=$found (expected yes, marker 'lot2-w2-ok' never appeared in '$GUARD_W2')"
      fi
      tmux kill-session -t "=$GUARD_W2" 2>/dev/null || true
      rm -f "$(seq_file "$GUARD_W2")" 2>/dev/null || true
    fi
  else
    echo "note: case 29 skipped (not inside tmux)"
  fi

  # 30-36 (Task 3, lot 2): form-first discrimination
  # (docs/plans/2026-08-02-desambiguisation-argument-session.md §2/§3) and the
  # --session/-s flag (§2 point tranché 1). None of these need the caller to
  # be inside tmux — they exercise a disposable session, not
  # own_tmux_session — so unlike cases 2-3/25-29 they always run.

  # 30. A session that IS alive is still recognized as before (non-regression).
  # rc must be neither 4 (would mean need_session wrongly rejected an alive
  # session) nor 127 (command-not-found — the surest sign of a typo'd helper
  # call); the exact rc otherwise depends on whether seq #1 was ever framed
  # in this fresh session, which this case doesn't control.
  tmux new-session -d -s "$GUARD_T3_ALIVE" 2>/dev/null || true
  (WSH_COCKPIT_AGENT="$GUARD_T3_KEY" remember_session "$GUARD_T3_ALIVE") 2>/dev/null || true
  set +e
  "$SCRIPT_DIR/wsh-live.sh" output "$GUARD_T3_ALIVE" 1 >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 4 ] && [ "$rc" -ne 127 ]; then
    report_guard_case "30 output on a live session-shaped token is recognized (rc != 4, != 127)" 0
  else
    report_guard_case "30 output on a live session-shaped token is recognized (rc != 4, != 127)" 1 "rc=$rc"
  fi

  # 31. A token shaped like a session but DEAD must fail loud (exit 4), not
  # fall through to the remembered GUARD_T3_ALIVE — this is the fix: before
  # it, the dead token was silently dropped and this call would have
  # succeeded (or failed some OTHER way) against GUARD_T3_ALIVE instead,
  # never mentioning GUARD_T3_DEAD at all.
  set +e
  err=$(WSH_COCKPIT_AGENT="$GUARD_T3_KEY" "$SCRIPT_DIR/wsh-live.sh" output "$GUARD_T3_DEAD" 1 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -eq 4 ] && printf '%s' "$err" | grep -q "no tmux session"; then
    report_guard_case "31 output on a dead session-shaped token fails loud (exit 4), not absorbed" 0
  else
    report_guard_case "31 output on a dead session-shaped token fails loud (exit 4), not absorbed" 1 "rc=$rc (expected 4), stderr='$err'"
  fi

  # 32. `banner`'s $# -gt 1 guard still protects a sole remaining argument
  # from being mistaken for a session, even when it now ALSO looks like one
  # by form — confined under GUARD_T3_KEY (remembered GUARD_T3_ALIVE) so
  # banner has a live session to actually write into; the control is on rc,
  # not on the pane's contents.
  set +e
  err=$(WSH_COCKPIT_AGENT="$GUARD_T3_KEY" "$SCRIPT_DIR/wsh-live.sh" banner header "$GUARD_T3_DEAD" 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -ne 4 ]; then
    report_guard_case "32 banner's sole remaining arg stays text, not mistaken for a session" 0
  else
    report_guard_case "32 banner's sole remaining arg stays text, not mistaken for a session" 1 "rc=4 (expected != 4), stderr='$err'"
  fi

  # 33. Bare numbers are still never mistaken for a session name — under a
  # key that has NO remembered session (GUARD_T3_KEY2), so this doesn't
  # accidentally piggyback on GUARD_T3_ALIVE from cases 30-32. The rc itself
  # is not asserted (it legitimately depends on whether SESS_DEFAULT
  # "cockpit" happens to be alive on this machine); what must NEVER happen is
  # '30' or '7' being named as an unknown session in stderr.
  set +e
  err=$(WSH_COCKPIT_AGENT="$GUARD_T3_KEY2" "$SCRIPT_DIR/wsh-live.sh" wait-done 30 7 2>&1 >/dev/null)
  rc=$?
  set -e
  if ! printf '%s' "$err" | grep -Eq "session '(30|7)'"; then
    report_guard_case "33 wait-done's bare numbers are never mistaken for a session name" 0
  else
    report_guard_case "33 wait-done's bare numbers are never mistaken for a session name" 1 "rc=$rc, stderr='$err'"
  fi

  # 34. --session/-s on a dead session short-circuits straight to exit 4 —
  # same outcome as case 31, reached through the flag instead of the
  # positional loop.
  set +e
  err=$(WSH_COCKPIT_AGENT="$GUARD_T3_KEY" "$SCRIPT_DIR/wsh-live.sh" output --session "$GUARD_T3_DEAD" 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -eq 4 ] && printf '%s' "$err" | grep -q "no tmux session"; then
    report_guard_case "34 output --session on a dead session exits 4" 0
  else
    report_guard_case "34 output --session on a dead session exits 4" 1 "rc=$rc (expected 4), stderr='$err'"
  fi

  # 35. --session/-s with no value (end of arguments) is a usage error, not a
  # silent no-op — exit 2, same family as spawn's -* usage errors above.
  set +e
  err=$(WSH_COCKPIT_AGENT="$GUARD_T3_KEY" "$SCRIPT_DIR/wsh-live.sh" output --session 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -eq 2 ]; then
    report_guard_case "35 output --session with no value exits 2 (usage error)" 0
  else
    report_guard_case "35 output --session with no value exits 2 (usage error)" 1 "rc=$rc (expected 2), stderr='$err'"
  fi

  # 36. Positive control: --session NAME still WRITES into that session —
  # cases 31/34/35 must not have turned the flag into a pure rejection path.
  # Poll mux_capture (not just rc) so this proves the command actually RAN.
  set +e
  WSH_COCKPIT_AGENT="$GUARD_T3_KEY" "$SCRIPT_DIR/wsh-live.sh" send 'echo lot2-t3-ok' --session "$GUARD_T3_ALIVE" >/dev/null 2>&1
  rc=$?
  set -e
  tries=0; found=no
  while [ "$tries" -lt 20 ]; do
    mux_capture "$GUARD_T3_ALIVE" 50 | grep -q lot2-t3-ok && { found=yes; break; }
    tries=$((tries + 1)); sleep 0.5
  done
  if [ "$rc" -eq 0 ] && [ "$found" = yes ]; then
    report_guard_case "36 send --session NAME still writes to that session (positive control)" 0
  else
    report_guard_case "36 send --session NAME still writes to that session (positive control)" 1 "rc=$rc (expected 0), found=$found (expected yes, marker 'lot2-t3-ok' never appeared in '$GUARD_T3_ALIVE')"
  fi

  # 37. Final-review fix: --session/-s accepts a leading "=" (tmux's own
  # exact-match-anchor syntax) without forwarding it verbatim to mux. Before
  # the fix, SESS_FLAG stayed "=NAME" unstripped and every mux call
  # downstream (send-keys -t, capture-pane -t) rejected it as an
  # unparseable target — poll mux_capture (not just rc) so this proves the
  # command actually ran, not just that the flag parsed.
  set +e
  WSH_COCKPIT_AGENT="$GUARD_T3_KEY" "$SCRIPT_DIR/wsh-live.sh" send 'echo lot2-fw-ok' --session "=$GUARD_T3_ALIVE" >/dev/null 2>&1
  rc=$?
  set -e
  tries=0; found=no
  while [ "$tries" -lt 20 ]; do
    mux_capture "$GUARD_T3_ALIVE" 50 | grep -q lot2-fw-ok && { found=yes; break; }
    tries=$((tries + 1)); sleep 0.5
  done
  if [ "$rc" -eq 0 ] && [ "$found" = yes ]; then
    report_guard_case "37 --session '=NAME' is stripped and reaches the pane" 0
  else
    report_guard_case "37 --session '=NAME' is stripped and reaches the pane" 1 "rc=$rc (expected 0), found=$found (expected yes, marker 'lot2-fw-ok' never appeared in '$GUARD_T3_ALIVE')"
  fi

  # 38. Final-review fix: a banner TEXT argument that is itself multi-word
  # and happens to start with "cockpit-" must not be mistaken for a session
  # — looks_like_session's cockpit-* glob used to match it regardless of
  # the embedded space (a real session name, produced only by spawn/start,
  # never contains whitespace). A leading dummy word ("essai") satisfies
  # banner's own $# -gt 1 guard so the trailing multi-word token is the one
  # actually probed by the sniff. Confined to GUARD_T3_KEY, which already
  # has a live GUARD_T3_ALIVE remembered from case 30 — resolution goes
  # through the ordinary DEFAULT path (no --session, no positional session
  # survives), same as real usage.
  set +e
  err=$(WSH_COCKPIT_AGENT="$GUARD_T3_KEY" "$SCRIPT_DIR/wsh-live.sh" banner "done" "essai" "cockpit-fixwave terminé" 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -ne 4 ]; then
    report_guard_case "38 banner's multi-word cockpit-shaped text is not mistaken for a session" 0
  else
    report_guard_case "38 banner's multi-word cockpit-shaped text is not mistaken for a session" 1 "rc=4 (expected != 4), stderr='$err'"
  fi

  # 39 (PR review, CodeRabbit). The equals form --session=NAME must behave
  # exactly like --session NAME — gc already accepts --idle=/--only-session=
  # so callers WILL type it; before the fix it fell into PSF_REST, matched
  # no discrimination branch, and the command silently ran against the
  # REMEMBERED session instead of the named one. Poll mux_capture so this
  # proves the command ran in the right pane, not just that parsing passed.
  set +e
  WSH_COCKPIT_AGENT="$GUARD_T3_KEY" "$SCRIPT_DIR/wsh-live.sh" send 'echo lot2-eq-ok' "--session=$GUARD_T3_ALIVE" >/dev/null 2>&1
  rc=$?
  set -e
  tries=0; found=no
  while [ "$tries" -lt 20 ]; do
    mux_capture "$GUARD_T3_ALIVE" 50 | grep -q lot2-eq-ok && { found=yes; break; }
    tries=$((tries + 1)); sleep 0.5
  done
  if [ "$rc" -eq 0 ] && [ "$found" = yes ]; then
    report_guard_case "39 --session=NAME (equals form) reaches the named session" 0
  else
    report_guard_case "39 --session=NAME (equals form) reaches the named session" 1 "rc=$rc (expected 0), found=$found (expected yes, marker 'lot2-eq-ok' never appeared in '$GUARD_T3_ALIVE')"
  fi

  # 40 (PR review, CodeRabbit). --session PLUS a session-shaped positional is
  # a contradiction — before the fix the positional was silently dropped and
  # the flag won without a word, the exact "guess instead of fail" behavior
  # this lot exists to close. flag_conflict_check must exit 2 with both names
  # on stderr.
  set +e
  err=$(WSH_COCKPIT_AGENT="$GUARD_T3_KEY" "$SCRIPT_DIR/wsh-live.sh" output --session "$GUARD_T3_ALIVE" "cockpit-conflict-$$" 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q 'name the session once'; then
    report_guard_case "40 --session + session-shaped positional fails loud (exit 2)" 0
  else
    report_guard_case "40 --session + session-shaped positional fails loud (exit 2)" 1 "rc=$rc (expected 2), stderr='$err'"
  fi

  # 41 (PR review, Copilot). read's LINES must be numeric on EVERY branch —
  # before the fix `read --session NAME foo` fed "foo" straight to
  # capture-pane -S as an invalid scrollback offset (confusing tmux error
  # instead of a usage error).
  set +e
  err=$(WSH_COCKPIT_AGENT="$GUARD_T3_KEY" "$SCRIPT_DIR/wsh-live.sh" read --session "$GUARD_T3_ALIVE" foo 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -eq 2 ] && printf '%s' "$err" | grep -q 'must be a positive integer'; then
    report_guard_case "41 read rejects a non-numeric lines argument (exit 2)" 0
  else
    report_guard_case "41 read rejects a non-numeric lines argument (exit 2)" 1 "rc=$rc (expected 2), stderr='$err'"
  fi

  # 42 (CodeRabbit review). A registry hit — find_registry_session, spawn's
  # étape 1 (spec v12 §2, "le registre des claims est l'autorité de
  # résolution") — must be refused, not silently handed back, when its
  # foreground process isn't a bare shell. find_reusable_session's own
  # remembered/newest fallbacks already run session_safe_to_reuse (cases 7,
  # 20b, ...); before this fix the registry hit was the one resolution step
  # that bypassed it entirely, so `send` could type straight into a
  # foreign foreground process (ssh, vim, less...) instead of a shell.
  tmux new-session -d -s "$GUARD_REGBUSY" 'exec top'
  tries=0; cmd=""
  while [ "$tries" -lt 20 ]; do
    cmd=$(mux_pane_command "$GUARD_REGBUSY")
    [ "$cmd" = top ] && break
    tries=$((tries + 1)); sleep 0.2
  done
  claim_create "$(session_slug "$GUARD_REGBUSY")" "$GUARD_REGKEY" >/dev/null 2>&1
  set +e
  reg42=$( WSH_COCKPIT_AGENT="$GUARD_REGKEY"; export WSH_COCKPIT_AGENT
           find_registry_session "" "$(normalize_prefix "")" 2>/dev/null )
  rc42=$?
  set -e
  if [ "$rc42" -ne 0 ] && [ -z "$reg42" ]; then
    report_guard_case "42 registry hit with busy foreground process refused, not silently reused" 0
  else
    report_guard_case "42 registry hit with busy foreground process refused, not silently reused" 1 "rc=$rc42 reg='$reg42' (cmd='$cmd')"
  fi

  selftest_guard_cleanup
  trap - EXIT
  if [ "$failures" -eq 0 ]; then echo "selftest-guard: all cases passed"; return 0
  else echo "selftest-guard: $failures failure(s)" >&2; return 1; fi
}

# Claim state-machine test (step-1.2, lib/claim.sh) — pure filesystem, no
# tmux session needed (same spirit as selftest-cache/selftest-oneshot-ssh).
# Slugs are opaque strings here on purpose: deriving a slug from a real
# session name is step-1.3's job, not this fiche's.
cmd_selftest_claim() {
  # NOT local: the EXIT trap runs after this function has already returned
  # (same rationale as selftest-guard's GUARD_* / selftest-cache's SESS).
  CLAIM_PREFIX="selftest-claim-$$"
  local failures=0 rc rc2 rc3 rc4 rcB rcV wins stale_leftover won_gone
  local key_after key_after_finalize key_after_release key_final key_won key8 pid8 lines8
  local slug prekey ownkey pidx pidy rcfile_a rcfile_b rcfile_e rcfile_f f

  report_claim_case() {  # $1 label  $2 rc (0=ok)  $3 detail (shown on failure)
    if [ "$2" -eq 0 ]; then
      echo "ok $1"
    else
      echo "FAIL $1${3:+: $3}" >&2
      failures=$((failures + 1))
    fi
  }

  selftest_claim_cleanup() {
    rm -f "${STATE_DIR}/adopt-claim-${CLAIM_PREFIX}"* 2>/dev/null || true
    rm -f "${TMPDIR:-/tmp}/wsh-cockpit-selftest-claim-"*".$$" 2>/dev/null || true
  }
  trap selftest_claim_cleanup EXIT

  mkdir -p "$STATE_DIR"

  # 1. Cycle nominal complet : création -> consommation -> vérif -> définitif
  #    -> release -> re-consommation par un nouvel agent.
  slug="${CLAIM_PREFIX}-cycle"
  prekey="user-preopen-1"
  ownkey="claude-selftest-cycle-$$"
  pidx="${$}A1"
  set +e
  claim_create "$slug" "$prekey" "$$" >/dev/null 2>&1; rc=$?
  claim_consume "$slug" "$pidx" >/dev/null 2>&1; rc2=$?
  claim_verify_won "$slug" "$pidx" >/dev/null 2>&1; rc3=$?
  claim_finalize "$slug" "$pidx" "$ownkey" >/dev/null 2>&1; rc4=$?
  set -e
  key_after_finalize=$(claim_read_key "$(claim_path "$slug")" 2>/dev/null || true)
  won_gone=1; [ -f "$(claim_won_path "$slug" "$pidx")" ] || won_gone=0
  if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$rc3" -eq 0 ] && [ "$rc4" -eq 0 ] \
     && [ "$key_after_finalize" = "$ownkey" ] && [ "$won_gone" -eq 0 ]; then
    report_claim_case "1a cycle nominal : create -> consume -> verify -> finalize" 0
  else
    report_claim_case "1a cycle nominal : create -> consume -> verify -> finalize" 1 \
      "rc=$rc/$rc2/$rc3/$rc4 key='$key_after_finalize' (attendu '$ownkey') won_gone=$won_gone"
  fi

  set +e
  claim_release "$slug" "$ownkey" >/dev/null 2>&1; rc=$?
  set -e
  key_after_release=$(claim_read_key "$(claim_path "$slug")" 2>/dev/null || true)
  if [ "$rc" -eq 0 ] && [ "$key_after_release" = "released" ]; then
    report_claim_case "1b release : POSSÉDÉ -> PRÉ-CLAIM released" 0
  else
    report_claim_case "1b release : POSSÉDÉ -> PRÉ-CLAIM released" 1 "rc=$rc key='$key_after_release'"
  fi

  pidy="${$}B1"
  set +e
  claim_consume "$slug" "$pidy" >/dev/null 2>&1; rc=$?
  claim_verify_won "$slug" "$pidy" >/dev/null 2>&1; rc2=$?
  set -e
  if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ]; then
    report_claim_case "1c re-consommation du released par un nouvel agent" 0
  else
    report_claim_case "1c re-consommation du released par un nouvel agent" 1 "rc=$rc rc2=$rc2"
  fi

  # 2. Course A/B sur un même pré-claim : exactement un gagnant (comptage),
  #    par dispatch réellement concurrent (deux sous-shells en arrière-plan).
  slug="${CLAIM_PREFIX}-race"
  claim_create "$slug" "user-preopen-2" "$$" >/dev/null 2>&1
  rcfile_a="${TMPDIR:-/tmp}/wsh-cockpit-selftest-claim-raceA.$$"
  rcfile_b="${TMPDIR:-/tmp}/wsh-cockpit-selftest-claim-raceB.$$"
  ( claim_consume "$slug" "${$}A2" >/dev/null 2>&1; echo $? >"$rcfile_a" ) &
  ( claim_consume "$slug" "${$}B2" >/dev/null 2>&1; echo $? >"$rcfile_b" ) &
  wait
  rc=$(cat "$rcfile_a" 2>/dev/null || echo 1)
  rc2=$(cat "$rcfile_b" 2>/dev/null || echo 1)
  wins=0
  [ "$rc" -eq 0 ] && wins=$((wins + 1))
  [ "$rc2" -eq 0 ] && wins=$((wins + 1))
  if [ "$wins" -eq 1 ]; then
    report_claim_case "2 course A/B sur un même pré-claim : exactement un gagnant" 0
  else
    report_claim_case "2 course A/B sur un même pré-claim : exactement un gagnant" 1 "wins=$wins rcA=$rc rcB=$rc2"
  fi

  # 3. Anti-ré-armement : B rename APRÈS le claim définitif de A -> détecté
  #    par la vérification de contenu (I2), rename inverse (rollback),
  #    aucune double adoption (le claim de A reste intact).
  slug="${CLAIM_PREFIX}-antirearm"
  claim_create "$slug" "user-preopen-3" "$$" >/dev/null 2>&1
  claim_consume "$slug" "${$}A3" >/dev/null 2>&1
  claim_verify_won "$slug" "${$}A3" >/dev/null 2>&1
  ownkey="claude-selftest-antirearm-A-$$"
  claim_finalize "$slug" "${$}A3" "$ownkey" >/dev/null 2>&1
  set +e
  claim_consume "$slug" "${$}B3" >/dev/null 2>&1; rcB=$?
  claim_verify_won "$slug" "${$}B3" >/dev/null 2>&1; rcV=$?
  set -e
  if [ "$rcV" -eq 0 ]; then
    report_claim_case "3 anti-ré-armement détecté par vérif de contenu" 1 \
      "claim_verify_won a validé à tort le claim définitif de A comme pré-claim"
  else
    set +e
    claim_rollback "$slug" "${$}B3" >/dev/null 2>&1
    set -e
    key_final=$(claim_read_key "$(claim_path "$slug")" 2>/dev/null || true)
    won_gone=1; [ -f "$(claim_won_path "$slug" "${$}B3")" ] || won_gone=0
    if [ "$rcB" -eq 0 ] && [ "$key_final" = "$ownkey" ] && [ "$won_gone" -eq 0 ]; then
      report_claim_case "3 anti-ré-armement détecté par vérif de contenu" 0
    else
      report_claim_case "3 anti-ré-armement détecté par vérif de contenu" 1 \
        "rcB=$rcB key_final='$key_final' (attendu '$ownkey') won_gone=$won_gone"
    fi
  fi

  # 4. .won-<pid> résiduel d'un pid recyclé : purgé/restauré avant la
  #    consommation réelle (jamais écrasé silencieusement — I1).
  slug="${CLAIM_PREFIX}-recycled"
  pidx="${$}R4"
  printf 'user-preopen-99\n%s\n' "$pidx" >"$(claim_won_path "$slug" "$pidx")"
  claim_create "$slug" "user-preopen-4" "$$" >/dev/null 2>&1
  set +e
  claim_consume "$slug" "$pidx" >/dev/null 2>&1; rc=$?
  set -e
  key_won=$(claim_read_key "$(claim_won_path "$slug" "$pidx")" 2>/dev/null || true)
  if [ "$rc" -eq 0 ] && [ "$key_won" = "user-preopen-4" ]; then
    report_claim_case "4 .won-<pid> résiduel de pid recyclé purgé avant consommation" 0
  else
    report_claim_case "4 .won-<pid> résiduel de pid recyclé purgé avant consommation" 1 \
      "rc=$rc key_won='$key_won' (attendu 'user-preopen-4')"
  fi

  # 5. Rollback face à un claim définitif apparu entre-temps : le .won est
  #    supprimé, le claim rival reste intact (jamais écrasé — I1).
  slug="${CLAIM_PREFIX}-rollback-race"
  pidx="${$}C5"
  claim_create "$slug" "user-preopen-5" "$$" >/dev/null 2>&1
  claim_consume "$slug" "$pidx" >/dev/null 2>&1
  ownkey="claude-selftest-rollback-D-$$"
  claim_create "$slug" "$ownkey" "$$" >/dev/null 2>&1
  set +e
  claim_rollback "$slug" "$pidx" >/dev/null 2>&1; rc=$?
  set -e
  key_after=$(claim_read_key "$(claim_path "$slug")" 2>/dev/null || true)
  won_gone=1; [ -f "$(claim_won_path "$slug" "$pidx")" ] || won_gone=0
  if [ "$rc" -ne 0 ] && [ "$key_after" = "$ownkey" ] && [ "$won_gone" -eq 0 ]; then
    report_claim_case "5 rollback vs claim définitif apparu entre-temps : won supprimé, claim intact" 0
  else
    report_claim_case "5 rollback vs claim définitif apparu entre-temps : won supprimé, claim intact" 1 \
      "rc=$rc key_after='$key_after' (attendu '$ownkey') won_gone=$won_gone"
  fi

  # 6. Remplacement d'orphelin sous course réelle : deux remplaçants
  #    concurrents sur le même orphelin -> exactement un gagnant, aucun
  #    .stale-<pid> résiduel, claim final valide (l'un des deux gagnants).
  #    Note : dans cette implémentation, le perdant échoue le plus souvent
  #    dès le `mv claim .stale-<pid>` (source disparue) plutôt qu'à l'étape
  #    O_EXCL elle-même — la protection I1 de `claim__restore` (perte
  #    O_EXCL -> restauration no-clobber) est exercée directement par les
  #    cas 3 et 5 ci-dessus, qui partagent la même primitive interne.
  slug="${CLAIM_PREFIX}-orphan-race"
  claim_create "$slug" "user-preopen-6" "$$" >/dev/null 2>&1
  rcfile_e="${TMPDIR:-/tmp}/wsh-cockpit-selftest-claim-orphanE.$$"
  rcfile_f="${TMPDIR:-/tmp}/wsh-cockpit-selftest-claim-orphanF.$$"
  ( claim_replace_orphan "$slug" "${$}E6" "claude-orphan-E-$$" >/dev/null 2>&1; echo $? >"$rcfile_e" ) &
  ( claim_replace_orphan "$slug" "${$}F6" "claude-orphan-F-$$" >/dev/null 2>&1; echo $? >"$rcfile_f" ) &
  wait
  rc=$(cat "$rcfile_e" 2>/dev/null || echo 1)
  rc2=$(cat "$rcfile_f" 2>/dev/null || echo 1)
  key_after=$(claim_read_key "$(claim_path "$slug")" 2>/dev/null || true)
  stale_leftover=0
  for f in "${STATE_DIR}/adopt-claim-${slug}".stale-*; do
    [ -e "$f" ] && stale_leftover=$((stale_leftover + 1))
  done
  wins=0
  [ "$rc" -eq 0 ] && wins=$((wins + 1))
  [ "$rc2" -eq 0 ] && wins=$((wins + 1))
  if [ "$wins" -eq 1 ] \
     && { [ "$key_after" = "claude-orphan-E-$$" ] || [ "$key_after" = "claude-orphan-F-$$" ]; } \
     && [ "$stale_leftover" -eq 0 ]; then
    report_claim_case "6 remplacement d'orphelin sous course : un gagnant, aucun .stale résiduel" 0
  else
    report_claim_case "6 remplacement d'orphelin sous course : un gagnant, aucun .stale résiduel" 1 \
      "wins=$wins rcE=$rc rcF=$rc2 key_after='$key_after' stale_leftover=$stale_leftover"
  fi

  # 7. Refus de clé réservée (user-preopen-*, released) vs. clé normale.
  if claim_key_reserved "user-preopen-7" && claim_key_reserved "released" \
     && ! claim_key_reserved "claude-not-reserved-$$"; then
    report_claim_case "7 refus de clé réservée (user-preopen-*, released)" 0
  else
    report_claim_case "7 refus de clé réservée (user-preopen-*, released)" 1 "claim_key_reserved incohérent"
  fi

  # 8. Format à deux lignes (clé, pid) relu correctement.
  slug="${CLAIM_PREFIX}-format"
  claim_create "$slug" "claude-format-$$" "4242" >/dev/null 2>&1
  key8=$(claim_read_key "$(claim_path "$slug")" 2>/dev/null || true)
  pid8=$(claim_read_pid "$(claim_path "$slug")" 2>/dev/null || true)
  lines8=$(wc -l <"$(claim_path "$slug")" | tr -d ' ')
  if [ "$key8" = "claude-format-$$" ] && [ "$pid8" = "4242" ] && [ "$lines8" -eq 2 ]; then
    report_claim_case "8 format à deux lignes (clé, pid) relu correctement" 0
  else
    report_claim_case "8 format à deux lignes (clé, pid) relu correctement" 1 \
      "key8='$key8' pid8='$pid8' lines8=$lines8"
  fi

  selftest_claim_cleanup
  trap - EXIT
  if [ "$failures" -eq 0 ]; then echo "selftest-claim: all cases passed"; return 0
  else echo "selftest-claim: $failures failure(s)" >&2; return 1; fi
}

# selftest-adopt — step-1.3, spec v12 §2 étape 1 ("le registre des claims est
# l'autorité de résolution"): spawn/start pose the creator's claim + a
# registered prefix at creation, and find_reusable_session/find_registry_session
# resolve MY sessions from that registry, ambiguity included.
#
# Every underlying tmux session here is created via the real `start`
# subcommand (real subprocess, `WSH_COCKPIT_AGENT` set per case) — `start`
# never calls "$0" open, unlike `spawn`'s creation/no-client-attached reuse
# paths, so this whole selftest never pops a real Wave block. The two real
# `spawn` subprocess calls below (cases 4 and 6b) are exactly the ones that
# exit BEFORE `spawn` would ever reach `open` (reserved-key refusal, registry
# ambiguity) — deliberately, not by luck. Where the test needs a SPAWN-style
# registered prefix (not `start`'s "(named)" sentinel) on an already-live
# session, it calls `prefix_write` directly in-process — the claim itself
# (line 1 = key) doesn't differ between the two callers, only the prefix
# value does, so overwriting just that file is a faithful stand-in for what
# `spawn`'s own creation branch would have written.
cmd_selftest_adopt() {
  ADOPT_KEY="claude-selftest-adopt-$$"
  local failures=0 rc
  local -a created=()

  report_adopt_case() {  # $1 label $2 rc (0=ok) $3 detail (shown on failure)
    if [ "$2" -eq 0 ]; then
      echo "ok $1"
    else
      echo "FAIL $1${3:+: $3}" >&2
      failures=$((failures + 1))
    fi
  }

  selftest_adopt_cleanup() {
    local s
    for s in ${created[@]+"${created[@]}"}; do
      teardown_session "$s" >/dev/null 2>&1 || true
    done
    rm -f "$(state_file 2>/dev/null || true)" 2>/dev/null || true
  }
  trap selftest_adopt_cleanup EXIT

  mkdir -p "$STATE_DIR"

  # 1. `start` pose bien le claim du créateur (ma clé) + le sentinel de
  #    préfixe "(named)" (jamais matchable par une requête de préfixe, spec
  #    v12 §2).
  named1="selftest-adopt-named1-$$"
  set +e
  WSH_COCKPIT_AGENT="$ADOPT_KEY" "$SCRIPT_DIR/wsh-live.sh" start "$named1" >/dev/null 2>&1
  rc=$?
  set -e
  created+=("$named1")
  k1=$(claim_read_key "$(claim_path "$(session_slug "$named1")")" 2>/dev/null || true)
  p1=$(prefix_read "$named1" 2>/dev/null || true)
  if [ "$rc" -eq 0 ] && [ "$k1" = "$ADOPT_KEY" ] && [ "$p1" = "(named)" ]; then
    report_adopt_case "1 start pose claim(ma clé) + sentinel de préfixe (named)" 0
  else
    report_adopt_case "1 start pose claim(ma clé) + sentinel de préfixe (named)" 1 \
      "rc=$rc key='$k1' (attendu '$ADOPT_KEY') prefix='$p1' (attendu '(named)')"
  fi

  # 2. `start` refuse un nom dont le slug collisionne avec celui d'une
  #    session vivante différente ('@' et '#' se réduisent tous deux au même
  #    '_' par session_slug — collision garantie par construction).
  coll_a="selftest-adopt-coll@$$"
  coll_b="selftest-adopt-coll#$$"
  WSH_COCKPIT_AGENT="$ADOPT_KEY" "$SCRIPT_DIR/wsh-live.sh" start "$coll_a" >/dev/null 2>&1
  created+=("$coll_a")
  set +e
  errcoll=$(WSH_COCKPIT_AGENT="$ADOPT_KEY" "$SCRIPT_DIR/wsh-live.sh" start "$coll_b" 2>&1)
  rccoll=$?
  set -e
  bexists=1; mux_has "$coll_b" && bexists=0
  if [ "$rccoll" -eq 2 ] && [ "$bexists" -eq 1 ]; then
    report_adopt_case "2 start refuse un nom au slug collisionnant (rc=2, pas créé)" 0
  else
    report_adopt_case "2 start refuse un nom au slug collisionnant (rc=2, pas créé)" 1 \
      "rccoll=$rccoll bexists=$bexists err='$errcoll'"
  fi

  # 3. Refus des clés réservées ("user-preopen-*"/"released") + levée par
  #    l'indicateur interne --preopen (start, portée sûre : aucun effet Wave).
  resv1="selftest-adopt-resv1-$$"
  set +e
  WSH_COCKPIT_AGENT="user-preopen-99" "$SCRIPT_DIR/wsh-live.sh" start "$resv1" >/dev/null 2>&1
  rcresv=$?
  set -e
  resv1_exists=1; mux_has "$resv1" && resv1_exists=0
  resv2="selftest-adopt-resv2-$$"
  set +e
  WSH_COCKPIT_AGENT="user-preopen-99" "$SCRIPT_DIR/wsh-live.sh" start "$resv2" --preopen >/dev/null 2>&1
  rcpreopen=$?
  set -e
  created+=("$resv2")
  resv2_ok=1; { [ "$rcpreopen" -eq 0 ] && mux_has "$resv2"; } && resv2_ok=0
  if [ "$rcresv" -eq 2 ] && [ "$resv1_exists" -eq 1 ] && [ "$resv2_ok" -eq 0 ]; then
    report_adopt_case "3 refus clé réservée + levée par --preopen" 0
  else
    report_adopt_case "3 refus clé réservée + levée par --preopen" 1 \
      "rcresv=$rcresv resv1_exists=$resv1_exists rcpreopen=$rcpreopen resv2_ok=$resv2_ok"
  fi

  # 4. `spawn` refuse la même clé réservée — sort avant même d'atteindre la
  #    détection de réutilisation, donc jamais d'ouverture Wave ici.
  set +e
  errspawnresv=$(WSH_COCKPIT_AGENT="released" "$SCRIPT_DIR/wsh-live.sh" spawn 2>&1)
  rcspawnresv=$?
  set -e
  if [ "$rcspawnresv" -eq 2 ]; then
    report_adopt_case "4 spawn refuse aussi la clé réservée 'released'" 0
  else
    report_adopt_case "4 spawn refuse aussi la clé réservée 'released'" 1 \
      "rcspawnresv=$rcspawnresv err='$errspawnresv'"
  fi

  # 5-6-7 : sessions A/B enregistrées SOUS PRÉFIXE (style spawn) — créées via
  # `start` (aucun effet Wave), puis leur sentinel "(named)" est remplacé par
  # un préfixe réel via prefix_write (seule la valeur de préfixe diffère
  # entre les deux appelants, cf. commentaire de tête de fonction).
  sess_a="selftest-adopt-a-$$"
  sess_b="selftest-adopt-b-$$"
  WSH_COCKPIT_AGENT="$ADOPT_KEY" "$SCRIPT_DIR/wsh-live.sh" start "$sess_a" >/dev/null 2>&1
  WSH_COCKPIT_AGENT="$ADOPT_KEY" "$SCRIPT_DIR/wsh-live.sh" start "$sess_b" >/dev/null 2>&1
  created+=("$sess_a" "$sess_b")
  pfx_a=$(normalize_prefix "adopt-pfx-a-$$")
  pfx_b=$(normalize_prefix "adopt-pfx-b-$$")
  prefix_write "$sess_a" "$pfx_a"
  prefix_write "$sess_b" "$pfx_b"

  had_agent=0; [ -n "${WSH_COCKPIT_AGENT+x}" ] && had_agent=1
  saved_agent="${WSH_COCKPIT_AGENT:-}"
  export WSH_COCKPIT_AGENT="$ADOPT_KEY"
  rm -f "$(state_file)" 2>/dev/null || true

  # 5. Alternance A→B→A : jamais de misroute (registre, étape 1).
  set +e
  r1=$(find_reusable_session "adopt-pfx-a-$$"); rc1=$?
  r2=$(find_reusable_session "adopt-pfx-b-$$"); rc2=$?
  r3=$(find_reusable_session "adopt-pfx-a-$$"); rc3=$?
  set -e
  if [ "$rc1" -eq 0 ] && [ "$r1" = "$sess_a" ] && [ "$rc2" -eq 0 ] && [ "$r2" = "$sess_b" ] \
     && [ "$rc3" -eq 0 ] && [ "$r3" = "$sess_a" ]; then
    report_adopt_case "5 alternance A→B→A sans misroute (registre, étape 1)" 0
  else
    report_adopt_case "5 alternance A→B→A sans misroute (registre, étape 1)" 1 \
      "rc1=$rc1 r1='$r1' rc2=$rc2 r2='$r2' rc3=$rc3 r3='$r3'"
  fi

  # 6a. N>1 de mes sessions au registre, sans préfixe demandé ni last-session
  #     enregistrée -> ambiguïté explicite (rc=2), jamais un (N+1)-ième
  #     cockpit silencieux.
  set +e
  find_reusable_session "" >/dev/null 2>&1; rc6a=$?
  set -e
  if [ "$rc6a" -eq 2 ]; then
    report_adopt_case "6a N>1 sans préfixe ni last-session -> rc=2 explicite" 0
  else
    report_adopt_case "6a N>1 sans préfixe ni last-session -> rc=2 explicite" 1 "rc6a=$rc6a"
  fi

  # 6b. Même condition, bout en bout via le vrai `spawn` — le rc=2 sort
  #     avant la création, donc avant tout "$0 open".
  set +e
  errspawnamb=$(WSH_COCKPIT_AGENT="$ADOPT_KEY" "$SCRIPT_DIR/wsh-live.sh" spawn 2>&1)
  rcspawnamb=$?
  set -e
  if [ "$rcspawnamb" -eq 2 ]; then
    report_adopt_case "6b spawn (sous-processus réel) surface la même ambiguïté" 0
  else
    report_adopt_case "6b spawn (sous-processus réel) surface la même ambiguïté" 1 \
      "rcspawnamb=$rcspawnamb err='$errspawnamb'"
  fi

  # 6c. Une last-session appartenant au registre départage l'ambiguïté.
  remember_session "$sess_a"
  set +e
  r6c=$(find_reusable_session ""); rc6c=$?
  set -e
  if [ "$rc6c" -eq 0 ] && [ "$r6c" = "$sess_a" ]; then
    report_adopt_case "6c last-session au registre départage l'ambiguïté" 0
  else
    report_adopt_case "6c last-session au registre départage l'ambiguïté" 1 "rc6c=$rc6c r6c='$r6c'"
  fi

  # 7. Une session créée par `start` (sentinel "(named)") reste inatteignable
  #    par une résolution à base de préfixe, même sous la même clé.
  named2="selftest-adopt-named2-$$"
  WSH_COCKPIT_AGENT="$ADOPT_KEY" "$SCRIPT_DIR/wsh-live.sh" start "$named2" >/dev/null 2>&1
  created+=("$named2")
  # find_registry_session (étape 1 seule), pas le wrapper find_reusable_session :
  # ce dernier retomberait légitimement sur last-session — que le `start` réel
  # ci-dessus vient de réécrire vers named2 lui-même — masquant la question
  # posée ici, qui porte sur le registre seul (spec v12 §2, étape 1).
  set +e
  r7=$(find_registry_session "some-fresh-prefix-$$" "$(normalize_prefix "some-fresh-prefix-$$")"); rc7=$?
  set -e
  if [ "$rc7" -eq 1 ]; then
    report_adopt_case "7 session créée par start ((named)) inatteignable par préfixe" 0
  else
    report_adopt_case "7 session créée par start ((named)) inatteignable par préfixe" 1 "rc7=$rc7 r7='$r7'"
  fi

  rm -f "$(state_file)" 2>/dev/null || true
  if [ "$had_agent" -eq 1 ]; then export WSH_COCKPIT_AGENT="$saved_agent"
  else unset WSH_COCKPIT_AGENT; fi

  # 8. `stop` d'une session créée ne laisse ni claim ni prefix-<slug> orphelin.
  sess_c="selftest-adopt-c-$$"
  WSH_COCKPIT_AGENT="$ADOPT_KEY" "$SCRIPT_DIR/wsh-live.sh" start "$sess_c" >/dev/null 2>&1
  created+=("$sess_c")
  slug_c=$(session_slug "$sess_c")
  claim_before=1; [ -f "$(claim_path "$slug_c")" ] && claim_before=0
  prefix_before=1; [ -f "$(prefix_file "$sess_c")" ] && prefix_before=0
  set +e
  WSH_COCKPIT_AGENT="$ADOPT_KEY" "$SCRIPT_DIR/wsh-live.sh" stop "$sess_c" >/dev/null 2>&1
  rc8=$?
  set -e
  claim_after=1; [ -f "$(claim_path "$slug_c")" ] && claim_after=0
  prefix_after=1; [ -f "$(prefix_file "$sess_c")" ] && prefix_after=0
  if [ "$claim_before" -eq 0 ] && [ "$prefix_before" -eq 0 ] && [ "$rc8" -eq 0 ] \
     && [ "$claim_after" -eq 1 ] && [ "$prefix_after" -eq 1 ]; then
    report_adopt_case "8 stop ne laisse ni claim ni prefix-<slug> orphelin" 0
  else
    report_adopt_case "8 stop ne laisse ni claim ni prefix-<slug> orphelin" 1 \
      "claim_before=$claim_before prefix_before=$prefix_before rc8=$rc8 claim_after=$claim_after prefix_after=$prefix_after"
  fi

  # 9-16 (step-1.4, spec v12 §2, étape 2 "adoption"). WSH_COCKPIT_ADOPT is
  # exercised via IN-PROCESS calls to try_adopt_session — never a real
  # `spawn` subprocess: on a synthetic, client-less session, spawn's shared
  # reuse branch would call `$0 open` (a genuine Wave block popup), the same
  # side effect already avoided by cases 1-8 above.
  had_agent9=0; [ -n "${WSH_COCKPIT_AGENT+x}" ] && had_agent9=1
  saved_agent9="${WSH_COCKPIT_AGENT:-}"
  had_adopt9=0; [ -n "${WSH_COCKPIT_ADOPT+x}" ] && had_adopt9=1
  saved_adopt9="${WSH_COCKPIT_ADOPT:-}"
  rm -f "$(state_file)" 2>/dev/null || true

  # 9. Adoption simple : consume+verify+sonde+finalize d'un pré-claim libre,
  #    avec PREUVE que la sonde a réellement tourné dans le pane (pas
  #    seulement rc=0 — le contenu hostname/pwd/whoami capturé compte).
  sess9="selftest-adopt-simple9-$$"
  WSH_COCKPIT_AGENT="user-preopen-9" "$SCRIPT_DIR/wsh-live.sh" start "$sess9" --preopen >/dev/null 2>&1
  created+=("$sess9")
  export WSH_COCKPIT_AGENT="$ADOPT_KEY"
  export WSH_COCKPIT_ADOPT="$sess9"
  set +e
  try_adopt_session "" ""
  rc9=$?
  set -e
  k9=$(claim_read_key "$(claim_path "$(session_slug "$sess9")")" 2>/dev/null || true)
  won9_gone=1; [ -f "$(claim_won_path "$(session_slug "$sess9")" "$$")" ] || won9_gone=0
  probe9_ok=1; printf '%s\n' "$ADOPT_PROBE_OUT" | grep -q '^WSH_SITUATE_HOST=' && probe9_ok=0
  if [ "$rc9" -eq 0 ] && [ "$ADOPT_RESULT" = "$sess9" ] && [ "$k9" = "$ADOPT_KEY" ] \
     && [ "$won9_gone" -eq 0 ] && [ "$probe9_ok" -eq 0 ]; then
    report_adopt_case "9 adoption simple, sonde PROUVÉE exécutée (hostname/pwd/whoami capturés)" 0
  else
    report_adopt_case "9 adoption simple, sonde PROUVÉE exécutée (hostname/pwd/whoami capturés)" 1 \
      "rc9=$rc9 ADOPT_RESULT='$ADOPT_RESULT' k9='$k9' won9_gone=$won9_gone probe9_ok=$probe9_ok probe_out='$ADOPT_PROBE_OUT'"
  fi

  # 10. Course A/B : le "perdant" (même $$ que le gagnant dans ce process de
  #     selftest, comme selftest-claim cas 2/3 suffixe déjà $$ plutôt que de
  #     forker un vrai second process) retombe sur le candidat SUIVANT de sa
  #     liste au lieu de s'arrêter. La ré-consommation du claim déjà finalisé
  #     par le gagnant est détectée par l'anti-ré-armement (I2,
  #     claim_verify_won) exactement comme un vrai perdant concurrent le
  #     serait — rollback, puis repli propre sur le candidat D.
  sessC10="selftest-adopt-race-c10-$$"
  sessD10="selftest-adopt-race-d10-$$"
  WSH_COCKPIT_AGENT="user-preopen-10" "$SCRIPT_DIR/wsh-live.sh" start "$sessC10" --preopen >/dev/null 2>&1
  WSH_COCKPIT_AGENT="user-preopen-10" "$SCRIPT_DIR/wsh-live.sh" start "$sessD10" --preopen >/dev/null 2>&1
  created+=("$sessC10" "$sessD10")
  export WSH_COCKPIT_AGENT="winner10-$$"
  export WSH_COCKPIT_ADOPT="$sessC10"
  set +e; try_adopt_session "" ""; rc10win=$?; set -e
  result10win="$ADOPT_RESULT"
  export WSH_COCKPIT_AGENT="loser10-$$"
  export WSH_COCKPIT_ADOPT="$sessC10,$sessD10"
  set +e; try_adopt_session "" ""; rc10lose=$?; set -e
  result10lose="$ADOPT_RESULT"
  kC10=$(claim_read_key "$(claim_path "$(session_slug "$sessC10")")" 2>/dev/null || true)
  kD10=$(claim_read_key "$(claim_path "$(session_slug "$sessD10")")" 2>/dev/null || true)
  if [ "$rc10win" -eq 0 ] && [ "$result10win" = "$sessC10" ] && [ "$kC10" = "winner10-$$" ] \
     && [ "$rc10lose" -eq 0 ] && [ "$result10lose" = "$sessD10" ] && [ "$kD10" = "loser10-$$" ]; then
    report_adopt_case "10 course A/B : le perdant retombe proprement sur le candidat suivant" 0
  else
    report_adopt_case "10 course A/B : le perdant retombe proprement sur le candidat suivant" 1 \
      "rc10win=$rc10win result10win='$result10win' kC10='$kC10' rc10lose=$rc10lose result10lose='$result10lose' kD10='$kD10'"
  fi

  # 11. Garde busy-pane élargie : un pane occupé par un process NI shell nu
  #     NI ssh/tailscale/mosh (ici `top`, même technique que GUARD_BUSY du
  #     selftest-guard, avec le même sondage tolérant au démarrage) échoue
  #     l'adoption ET restaure le claim en PRÉ-CLAIM (rollback) — jamais de
  #     claim laissé EN-COURS/POSSÉDÉ sans sonde réussie.
  sess11="cockpit-selftest-adopt-busy11-$$"
  tmux new-session -d -s "$sess11" 'exec top'
  created+=("$sess11")
  tries11=0; cmd11=""
  while [ "$tries11" -lt 20 ]; do
    cmd11=$(mux_pane_command "$sess11")
    [ "$cmd11" = top ] && break
    tries11=$((tries11 + 1)); sleep 0.2
  done
  slug11=$(session_slug "$sess11")
  claim_create "$slug11" "user-preopen-11" "$$" >/dev/null 2>&1
  prefix_write "$sess11" "(named)"
  export WSH_COCKPIT_AGENT="busyagent11-$$"
  export WSH_COCKPIT_ADOPT="$sess11"
  set +e; try_adopt_session "" ""; rc11=$?; set -e
  k11=$(claim_read_key "$(claim_path "$slug11")" 2>/dev/null || true)
  won11_gone=1; [ -f "$(claim_won_path "$slug11" "$$")" ] || won11_gone=0
  if [ "$rc11" -ne 0 ] && [ -z "$ADOPT_RESULT" ] && [ "$k11" = "user-preopen-11" ] && [ "$won11_gone" -eq 0 ]; then
    report_adopt_case "11 pane busy (ni shell nu ni ssh/tailscale/mosh) : rollback, claim restauré" 0
  else
    report_adopt_case "11 pane busy (ni shell nu ni ssh/tailscale/mosh) : rollback, claim restauré" 1 \
      "rc11=$rc11 ADOPT_RESULT='$ADOPT_RESULT' k11='$k11' won11_gone=$won11_gone cmd11='$cmd11'"
  fi

  # 12. Garde busy-pane élargie, sur la prédicate pure (pas de vrai process
  #     `ssh` fake dans un pane — mêmes raisons pragmatiques que le cas 7
  #     historique sur find_registry_session) : bare shell ET ssh/tailscale/
  #     mosh sont adoptables, tout le reste est refusé.
  ok12=0
  for cmd12 in "" bash zsh sh fish -bash -zsh -sh -fish ssh -ssh tailscale mosh mosh-client; do
    adopt_state_allowed "$cmd12" || ok12=1
  done
  bad12=0
  for cmd12 in top vim nano less htop python3 node; do
    adopt_state_allowed "$cmd12" && bad12=1
  done
  if [ "$ok12" -eq 0 ] && [ "$bad12" -eq 0 ]; then
    report_adopt_case "12 garde élargie : bare shell + ssh/tailscale/mosh adoptables, le reste refusé" 0
  else
    report_adopt_case "12 garde élargie : bare shell + ssh/tailscale/mosh adoptables, le reste refusé" 1 \
      "ok12=$ok12 bad12=$bad12"
  fi

  # 13. Une session offerte qui EST la session tmux du process appelant est
  #     toujours refusée, même via WSH_COCKPIT_ADOPT — jamais de claim
  #     touché sur sa propre session.
  if [ -n "${TMUX:-}" ]; then
    own13=$(own_tmux_session)
    export WSH_COCKPIT_AGENT="selfowner13-$$"
    export WSH_COCKPIT_ADOPT="$own13"
    set +e; try_adopt_session "" ""; rc13=$?; set -e
    if [ "$rc13" -ne 0 ] && [ -z "$ADOPT_RESULT" ]; then
      report_adopt_case "13 refus d'adopter sa propre session" 0
    else
      report_adopt_case "13 refus d'adopter sa propre session" 1 "rc13=$rc13 ADOPT_RESULT='$ADOPT_RESULT'"
    fi
  else
    echo "note: case 13 skipped (not inside tmux)"
  fi

  # 14. Candidat offert mais mort (jamais créé) : message d'avertissement une
  #     seule fois, pas à chaque appel.
  dead14="cockpit-selftest-adopt-dead14-$$"
  export WSH_COCKPIT_AGENT="deadagent14-$$"
  export WSH_COCKPIT_ADOPT="$dead14"
  set +e; out14a=$(try_adopt_session "" "" 2>&1 1>/dev/null); rc14a=$?; set -e
  set +e; out14b=$(try_adopt_session "" "" 2>&1 1>/dev/null); rc14b=$?; set -e
  warn14_once=1
  if printf '%s\n' "$out14a" | grep -q 'not alive'; then
    printf '%s\n' "$out14b" | grep -q 'not alive' || warn14_once=0
  fi
  rm -f "$(adopt_warn_file "$dead14")" 2>/dev/null || true
  if [ "$rc14a" -ne 0 ] && [ "$rc14b" -ne 0 ] && [ "$warn14_once" -eq 0 ]; then
    report_adopt_case "14 candidat mort : avertissement une seule fois" 0
  else
    report_adopt_case "14 candidat mort : avertissement une seule fois" 1 \
      "rc14a=$rc14a rc14b=$rc14b out14a='$out14a' out14b='$out14b'"
  fi

  # 15. Préfixe demandé qui ne correspond pas au préfixe enregistré du
  #     candidat -> jamais une adoption nominale, même si le candidat est par
  #     ailleurs parfaitement libre/adoptable (contrôle positif inclus : le
  #     même candidat s'adopte bien avec le BON préfixe).
  sess15="selftest-adopt-pfxmiss15-$$"
  WSH_COCKPIT_AGENT="user-preopen-15" "$SCRIPT_DIR/wsh-live.sh" start "$sess15" --preopen >/dev/null 2>&1
  created+=("$sess15")
  pfx15_real=$(normalize_prefix "adopt-pfx15-real-$$")
  pfx15_other=$(normalize_prefix "adopt-pfx15-other-$$")
  prefix_write "$sess15" "$pfx15_real"
  export WSH_COCKPIT_AGENT="pfxagent15-$$"
  export WSH_COCKPIT_ADOPT="$sess15"
  set +e; try_adopt_session "adopt-pfx15-other-$$" "$pfx15_other"; rc15a=$?; set -e
  res15a="$ADOPT_RESULT"
  set +e; try_adopt_session "adopt-pfx15-real-$$" "$pfx15_real"; rc15b=$?; set -e
  res15b="$ADOPT_RESULT"
  if [ "$rc15a" -ne 0 ] && [ -z "$res15a" ] && [ "$rc15b" -eq 0 ] && [ "$res15b" = "$sess15" ]; then
    report_adopt_case "15 préfixe non matché : jamais une adoption nominale (+ contrôle positif)" 0
  else
    report_adopt_case "15 préfixe non matché : jamais une adoption nominale (+ contrôle positif)" 1 \
      "rc15a=$rc15a res15a='$res15a' rc15b=$rc15b res15b='$res15b'"
  fi

  # 16. Un candidat libre offert prime sur une last-session résiduelle "hors
  #     registre" (créée sans claim, style pré-étape-1.3) : le registre rate
  #     (rc=1), find_reusable_session RETOMBERAIT sur la résiduelle (contrôle
  #     positif : elle existe et est réutilisable), mais try_adopt_session
  #     réussit d'abord — c'est cet ordre-là que spawn câble réellement
  #     (wsh-live.sh : registre -> adoption -> repli find_reusable_session).
  sess16_residual="cockpit-selftest-adopt-residual16-$$"
  create_session "$sess16_residual"
  created+=("$sess16_residual")
  sess16_free="selftest-adopt-free16-$$"
  WSH_COCKPIT_AGENT="user-preopen-16" "$SCRIPT_DIR/wsh-live.sh" start "$sess16_free" --preopen >/dev/null 2>&1
  created+=("$sess16_free")
  export WSH_COCKPIT_AGENT="freshagent16-$$"
  export WSH_COCKPIT_ADOPT="$sess16_free"
  rm -f "$(state_file)" 2>/dev/null || true
  remember_session "$sess16_residual"
  norm16=$(normalize_prefix "")
  set +e
  reg16=$(find_registry_session "" "$norm16"); rcreg16=$?
  legacy16=$(find_reusable_session ""); rclegacy16=$?
  try_adopt_session "" "$norm16"; rcadopt16=$?
  set -e
  result16="$ADOPT_RESULT"
  if [ "$rcreg16" -eq 1 ] && [ "$rclegacy16" -eq 0 ] && [ "$legacy16" = "$sess16_residual" ] \
     && [ "$rcadopt16" -eq 0 ] && [ "$result16" = "$sess16_free" ]; then
    report_adopt_case "16 candidat libre prime sur une last-session résiduelle" 0
  else
    report_adopt_case "16 candidat libre prime sur une last-session résiduelle" 1 \
      "rcreg16=$rcreg16 rclegacy16=$rclegacy16 legacy16='$legacy16' rcadopt16=$rcadopt16 result16='$result16'"
  fi

  # 17-22 (step-1.5, spec v12 §2, étape 3 "scan"): the cockpit-<prefix>-*
  # scan excludes every claimed session (I3), a claimed sibling never
  # over-matches a shorter slug, an unclaimed legacy session gets claimed +
  # probed on reuse, and `--force` bypasses all of the above while leaving
  # existing claims untouched.
  unset WSH_COCKPIT_ADOPT
  rm -f "$(state_file)" 2>/dev/null || true

  # 17. Les trois formes de claim (I3 : définitif d'un tiers, pré-claim du
  #     wrapper, transfert .won-* en cours) excluent TOUTES la session du
  #     scan — une quatrième session, non claimée, reste seule éligible même
  #     si elle est lexicographiquement la plus ANCIENNE du groupe (sans
  #     l'exclusion, `newest_session_for_prefix` retiendrait la plus RÉCENTE,
  #     qui est ici systématiquement une des trois claimées).
  pfx17="selftest-adopt-scan17-$$"
  norm17=$(normalize_prefix "$pfx17")
  s17_free="cockpit-${norm17}-100000"
  s17_def="cockpit-${norm17}-200000"
  s17_pre="cockpit-${norm17}-300000"
  s17_won="cockpit-${norm17}-400000"
  create_session "$s17_free"
  create_session "$s17_def"
  create_session "$s17_pre"
  create_session "$s17_won"
  created+=("$s17_free" "$s17_def" "$s17_pre" "$s17_won")
  claim_create "$(session_slug "$s17_def")" "someone-else-17-$$" >/dev/null 2>&1
  claim_create "$(session_slug "$s17_pre")" "user-preopen-17" >/dev/null 2>&1
  claim_create "$(session_slug "$s17_won")" "user-preopen-17w" >/dev/null 2>&1
  claim_consume "$(session_slug "$s17_won")" "$$" >/dev/null 2>&1
  export WSH_COCKPIT_AGENT="scan17agent-$$"
  set +e
  r17=$(find_reusable_session "$pfx17"); rc17=$?
  set -e
  if [ "$rc17" -eq 0 ] && [ "$r17" = "$s17_free" ]; then
    report_adopt_case "17 les trois formes de claim excluent le scan (définitif/pré-claim/.won-*)" 0
  else
    report_adopt_case "17 les trois formes de claim excluent le scan (définitif/pré-claim/.won-*)" 1 \
      "rc17=$rc17 r17='$r17' (attendu '$s17_free')"
  fi

  # 18. Le glob exact (I3) ne sur-matche pas une sœur suffixée "-1" : un
  #     claim définitif sur le slug SIBLING ("<slug>-1") ne doit jamais
  #     faire passer le slug de base pour claimé.
  pfx18="selftest-adopt-scan18-$$"
  norm18=$(normalize_prefix "$pfx18")
  s18_base="cockpit-${norm18}-100000"
  s18_sibling="${s18_base}-1"
  create_session "$s18_base"
  create_session "$s18_sibling"
  created+=("$s18_base" "$s18_sibling")
  claim_create "$(session_slug "$s18_sibling")" "someone-else-18-$$" >/dev/null 2>&1
  base18_claimed=1; claim_is_claimed "$(session_slug "$s18_base")" || base18_claimed=0
  set +e
  r18=$(newest_session_for_prefix "$norm18"); rc18=$?
  set -e
  if [ "$base18_claimed" -eq 0 ] && [ "$rc18" -eq 0 ] && [ "$r18" = "$s18_base" ]; then
    report_adopt_case "18 le claim d'une sœur -1 ne sur-matche pas le slug de base" 0
  else
    report_adopt_case "18 le claim d'une sœur -1 ne sur-matche pas le slug de base" 1 \
      "base18_claimed=$base18_claimed rc18=$rc18 r18='$r18' (attendu '$s18_base')"
  fi

  # 19. Reprise d'une session legacy jamais claimée : `try_legacy_claim`
  #     pose le claim du créateur (ma clé) ET exécute la sonde, avec PREUVE
  #     qu'elle a réellement tourné dans le pane (même exigence que le cas 9,
  #     fiche 1.4) — pas seulement rc=0.
  pfx19="selftest-adopt-scan19-$$"
  norm19=$(normalize_prefix "$pfx19")
  s19="cockpit-${norm19}-190000"
  create_session "$s19"
  created+=("$s19")
  export WSH_COCKPIT_AGENT="legacy19agent-$$"
  set +e
  try_legacy_claim "$s19" "$norm19" >/dev/null 2>&1
  rc19=$?
  set -e
  k19=$(claim_read_key "$(claim_path "$(session_slug "$s19")")" 2>/dev/null || true)
  p19=$(prefix_read "$s19" 2>/dev/null || true)
  probe19_ok=1; printf '%s\n' "$ADOPT_PROBE_OUT" | grep -q '^WSH_SITUATE_HOST=' && probe19_ok=0
  if [ "$rc19" -eq 0 ] && [ "$LEGACY_RESULT" = "$s19" ] && [ "$k19" = "legacy19agent-$$" ] \
     && [ "$p19" = "$norm19" ] && [ "$probe19_ok" -eq 0 ]; then
    report_adopt_case "19 reprise legacy : claim du créateur posé + sonde PROUVÉE exécutée" 0
  else
    report_adopt_case "19 reprise legacy : claim du créateur posé + sonde PROUVÉE exécutée" 1 \
      "rc19=$rc19 LEGACY_RESULT='$LEGACY_RESULT' k19='$k19' p19='$p19' probe19_ok=$probe19_ok probe_out='$ADOPT_PROBE_OUT'"
  fi

  # 20. `spawn --force` : création directe même avec un candidat legacy
  #     libre présent (scan/legacy-claim jamais atteints — le candidat reste
  #     non-claimé après coup) ET les claims déjà possédés par l'agent
  #     restent intacts. `wsh` est masqué du PATH pour ce seul sous-processus
  #     (open échoue tôt sur "wsh not found", exit 5, AVANT tout wsh run —
  #     donc aucun effet Wave ; création+claim ont déjà eu lieu avant ce
  #     point, sous le même `set -e` ligne-à-ligne).
  sess20_existing="selftest-adopt-force-existing20-$$"
  WSH_COCKPIT_AGENT="$ADOPT_KEY" "$SCRIPT_DIR/wsh-live.sh" start "$sess20_existing" >/dev/null 2>&1
  created+=("$sess20_existing")
  slug20_existing=$(session_slug "$sess20_existing")
  key20_before=$(claim_read_key "$(claim_path "$slug20_existing")" 2>/dev/null || true)

  pfx20="selftest-adopt-force20-$$"
  norm20=$(normalize_prefix "$pfx20")
  s20_free="cockpit-${norm20}-999999"
  create_session "$s20_free"
  created+=("$s20_free")

  NOWSH_PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  rm -f "$(state_file)" 2>/dev/null || true
  set +e
  out20=$(WSH_COCKPIT_AGENT="$ADOPT_KEY" PATH="$NOWSH_PATH" "$SCRIPT_DIR/wsh-live.sh" spawn "$pfx20" --force 2>&1)
  set -e
  sess20_new=$(printf '%s\n' "$out20" | sed -n "s/^created fresh .* session '\(.*\)'\$/\1/p")
  created+=("${sess20_new:-selftest-adopt-force20-none-$$}")

  free20_untouched=1; claim_is_claimed "$(session_slug "$s20_free")" || free20_untouched=0
  key20_after=$(claim_read_key "$(claim_path "$slug20_existing")" 2>/dev/null || true)
  newclaim20_key=""
  [ -n "$sess20_new" ] && newclaim20_key=$(claim_read_key "$(claim_path "$(session_slug "$sess20_new")")" 2>/dev/null || true)
  if [ -n "$sess20_new" ] && [ "$sess20_new" != "$s20_free" ] && mux_has "$sess20_new" \
     && [ "$free20_untouched" -eq 0 ] && [ "$key20_before" = "$ADOPT_KEY" ] \
     && [ "$key20_after" = "$ADOPT_KEY" ] && [ "$newclaim20_key" = "$ADOPT_KEY" ]; then
    report_adopt_case "20 spawn --force : session neuve, candidat legacy libre ignoré, claims intacts" 0
  else
    report_adopt_case "20 spawn --force : session neuve, candidat legacy libre ignoré, claims intacts" 1 \
      "sess20_new='$sess20_new' free20_untouched=$free20_untouched key20_before='$key20_before' key20_after='$key20_after' newclaim20_key='$newclaim20_key' out20='$out20'"
  fi

  # 21-28 (step-1.6, spec v12 §3, "release" + sticky "keep"). $WSH_COCKPIT_AGENT/
  # $WSH_COCKPIT_ADOPT keep being reassigned freely below (restored to the
  # cases 9-16 baseline only at the very end, same discipline as cases 9-20).

  # 21. `release` sans argument -> erreur d'usage (argument obligatoire, pas
  #     de repli sur la dernière session — spec v12 §3).
  set +e
  out21=$(WSH_COCKPIT_AGENT="$ADOPT_KEY" "$SCRIPT_DIR/wsh-live.sh" release 2>&1)
  rc21=$?
  set -e
  if [ "$rc21" -ne 0 ] && printf '%s\n' "$out21" | grep -qi 'usage'; then
    report_adopt_case "21 release sans argument : erreur d'usage" 0
  else
    report_adopt_case "21 release sans argument : erreur d'usage" 1 "rc21=$rc21 out21='$out21'"
  fi

  # 22. `release` par une clé qui ne possède PAS le claim -> refus (I4),
  #     claim intact.
  sess22="selftest-adopt-release-owner22-$$"
  WSH_COCKPIT_AGENT="$ADOPT_KEY" "$SCRIPT_DIR/wsh-live.sh" start "$sess22" >/dev/null 2>&1
  created+=("$sess22")
  slug22=$(session_slug "$sess22")
  key22_before=$(claim_read_key "$(claim_path "$slug22")" 2>/dev/null || true)
  export WSH_COCKPIT_AGENT="not-the-owner-22-$$"
  unset WSH_COCKPIT_ADOPT
  set +e; release_session "$sess22"; rc22=$?; set -e
  key22_after=$(claim_read_key "$(claim_path "$slug22")" 2>/dev/null || true)
  if [ "$rc22" -eq 1 ] && [ "$key22_after" = "$key22_before" ]; then
    report_adopt_case "22 release par une clé non propriétaire : refus (I4), claim intact" 0
  else
    report_adopt_case "22 release par une clé non propriétaire : refus (I4), claim intact" 1 \
      "rc22=$rc22 key22_before='$key22_before' key22_after='$key22_after'"
  fi

  # 23. Release d'une session ADOPTÉE : le claim rétrograde en pré-claim
  #     "released" (jamais supprimé) -> ré-adoptable via étape 2 UNIQUEMENT,
  #     par le même agent qui vient de la relâcher, sonde PROUVÉE exécutée à
  #     la ré-adoption (même exigence que le cas 9).
  sess23="selftest-adopt-release-adopted23-$$"
  WSH_COCKPIT_AGENT="user-preopen-23" "$SCRIPT_DIR/wsh-live.sh" start "$sess23" --preopen >/dev/null 2>&1
  created+=("$sess23")
  slug23=$(session_slug "$sess23")
  export WSH_COCKPIT_AGENT="releaser23-$$"
  export WSH_COCKPIT_ADOPT="$sess23"
  set +e; try_adopt_session "" ""; rc23a=$?; set -e
  key23_adopted=$(claim_read_key "$(claim_path "$slug23")" 2>/dev/null || true)
  set +e; release_session "$sess23"; rc23rel=$?; set -e
  key23_released=$(claim_read_key "$(claim_path "$slug23")" 2>/dev/null || true)
  set +e; try_adopt_session "" ""; rc23readopt=$?; set -e
  probe23_ok=1; printf '%s\n' "$ADOPT_PROBE_OUT" | grep -q '^WSH_SITUATE_HOST=' && probe23_ok=0
  if [ "$rc23a" -eq 0 ] && [ "$key23_adopted" = "releaser23-$$" ] \
     && [ "$rc23rel" -eq 0 ] && [ "$key23_released" = "released" ] \
     && [ "$rc23readopt" -eq 0 ] && [ "$ADOPT_RESULT" = "$sess23" ] && [ "$probe23_ok" -eq 0 ]; then
    report_adopt_case "23 release d'une adoptée : claim 'released', ré-adoption étape 2 avec sonde" 0
  else
    report_adopt_case "23 release d'une adoptée : claim 'released', ré-adoption étape 2 avec sonde" 1 \
      "rc23a=$rc23a key23_adopted='$key23_adopted' rc23rel=$rc23rel key23_released='$key23_released' rc23readopt=$rc23readopt ADOPT_RESULT='$ADOPT_RESULT' probe23_ok=$probe23_ok"
  fi

  # 24. Release d'une session CRÉÉE (jamais dans $WSH_COCKPIT_ADOPT) : le
  #     claim est supprimé entièrement (retour à ABSENT), re-scannable via
  #     étape 3.
  sess24="selftest-adopt-release-created24-$$"
  WSH_COCKPIT_AGENT="$ADOPT_KEY" "$SCRIPT_DIR/wsh-live.sh" start "$sess24" >/dev/null 2>&1
  created+=("$sess24")
  slug24=$(session_slug "$sess24")
  export WSH_COCKPIT_AGENT="$ADOPT_KEY"
  unset WSH_COCKPIT_ADOPT
  set +e; release_session "$sess24"; rc24=$?; set -e
  claimed24=1; claim_is_claimed "$slug24" && claimed24=0
  if [ "$rc24" -eq 0 ] && [ "$claimed24" -eq 1 ]; then
    report_adopt_case "24 release d'une créée : claim supprimé, session re-scannable" 0
  else
    report_adopt_case "24 release d'une créée : claim supprimé, session re-scannable" 1 \
      "rc24=$rc24 claimed24=$claimed24"
  fi

  # 25. Continuité du compteur seq-<slug> à travers release : release ne le
  #     touche JAMAIS (spec v12 §3) — le ré-adopter re-déclenche sa propre
  #     sonde (donc incrémente à nouveau, légitimement) ; ce qui compte ici
  #     est que release seul ne le remette pas à zéro/une valeur périmée,
  #     ce qui ferait faussement matcher un footer "└─[#N] exit" déjà vu.
  sess25="selftest-adopt-release-seq25-$$"
  WSH_COCKPIT_AGENT="user-preopen-25" "$SCRIPT_DIR/wsh-live.sh" start "$sess25" --preopen >/dev/null 2>&1
  created+=("$sess25")
  export WSH_COCKPIT_AGENT="seqagent25-$$"
  export WSH_COCKPIT_ADOPT="$sess25"
  set +e; try_adopt_session "" ""; rc25a=$?; set -e
  mkdir -p "$STATE_DIR"
  printf '7\n' >"$(seq_file "$sess25")"
  set +e; release_session "$sess25"; rc25rel=$?; set -e
  seq25_after_release=$(cat "$(seq_file "$sess25")" 2>/dev/null || true)
  if [ "$rc25a" -eq 0 ] && [ "$rc25rel" -eq 0 ] && [ "$seq25_after_release" = "7" ]; then
    report_adopt_case "25 release laisse seq-<slug> intact" 0
  else
    report_adopt_case "25 release laisse seq-<slug> intact" 1 \
      "rc25a=$rc25a rc25rel=$rc25rel seq25_after_release='$seq25_after_release'"
  fi

  # 26. Keep sticky, chemin 1 (adoptée) : marqueur keep-<slug> posé AVANT
  #     l'adoption (simule le wrapper, fiche 1.9, hors périmètre — on ne fait
  #     que le LIRE ici) ; `stop` sur la session adoptée route vers release,
  #     JAMAIS teardown : session/bloc restent vivants, claim rétrogradé.
  sess26="selftest-adopt-keep-adopted26-$$"
  WSH_COCKPIT_AGENT="user-preopen-26" "$SCRIPT_DIR/wsh-live.sh" start "$sess26" --preopen >/dev/null 2>&1
  created+=("$sess26")
  mkdir -p "$STATE_DIR"
  set +e; : >"$(keep_file "$sess26" 2>/dev/null)"; set -e
  export WSH_COCKPIT_AGENT="keepadopter26-$$"
  export WSH_COCKPIT_ADOPT="$sess26"
  set +e; try_adopt_session "" ""; set -e
  set +e
  out26=$(WSH_COCKPIT_AGENT="keepadopter26-$$" WSH_COCKPIT_ADOPT="$sess26" "$SCRIPT_DIR/wsh-live.sh" stop "$sess26" 2>&1)
  rc26=$?
  set -e
  key26_after=$(claim_read_key "$(claim_path "$(session_slug "$sess26")")" 2>/dev/null || true)
  alive26=1; mux_has "$sess26" && alive26=0
  if [ "$rc26" -eq 0 ] && [ "$alive26" -eq 0 ] && [ "$key26_after" = "released" ]; then
    report_adopt_case "26 keep sticky (chemin adoption) : stop => release, session/bloc vivants" 0
  else
    report_adopt_case "26 keep sticky (chemin adoption) : stop => release, session/bloc vivants" 1 \
      "rc26=$rc26 alive26=$alive26 key26_after='$key26_after' out26='$out26'"
  fi

  # 27. Keep sticky, chemin 2 (créée-relâchée, reprise au scan) : keep posé
  #     à la création, la session survit à un release (claim supprimé) puis
  #     à une reprise legacy par un AUTRE agent — le marqueur keep est une
  #     propriété de la session, pas du claim, donc il est hérité tel quel ;
  #     `stop` route encore vers release, jamais teardown.
  sess27="selftest-adopt-keep-scan27-$$"
  export WSH_COCKPIT_AGENT="keepcreator27-$$"
  unset WSH_COCKPIT_ADOPT
  "$SCRIPT_DIR/wsh-live.sh" start "$sess27" >/dev/null 2>&1
  created+=("$sess27")
  mkdir -p "$STATE_DIR"
  set +e; : >"$(keep_file "$sess27" 2>/dev/null)"; set -e
  set +e; release_session "$sess27"; set -e
  claimed27_after_release=1; claim_is_claimed "$(session_slug "$sess27")" && claimed27_after_release=0
  export WSH_COCKPIT_AGENT="keepscanner27-$$"
  norm27=$(normalize_prefix "")
  set +e; try_legacy_claim "$sess27" "$norm27"; rc27claim=$?; set -e
  set +e
  out27=$(WSH_COCKPIT_AGENT="keepscanner27-$$" "$SCRIPT_DIR/wsh-live.sh" stop "$sess27" 2>&1)
  rc27=$?
  set -e
  alive27=1; mux_has "$sess27" && alive27=0
  keep27_still_set=1; keep_is_set "$sess27" && keep27_still_set=0
  if [ "$claimed27_after_release" -eq 1 ] && [ "$rc27claim" -eq 0 ] \
     && [ "$rc27" -eq 0 ] && [ "$alive27" -eq 0 ] && [ "$keep27_still_set" -eq 0 ]; then
    report_adopt_case "27 keep sticky (créée-relâchée, reprise au scan) : keep hérité, stop => release" 0
  else
    report_adopt_case "27 keep sticky (créée-relâchée, reprise au scan) : keep hérité, stop => release" 1 \
      "claimed27_after_release=$claimed27_after_release rc27claim=$rc27claim rc27=$rc27 alive27=$alive27 keep27_still_set=$keep27_still_set out27='$out27'"
  fi

  # 28. Release par un sous-agent en fin de tâche, via le VRAI sous-commande
  #     `release` (dispatch wsh-live.sh, pas l'appel direct à la primitive
  #     comme au cas 23) : claim rétrogradé en "released".
  sess28="selftest-adopt-release-subagent28-$$"
  WSH_COCKPIT_AGENT="user-preopen-28" "$SCRIPT_DIR/wsh-live.sh" start "$sess28" --preopen >/dev/null 2>&1
  created+=("$sess28")
  export WSH_COCKPIT_AGENT="subagent28-$$"
  export WSH_COCKPIT_ADOPT="$sess28"
  set +e; try_adopt_session "" ""; set -e
  set +e
  out28=$(WSH_COCKPIT_AGENT="subagent28-$$" WSH_COCKPIT_ADOPT="$sess28" "$SCRIPT_DIR/wsh-live.sh" release "$sess28" 2>&1)
  rc28=$?
  set -e
  key28_after=$(claim_read_key "$(claim_path "$(session_slug "$sess28")")" 2>/dev/null || true)
  alive28=1; mux_has "$sess28" && alive28=0
  if [ "$rc28" -eq 0 ] && [ "$alive28" -eq 0 ] && [ "$key28_after" = "released" ]; then
    report_adopt_case "28 release par un sous-agent (vraie sous-commande) : claim rétrogradé" 0
  else
    report_adopt_case "28 release par un sous-agent (vraie sous-commande) : claim rétrogradé" 1 \
      "rc28=$rc28 alive28=$alive28 key28_after='$key28_after' out28='$out28'"
  fi

  # 29. Prédicate pure sur la dernière ligne capturée (mitigation
  #     best-effort spec §2, mesurée sur le vrai prompt de la machine — voir
  #     docs/gotchas.md) : prompt nu (avec ou sans décoration RPROMPT) →
  #     adoptable ; prompt + texte tapé → refusé ; ligne inclassable (thème
  #     de prompt non reconnu, scrollback quelconque) → adoptable (jamais de
  #     blocage sur une forme qu'on ne sait pas classer).
  ok29=0
  for line29 in '❯' '❯                                                                       ─╯' ''; do
    adopt_last_line_busy "$line29" && ok29=1
  done
  bad29=0
  for line29 in '❯ echo hello' '❯ echo hello                                                          ─╯'; do
    adopt_last_line_busy "$line29" || bad29=1
  done
  unclassified29=0
  for line29 in '$ ' 'some random scrollback line' '% '; do
    adopt_last_line_busy "$line29" && unclassified29=1
  done
  if [ "$ok29" -eq 0 ] && [ "$bad29" -eq 0 ] && [ "$unclassified29" -eq 0 ]; then
    report_adopt_case "29 dernière ligne : prompt nu adoptable, prompt+texte refusé, forme inconnue adoptable" 0
  else
    report_adopt_case "29 dernière ligne : prompt nu adoptable, prompt+texte refusé, forme inconnue adoptable" 1 \
      "ok29=$ok29 bad29=$bad29 unclassified29=$unclassified29"
  fi

  # 30. Cas réel : texte tapé dans le pane SANS Entrée (le process reste un
  #     shell nu, invisible à adopt_state_allowed) offert à l'adoption →
  #     refusée par la garde dernière-ligne, claim restauré à l'identique
  #     (calque du cas 11 busy-pane, sur le vrai prompt de la machine plutôt
  #     qu'un process `top`).
  sess30="cockpit-selftest-adopt-typing30-$$"
  tmux new-session -d -s "$sess30"
  created+=("$sess30")
  tries30=0; idle30=1; line30=""
  while [ "$tries30" -lt 30 ]; do
    line30=$(mux_pane_last_line "$sess30")
    if [ -n "$line30" ] && ! adopt_last_line_busy "$line30"; then idle30=0; break; fi
    tries30=$((tries30 + 1)); sleep 0.3
  done
  slug30=$(session_slug "$sess30")
  claim_create "$slug30" "user-preopen-30" "$$" >/dev/null 2>&1
  prefix_write "$sess30" "(named)"
  tmux send-keys -t "$sess30" -l 'echo selftest-adopt-typing30-not-run'
  sleep 0.4
  # Direct assertion on the new gate itself (fast, deterministic — same
  # pragmatic reasoning as testing session_safe_to_reuse directly against
  # GUARD_BUSY in selftest-guard): the pane's foreground IS a bare shell
  # (adopt_state_allowed alone would say "adoptable"), so only the new
  # last-line check can be refusing it here.
  ready30=0; adopt_pane_ready "$sess30" && ready30=1
  export WSH_COCKPIT_AGENT="typingagent30-$$"
  export WSH_COCKPIT_ADOPT="$sess30"
  # Elapsed-time guard: adopt_pane_ready must refuse BEFORE try_adopt_session
  # ever reaches adopt_run_probe — if it didn't, the probe's `send` would
  # merge its own text onto the tail of the still-unsubmitted typed line
  # above (mux_send_line's Enter would submit the GARBLED result), and
  # wait-done's 60s timeout would still make this case superficially "pass"
  # for the wrong reason (measured while writing this case, see
  # docs/gotchas.md). A well under a minute completion proves the gate fired
  # first, never touching the probe.
  SECONDS=0
  set +e; try_adopt_session "" ""; rc30=$?; set -e
  elapsed30=$SECONDS
  k30=$(claim_read_key "$(claim_path "$slug30")" 2>/dev/null || true)
  won30_gone=1; [ -f "$(claim_won_path "$slug30" "$$")" ] || won30_gone=0
  if [ "$idle30" -eq 0 ] && [ "$ready30" -eq 0 ] && [ "$rc30" -ne 0 ] && [ -z "$ADOPT_RESULT" ] \
     && [ "$k30" = "user-preopen-30" ] && [ "$won30_gone" -eq 0 ] && [ "$elapsed30" -lt 15 ]; then
    report_adopt_case "30 texte tapé sans Entrée (garde dernière ligne) : adoption refusée, claim restauré" 0
  else
    report_adopt_case "30 texte tapé sans Entrée (garde dernière ligne) : adoption refusée, claim restauré" 1 \
      "idle30=$idle30 ready30=$ready30 rc30=$rc30 ADOPT_RESULT='$ADOPT_RESULT' k30='$k30' won30_gone=$won30_gone elapsed30=${elapsed30}s line30='$line30'"
  fi

  rm -f "$(state_file)" 2>/dev/null || true
  if [ "$had_agent9" -eq 1 ]; then export WSH_COCKPIT_AGENT="$saved_agent9"
  else unset WSH_COCKPIT_AGENT; fi
  if [ "$had_adopt9" -eq 1 ]; then export WSH_COCKPIT_ADOPT="$saved_adopt9"
  else unset WSH_COCKPIT_ADOPT; fi

  selftest_adopt_cleanup
  trap - EXIT
  if [ "$failures" -eq 0 ]; then echo "selftest-adopt: all cases passed"; return 0
  else echo "selftest-adopt: $failures failure(s)" >&2; return 1; fi
}

# `open --tab <nom>` resolution (step-1.8, spec v12 §4): sql_quote() and
# resolve_tab_by_name() exercised against a throwaway FIXTURE sqlite DB
# (schema db_workspace/db_tab, minimal — the two columns the v12 query
# reads), never the real Wave DB, deterministic on purpose. Pure function
# test, no tmux session needed (same spirit as selftest-claim).
cmd_selftest_tab() {
  local failures=0

  report_tab_case() {  # $1 label  $2 rc (0=ok)  $3 detail (shown on failure)
    if [ "$2" -eq 0 ]; then
      echo "ok $1"
    else
      echo "FAIL $1${3:+: $3}" >&2
      failures=$((failures + 1))
    fi
  }

  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "selftest-tab: skip (no sqlite3 on PATH)"
    return 0
  fi

  # tmpdir/saved_ws/had_ws deliberately NOT local — same rationale as
  # cmd_selftest_sep's tmpdir: the EXIT trap below fires after this function
  # returns, when a `local` would already be out of scope.
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/wsh-tab-test.XXXXXX")
  trap 'rm -rf "$tmpdir" 2>/dev/null || true' EXIT
  had_ws=0; saved_ws=""
  [ -n "${WAVETERM_WORKSPACEID+x}" ] && { had_ws=1; saved_ws="$WAVETERM_WORKSPACEID"; }
  selftest_tab_cleanup() {
    if [ "$had_ws" -eq 1 ]; then export WAVETERM_WORKSPACEID="$saved_ws"
    else unset WAVETERM_WORKSPACEID; fi
  }
  trap 'selftest_tab_cleanup; rm -rf "$tmpdir" 2>/dev/null || true' EXIT

  local db ro
  db="$tmpdir/fixture.db"
  ro="file:$db?mode=ro"
  sqlite3 "$db" \
    'CREATE TABLE db_workspace (oid TEXT PRIMARY KEY, data TEXT); CREATE TABLE db_tab (oid TEXT PRIMARY KEY, data TEXT);'

  # ws1: the workspace under test. pinnedtabids present (non-empty) with a
  # single pinned "Dup"; tabids holds two more unpinned "Dup" whose ARRAY
  # ORDER (dup3 before dup2) is deliberately the REVERSE of their db_tab
  # insertion order below — proves the elected order follows
  # json_each.key/array position, not sqlite rowid/insertion order.
  local ws1='ws1' ws2='ws2'
  sqlite3 "$db" "INSERT INTO db_workspace (oid, data) VALUES ($(sql_quote "$ws1"), $(sql_quote \
    '{"tabids":["tabZ","tabY","dup3","dup2","hquote","hpercent","hnewline","hinject","dup2a","dup2b"],"pinnedtabids":["dup1"]}'));"
  # ws2: a second workspace, deliberately WITHOUT a pinnedtabids key at all
  # (absence of the key, not just an empty array — case 5) and holding a
  # tab homonym of ws1's "Alpha" (cross-workspace exclusion, case 2).
  sqlite3 "$db" "INSERT INTO db_workspace (oid, data) VALUES ($(sql_quote "$ws2"), $(sql_quote \
    '{"tabids":["wsb-alpha"]}'));"

  insert_tab() {  # $1 oid  $2 name (raw; none of the fixture's names need
                   # JSON escaping — no '"' or backslash among them)
    sqlite3 "$db" "INSERT INTO db_tab (oid, data) VALUES ($(sql_quote "$1"), $(sql_quote "{\"name\":\"$2\"}"));"
  }
  insert_tab dup2 "Dup"
  insert_tab dup3 "Dup"
  insert_tab tabZ "Alpha"
  insert_tab tabY "Beta"
  insert_tab dup1 "Dup"
  insert_tab hquote "it's a tab"
  insert_tab hpercent "100% done"
  insert_tab hnewline 'multi\nligne'
  insert_tab hinject "x'; DROP TABLE db_tab;--"
  insert_tab wsb-alpha "Alpha"
  insert_tab dup2a "Dup2"
  insert_tab dup2b "Dup2"

  local rc

  # 0. sql_quote() itself: no-op on a plain string, doubles an embedded '.
  if [ "$(sql_quote "abc")" = "'abc'" ]; then
    report_tab_case "0a sql_quote: chaîne simple" 0
  else
    report_tab_case "0a sql_quote: chaîne simple" 1 "got '$(sql_quote "abc")'"
  fi
  if [ "$(sql_quote "it's")" = "'it''s'" ]; then
    report_tab_case "0b sql_quote: quote simple doublée" 0
  else
    report_tab_case "0b sql_quote: quote simple doublée" 1 "got '$(sql_quote "it's")'"
  fi

  # 1. résolution simple par nom, bornée à ws1 — et pas de fuite du candidat
  # homonyme de ws2 (TAB_BY_NAME_ALL n'a qu'une ligne).
  export WAVETERM_WORKSPACEID="$ws1"
  rc=0; resolve_tab_by_name "Alpha" "$ro" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$TAB_BY_NAME_RESULT" = "tabZ" ] \
     && [ "$(printf '%s\n' "$TAB_BY_NAME_ALL" | wc -l | tr -d ' ')" -eq 1 ]; then
    report_tab_case "1 résolution simple par nom (ws1)" 0
  else
    report_tab_case "1 résolution simple par nom (ws1)" 1 "rc=$rc result='$TAB_BY_NAME_RESULT' all='$TAB_BY_NAME_ALL'"
  fi

  # 2/5. ws2 : homonyme d'un AUTRE workspace ne matche jamais (résout à
  # wsb-alpha seul, jamais tabZ) — et sa DB n'a pas de clé pinnedtabids du
  # tout, prouvant que l'union défensive reste valide sans elle.
  export WAVETERM_WORKSPACEID="$ws2"
  rc=0; resolve_tab_by_name "Alpha" "$ro" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$TAB_BY_NAME_RESULT" = "wsb-alpha" ]; then
    report_tab_case "2/5 homonyme d'un autre workspace ignoré + pinnedtabids absent (ws2)" 0
  else
    report_tab_case "2/5 homonyme d'un autre workspace ignoré + pinnedtabids absent (ws2)" 1 "rc=$rc result='$TAB_BY_NAME_RESULT'"
  fi
  export WAVETERM_WORKSPACEID="$ws1"

  # 3. doublons : élue = première dans l'ordre épinglés (dup1) puis tabids à
  # index croissant (dup3 avant dup2, malgré l'insertion inversée) ; warning
  # listant TOUS les candidats dans cet ordre exact.
  rc=0; resolve_tab_by_name "Dup" "$ro" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$TAB_BY_NAME_RESULT" = "dup1" ] \
     && [ "$TAB_BY_NAME_ALL" = "$(printf 'dup1\ndup3\ndup2')" ]; then
    report_tab_case "3 doublons: pinné d'abord, ordre array-index malgré insertion inversée, tous les candidats" 0
  else
    report_tab_case "3 doublons" 1 "rc=$rc result='$TAB_BY_NAME_RESULT' all='$TAB_BY_NAME_ALL'"
  fi

  # 3b. tab_count_candidates() : fonction pure factorisée (audit step-1.11.3,
  # É3) — comptage du nombre de candidats dans TAB_BY_NAME_ALL. N=1 (Alpha,
  # pas de warning attendu côté caller), N=2 ("Dup2", le cas qui échouait sur
  # `printf '%s' … | wc -l` — compte des TERMINATEURS de ligne sur une chaîne
  # sans retour final, donc N-1 : 2 candidats -> 1, seuil `-gt 1` muet), N=3
  # ("Dup", déjà correct par coïncidence avec l'ancien code buggé).
  rc=0; resolve_tab_by_name "Alpha" "$ro" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(tab_count_candidates "$TAB_BY_NAME_ALL")" -eq 1 ]; then
    report_tab_case "3b tab_count_candidates: N=1 candidat" 0
  else
    report_tab_case "3b tab_count_candidates: N=1 candidat" 1 "rc=$rc all='$TAB_BY_NAME_ALL' got='$(tab_count_candidates "$TAB_BY_NAME_ALL" 2>&1)'"
  fi
  rc=0; resolve_tab_by_name "Dup2" "$ro" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(tab_count_candidates "$TAB_BY_NAME_ALL")" -eq 2 ]; then
    report_tab_case "3b tab_count_candidates: N=2 candidats (cas ex-cassé, wc -l sans \\n final -> N-1)" 0
  else
    report_tab_case "3b tab_count_candidates: N=2 candidats" 1 "rc=$rc all='$TAB_BY_NAME_ALL' got='$(tab_count_candidates "$TAB_BY_NAME_ALL" 2>&1)'"
  fi
  rc=0; resolve_tab_by_name "Dup" "$ro" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$(tab_count_candidates "$TAB_BY_NAME_ALL")" -eq 3 ]; then
    report_tab_case "3b tab_count_candidates: N=3 candidats" 0
  else
    report_tab_case "3b tab_count_candidates: N=3 candidats" 1 "rc=$rc all='$TAB_BY_NAME_ALL' got='$(tab_count_candidates "$TAB_BY_NAME_ALL" 2>&1)'"
  fi

  # 4. noms hostiles : résolution correcte, jamais d'erreur de syntaxe.
  local hostile
  for hostile in "it's a tab:hquote" "100% done:hpercent" "x'; DROP TABLE db_tab;--:hinject"; do
    local qname="${hostile%%:*}" oid="${hostile##*:}"
    rc=0; resolve_tab_by_name "$qname" "$ro" || rc=$?
    if [ "$rc" -eq 0 ] && [ "$TAB_BY_NAME_RESULT" = "$oid" ]; then
      report_tab_case "4 nom hostile '$qname' résolu" 0
    else
      report_tab_case "4 nom hostile '$qname'" 1 "rc=$rc result='$TAB_BY_NAME_RESULT'"
    fi
  done
  # Retour à la ligne RÉEL dans le nom cherché (distinct du '\n' JSON stocké).
  local qnl
  qnl=$'multi\nligne'
  rc=0; resolve_tab_by_name "$qnl" "$ro" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$TAB_BY_NAME_RESULT" = "hnewline" ]; then
    report_tab_case "4 nom hostile avec retour à la ligne réel résolu" 0
  else
    report_tab_case "4 nom hostile avec retour à la ligne réel" 1 "rc=$rc result='$TAB_BY_NAME_RESULT'"
  fi
  # Aucune altération après la tentative d'injection : les 12 lignes de
  # db_tab sont toutes encore là (10 + dup2a/dup2b ajoutés au cas 3b).
  local cnt
  cnt=$(sqlite3 "$ro" "SELECT count(*) FROM db_tab;" 2>/dev/null || true)
  if [ "$cnt" = "12" ]; then
    report_tab_case "4 aucune altération de db_tab après injection (12 lignes intactes)" 0
  else
    report_tab_case "4 aucune altération de db_tab après injection" 1 "count=$cnt (want 12)"
  fi

  # 6. WAVETERM_WORKSPACEID absent -> rc=2, échec explicite, PAS de fallback
  # arbitraire (spec v12 §4, point b).
  unset WAVETERM_WORKSPACEID
  rc=0; resolve_tab_by_name "Alpha" "$ro" || rc=$?
  if [ "$rc" -eq 2 ]; then
    report_tab_case "6 WAVETERM_WORKSPACEID absent -> rc=2 (hors Wave, pas de fallback)" 0
  else
    report_tab_case "6 WAVETERM_WORKSPACEID absent -> rc=2" 1 "rc=$rc"
  fi
  export WAVETERM_WORKSPACEID="$ws1"

  # 7. onglet introuvable -> rc=3 (le caller avertit + retombe sur le
  # comportement actuel, testé au niveau wsh-live.sh, pas ici).
  rc=0; resolve_tab_by_name "NoSuchTab" "$ro" || rc=$?
  if [ "$rc" -eq 3 ]; then
    report_tab_case "7 onglet introuvable -> rc=3" 0
  else
    report_tab_case "7 onglet introuvable -> rc=3" 1 "rc=$rc"
  fi

  # 8. DB Wave inatteignable (wsh absent du PATH) -> rc=1, sans passer par le
  # fallback codé en dur de wave_db_ro (spec v12 §4, point c) : appelé SANS
  # l'override $2 cette fois, pour exercer le vrai chemin wave_db_ro_strict.
  local emptybin
  emptybin="$tmpdir/emptybin"
  mkdir -p "$emptybin"
  rc=0; ( PATH="$emptybin"; resolve_tab_by_name "Alpha" ) || rc=$?
  if [ "$rc" -eq 1 ]; then
    report_tab_case "8 wsh introuvable -> rc=1 (échec propre, pas de fallback AppSupport)" 0
  else
    report_tab_case "8 wsh introuvable -> rc=1" 1 "rc=$rc"
  fi

  selftest_tab_cleanup
  trap - EXIT
  rm -rf "$tmpdir" 2>/dev/null || true
  if [ "$failures" -eq 0 ]; then echo "selftest-tab: all cases passed"; return 0
  else echo "selftest-tab: $failures failure(s)" >&2; return 1; fi
}

# selftest-wrapper (fiche step-1.9): exercises claude-cockpit.sh end-to-end
# WITHOUT ever popping a real Wave block and WITHOUT ever launching a real
# `claude` — the two things automated selftests must never trigger (see
# execution/CONVENTIONS.md and the "aucun effet Wave" precedent already set
# by selftest-adopt's use of `start`).
#
# Harness (built fresh per invocation, in a throwaway tmpdir):
#   $tmpdir/claude-cockpit.sh  -> symlink to the REAL script under test.
#     `dirname "$0"` on a symlink resolves to the SYMLINK's own directory
#     (not its target's), so the real script's own SCRIPT_DIR computation
#     lands on $tmpdir here — which is exactly what lets the two swaps below
#     work without any test-only seam in the production script itself.
#   $tmpdir/lib                -> symlink to the REAL scripts/lib (so both
#     claude-cockpit.sh's own sourcing and the fake wsh-live.sh below run
#     against the real primitives, not a reimplementation of them).
#   $tmpdir/wsh-live.sh         a REAL, executable fake: its `spawn` replicates
#     wsh-live.sh's own fresh-creation tail verbatim (unique_session_name ->
#     create_session -> remember_session -> claim_new_session -> "SESSION=")
#     MINUS the "$0" open "$SESS" call — every other subcommand (stop/
#     release/...) execs straight through to the real wsh-live.sh, which
#     never pops a Wave block for those. Logs its own argv+env to
#     $WRAPTEST_SPAWN_LOG on every spawn call (proves per-group relay +
#     env isolation); exits 7 for a prefix matching $FAKE_SPAWN_FAIL_PREFIX
#     (proves the "abort before launching claude" path without needing a
#     real spawn failure).
#   $tmpdir/bin/claude          a REAL, executable stub: logs its own
#     argv+env to $WRAPTEST_CLAUDE_LOG, never touches tmux/Wave/the real
#     claude binary, exits $WRAPTEST_CLAUDE_EXIT (default 0).
# claude-cockpit.sh is invoked with PATH="$tmpdir/bin:$PATH" so `claude`
# resolves to the stub, and $0's own dirname resolution finds the fake
# wsh-live.sh as its sibling — no env-var override hook needed in the
# production script for any of this.
cmd_selftest_wrapper() {
  local failures=0

  report_wrapper_case() {  # $1 label  $2 rc (0=ok)  $3 detail (shown on failure)
    if [ "$2" -eq 0 ]; then
      echo "ok $1"
    else
      echo "FAIL $1${3:+: $3}" >&2
      failures=$((failures + 1))
    fi
  }

  local wrap="$SCRIPT_DIR/claude-cockpit.sh"
  if [ ! -f "$wrap" ]; then
    echo "selftest-wrapper: $wrap does not exist yet" >&2
    return 1
  fi

  # tmpdir/created deliberately NOT local — same rationale as cmd_selftest_tab's
  # tmpdir: the EXIT trap fires after this function returns.
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/wsh-wrapper-test.XXXXXX")
  local -a created=()
  selftest_wrapper_cleanup() {
    local s
    for s in ${created[@]+"${created[@]}"}; do
      teardown_session "$s" >/dev/null 2>&1 || true
    done
    rm -rf "$tmpdir" 2>/dev/null || true
  }
  trap selftest_wrapper_cleanup EXIT

  ln -s "$wrap" "$tmpdir/claude-cockpit.sh"
  ln -s "$SCRIPT_DIR/lib" "$tmpdir/lib"
  mkdir -p "$tmpdir/bin"

  cat >"$tmpdir/wsh-live.sh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
STATE_DIR="${WSH_COCKPIT_STATE_DIR:-$HOME/.cache/wsh-cockpit}"
MUX="tmux"
. "$SCRIPT_DIR/lib/mux.sh"
. "$SCRIPT_DIR/lib/claim.sh"
. "$SCRIPT_DIR/lib/session.sh"
case "${1:-}" in
  spawn)
    shift
    {
      echo "ARGS: $*"
      env
      echo "---"
    } >>"$WRAPTEST_SPAWN_LOG"
    PFX=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --force|--situate|--preopen) shift ;;
        --pre|--tab) shift 2 ;;
        -*) shift ;;
        *) PFX="$1"; shift ;;
      esac
    done
    if [ -n "${FAKE_SPAWN_FAIL_PREFIX:-}" ] && [ "$PFX" = "$FAKE_SPAWN_FAIL_PREFIX" ]; then
      echo "fake-spawn: simulated failure for prefix '$PFX'" >&2
      exit 7
    fi
    SESS=$(unique_session_name "$PFX")
    create_session "$SESS"
    remember_session "$SESS"
    claim_new_session "$SESS" "$(normalize_prefix "$PFX")"
    echo "created fresh $MUX session '$SESS' (selftest fake — no Wave open)"
    echo "SESSION=$SESS"
    ;;
  *)
    exec "$REAL_WSH_LIVE" "$@"
    ;;
esac
FAKE
  chmod +x "$tmpdir/wsh-live.sh"

  cat >"$tmpdir/bin/claude" <<'STUB'
#!/usr/bin/env bash
{
  echo "ARGS: $*"
  env
} >"$WRAPTEST_CLAUDE_LOG"
exit "${WRAPTEST_CLAUDE_EXIT:-0}"
STUB
  chmod +x "$tmpdir/bin/claude"

  export REAL_WSH_LIVE="$SCRIPT_DIR/wsh-live.sh"

  # -- Case A: 2 groups, --tab pass-through, --keep extraction, env isolation,
  #    exact WSH_COCKPIT_ADOPT/WSH_COCKPIT_AGENT, and the exit sweep. -------
  local pfx1="wraptest-a1-$$" pfx2="wraptest-a2-$$"
  local spawnlog="$tmpdir/spawn-a.log" claudelog="$tmpdir/claude-a.log"
  : >"$spawnlog"; rm -f "$claudelog"
  # Exported in THIS test's own shell (not the wrapper's) to prove the
  # wrapper actively strips it, rather than merely never setting it itself.
  export WSH_COCKPIT_PREFIX="should-not-leak-$$"
  export WRAPTEST_SPAWN_LOG="$spawnlog" WRAPTEST_CLAUDE_LOG="$claudelog"
  unset WRAPTEST_CLAUDE_EXIT FAKE_SPAWN_FAIL_PREFIX 2>/dev/null || true

  local rc=0
  PATH="$tmpdir/bin:$PATH" "$tmpdir/claude-cockpit.sh" \
    "$pfx1" --tab sometab --and "$pfx2" --keep -- echo hi \
    >"$tmpdir/a.out" 2>"$tmpdir/a.err" || rc=$?
  unset WSH_COCKPIT_PREFIX
  report_wrapper_case "A0 run exits 0 (both groups + claude stub succeeded)" \
    "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "rc=$rc stderr=$(cat "$tmpdir/a.err")"

  local sess1 sess2
  sess1=$(grep '^SESSION=' "$tmpdir/a.out" | sed -n '1s/^SESSION=//p')
  sess2=$(grep '^SESSION=' "$tmpdir/a.out" | sed -n '2s/^SESSION=//p')
  created+=("$sess1" "$sess2")
  report_wrapper_case "A1 exactly 2 SESSION= lines, both non-empty" \
    "$([ -n "$sess1" ] && [ -n "$sess2" ] && [ "$sess1" != "$sess2" ] && echo 0 || echo 1)" \
    "sess1='$sess1' sess2='$sess2'"

  # Group 1's fake-spawn call: prefix + --tab relayed, --force/--preopen
  # added, --keep absent (group 1 never had it), agent key scoped, no
  # WSH_COCKPIT_PREFIX leak.
  local block1
  block1=$(awk '/^ARGS:/{n++} n==1' "$spawnlog")
  report_wrapper_case "A2 group1 relay: prefix + --tab sometab + --force + --preopen, no --keep" \
    "$(printf '%s\n' "$block1" | grep -q "^ARGS: .*$pfx1 --tab sometab.*--force.*--preopen" \
       && ! printf '%s\n' "$block1" | grep -q -- '--keep' && echo 0 || echo 1)" \
    "block1='$block1'"
  report_wrapper_case "A3 group1 scoped WSH_COCKPIT_AGENT=user-preopen-1, no WSH_COCKPIT_PREFIX" \
    "$(printf '%s\n' "$block1" | grep -qx 'WSH_COCKPIT_AGENT=user-preopen-1' \
       && ! printf '%s\n' "$block1" | grep -q '^WSH_COCKPIT_PREFIX=' && echo 0 || echo 1)" \
    "block1='$block1'"

  local block2
  block2=$(awk '/^ARGS:/{n++} n==2' "$spawnlog")
  report_wrapper_case "A4 group2 relay: prefix + --force + --preopen, --keep extracted (not forwarded)" \
    "$(printf '%s\n' "$block2" | grep -q "^ARGS: .*$pfx2.*--force.*--preopen" \
       && ! printf '%s\n' "$block2" | grep -q -- '--keep' && echo 0 || echo 1)" \
    "block2='$block2'"
  report_wrapper_case "A5 group2 scoped WSH_COCKPIT_AGENT=user-preopen-2, no WSH_COCKPIT_PREFIX" \
    "$(printf '%s\n' "$block2" | grep -qx 'WSH_COCKPIT_AGENT=user-preopen-2' \
       && ! printf '%s\n' "$block2" | grep -q '^WSH_COCKPIT_PREFIX=' && echo 0 || echo 1)" \
    "block2='$block2'"

  # claude stub: exact args, exact WSH_COCKPIT_ADOPT, claude-<runid> shape,
  # no WSH_COCKPIT_PREFIX, no user-preopen-* key anywhere in its env.
  report_wrapper_case "A6 claude stub was launched" \
    "$([ -f "$claudelog" ] && echo 0 || echo 1)" "no $claudelog"
  if [ -f "$claudelog" ]; then
    report_wrapper_case "A7 claude stub got exactly the post-'--' args (echo hi)" \
      "$(grep -qx 'ARGS: echo hi' "$claudelog" && echo 0 || echo 1)" \
      "$(grep '^ARGS:' "$claudelog")"
    report_wrapper_case "A8 claude stub sees WSH_COCKPIT_ADOPT=sess1,sess2 in order" \
      "$(grep -qx "WSH_COCKPIT_ADOPT=$sess1,$sess2" "$claudelog" && echo 0 || echo 1)" \
      "$(grep '^WSH_COCKPIT_ADOPT=' "$claudelog")"
    report_wrapper_case "A9 claude stub sees WSH_COCKPIT_AGENT=claude-<epoch>-<pid>" \
      "$(grep -Eq '^WSH_COCKPIT_AGENT=claude-[0-9]+-[0-9]+$' "$claudelog" && echo 0 || echo 1)" \
      "$(grep '^WSH_COCKPIT_AGENT=' "$claudelog")"
    report_wrapper_case "A10 claude stub never sees WSH_COCKPIT_PREFIX" \
      "$(! grep -q '^WSH_COCKPIT_PREFIX=' "$claudelog" && echo 0 || echo 1)" \
      "$(grep '^WSH_COCKPIT_PREFIX=' "$claudelog")"
    report_wrapper_case "A11 claude stub never sees a user-preopen-<n> agent key" \
      "$(! grep -q '^WSH_COCKPIT_AGENT=user-preopen-' "$claudelog" && echo 0 || echo 1)" \
      "$(grep '^WSH_COCKPIT_AGENT=' "$claudelog")"
  fi

  # Exit sweep, after the stub returned normally: sess1 (no --keep) destroyed
  # with no orphaned claim/prefix marker; sess2 (--keep) still alive, claim
  # freed (not left owned), sticky keep-<slug> marker itself untouched.
  local h1=1 h2=1
  mux_has "$sess1" && h1=0
  mux_has "$sess2" && h2=0
  report_wrapper_case "A12 non-keep session1 destroyed by the exit sweep" \
    "$([ "$h1" -eq 1 ] && echo 0 || echo 1)" "mux_has sess1 rc=$h1"
  report_wrapper_case "A13 keep session2 still alive after the exit sweep (released, not stopped)" \
    "$([ "$h2" -eq 0 ] && echo 0 || echo 1)" "mux_has sess2 rc=$h2"
  report_wrapper_case "A14 session1's claim/prefix markers cleaned up (no orphan)" \
    "$([ ! -e "$(claim_path "$(session_slug "$sess1")")" ] && [ ! -e "$(prefix_file "$sess1")" ] && echo 0 || echo 1)" \
    "claim=$(claim_path "$(session_slug "$sess1")") prefix=$(prefix_file "$sess1")"
  if [ "$h2" -eq 0 ]; then
    report_wrapper_case "A15 session2's claim retrograded to a 'released' pré-claim (part of this run's ADOPT_LIST, so not removed outright to ABSENT)" \
      "$([ "$(claim_read_key "$(claim_path "$(session_slug "$sess2")")" 2>/dev/null || true)" = "released" ] && echo 0 || echo 1)" \
      "key=$(claim_read_key "$(claim_path "$(session_slug "$sess2")")" 2>/dev/null || true)"
    report_wrapper_case "A16 session2's sticky keep marker survives the release" \
      "$(keep_is_set "$sess2" && echo 0 || echo 1)" "keep_file=$(keep_file "$sess2")"
  fi

  # -- Case B: a value literally containing "--" (superset of "--and") must
  #    refuse BEFORE any spawn call, and never launch the claude stub. -----
  local b_case
  for b_case in "evil--and-thing" "just--dashes"; do
    local spawnlogb="$tmpdir/spawn-b.log" claudelogb="$tmpdir/claude-b.log"
    : >"$spawnlogb"; rm -f "$claudelogb"
    export WRAPTEST_SPAWN_LOG="$spawnlogb" WRAPTEST_CLAUDE_LOG="$claudelogb"
    rc=0
    PATH="$tmpdir/bin:$PATH" "$tmpdir/claude-cockpit.sh" "$b_case" -- echo hi \
      >"$tmpdir/b.out" 2>"$tmpdir/b.err" || rc=$?
    report_wrapper_case "B refuses value '$b_case' (rc!=0, no spawn, no claude launch)" \
      "$([ "$rc" -ne 0 ] && [ ! -s "$spawnlogb" ] && [ ! -f "$claudelogb" ] && echo 0 || echo 1)" \
      "rc=$rc spawnlog=$(cat "$spawnlogb" 2>/dev/null) stderr=$(cat "$tmpdir/b.err")"
  done

  # -- Case C: two groups resolving to the same prefix must refuse BEFORE
  #    any spawn call. ---------------------------------------------------
  local spawnlogc="$tmpdir/spawn-c.log" claudelogc="$tmpdir/claude-c.log"
  : >"$spawnlogc"; rm -f "$claudelogc"
  export WRAPTEST_SPAWN_LOG="$spawnlogc" WRAPTEST_CLAUDE_LOG="$claudelogc"
  local samepfx="wraptest-c-$$"
  rc=0
  PATH="$tmpdir/bin:$PATH" "$tmpdir/claude-cockpit.sh" "$samepfx" --and "$samepfx" -- echo hi \
    >"$tmpdir/c.out" 2>"$tmpdir/c.err" || rc=$?
  report_wrapper_case "C refuses two groups sharing the same prefix (rc!=0, no spawn, no claude launch)" \
    "$([ "$rc" -ne 0 ] && [ ! -s "$spawnlogc" ] && [ ! -f "$claudelogc" ] && echo 0 || echo 1)" \
    "rc=$rc spawnlog=$(cat "$spawnlogc" 2>/dev/null) stderr=$(cat "$tmpdir/c.err")"

  # -- Case D: the exit sweep must never touch a session from a DIFFERENT,
  #    concurrent run (step-1.11.1, audit finding E1). Pre-claim keys are
  #    indexed by GROUP NUMBER ("user-preopen-<n>"), not by run, so two
  #    parallel runs' first groups both use "user-preopen-1" — the sweep
  #    must restrict that branch to sessions this run actually spawned
  #    (ALL_SESSIONS), never to every live session merely wearing the same
  #    pre-claim key. ----------------------------------------------------
  local d_ownpfx="wraptest-d-own-$$"
  local spawnlogd="$tmpdir/spawn-d.log" claudelogd="$tmpdir/claude-d.log"
  : >"$spawnlogd"; rm -f "$claudelogd"
  export WRAPTEST_SPAWN_LOG="$spawnlogd" WRAPTEST_CLAUDE_LOG="$claudelogd"
  unset WRAPTEST_CLAUDE_EXIT FAKE_SPAWN_FAIL_PREFIX 2>/dev/null || true

  # Foreign session A: posed with the REAL primitives (create_session ->
  # remember_session -> claim_new_session), carrying the same "user-preopen-1"
  # pre-claim a DIFFERENT run's own first group would use — but never passed
  # on this run's command line, so it can never legitimately end up in
  # ALL_SESSIONS.
  local foreign_user
  foreign_user=$(unique_session_name "wraptest-d-foreign-user-$$")
  create_session "$foreign_user"
  remember_session "$foreign_user"
  ( WSH_COCKPIT_AGENT=user-preopen-1
    claim_new_session "$foreign_user" "$(normalize_prefix "wraptest-d-foreign-user-$$")" )
  created+=("$foreign_user")

  # Foreign session B: claimed by a DIFFERENT run's AGENT_KEY (already
  # adopted there) — cheap non-regression lock on the branch that was
  # already safe (protected today by plain key inequality, must stay
  # protected once the fix narrows the user-preopen-* branch).
  local foreign_claude
  foreign_claude=$(unique_session_name "wraptest-d-foreign-claude-$$")
  create_session "$foreign_claude"
  remember_session "$foreign_claude"
  ( WSH_COCKPIT_AGENT="claude-19700101-1"
    claim_new_session "$foreign_claude" "$(normalize_prefix "wraptest-d-foreign-claude-$$")" )
  created+=("$foreign_claude")

  rc=0
  PATH="$tmpdir/bin:$PATH" "$tmpdir/claude-cockpit.sh" \
    "$d_ownpfx" -- echo hi \
    >"$tmpdir/d.out" 2>"$tmpdir/d.err" || rc=$?
  report_wrapper_case "D0 run exits 0" \
    "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "rc=$rc stderr=$(cat "$tmpdir/d.err")"

  local own_sess
  own_sess=$(grep '^SESSION=' "$tmpdir/d.out" | sed -n '1s/^SESSION=//p')
  created+=("$own_sess")
  report_wrapper_case "D1 this run's own (non-keep) session is destroyed by the sweep" \
    "$(! mux_has "$own_sess" && echo 0 || echo 1)" "own_sess='$own_sess'"

  report_wrapper_case "D2 foreign session sharing the 'user-preopen-1' key survives the sweep" \
    "$(mux_has "$foreign_user" && echo 0 || echo 1)" "foreign_user='$foreign_user'"
  report_wrapper_case "D3 foreign session's 'user-preopen-1' claim is untouched" \
    "$([ "$(claim_read_key "$(claim_path "$(session_slug "$foreign_user")")" 2>/dev/null || true)" = "user-preopen-1" ] && echo 0 || echo 1)" \
    "key=$(claim_read_key "$(claim_path "$(session_slug "$foreign_user")")" 2>/dev/null || true)"

  report_wrapper_case "D4 foreign session claimed by another run's AGENT_KEY survives the sweep" \
    "$(mux_has "$foreign_claude" && echo 0 || echo 1)" "foreign_claude='$foreign_claude'"
  report_wrapper_case "D5 foreign session's claude-<otherrun> claim is untouched" \
    "$([ "$(claim_read_key "$(claim_path "$(session_slug "$foreign_claude")")" 2>/dev/null || true)" = "claude-19700101-1" ] && echo 0 || echo 1)" \
    "key=$(claim_read_key "$(claim_path "$(session_slug "$foreign_claude")")" 2>/dev/null || true)"

  # -- Case F: a group's spawn genuinely failing aborts BEFORE claude is
  #    launched; earlier groups already opened in this run stay open. -----
  local okpfx="wraptest-f-ok-$$" failpfx="wraptest-f-fail-$$"
  local spawnlogf="$tmpdir/spawn-f.log" claudelogf="$tmpdir/claude-f.log"
  : >"$spawnlogf"; rm -f "$claudelogf"
  export WRAPTEST_SPAWN_LOG="$spawnlogf" WRAPTEST_CLAUDE_LOG="$claudelogf"
  export FAKE_SPAWN_FAIL_PREFIX="$failpfx"
  rc=0
  PATH="$tmpdir/bin:$PATH" "$tmpdir/claude-cockpit.sh" "$okpfx" --and "$failpfx" -- echo hi \
    >"$tmpdir/f.out" 2>"$tmpdir/f.err" || rc=$?
  unset FAKE_SPAWN_FAIL_PREFIX
  local sess_ok
  sess_ok=$(grep '^SESSION=' "$tmpdir/f.out" | sed -n '1s/^SESSION=//p')
  [ -n "$sess_ok" ] && created+=("$sess_ok")
  report_wrapper_case "F aborts without launching claude when a group's spawn fails" \
    "$([ "$rc" -ne 0 ] && [ ! -f "$claudelogf" ] && echo 0 || echo 1)" \
    "rc=$rc stderr=$(cat "$tmpdir/f.err")"
  report_wrapper_case "F earlier-opened group's cockpit is left open (no rollback)" \
    "$([ -n "$sess_ok" ] && mux_has "$sess_ok" && echo 0 || echo 1)" "sess_ok='$sess_ok'"

  unset REAL_WSH_LIVE WRAPTEST_SPAWN_LOG WRAPTEST_CLAUDE_LOG 2>/dev/null || true
  selftest_wrapper_cleanup
  trap - EXIT
  if [ "$failures" -eq 0 ]; then echo "selftest-wrapper: all cases passed"; return 0
  else echo "selftest-wrapper: $failures failure(s)" >&2; return 1; fi
}

cmd_selftest_attach() {
  # Régression de l'« écran noir » : lancé en `exec mux attach`, le process d'un
  # bloc Wave meurt avec son attach (Ctrl+A d, session tuée, binaire absent) et
  # Wave laisse un terminal mort — noir, insensible à TOUTE touche, prefix
  # compris, donc indiscernable d'un plantage. La commande du bloc doit survivre
  # au détachement, dire ce qui s'est passé, et permettre de se rattacher.
  # Le banc est tmux de bout en bout (socket dédié, detach-client, capture-pane)
  # et mux_block_attach_cmd branche sur $MUX : sous zellij il produirait une
  # commande zellij que ce banc ne saurait pas exercer — d'où un skip franc
  # plutôt qu'un échec incompréhensible. Le skip précède have_mux : sous zellij,
  # exiger un binaire tmux (ou pire, se plaindre de zellij) n'aurait aucun sens.
  if [ "$MUX" != tmux ]; then
    echo "selftest-attach: skip (tmux-only — le banc et la régression sont tmux)"
    return 0
  fi
  have_mux
  # NOT local: the EXIT trap runs after this function has already returned.
  ATTACH_TGT="selftest-attach-tgt-$$"
  ATTACH_SOCK="cockpit-selftest-attach-$$"
  local failures=0 cmd bin rc bench_alive pane_text

  report_attach_case() {  # $1 label  $2 rc (0=ok)  $3 detail (shown on failure)
    if [ "$2" -eq 0 ]; then
      echo "ok $1"
    else
      echo "FAIL $1${3:+: $3}" >&2
      failures=$((failures + 1))
    fi
  }

  selftest_attach_cleanup() {
    tmux kill-session -t "=$ATTACH_TGT" 2>/dev/null || true
    tmux -L "$ATTACH_SOCK" kill-server 2>/dev/null || true
  }
  trap selftest_attach_cleanup EXIT

  attach_wait() {  # attend une condition (5 s max) au lieu d'un sleep arbitraire
    local i=0
    while [ "$i" -lt 25 ]; do
      if eval "$1" >/dev/null 2>&1; then return 0; fi
      sleep 0.2; i=$((i + 1))
    done
    return 1
  }
  attach_has_client() { [ -n "$(tmux list-clients -t "$ATTACH_TGT" -F x 2>/dev/null)" ]; }

  bin=$(command -v tmux)
  tmux new-session -d -s "$ATTACH_TGT" 2>/dev/null || true
  cmd=$(mux_block_attach_cmd "$ATTACH_TGT" "$bin")

  # Le banc vit sur un socket tmux séparé : son pane fournit le pty qu'un vrai
  # bloc Wave fournirait, sans polluer le serveur par défaut. `unset TMUX` est
  # obligatoire, sinon tmux refuse de s'attacher depuis un pane (imbrication).
  tmux -L "$ATTACH_SOCK" new-session -d -s bench -x 80 -y 24 2>/dev/null || true
  tmux -L "$ATTACH_SOCK" send-keys -t bench -l "unset TMUX; $cmd"
  tmux -L "$ATTACH_SOCK" send-keys -t bench Enter

  # 1. La commande du bloc attache réellement la session.
  if attach_wait attach_has_client; then
    report_attach_case "1 la commande de bloc attache la session" 0
  else
    report_attach_case "1 la commande de bloc attache la session" 1 "aucun client sur $ATTACH_TGT"
  fi

  # 2. Le bloc SURVIT au détachement — c'est la régression : avec `exec`, le pane
  #    est remplacé par l'attach, sa mort ferme la dernière fenêtre du banc.
  tmux detach-client -s "$ATTACH_TGT" 2>/dev/null || true
  sleep 0.5
  bench_alive=0; tmux -L "$ATTACH_SOCK" has-session -t bench 2>/dev/null || bench_alive=1
  report_attach_case "2 le bloc survit au détachement" "$bench_alive" \
    "le process du bloc est mort avec l'attach (écran noir muet)"

  # 3. Il dit pourquoi, au lieu de rester noir et muet.
  pane_text=$(tmux -L "$ATTACH_SOCK" capture-pane -p -t bench 2>/dev/null || true)
  case "$pane_text" in *"[cockpit]"*) rc=0 ;; *) rc=1 ;; esac
  report_attach_case "3 le bloc explique le détachement" "$rc" "aucun message [cockpit] dans le pane"

  # 4. Entrée rattache, sans avoir à rouvrir un bloc.
  tmux -L "$ATTACH_SOCK" send-keys -t bench Enter 2>/dev/null || true
  if attach_wait attach_has_client; then
    report_attach_case "4 Entrée rattache le bloc" 0
  else
    report_attach_case "4 Entrée rattache le bloc" 1 "toujours aucun client après Entrée"
  fi

  selftest_attach_cleanup
  trap - EXIT
  if [ "$failures" -eq 0 ]; then echo "selftest-attach: all cases passed"; return 0
  else echo "selftest-attach: $failures failure(s)" >&2; return 1; fi
}
