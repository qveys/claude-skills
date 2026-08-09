#!/usr/bin/env bash
# lib/session.sh — session naming, last-session state, and resolution guards.
# Sourced by wsh-live.sh; not meant to be run standalone.

# Unique session name: cockpit-<prefix>-<HHMMSS>. Prefix defaults to WSH_COCKPIT_PREFIX
# or the basename of the caller (e.g. "grok", "claude") when detectable.
unique_session_name() {
  local prefix; prefix=$(normalize_prefix "$1")   # same slug rules, one definition
  local ts
  ts=$(date '+%H%M%S')
  local name="cockpit-${prefix}-${ts}"
  local n=0
  while mux_has "$name"; do
    n=$((n + 1))
    name="cockpit-${prefix}-${ts}-${n}"
  done
  printf '%s\n' "$name"
}

# Remember the last spawned session so send/read can default to it within one workflow.
# Pure path computation — no mkdir here: state_file() is called on every read path
# (last_session → resolve_session, on each send/read/banner), and the dir only needs
# to exist when we actually WRITE (remember_session). (Lowercasing stays on `tr`, not
# ${x,,}: macOS ships bash 3.2 and the rest of this script avoids bash-4 expansions.)
state_file() {
  local key="${WSH_COCKPIT_AGENT:-${WSH_COCKPIT_PREFIX:-default}}"
  key=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '_')
  printf '%s/last-session-%s\n' "$STATE_DIR" "$key"
}

remember_session() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" >"$(state_file)"
}

last_session() {
  local f
  f=$(state_file)
  [ -f "$f" ] || return 1
  local s
  s=$(tr -d '[:space:]' <"$f")
  [ -n "$s" ] && mux_has "$s" || return 1
  printf '%s\n' "$s"
}

