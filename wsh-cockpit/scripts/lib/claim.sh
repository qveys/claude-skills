#!/usr/bin/env bash
# lib/claim.sh — claim registry primitives (adopt-claim-<slug> state machine).
# Sourced by wsh-live.sh; not meant to be run standalone.
#
# Spec v12 §2 ("Table d'états du claim") is authoritative. States:
#   ABSENT -> PRÉ-CLAIM (key "user-preopen-<n>" or "released")
#          -> EN-COURS (".won-<pid>", content = the pre-claim it came from)
#          -> POSSÉDÉ (key of the owning agent)
# Format = a parsed contract, not a debug aid: line 1 = agent key, line 2 =
# pid (debug only, never parsed for logic).
#
# This file only encapsulates the transition primitives (one function per row
# of the spec's "Primitives des transitions" table) — no call site outside
# this file composes mv/ln on a claim path by hand. Wiring these into
# spawn/start/release/gc is step-1.3 and later; this file does not touch
# tmux, sessions, or $STATE_DIR beyond the marker files themselves.
#
# Invariants enforced here (spec v12 §2):
#   I1 every write to adopt-claim-<slug> is O_EXCL or no-clobber — never an
#      overwriting mv; a rollback/restore that finds a definitive claim
#      already in place drops its own .won/.stale instead of clobbering it.
#   I2 after any winning rename, the .won content MUST be a pre-claim
#      (anti-ré-armement) — checked by claim_verify_won, not by claim_consume.
#   I3 "claimed" (for scan exclusion, step-1.5) = adopt-claim-<slug> exact OR
#      adopt-claim-<slug>.won-* — not enforced here, it's a scan-side read.
#   I4 only the owning key may write `release` — enforced by claim_release.

# -- paths --------------------------------------------------------------

claim_path()      { printf '%s/adopt-claim-%s\n' "$STATE_DIR" "$1"; }
claim_won_path()  { printf '%s.won-%s\n' "$(claim_path "$1")" "$2"; }
claim_stale_path() { printf '%s.stale-%s\n' "$(claim_path "$1")" "$2"; }

# -- format (line 1 = key, line 2 = pid, debug-only) ---------------------

claim_read_key() {  # $1 path -> prints line 1, rc 1 if the file is missing
  [ -f "$1" ] || return 1
  sed -n '1p' "$1"
}

claim_read_pid() {  # $1 path -> prints line 2, rc 1 if the file is missing
  [ -f "$1" ] || return 1
  sed -n '2p' "$1"
}

# Reserved key space (spec v12 §2): spawn/start must refuse a
# WSH_COCKPIT_AGENT starting with "user-preopen-" or equal to "released" —
# otherwise a misconfigured agent would make its own sessions adoptable by
# anyone at resolution step 2. This is a misconfiguration guard-rail, not a
# security boundary (any local process can write the cache regardless). The
# wrapper legitimately uses these keys via its own internal --preopen flag,
# which bypasses this check at the call site — enforcement lives in
# spawn/start (step-1.3), this is only the predicate.
claim_key_reserved() {  # $1 key -> rc 0 if reserved
  case "$1" in
    user-preopen-*|released) return 0 ;;
    *) return 1 ;;
  esac
}

# I3 (spec v12 §2, scan exclusion, step-1.5): a slug counts as CLAIMED — by
# anyone, in any state past ABSENT (pré-claim, EN-COURS transfer, or
# POSSÉDÉ) — when its definitive claim file exists OR a .won-<pid> transfer
# is in flight. Deliberately NOT a glob on "<slug>*": that form would
# over-match a sibling slug that merely starts with this one (e.g. slug
# "foo" vs sibling "foo-1") — only the exact claim path, or that exact
# path's own ".won-*" suffix, count. The glob below tolerates zero matches
# under `set -euo pipefail` (bash 3.2, no nullglob): an unexpanded pattern
# is left literal and `[ -e ]` on it is simply false (same idiom fixed for
# claim.sh's own stale-marker counting in step-1.2).
claim_is_claimed() {  # $1 slug -> rc 0 claimed, 1 free (ABSENT)
  local slug="$1" path f
  path=$(claim_path "$slug")
  [ -e "$path" ] && return 0
  for f in "$path".won-*; do
    [ -e "$f" ] && return 0
  done
  return 1
}

# -- internal helpers -----------------------------------------------------

# O_EXCL create: fails if $1 already exists. Used by every ABSENT-origin
# transition (claim_create, claim_finalize, claim_replace_orphan's rewrite).
claim__excl_write() {  # $1 path $2 key $3 pid -> rc 0 created, nonzero EEXIST/other
  local path="$1" key="$2" pid="$3" rc=0
  mkdir -p "$STATE_DIR"
  ( set -o noclobber; printf '%s\n%s\n' "$key" "$pid" >"$path" ) 2>/dev/null || rc=$?
  return "$rc"
}

# Destination-exclusive restore: `ln $1 $2` (link(2), EEXIST if $2 already
# exists — a definitive claim that appeared in the meantime is NEVER
# overwritten, I1), then `rm $1` unconditionally either way. rc mirrors ln's:
# 0 = genuine restore happened, nonzero = a rival claim was protected instead
# (this call only dropped its own temp file).
claim__restore() {  # $1 tmp_path $2 dest_path
  local tmp="$1" dest="$2" rc=0
  [ -f "$tmp" ] || return 1
  ln "$tmp" "$dest" 2>/dev/null || rc=$?
  rm -f "$tmp"
  return "$rc"
}

