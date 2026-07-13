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

  # 10. local-init reverts THIS session back to the short __wsh-call form —
  # match the exact literal line sep_wrap emits for THIS send (a distinct
  # marker text), so leftover inline text from step 9's scrollback can't
  # produce a false pass.
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
  # machine, including a developer's own detached cockpits.
  live_selftest_gc_cleanup() {
    "$0" stop "$SESS" >/dev/null 2>&1 || true
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