# Normalize a spawn prefix (same rules as unique_session_name).
normalize_prefix() {
  local prefix="${1:-}"
  if [ -z "$prefix" ]; then
    prefix="${WSH_COCKPIT_PREFIX:-}"
  fi
  if [ -z "$prefix" ]; then
    prefix="${WSH_COCKPIT_AGENT:-live}"
  fi
  prefix=$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-')
  prefix=${prefix#-}; prefix=${prefix%-}
  [ -n "$prefix" ] || prefix="live"
  printf '%s\n' "$prefix"
}

# Slug for per-session marker files (adopt-claim-<slug>, prefix-<slug>) — same
# charset/squeeze rule as the pre-existing seq-<slug>/oneshot-ssh-<slug>/cm-<slug>
# family (spec v12 §2 groups them explicitly); one shared definition so the
# session-name -> slug bridge isn't redefined ad hoc at each call site.
session_slug() { printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_'; }

# The key a claim is created/matched under: the caller's own agent identity.
# "default" when WSH_COCKPIT_AGENT is unset (spec v12 decisions table: "claude
# lancé sans wrapper = clé `default` héritée, garanties réduites").
agent_claim_key() { printf '%s' "${WSH_COCKPIT_AGENT:-default}"; }

# Registered-prefix marker (spec v12 §2, "préfixe enregistré, pas parsé"):
# written once at session creation, read (never re-parsed from the session
# name) by the registry resolution below.
prefix_file() { printf '%s/prefix-%s\n' "$STATE_DIR" "$(session_slug "$1")"; }
prefix_write() {  # $1 sess $2 value (normalized prefix, or the "(named)" sentinel)
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$2" >"$(prefix_file "$1")"
}
prefix_read() {  # $1 sess -> prints the registered value, rc 1 if none recorded
  local f; f=$(prefix_file "$1")
  [ -f "$f" ] || return 1
  tr -d '[:space:]' <"$f"
}

# Pose the creator's claim + registered prefix for a session that was JUST
# created (spec v12 §2: "la création pose le claim du créateur"). $2 is the
# value to register in prefix-<slug> — the normalized prefix for `spawn`, or
# the "(named)" sentinel for `start` (never matchable by a requested prefix,
# spec v12 §2: "start ... jamais matchable"). Shared by both call sites so
# they can't re-diverge on the claim-then-prefix sequencing.
# O_EXCL create is expected to win here: $sess was JUST created under a
# unique/just-checked name, so any pre-existing adopt-claim-<slug> at this
# exact slug can only be a residue from an earlier (dead) life of a recycled
# name — claim_replace_orphan is the fallback for exactly that case (spec v12
# §2: "collision de nom recyclé"). Best-effort: a failure here degrades
# registry lookups for this one session but must never abort an otherwise-
# successful spawn/start.
claim_new_session() {  # $1 sess $2 prefix-value
  local sess="$1" val="$2" slug key
  slug=$(session_slug "$sess")
  key=$(agent_claim_key)
  if claim_create "$slug" "$key" || claim_replace_orphan "$slug" "$$" "$key"; then
    prefix_write "$sess" "$val"
  else
    echo "warning: could not register claim for '$sess' (registry lookups may miss it)" >&2
  fi
}

# Step 1 of spawn's resolution order (spec v12 §2, "Mes sessions (registre)"):
# among LIVE sessions whose claim carries MY agent key (agent_claim_key) —
# narrowed to those whose registered prefix (prefix-<slug>) equals $2 when a
# prefix was actually requested ($1 non-empty: the caller passed a positional
# arg, BEFORE normalize_prefix's own WSH_COCKPIT_PREFIX/WSH_COCKPIT_AGENT/live
# fallback chain — spec v12 §2, "aucun préfixe demandé"). Prints the resolved
# session and returns 0; returns 1 when the registry has no match at all
# (caller falls through to the legacy last-session/newest-for-prefix path,
# the étape-2/3 stand-in until step-1.4/1.5 land real adoption/scan) OR when
# the sole match / remembered match fails session_safe_to_reuse (its
# foreground process isn't a bare shell — same fallthrough as a plain miss,
# never returned as a silent success); returns 2 when the match is
# genuinely AMBIGUOUS (2+ live candidates and none of them is the
# remembered last-session) — the caller must surface an explicit error,
# never silently spin up an (N+1)-th cockpit.
find_registry_session() {  # $1 requested prefix (raw, "" = none given) $2 normalized prefix
  local requested="${1:-}" norm="$2" mykey slug ckey s pf remembered
  mykey=$(agent_claim_key)
  local -a cands=()
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    slug=$(session_slug "$s")
    ckey=$(claim_read_key "$(claim_path "$slug")" 2>/dev/null) || continue
    [ "$ckey" = "$mykey" ] || continue
    if [ -n "$requested" ]; then
      pf=$(prefix_read "$s" 2>/dev/null) || continue
      [ "$pf" = "$norm" ] || continue
    fi
    cands+=("$s")
  done < <(mux_list_sessions)

  [ ${#cands[@]} -gt 0 ] || return 1
  if [ ${#cands[@]} -eq 1 ]; then
    # A registry hit still has to clear the same bare-shell-only check as
    # every other reuse path (session_safe_to_reuse) — the registry being
    # the resolution authority (spec v12 §2, étape 1) says WHICH session is
    # mine, not that it's still safe to type into silently. Refusing here
    # counts as a registry MISS (rc 1), same as find_reusable_session
    # already treats its own remembered/newest fallbacks failing this
    # check, so the caller falls through to adoption/scan instead of
    # bypassing the guard on the one path that used to skip it.
    session_safe_to_reuse "${cands[0]}" || return 1
    printf '%s\n' "${cands[0]}"
    return 0
  fi

  remembered=$(last_session 2>/dev/null || true)
  if [ -n "$remembered" ]; then
    local c
    for c in "${cands[@]}"; do
      if [ "$c" = "$remembered" ]; then
        session_safe_to_reuse "$c" || return 1
        printf '%s\n' "$c"
        return 0
      fi
    done
  fi
  return 2
}

# Newest alive tmux session matching cockpit-<prefix>-* (lex sort ≈ time
# suffix). Claimed sessions (I3, claim.sh) are excluded from the scan
# entirely — by anyone, not just other agents: a session already claimed
# by ME would have surfaced via find_registry_session (étape 1) already,
# so reaching here claimed-by-me would only mean a stale/inconsistent
# registry, not a legitimate hit; a session claimed by someone else must
# never be silently handed to a different agent (spec v12 §2, step-1.5).
newest_session_for_prefix() {
  local prefix="$1" best="" s slug
  local pattern="cockpit-${prefix}-"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    slug=$(session_slug "$s")
    claim_is_claimed "$slug" && continue
    if [ -z "$best" ] || [[ "$s" > "$best" ]]; then
      best="$s"
    fi
  done < <(mux_list_sessions | grep "^${pattern}" || true)
  [ -n "$best" ] && mux_has "$best" || return 1
  printf '%s\n' "$best"
}

# The tmux session CURRENTLY running the calling process itself, if any.
# `$TMUX` is set by tmux in every process spawned inside a pane — including
# the Bash tool call whose shell lives inside the Claude Code CLI's own
# wrapping tmux session (Wave wraps every terminal in tmux, one block = one
# session). `tmux display-message` asks the tmux server, not the pane
# content, so it's authoritative regardless of what's drawn on screen.
own_tmux_session() {
  [ "$MUX" = tmux ] || return 1
  [ -n "${TMUX:-}" ] || return 1
  # Measured twice (M-a, tmux 3.7b): anchoring on $TMUX_PANE does NOT
  # stabilise the display-message call below — under a grouped session the
  # anchored form drifts exactly like the bare '#S' form. Do not "fix" this
  # by adding -t "$TMUX_PANE" here; it has already been proposed and
  # measured wrong twice. Instead: without $TMUX_PANE, "my own session" has
  # no answer worth trusting at all — refuse rather than guess (Task 8).
  [ -n "${TMUX_PANE:-}" ] || return 2   # under tmux, but identity indeterminable
  tmux display-message -p '#S' 2>/dev/null
}

# Whether <sess> designates the tmux session the caller is itself running
# inside. With grouped sessions "my session" has no unique answer: several
# session names can share the exact same pane, and the two ways tmux gives
# you to name a session (the string you were handed vs. `#{session_name}`)
# can disagree (measured on this machine: `$TMUX`'s sid names one session,
# `#S` names another, same live pane). The pane is the only identity that
# stays pinned to the caller regardless of naming, so pane membership is
# the PRIMARY test; name equality is only a fallback for when pane info is
# unavailable:
#   1. strip a leading "=" anchor — `=X` and `X` name the same session, but
#      tmux only resolves "=" for target-SESSION commands (has-session), not
#      target-PANE ones (display-message, capture-pane): left unstripped,
#      the canonical-name lookup below goes blind (empty, rc=0) on exactly
#      the input this function most needs to catch, and `mux_kill` — which
#      DOES honour "=" — would then tear down the caller's own session;
#   2. resolve the canonical name (mux_session_name), falling back to the
#      stripped name itself if that lookup comes back empty;
#   3. PRIMARY — is $TMUX_PANE non-empty and a member of
#      mux_session_panes(canonical)? Catches grouped sessions (a different
#      session name sharing the caller's pane — how Wave wraps blocks) and,
#      as a side effect, exact/prefix/fnmatch aliases too, since those all
#      resolve to a session containing that same pane;
#   4. FALLBACK — raw or canonical name equal to own_tmux_session(). Reached
#      whenever $TMUX_PANE is present but not a member of the target's
#      panes (the ordinary case: a genuinely different session) — NOT only
#      when $TMUX_PANE is unset, contrary to what this comment used to say.
#      Since Task 8, an unset $TMUX_PANE is caught earlier: own_tmux_session
#      returns 2 (indeterminable) and this function propagates that before
#      ever reaching this fallback.
# Sets SESSION_OWN_CANON / SESSION_OWN_REASON (exact|alias|shared-pane) /
# SESSION_OWN_PANE (shared-pane only) for session_own_refusal to build a
# message from — deliberately NOT `local`: callers read them after return.
# Silent otherwise: it only tests, callers write the refusal message.
# rc 1 outside tmux and under zellij (own_tmux_session is a no-op there),
# same as before this function existed; rc 2 under tmux when $TMUX_PANE is
# unset (identity indeterminable — see own_tmux_session, Task 8).
SESSION_OWN_CANON=""
SESSION_OWN_REASON=""
SESSION_OWN_PANE=""
session_is_own() {
  local raw="$1" sess canon own panes rc
  sess="${raw#=}"
  canon=$(mux_session_name "$sess" 2>/dev/null || true)
  [ -n "$canon" ] || canon="$sess"
  SESSION_OWN_CANON="$canon"
  SESSION_OWN_REASON=""
  SESSION_OWN_PANE=""
  rc=0; own=$(own_tmux_session) || rc=$?
  # rc=2 (own_tmux_session: $TMUX set, $TMUX_PANE unset — identity
  # indeterminable) must propagate as-is, not collapse into "not own" (rc=1):
  # a guard that can't tell must refuse, not guess (Task 8, option A).
  [ "$rc" -ne 2 ] || return 2
  [ "$rc" -eq 0 ] || return 1

  if [ -n "${TMUX_PANE:-}" ]; then
    panes=$(mux_session_panes "$canon" || true)
    if grep -Fqx -- "$TMUX_PANE" <<<"$panes"; then
      if [ "$raw" = "$own" ]; then SESSION_OWN_REASON="exact"
      elif [ "$canon" = "$own" ]; then SESSION_OWN_REASON="alias"
      else SESSION_OWN_REASON="shared-pane"; SESSION_OWN_PANE="$TMUX_PANE"
      fi
      return 0
    fi
  fi

  if [ "$raw" = "$own" ]; then SESSION_OWN_REASON="exact"; return 0; fi
  if [ "$canon" = "$own" ]; then SESSION_OWN_REASON="alias"; return 0; fi
  return 1
}

# Refusal message for a target session_is_own just confirmed is the
# caller's own — reads the globals it sets, so always call this right
# after a session_is_own that returned 0. Factored so session_safe_to_reuse
# and `start --reuse` (wsh-live.sh) can't re-diverge the way they already
# had (the ~6-line block used to be duplicated, with slightly different
# wording in each place).
session_own_refusal() {
  local sess="$1"
  case "$SESSION_OWN_REASON" in
    shared-pane)
      echo "⚠️  session '$sess' shares pane $SESSION_OWN_PANE with the tmux session this call is running inside (your own controlling terminal) — refusing to reuse it under any circumstance" >&2 ;;
    alias)
      echo "⚠️  session '$sess' resolves to '$SESSION_OWN_CANON', the tmux session this call is running inside (your own controlling terminal) — refusing to reuse it under any circumstance" >&2 ;;
    *)
      echo "⚠️  session '$sess' IS the tmux session this call is running inside (your own controlling terminal) — refusing to reuse it under any circumstance" >&2 ;;
  esac
}

# Refusal message for when session_is_own returned 2: $TMUX is set but
# $TMUX_PANE is not, so the caller's own identity cannot be established at
# all (own_tmux_session, Task 8). This is NOT "confirmed not yours" — it's
# "cannot check" — so the guard refuses by principle instead of falling
# back to an arbitrary name comparison. Companion to session_own_refusal,
# factored for the same reason: session_safe_to_reuse and `start --reuse`
# (wsh-live.sh) must not re-diverge on wording.
session_indeterminate_refusal() {
  local sess="$1"
  echo "⚠️  cannot verify whether session '$sess' is the tmux session this call is running inside (\$TMUX is set but \$TMUX_PANE is not — identity indeterminable) — refusing by principle; relaunch from inside a real tmux pane, or pass --force for a fresh cockpit" >&2
}

# One-shot own-session guard for a resolved (already existence-checked)
# session: probe + print the right refusal + return 1, or return 0 to
# proceed. Factored for the same reason as session_own_refusal itself — 4
# call sites (wsh-live.sh: send/keys/step-run/banner, Task 2 lot 2) that
# must not re-diverge on the rc=0/rc=2/set -e dance session_is_own requires
# (the `rc=0; … || rc=$?` form, not a bare `if session_is_own; then`, so a
# non-zero rc under `set -e` doesn't abort the caller before this function
# even gets to inspect it). rc=2 (identity indeterminable) is refused just
# like rc=0 (confirmed own): "cannot verify" is not "confirmed not yours" —
# guessing wrong here means typing into a stranger's own terminal, so both
# non-clear outcomes refuse alike (same principle as session_safe_to_reuse
# and stop's guard, Task 8 option A).
deny_own_session() {
  local sess="$1" rc=0
  session_is_own "$sess" || rc=$?
  if [ "$rc" -eq 2 ]; then
    session_indeterminate_refusal "$sess"
    return 1
  fi
  if [ "$rc" -eq 0 ]; then
    session_own_refusal "$sess"
    return 1
  fi
  return 0
}

# A session is safe to silently reuse only if BOTH hold:
#   1. it is not the tmux session the caller is itself running inside, by any
#      alias (absolute, unconditional block — see session_is_own); this also
#      refuses outright when identity is indeterminable rather than own
#      (session_is_own rc=2, Task 8);
#   2. its foreground process is a bare shell, not some other interactive
#      program left running in an otherwise-orphaned cockpit (most
#      dangerously another CLI: `send` would TYPE into its input).
# Empty pane_current_command (zellij: unsupported, or transient read
# failure) is treated unverifiable-but-safe, not unsafe.
# NOTE (spec claude-cockpit §2): lot 2 extends check 2 for ADOPTION with
# ssh/tailscale/mosh as adoptable states — reuse stays bare-shell strict.
session_safe_to_reuse() {
  # Strip a leading "=" anchor like session_is_own does: check 2 below feeds
  # $sess to mux_pane_command (display-message, a target-pane command that is
  # blind to "=" — empty output, rc=0), so an anchored "=name" left unstripped
  # would be classed unverifiable-but-safe and skip the foreground check
  # entirely. Not reachable in prod (find_reusable_session only ever passes
  # canonical names) — API-consistency hardening, not an exploitable hole.
  local sess="${1#=}" cmd rc
  rc=0; session_is_own "$sess" || rc=$?
  if [ "$rc" -eq 2 ]; then
    session_indeterminate_refusal "$sess"
    return 1
  fi
  if [ "$rc" -eq 0 ]; then
    session_own_refusal "$sess"
    return 1
  fi
  cmd=$(mux_pane_command "$sess")
  case "$cmd" in
    ""|bash|zsh|sh|fish|-bash|-zsh|-sh|-fish) return 0 ;;
    *)
      echo "⚠️  session '$sess' has foreground process '$cmd', not a bare shell — refusing silent reuse (pass --force for a fresh cockpit, or 'read' it manually first)" >&2
      return 1 ;;
  esac
}

# Étape 1 (registry) first — spec v12 §2: "le registre des claims est
# l'autorité de résolution", last-session "rétrogradé en simple mémo". A
# registry hit (rc 0) or genuine ambiguity (rc 2) both short-circuit here;
# only a registry MISS (rc 1 — nothing of mine in the registry, e.g. a
# session that predates step-1.3) falls through to the legacy
# last-session/newest-for-prefix path below, which stays as the étape-2/3
# stand-in until step-1.4/1.5 land real adoption/scan.
find_reusable_session() {
  local prefix="${1:-}"
  local norm remembered newest hit rc
  norm=$(normalize_prefix "$prefix")

  rc=0; hit=$(find_registry_session "$prefix" "$norm") || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$hit"
    return 0
  elif [ "$rc" -eq 2 ]; then
    return 2
  fi

  if remembered=$(last_session 2>/dev/null) \
     && ! claim_is_claimed "$(session_slug "$remembered")" \
     && session_safe_to_reuse "$remembered"; then
    printf '%s\n' "$remembered"
    return 0
  fi
  if newest=$(newest_session_for_prefix "$norm" 2>/dev/null) && session_safe_to_reuse "$newest"; then
    printf '%s\n' "$newest"
    return 0
  fi
  return 1
}

# Reprise d'une session legacy (spec v12 §2, step-1.5): find_reusable_session
# only ever hands back a session unclaimed by anyone (claim_is_claimed
# exclusion, above) THROUGH ITS LEGACY FALLBACK — a registry hit (étape 1)
# always returns an already-mine-claimed session instead. Callers tell the
# two apart post-hoc (! claim_is_claimed on the resolved name) rather than
# via a global set inside find_reusable_session, because that function is
# routinely called through `$(...)` (including by selftest-adopt cases
# 5/6a-6c/16 directly) — a global assigned inside a command-substitution
# subshell would never reach the caller.
#
# A never-claimed session's state is unknown, exactly like an adopted one
# (never created by us) — same argument as fiche 1.4, reusing its probe
# mechanic verbatim (adopt_run_probe/adopt_print_probe). Unlike adoption
# there is no pre-claim to consume: the transition is the direct
# ABSENT -> POSSÉDÉ form of claim_create (ABSENT -> PRÉ-CLAIM is the OTHER
# thing that primitive is used for, at wrapper bootstrap — see claim.sh).
# A failed probe reverts the claim to a "released" pré-claim (claim_release)
# rather than dropping it back to ABSENT: claim_is_claimed tests existence
# only, so "released" still counts as claimed and keeps this same session
# from being re-offered to the next naive spawn in a probe-fail loop — it
# remains reachable only via the explicit WSH_COCKPIT_ADOPT mechanism.
LEGACY_RESULT=""
try_legacy_claim() {  # $1 sess $2 normalized prefix -> rc 0 claimed+probed, 1 raced/probe failed
  LEGACY_RESULT=""
  local sess="$1" norm="${2:-}" slug key
  slug=$(session_slug "$sess")
  key=$(agent_claim_key)
  claim_create "$slug" "$key" || return 1
  adopt_run_probe "$sess"
  if [ "$ADOPT_PROBE_RC" -ne 0 ]; then
    claim_release "$slug" "$key"
    return 1
  fi
  prefix_write "$sess" "$norm"
  echo "legacy cockpit '$sess' entered the registry (claimed + probed)"
  adopt_print_probe "$sess"
  LEGACY_RESULT="$sess"
  return 0
}

# -- Adoption (étape 2, spec v12 §2) --------------------------------------
# Backward compatibility: everything below is reachable ONLY through
# try_adopt_session, which itself is a no-op (rc 1, ADOPT_RESULT unset)
# whenever WSH_COCKPIT_ADOPT is absent/empty — for every caller that never
# sets it, étape 2 simply does not exist.

# Warn-once marker so a dead candidate offered repeatedly (e.g. every retry
# of a failed spawn) doesn't spam stderr — mirrors the seq-<slug>-style
# per-session marker family, one file per offered (not per live) name.
adopt_warn_file() { printf '%s/adopt-dead-warned-%s\n' "$STATE_DIR" "$(session_slug "$1")"; }
adopt_warn_dead_once() {  # $1 candidate name (already confirmed not alive)
  local f; f=$(adopt_warn_file "$1")
  [ -f "$f" ] && return 0
  mkdir -p "$STATE_DIR"
  : >"$f"
  echo "adopt: offered cockpit '$1' (WSH_COCKPIT_ADOPT) is not alive — ignoring (warned once)" >&2
}

# Widened busy-pane guard for adoption ONLY (spec v12 §2): a bare shell OR an
# ssh/tailscale/mosh foreground process both count as adoptable — unlike
# session_safe_to_reuse's strict bare-shell-only check for silent reuse. Pure
# predicate on the command-name string (not a live session) so it's testable
# without faking a real OS process name in a pane — same pragmatic reasoning
# already applied to find_registry_session in selftest-adopt case 7.
adopt_state_allowed() {  # $1 pane_current_command string -> rc 0 if adoptable
  case "$1" in
    ""|bash|zsh|sh|fish|-bash|-zsh|-sh|-fish) return 0 ;;
    ssh|-ssh|tailscale|mosh|mosh-client) return 0 ;;
    *) return 1 ;;
  esac
}
# Best-effort mitigation for "texte après le prompt" (spec v12 §2):
# pane_current_command only sees the pane's foreground PROCESS — a command
# being TYPED but not yet run (no Enter pressed) is invisible to it, since
# the foreground process is still the bare shell. Measured on the machine's
# real prompt (session tmux jetable, see docs/gotchas.md): a zsh
# powerlevel-style prompt with a right-side segment (RPROMPT) pads the WHOLE
# line out to the pane width and appends "─"+a corner glyph ("╮"/"╯") flush
# right, unrelated to whether text was typed — a naive "any content at the
# end of the last line" heuristic would refuse EVERY adoption. Recognized
# shapes only (best-effort, conservative):
#   idle: "❯" alone, with or without the padded RPROMPT decoration
#   busy: "❯ <typed text>", with or without the same decoration
# A last line that doesn't match either shape (a different prompt theme, an
# empty capture, unrelated scrollback content) is UNRECOGNIZED and must NOT
# refuse adoption: a false positive here would make a healthy cockpit
# unadoptable, worse than the documented best-effort limit (docs/gotchas.md).
adopt_last_line_busy() {  # $1 last non-blank captured pane line -> rc 0 if busy (refuse), rc 1 if idle/unrecognized (allow)
  local line="$1" body
  if [[ "$line" =~ ^(.*)[[:space:]]─+[╮╯]$ ]]; then
    body="${BASH_REMATCH[1]}"
  else
    body="$line"
  fi
  body="${body%"${body##*[![:space:]]}"}"  # trim trailing whitespace left by the strip above
  case "$body" in
    '❯') return 1 ;;
    '❯ '*) return 0 ;;
    *) return 1 ;;
  esac
}
adopt_pane_ready() {  # $1 sess -> rc 0 pane's foreground process AND last line are adoptable
  adopt_state_allowed "$(mux_pane_command "$1")" || return 1
  ! adopt_last_line_busy "$(mux_pane_last_line "$1")"
}