# -- transitions (spec v12 §2, "Primitives des transitions") --------------

# ABSENT -> PRÉ-CLAIM (wrapper --preopen) or POSSÉDÉ (scan/create, legacy
# reuse) — same primitive, the caller decides which key to write.
claim_create() {  # $1 slug $2 key [$3 pid, default $$]
  claim__excl_write "$(claim_path "$1")" "$2" "${3:-$$}"
}

# PRÉ-CLAIM -> EN-COURS: `mv claim .won-<pid>` (rename(2)) — the SOURCE
# disappears atomically, so exactly one concurrent `mv` on the same claim
# wins; every loser gets ENOENT. `.won-<pid>` is a mono-writer space (no one
# else creates a file under MY pid while I'm alive) EXCEPT a residual left
# behind by an earlier life of a recycled pid — that residual is
# purged/restored via claim__restore BEFORE the real mv, so this mv never
# silently clobbers it (I1). This function does NOT verify content — see
# claim_verify_won (I2) — a caller must call both in sequence.
claim_consume() {  # $1 slug $2 pid (default $$) -> rc 0 win, nonzero lose/absent
  local slug="$1" pid="${2:-$$}" path won rc=0
  path=$(claim_path "$slug")
  won=$(claim_won_path "$slug" "$pid")
  if [ -f "$won" ]; then
    claim__restore "$won" "$path" >/dev/null 2>&1 || true
  fi
  mv "$path" "$won" 2>/dev/null || rc=$?
  return "$rc"
}

# I2, anti-ré-armement: the .won a rename just won is NOT proof of victory by
# itself — if the definitive claim I raced against had ALREADY been written
# to the same path by its own owner before my rename, my rename "succeeds"
# too (on THEIR claim, not the pre-claim I meant to consume). Content is the
# only thing that tells the two apart: a genuine pre-claim's key always
# starts with "user-preopen-" or is exactly "released".
claim_verify_won() {  # $1 slug $2 pid -> rc 0 valid pre-claim, 1 not (anti-rearm), 2 missing
  local slug="$1" pid="$2" won key
  won=$(claim_won_path "$slug" "$pid")
  [ -f "$won" ] || return 2
  key=$(claim_read_key "$won" 2>/dev/null || true)
  case "$key" in
    user-preopen-*|released) return 0 ;;
    *) return 1 ;;
  esac
}

# EN-COURS -> POSSÉDÉ: O_EXCL write of the definitive claim, then drop the
# now-redundant .won. Caller must have already verified the .won's content
# (claim_verify_won) AND run its adoption probe before calling this — this
# function does not re-check either.
claim_finalize() {  # $1 slug $2 pid $3 key -> rc 0 owned, nonzero on write failure
  local slug="$1" pid="$2" key="$3"
  claim__excl_write "$(claim_path "$slug")" "$key" "$pid" || return 1
  rm -f "$(claim_won_path "$slug" "$pid")"
}

# EN-COURS -> PRÉ-CLAIM: abandon a consumed-but-not-yet-finalized claim
# (busy-pane guard, failed probe, or a rival definitive claim materialized
# meanwhile) via claim__restore. On the race case (I1 protects a rival claim
# that appeared in the meantime), this only drops the .won — the rival is
# left untouched, exactly as intended.
claim_rollback() {  # $1 slug $2 pid
  claim__restore "$(claim_won_path "$1" "$2")" "$(claim_path "$1")"
}

# Replacement of an orphaned claim (dead session, HHMMSS name recycled):
# consume it out of the way first (`mv claim .stale-<pid>` — never an
# overwriting mv toward the shared path), then attempt the O_EXCL rewrite;
# if a third party re-created the path in between, the O_EXCL loses and the
# .stale is restored/dropped through the same no-clobber primitive as
# claim_rollback (I1) — never a corrupted or double-claimed slug either way.
claim_replace_orphan() {  # $1 slug $2 pid $3 key -> rc 0 replaced, nonzero if raced away
  local slug="$1" pid="$2" key="$3" path stale rc=0
  path=$(claim_path "$slug")
  stale=$(claim_stale_path "$slug" "$pid")
  mv "$path" "$stale" 2>/dev/null || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  if claim__excl_write "$path" "$key" "$pid"; then
    rm -f "$stale"
    return 0
  fi
  claim__restore "$stale" "$path" >/dev/null 2>&1 || true
  return 1
}

# POSSÉDÉ -> PRÉ-CLAIM "released" (I4: owner-only). Mono-writer by
# construction (only the current owner ever calls this), so a plain
# temp+mv atomic replace is sufficient — no no-clobber primitive needed,
# unlike the multi-writer transitions above. Verifies the caller actually
# owns the claim before writing (defense in depth for I4, not just a
# documentation comment).
claim_release() {  # $1 slug $2 owner_key -> rc 0 released, 1 not owner/absent
  local slug="$1" owner_key="$2" path cur tmp
  path=$(claim_path "$slug")
  cur=$(claim_read_key "$path" 2>/dev/null || true)
  [ -n "$cur" ] && [ "$cur" = "$owner_key" ] || return 1
  tmp="${path}.tmp-$$"
  printf '%s\n%s\n' "released" "$$" >"$tmp"
  mv "$tmp" "$path"
}
