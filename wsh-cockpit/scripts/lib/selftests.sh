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

  # 11. stop kills the session and removes its seq file
  "$0" stop "$SESS" >/dev/null 2>&1 || true
  if mux_has "$SESS"; then
    report_live_case "11 stop" 1 "session '$SESS' still alive"
  elif [ -f "$SEQF" ]; then
    report_live_case "11 stop" 1 "seq file still present: $SEQF"
  else
    report_live_case "11 stop" 0
  fi

  if [ "$failures" -ne 0 ]; then
    echo "selftest-live: $failures failure(s)" >&2
    exit 1
  fi
  echo "selftest-live: ok"
}