# Systematic, non-optional probe (spec v12 §2): a released/hand-opened keep
# may have been ssh-hopped without ever calling remote-init, so its sticky
# remote-mode tmux option can't be trusted — WSH_LIVE_SEP_REINIT=1 forces
# self-contained inline framing regardless. Split run/print (unlike
# situate_session's single-shot version in wsh-live.sh) because the gate on
# claim_finalize below needs the probe's rc BEFORE anything is printed: "jamais
# de claim conservé sans sonde réussie" means a failed probe must roll back,
# not just warn-and-continue as situate_session tolerates.
ADOPT_PROBE_OUT=""
ADOPT_PROBE_RC=0
adopt_run_probe() {  # $1 sess -> sets ADOPT_PROBE_OUT/ADOPT_PROBE_RC, prints nothing
  local sess="$1" rc=0
  ADOPT_PROBE_OUT=""
  WSH_LIVE_SEP_REINIT=1 "$0" send 'printf "WSH_SITUATE_HOST=%s\n" "$(hostname)"; pwd; whoami 2>&1' "$sess"
  WSH_LIVE_SEP_REINIT=1 "$0" wait-done "$sess" 60 || rc=$?
  ADOPT_PROBE_RC="$rc"
  ADOPT_PROBE_OUT=$(WSH_LIVE_SEP_REINIT=1 "$0" read "$sess" 20)
}
# Prints the already-captured probe output, then applies situate_session's
# own best-effort remote-init auto-detection (host mismatch -> push helpers).
adopt_print_probe() {  # $1 sess
  local sess="$1" remote_host remote_conn
  printf '%s\n' "$ADOPT_PROBE_OUT"
  remote_host=$(printf '%s\n' "$ADOPT_PROBE_OUT" | tr -d '\r' | grep -o '^WSH_SITUATE_HOST=.*' | tail -n1 | cut -d= -f2-)
  if [ -n "$remote_host" ] && [ "$remote_host" != "$(hostname)" ] && ! remote_mode_get "$sess"; then
    remote_conn="${remote_host%.local}"
    echo "adopt: pane is on '$remote_host' (this Mac is '$(hostname)') — auto-calling remote-init '$remote_conn' (best-effort push; falls back to inline framing with a warning if unreachable)"
    "$0" remote-init "$sess" "$remote_conn"
  fi
}

# Étape 2 of spawn's resolution order (spec v12 §2): among the comma-
# separated sessions offered via WSH_COCKPIT_ADOPT, atomically consume the
# first candidate whose pre-claim is genuinely free (claim.sh primitives
# ONLY — no ad hoc mv/ln), whose pane is adoptable, and whose probe actually
# completes. Any failure at any stage -> claim_rollback + next candidate;
# nothing is ever left claimed without a successful probe (I1/I2 from
# claim.sh, enforced by construction here). $1/$2 mirror find_registry_session
# exactly (requested prefix raw, normalized) so a requested prefix that
# doesn't match a candidate's registered prefix never nominally adopts it.
# ADOPT_RESULT (not stdout) carries the winning name back — this function's
# caller is deliberately NOT reached via $(...), so the "adopted ..."
# announcement and the probe output below can be loud (see spawn in
# wsh-live.sh).
ADOPT_RESULT=""
try_adopt_session() {  # $1 requested prefix (raw) $2 normalized -> rc 0 adopted, 1 nothing adoptable
  ADOPT_RESULT=""
  [ -n "${WSH_COCKPIT_ADOPT:-}" ] || return 1
  local requested="${1:-}" norm="${2:-}" mykey pid cand slug ckey pf rc
  mykey=$(agent_claim_key)
  pid=$$
  local -a list=()
  IFS=',' read -r -a list <<<"$WSH_COCKPIT_ADOPT"
  for cand in ${list[@]+"${list[@]}"}; do
    [ -n "$cand" ] || continue
    if ! mux_has "$cand"; then
      adopt_warn_dead_once "$cand"
      continue
    fi
    if [ -n "$requested" ]; then
      pf=$(prefix_read "$cand" 2>/dev/null) || continue
      [ "$pf" = "$norm" ] || continue
    fi
    rc=0; session_is_own "$cand" || rc=$?
    if [ "$rc" -eq 2 ]; then session_indeterminate_refusal "$cand"; continue; fi
    if [ "$rc" -eq 0 ]; then session_own_refusal "$cand"; continue; fi
    slug=$(session_slug "$cand")
    ckey=$(claim_read_key "$(claim_path "$slug")" 2>/dev/null) || continue
    claim_key_reserved "$ckey" || continue
    claim_consume "$slug" "$pid" || continue
    rc=0; claim_verify_won "$slug" "$pid" || rc=$?
    if [ "$rc" -ne 0 ]; then claim_rollback "$slug" "$pid"; continue; fi
    if ! adopt_pane_ready "$cand"; then claim_rollback "$slug" "$pid"; continue; fi
    adopt_run_probe "$cand"
    if [ "$ADOPT_PROBE_RC" -ne 0 ]; then claim_rollback "$slug" "$pid"; continue; fi
    if ! claim_finalize "$slug" "$pid" "$mykey"; then claim_rollback "$slug" "$pid"; continue; fi
    echo "adopted user cockpit: $cand"
    adopt_print_probe "$cand"
    ADOPT_RESULT="$cand"
    return 0
  done
  return 1
}

# Same comma-split membership test try_adopt_session applies to
# $WSH_COCKPIT_ADOPT, exposed standalone so release_session() (below) can
# reuse it without re-running any adoption/probe side effect.
adopt_list_contains() {  # $1 session name -> rc 0 present in $WSH_COCKPIT_ADOPT
  local target="$1" cand
  [ -n "${WSH_COCKPIT_ADOPT:-}" ] || return 1
  local -a list=()
  IFS=',' read -r -a list <<<"$WSH_COCKPIT_ADOPT"
  for cand in ${list[@]+"${list[@]}"}; do
    [ "$cand" = "$target" ] && return 0
  done
  return 1
}

# POSSÉDÉ -> free, WITHOUT touching tmux/the Wave block (spec v12 §3): makes
# a session available to a future resolution pass again, as opposed to
# `stop`'s teardown_session which destroys it. I4 (owner-only) is enforced by
# claim_release itself; this function only decides WHICH free state the
# claim lands in:
#   - session currently listed in MY $WSH_COCKPIT_ADOPT (i.e. I originally
#     reached it via étape 2 adoption) -> retrograde to the "released"
#     pré-claim (claim_release) so it is re-adoptable via étape 2 ONLY, never
#     picked up by the étape 3 legacy scan (claim_is_claimed still true).
#   - anything else (a session I `start`ed/`spawn`ed myself, outside the
#     ADOPT pool) -> the claim is removed outright (back to ABSENT), so étape
#     3's scan can find and legacy-claim it again.
# $WSH_COCKPIT_ADOPT membership is re-tested at release time rather than
# recorded anywhere: a sub-agent process keeps the same env var for its
# whole task lifetime (spawn-time and release/stop-time are the same
# process), so this reconstructs "was this an ADOPT-pool session" correctly
# without any extra bookkeeping file. Deliberately does NOT touch
# keep-<slug>, seq-<slug> or oneshot-ssh-<slug> — those track properties of
# the SESSION across release/re-adoption, not of the claim being released
# (resetting seq here would let a stale "└─[#N] exit" footer falsely match
# for the next adopter).
release_session() {  # $1 session -> rc 0 released, 1 not owner/absent
  local sess="$1" slug key last
  slug=$(session_slug "$sess")
  key=$(agent_claim_key)
  if adopt_list_contains "$sess"; then
    claim_release "$slug" "$key" || return 1
  else
    claim_read_key "$(claim_path "$slug")" 2>/dev/null | grep -Fqx -- "$key" || return 1
    rm -f "$(claim_path "$slug")"
  fi
  last=$(last_session 2>/dev/null || true)
  [ "$last" = "$sess" ] && rm -f "$(state_file)"
  return 0
}

# Form-based test: does this token LOOK like a session name, regardless of
# whether such a session exists right now? Deliberately STABLE and LOCAL (the
# string's shape) as opposed to mux_has, which tests EXISTENCE — a property of
# the system at this instant. Conflating the two in one discrimination loop is
# the design fault named in
# docs/plans/2026-08-02-desambiguisation-argument-session.md §2: a token that
# looks like a session but doesn't (yet, or anymore) exist must reach
# need_session and fail loud (exit 4), not silently fall through into another
# argument category. $SESS_DEFAULT is set in wsh-live.sh before this file is
# sourced.
looks_like_session() {
  case "$1" in
    # A real session name never contains whitespace (spawn/start never
    # produce one) — a multi-word banner text starting with "cockpit-"
    # (e.g. "cockpit-build terminé") must NOT be mistaken for one.
    *[[:space:]]*) return 1 ;;
    cockpit-*|"$SESS_DEFAULT"|=*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_session() {
  local requested="${1:-}"
  if [ -n "$requested" ]; then
    printf '%s\n' "$requested"
    return 0
  fi
  if last_session; then return 0; fi
  printf '%s\n' "$SESS_DEFAULT"
}

need_session() {
  mux_has "$1" || {
    echo "no $MUX session '$1' — run: $0 start $1" >&2; exit 4; }
}

# parse_session_flag "$@" — pre-scan for a --session/-s VALUE pair (or the
# equals forms --session=VALUE / -s=VALUE) ahead of any positional
# discrimination. Sets exactly two globals and does nothing else:
#   SESS_FLAG   the value with a leading "=" stripped (same as the positional
#               acceptance path's "${arg#=}") — empty when the flag was
#               absent. Un-stripped, "=name" reaches mux_send_line/tmux
#               send-keys -t as a target-pane spec containing "=", which
#               tmux rejects ("can't find pane"); mux_capture fails the same
#               way, silently.
#   PSF_REST    the remaining positionals with the flag and its value
#               removed, in order; the caller rebuilds "$@" with
#               `set -- ${PSF_REST[@]+"${PSF_REST[@]}"}` — NOT the plain
#               `"${PSF_REST[@]}"` form: bash 3.2, under `set -u`, treats an
#               array with zero elements as unbound on a bare `[@]`
#               expansion ("PSF_REST[@]: unbound variable") even though the
#               array itself was assigned; `${PSF_REST[@]+"${PSF_REST[@]}"}`
#               is the standard guard (measured: reproduces and is fixed by
#               this exact idiom on this Mac's /usr/bin/env bash 3.2.57).
# Bash 3.2: no associative arrays, so PSF_REST is a plain indexed array (the
# script already relies on those elsewhere, e.g. wsh-live.sh's output
# truncation). A missing value (end of arguments, or a value starting with
# "-") is a usage error raised HERE, exit 2 — not left for the caller.
parse_session_flag() {
  SESS_FLAG=""
  PSF_REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --session=*|-s=*)
        # Equals form — the same spelling gc already accepts (--idle=,
        # --only-session=), so callers WILL type it; silently ignoring it
        # would re-create the exact absorption this lot exists to close.
        SESS_FLAG="${1#*=}"
        SESS_FLAG="${SESS_FLAG#=}"
        if [ -z "$SESS_FLAG" ]; then
          echo "wsh-live: ${1%%=*} requires a value" >&2; exit 2
        fi
        shift
        ;;
      --session|-s)
        if [ $# -lt 2 ]; then
          echo "wsh-live: $1 requires a value" >&2; exit 2
        fi
        case "$2" in
          -*) echo "wsh-live: $1 takes a session name, got '$2' (a flag is not a value)" >&2; exit 2 ;;
        esac
        SESS_FLAG="${2#=}"
        shift 2
        ;;
      --session*)
        # Unknown spelling (--sessions, --session:x, …): reject rather than
        # let it fall into PSF_REST and be silently dropped downstream.
        echo "wsh-live: unknown option '$1' (did you mean --session NAME or --session=NAME?)" >&2; exit 2
        ;;
      *)
        PSF_REST+=("$1")
        shift
        ;;
    esac
  done
}

# A session-shaped positional NEXT TO --session/-s is a contradiction the
# caller must resolve — fail loud instead of silently dropping the token
# (same "no guessing" rule as looks_like_session; the flag would otherwise
# win and the second name would vanish without a word). Shared by the four
# discrimination sites (banner/wait-done/output/step-run), same
# anti-divergence rationale as deny_own_session.
flag_conflict_check() {  # $1 candidate token
  [ -n "$SESS_FLAG" ] && looks_like_session "$1" || return 0
  echo "wsh-live: got both --session '$SESS_FLAG' and session-shaped token '$1' — name the session once" >&2
  exit 2
}

# --- Remote mode: sticky per-session inline-framing flag ---------------------
# The local helper files (lib/framing.sh's sep/step helpers) live under
# $STATE_DIR on the Mac. Once a pane `ssh`/`tailscale ssh`-hops to a remote
# host, that path doesn't exist there, so sourcing it fails ("command not
# found") — the existing fix is the self-contained inline framing
# (WSH_LIVE_SEP_REINIT=1 / WSH_STEP_INLINE=1), but requiring the caller to
# repeat those env vars on every single send/banner after the hop is exactly
# the kind of thing that gets forgotten mid-workflow. `remote-init` sets a
# tmux session option once; send/banner then default to inline framing for
# that session until `local-init` clears it. Explicit env vars still win, for
# one-off overrides. Zellij has no per-session option store (same limitation
# as helper_loaded) — remote mode is env-var-only there; remote_mode_set is a
# no-op with a stderr note rather than a silent failure.
remote_mode_option() { printf '@wsh_remote_mode\n'; }
remote_mode_get() {  # $1 sess -> "1" (on) or "" (off/unset)
  [ "$MUX" = tmux ] || return 1
  [ "$(tmux show-option -qv -t "$1" "$(remote_mode_option)" 2>/dev/null || true)" = "1" ]
}
remote_mode_set() {  # $1 sess  $2 (1|0) -> 0 if actually set, 1 if a tmux-only no-op
  if [ "$MUX" != tmux ]; then
    echo "note: remote-init/local-init has no effect under $MUX (no per-session option store) — use WSH_LIVE_SEP_REINIT=1 / WSH_STEP_INLINE=1 explicitly instead" >&2
    return 1
  fi
  tmux set-option -t "$1" "$(remote_mode_option)" "$2" >/dev/null 2>&1 || true
}

# --- Remote mode: pushed-helper paths (when remote-init was given a host) ---
# When `remote-init <session> <host>` manages to push the sep/step helper
# files to the remote host (see wsh-live.sh's remote-init case, which shells
# out to wsh-push.sh), the REMOTE absolute path of each pushed file is
# recorded here so send/banner can build the short `. '<remote-path>' && ...`
# sourcing form instead of falling back to the ~700-char inline blob. Same
# per-session tmux-option store as remote_mode_*, same Zellij limitation
# (no-op — callers just never find a path, so they fall back to inline).
remote_helper_option() { printf '@wsh_remote_helper_%s\n' "$1"; }  # $1 kind (sep|step)
remote_helper_path_get() {  # $1 sess $2 kind -> remote path, or "" if none recorded
  [ "$MUX" = tmux ] || { printf ''; return 0; }
  tmux show-option -qv -t "$1" "$(remote_helper_option "$2")" 2>/dev/null || true
}
remote_helper_path_set() {  # $1 sess $2 kind $3 remote-path
  [ "$MUX" = tmux ] || return 0
  tmux set-option -t "$1" "$(remote_helper_option "$2")" "$3" >/dev/null 2>&1 || true
}
remote_helper_path_clear() {  # $1 sess $2 kind
  [ "$MUX" = tmux ] || return 0
  tmux set-option -u -t "$1" "$(remote_helper_option "$2")" >/dev/null 2>&1 || true
}

# --- Remote mode: recorded hop host (for out-of-pane push/pull) -------------
# `remote-init <sess> <host>` / `remote-init --pre <host> <sess>` learn the
# host the pane has (or is about to) ssh-hop to; `push`/`pull` need that same
# host to pick a transport WITHOUT asking the caller to repeat it (the whole
# point is that the agent never re-types a hostname it already told the skill
# once). Same per-session tmux-option store as remote_mode_*/remote_helper_*,
# same Zellij limitation (no-op — push/pull just find no host and error).
remote_host_option() { printf '@wsh_remote_host\n'; }
remote_host_get() {  # $1 sess -> recorded host, or "" if none
  [ "$MUX" = tmux ] || { printf ''; return 0; }
  tmux show-option -qv -t "$1" "$(remote_host_option)" 2>/dev/null || true
}
remote_host_set() {  # $1 sess $2 host
  [ "$MUX" = tmux ] || return 0
  # control_path_for_session keys the ControlMaster socket by session name
  # alone (below) — if this session is later repointed to a DIFFERENT host,
  # a still-live master from the old endpoint would let push/pull silently
  # reuse it. Tear down any existing master here, before the new host is
  # recorded, so a stale one is never picked up.
  local prev cpath
  prev=$(remote_host_get "$1")
  if [ -n "$prev" ] && [ "$prev" != "$2" ]; then
    cpath=$(control_path_for_session "$1")
    if [ -S "$cpath" ] && command -v ssh >/dev/null 2>&1; then
      ssh -o ControlPath="$cpath" -O exit x >/dev/null 2>&1 || true
    fi
    rm -f "$cpath" 2>/dev/null || true
  fi
  tmux set-option -t "$1" "$(remote_host_option)" "$2" >/dev/null 2>&1 || true
}
remote_host_clear() {  # $1 sess
  [ "$MUX" = tmux ] || return 0
  tmux set-option -u -t "$1" "$(remote_host_option)" >/dev/null 2>&1 || true
}

# --- OpenSSH ControlMaster socket path for a session -------------------------
# Deterministic from the session name alone (no state lookup needed) so both
# the pane's hop command (`ssh -o ControlPath=...`, see SKILL.md) and
# push/pull's out-of-pane scp/ssh calls agree on the exact same socket path
# without any extra bookkeeping. tailscale ssh does NOT support ControlMaster
# — a session hopped that way just never has a live socket here, and
# wsh-push.sh's `try_control_path` falls through cleanly when `ssh -O check`
# finds nothing (see wsh-push.sh). Cleaned up by teardown_session below.
control_path_for_session() {  # $1 sess -> path under STATE_DIR
  printf '%s/cm-%s\n' "$STATE_DIR" "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_')"
}

# Human-only narration. The cockpit is driven by Claude through a non-TTY Bash pipe,
# where every line is re-read into the model's context on each call — so per-command
# confirmations and multi-line "how to attach" help are pure token cost there. Print
# such guidance ONLY when stdout is a real TTY (a human running the script by hand);
# machine lines (SESSION=, sent #N) stay unconditional and terse.
tty_only() { [ -t 1 ] && printf '%s\n' "$@" || true; }

# Per-session sequence counter file path: normalized slug of session name.
seq_file() { printf '%s/seq-%s\n' "$STATE_DIR" "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_')"; }

# Sticky "keep" marker (spec v12 §3, step-1.6): a property of the SESSION,
# not of the claim — it survives release and re-adoption by a different
# agent, unlike claim state. Posing this marker at creation time is the
# wrapper's job (fiche 1.9, out of scope here); this file only exposes the
# read-only predicate that `stop` (wsh-live.sh) and release_session() below
# consult to decide whether a "destroy" request must be downgraded to a
# release instead.
keep_file() { printf '%s/keep-%s\n' "$STATE_DIR" "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_')"; }
keep_is_set() { [ -e "$(keep_file "$1")" ]; }

# --- One-shot SSH nudge -------------------------------------------------------
# SKILL.md requires one persistent SSH session per host (auth once, work
# inside, `send 'exit'`) — a fire-and-forget `ssh host '<cmd>'` per command is
# only legitimate for a one-off diagnostic (1-2 commands). This tracks
# consecutive `send`s that look like that one-shot shape and, from the 2nd
# consecutive match on, prints a nudge to STDERR (never the pane, never
# blocking — legitimate bursts like multi-host probes exist).
oneshot_ssh_file() { printf '%s/oneshot-ssh-%s\n' "$STATE_DIR" "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_')"; }

# A one-shot ssh/tailscale-ssh call carrying an inline command:
# `ssh host '<cmd>'` / `tailscale ssh host "<cmd>"`. Deliberately does NOT
# match: a bare interactive hop (`ssh host`, `tailscale ssh host` — no inline
# command, the persistent-session shape this nudge wants to encourage),
# `wsh ssh -n host` (opens a Wave connection, different verb), or `scp`/`rsync`.
oneshot_ssh_is_inline() {
  [[ "$1" =~ ^(tailscale[[:space:]]+)?ssh[[:space:]].*[[:space:]][\"\'] ]]
}

# Update the per-session consecutive-count and warn from the 2nd match on.
# $1 sess $2 cmd — no return value; state file write is the only side effect
# besides the optional stderr line.
oneshot_ssh_track() {
  local sess="$1" cmd="$2" f n
  f=$(oneshot_ssh_file "$sess")
  if oneshot_ssh_is_inline "$cmd"; then
    n=$(cat "$f" 2>/dev/null || true)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    n=$((n + 1))
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$n" >"$f"
    if [ "$n" -ge 2 ]; then
      echo "wsh-cockpit: ${n} one-shot SSH commands in a row on '${sess}' — for real work on a host, prefer ONE persistent session: send 'ssh <host>' (or 'tailscale ssh <host>') once, remote-init, work inside, then send 'exit'. (nudge only, not blocking — multi-host probes are a legitimate burst)" >&2
    fi
  else
    rm -f "$f" 2>/dev/null || true
  fi
}

# Kill a session and clean up everything that belongs to it: the seq-counter
# file, the sep/step "helpers loaded" tmux options, its ttyd web view (if
# any), the Wave block `open` last attached (best-effort deleteblock), and —
# only if it was the one remembered for the CURRENT agent/prefix — the
# last-session pointer. Shared by `stop` (explicit, one session) and `gc`
# (idle sweep, many sessions) so this cleanup logic lives in exactly one
# place. Returns 0 if a session was actually killed, 1 if there was nothing
# to kill (already gone).
teardown_session() {
  local sess="$1" sf killed=1 cpath
  rm -f "$(seq_file "$sess")" 2>/dev/null || true
  rm -f "$(oneshot_ssh_file "$sess")" 2>/dev/null || true
  rm -f "$(claim_path "$(session_slug "$sess")")" 2>/dev/null || true
  rm -f "$(prefix_file "$sess")" 2>/dev/null || true
  tab_cache_invalidate "$sess"
  if [ "$MUX" = tmux ]; then
    # `stop` (wsh-live.sh) hands its raw argument straight to this function
    # with no mux_has check of its own — so $sess can be a bare PREFIX, not
    # the exact session name. `set-option` rejects "=" and resolves by
    # PREFIX instead (measured — see docs/gotchas.md's I1/I2 gotchas), so
    # unlike the anchored `mux_kill` below, the six set-option calls used to
    # run against whatever session $sess happened to prefix-match — wiping
    # a live NEIGHBOUR's remote-mode options while `mux_kill` correctly (and
    # silently) refused to kill anything. `mux_has` is anchored ("=", exact
    # match only), so gate on it FIRST: only when an EXACT session really
    # exists do we resolve its canonical name (mux_session_name, same
    # round-trip session_is_own uses, for the rare grouped-session alias)
    # and let these calls proceed. If nothing matches exactly, leave $sess
    # untouched and skip the whole block — closes the hole for whatever
    # tmux target command gets added here next, not just today's six lines.
    if mux_has "$sess"; then
      local canon; canon=$(mux_session_name "$sess" 2>/dev/null || true)
      [ -n "$canon" ] && sess="$canon"
      tmux set-option -u -t "$sess" "$(sep_helper_option "$sess")" >/dev/null 2>&1 || true
      tmux set-option -u -t "$sess" "$(step_helper_option "$sess")" >/dev/null 2>&1 || true
      tmux set-option -u -t "$sess" "$(remote_mode_option)" >/dev/null 2>&1 || true
      tmux set-option -u -t "$sess" "$(remote_helper_option sep)" >/dev/null 2>&1 || true
      tmux set-option -u -t "$sess" "$(remote_helper_option step)" >/dev/null 2>&1 || true
      tmux set-option -u -t "$sess" "$(remote_host_option)" >/dev/null 2>&1 || true
    fi
  fi
  # Close and remove the session's ControlMaster socket, if any (orphaned
  # otherwise — see control_path_for_session). "-O exit" needs a host
  # argument syntactically but ignores it once -o ControlPath points at a
  # real socket; a dead/stale socket file just fails the check, so `rm -f`
  # after it is what actually clears it either way.
  cpath=$(control_path_for_session "$sess")
  if [ -S "$cpath" ] && command -v ssh >/dev/null 2>&1; then
    ssh -o ControlPath="$cpath" -O exit x >/dev/null 2>&1 || true
  fi
  rm -f "$cpath" 2>/dev/null || true
  web_teardown "$sess"
  if mux_kill "$sess"; then killed=0; fi
  block_id_close "$sess"
  sf=$(state_file)
  if [ -f "$sf" ] && [ "$(tr -d '[:space:]' <"$sf")" = "$sess" ]; then
    rm -f "$sf" 2>/dev/null || true
  fi
  return "$killed"
}
