#!/usr/bin/env bash
# lib/wave.sh — resolve the live Wave tab from Wave's state SQLite (read-only).
# Sourced by wsh-live.sh; not meant to be run standalone.

# Resolve a LIVE Wave tab id to anchor a new block on, robust to a stale env.
# Strategy, best-first (the goal is the INITIATING shell's tab, so the cockpit
# opens next to the Claude Code that spawned it):
#   0. Live signals over env — (a) the wave-init tmux session-group name
#      (wave-<tab8>, 1 tab = 1 group) resolved back to a full tab oid, else
#      (b) the tab whose blockids contain WAVETERM_BLOCKID.
#   1. If WAVETERM_TABID is set AND still present in Wave's state DB, trust it.
#   2. Otherwise read db_workspace.activetabid for the env's workspace (or, if
#      that workspace is gone too, the single/first workspace) from the state
#      SQLite, opened READ-ONLY so we never touch Wave's live DB.
# Prints the tab id on success; prints nothing and returns non-zero if no live
# tab can be found (caller falls back to telling the human to attach by hand).
# Echo the `file:…?mode=ro` URI for Wave's state SQLite, or return 1 if it/sqlite3
# is unavailable. CRITICAL: mode=ro ONLY — never add immutable=1. Wave's DB is in
# WAL mode, so recent writes (the active-tab switch, new blocks, freshly recreated
# tab oids) live in the -wal file; immutable=1 tells SQLite "this file never changes,
# ignore the WAL" → a STALE snapshot that resolves the wrong (often oldest) tab and
# dead oids. mode=ro reads through the WAL (we have rw perms, so -shm/-wal read fine).
wave_db_ro() {
  local data_dir db
  data_dir=$(wsh wavepath data 2>/dev/null) || data_dir=""
  [ -n "$data_dir" ] || data_dir="$HOME/Library/Application Support/waveterm"
  db="$data_dir/db/waveterm.db"
  [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1 || return 1
  printf 'file:%s?mode=ro\n' "$db"
}

# Escape $1 as a single-quoted SQL literal, safe to splice into a query
# string passed as ONE argv argument to `sqlite3` (spec v12 §4, finding
# 3721135358: sqlite3's dot-commands are parsed line-by-line and can't carry
# a value containing a newline, so `.parameter set` is unusable here — the
# query is built with the literal already embedded instead). SQLite's
# single-quoted literal grammar has no other metacharacter (no backslash
# escaping) and newlines are legal inside a literal, so doubling `'` and
# wrapping in `'...'` is a complete neutralization by construction; `%` stays
# inert under `=` (this isn't a LIKE pattern).
# GOTCHA (measured step-1.1, rapport-step-1.1.md §6): writing the doubling
# directly as "${s//\'/\'\'}" inserts LITERAL BACKSLASHES in this bash
# instead of doubling the quote — route the quote character through a
# variable first, never write that pattern inline again.
sql_quote() {
  local s="$1" q="'"
  s="${s//$q/$q$q}"
  printf "'%s'" "$s"
}

# Resolve the live Wave state DB via `wsh wavepath data` ONLY — deliberately
# WITHOUT wave_db_ro's hardcoded ~/Library/Application Support/waveterm
# fallback (spec v12 §4, point c: that fallback can be a divergent/older DB,
# measured 9 days stale in rapport-step-1.1.md §5 — fine for the best-effort
# resolve_live_tab, wrong for a --tab request the caller explicitly made).
# --tab must fail cleanly here rather than silently resolve against it.
wave_db_ro_strict() {
  local data_dir db
  command -v wsh >/dev/null 2>&1 || return 1
  data_dir=$(wsh wavepath data 2>/dev/null) || return 1
  [ -n "$data_dir" ] || return 1
  db="$data_dir/db/waveterm.db"
  [ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1 || return 1
  printf 'file:%s?mode=ro\n' "$db"
}

# Resolve a Wave tab id by NAME ($1), bounded to the CURRENT workspace only
# (spec v12 §4 — the CTE below is the spec's query, reprise telle quelle,
# with :ws/:nom spliced in pre-quoted via sql_quote rather than sqlite3
# dot-command binding). $2 is an optional ro URI override, used only by
# selftest-tab to point at a throwaway fixture DB instead of the live one.
#
# Return codes (never printed — see the two globals below):
#   0  resolved (TAB_BY_NAME_RESULT/_ALL set)
#   1  the live Wave DB itself is unreachable (wsh/wavepath/sqlite3 missing)
#   2  WAVETERM_WORKSPACEID unset — hors Wave, no workspace to bound the
#      search to (spec v12 §4: échec propre, pas de fallback arbitraire)
#   3  no tab named $1 in this workspace (caller warns + falls back)
#
# On rc=0:
#   TAB_BY_NAME_RESULT  the elected tab oid — first row (pinned ASC, then
#                       array-position ASC — deterministic even across ties)
#   TAB_BY_NAME_ALL     every matching oid, one per line, same order; more
#                       than one line means duplicates — caller warns
resolve_tab_by_name() {
  local name="$1" ro="${2:-}" ws q rows
  TAB_BY_NAME_RESULT=""
  TAB_BY_NAME_ALL=""
  ws="${WAVETERM_WORKSPACEID:-}"
  [ -n "$ws" ] || return 2
  if [ -z "$ro" ]; then
    ro=$(wave_db_ro_strict) || return 1
  fi
  q="WITH workspace_tabs AS (
  SELECT json_each.value AS tabid, 0 AS pinned, json_each.key AS ord
  FROM db_workspace, json_each(db_workspace.data, '\$.pinnedtabids')
  WHERE db_workspace.oid = $(sql_quote "$ws")
  UNION ALL
  SELECT json_each.value, 1, json_each.key
  FROM db_workspace, json_each(db_workspace.data, '\$.tabids')
  WHERE db_workspace.oid = $(sql_quote "$ws")
)
SELECT db_tab.oid
FROM db_tab JOIN workspace_tabs ON workspace_tabs.tabid = db_tab.oid
WHERE json_extract(db_tab.data, '\$.name') = $(sql_quote "$name")
ORDER BY workspace_tabs.pinned ASC, workspace_tabs.ord ASC;"
  rows=$(sqlite3 "$ro" "$q" 2>/dev/null) || return 1
  [ -n "$rows" ] || return 3
  TAB_BY_NAME_ALL="$rows"
  TAB_BY_NAME_RESULT=$(printf '%s\n' "$rows" | head -1)
  return 0
}

# Count the candidates in a resolve_tab_by_name-style newline-separated
# string ($1 — e.g. TAB_BY_NAME_ALL: N oids, one per line, NO trailing
# newline since it comes out of a `$(…)` substitution). Factored out (audit
# step-1.11.3, É3) because `printf '%s' "$1" | wc -l` — counting line
# TERMINATORS on a string missing its final one — undercounts by one: N
# candidates -> N-1, so a caller's `-gt 1` warning threshold stayed silent at
# exactly N=2. `printf '%s\n' "$1"` restores the missing terminator first.
tab_count_candidates() {
  printf '%s\n' "$1" | wc -l | tr -d ' '
}

resolve_live_tab() {
  local ro tab ws sessname tab8
  ro=$(wave_db_ro) || return 1

  # 0. The tab hosting the INITIATING shell — best signal first. The env
  # WAVETERM_TABID/BLOCKID can be STALE while still existing in the DB (a tmux
  # window outlives the block that created it and gets re-viewed from another
  # tab), so prefer live signals over the env:
  #   a. under the wave-init tmux wrapping, the session group is named
  #      wave-<tab8> (1 tab = 1 group, Wave UUIDs are stable) — the freshest
  #      binding there is; resolve tab8 back to the full oid;
  #   b. else find the tab whose data JSON (its blockids list) contains
  #      WAVETERM_BLOCKID — a LIKE match on db_tab.data, since blockids is a
  #      key inside that blob, not a column (survives block moves).
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    sessname=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null || true)
    case "$sessname" in
      # Exactly wave-<8hex> or wave-<8hex>-… : anything else (e.g. a 9th hex
      # char or stray punctuation) must NOT reach the SQL interpolation below.
      wave-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]|wave-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*)
        tab8=${sessname#wave-}; tab8=${tab8%%-*}
        tab=$(sqlite3 "$ro" "SELECT oid FROM db_tab WHERE oid LIKE '${tab8}%';" 2>/dev/null)
        case "$tab" in *$'\n'*) tab="" ;; esac   # ambiguous prefix — fall through
        ;;
    esac
  fi
  if [ -z "${tab:-}" ] && [ -n "${WAVETERM_BLOCKID:-}" ]; then
    tab=$(sqlite3 "$ro" \
      "SELECT oid FROM db_tab WHERE data LIKE '%${WAVETERM_BLOCKID//\'/}%' LIMIT 1;" 2>/dev/null)
  fi
  if [ -n "${tab:-}" ] && [ "$(sqlite3 "$ro" \
        "SELECT count(*) FROM db_tab WHERE oid='${tab//\'/}';" 2>/dev/null)" = "1" ]; then
    printf '%s\n' "$tab"; return 0
  fi
  tab=""

  # 1. Trust the env tab only if it actually exists in the DB.
  if [ -n "${WAVETERM_TABID:-}" ]; then
    if [ "$(sqlite3 "$ro" \
          "SELECT count(*) FROM db_tab WHERE oid='${WAVETERM_TABID//\'/}';" \
          2>/dev/null)" = "1" ]; then
      printf '%s\n' "$WAVETERM_TABID"; return 0
    fi
  fi

  # 2. activetabid of the env workspace, else of any workspace.
  ws="${WAVETERM_WORKSPACEID:-}"
  if [ -n "$ws" ]; then
    tab=$(sqlite3 "$ro" \
      "SELECT json_extract(data,'\$.activetabid') FROM db_workspace WHERE oid='${ws//\'/}';" \
      2>/dev/null)
  fi
  [ -n "${tab:-}" ] || tab=$(sqlite3 "$ro" \
    "SELECT json_extract(data,'\$.activetabid') FROM db_workspace LIMIT 1;" 2>/dev/null)

  # Sanity-check the resolved tab actually exists as a tab row.
  if [ -n "${tab:-}" ] && [ "$(sqlite3 "$ro" \
        "SELECT count(*) FROM db_tab WHERE oid='${tab//\'/}';" 2>/dev/null)" = "1" ]; then
    printf '%s\n' "$tab"; return 0
  fi
  return 1
}

# Per-session cache of a resolved live tab id: normalized slug of the session
# name, same convention as session.sh's seq_file/pane_file. The session→tab
# mapping is stable for the life of a cockpit session, so repeated `open`
# calls don't need to re-run resolve_live_tab's 5-6 sqlite3 round-trips.
tab_cache_file() { printf '%s/tab-%s\n' "$STATE_DIR" "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_')"; }

# Cached wrapper around resolve_live_tab(), keyed by cockpit session name
# ($1). A cache hit still costs one read-only sqlite3 query to confirm the
# cached tab still exists in Wave's DB (it can vanish if the tab was closed);
# a stale entry is dropped and resolve_live_tab runs its full strategy.
# Call with no session name (or an empty one) to behave exactly like the
# uncached resolve_live_tab — used by `doctor`, which must never write state.
resolve_live_tab_cached() {
  # ${1:-}, not $1: the documented no-session mode above (called by `doctor`)
  # omits the argument entirely, which would abort under set -u otherwise.
  local sess="${1:-}" cache tab ro
  if [ -n "$sess" ]; then
    cache=$(tab_cache_file "$sess")
    if [ -f "$cache" ]; then
      tab=$(tr -d '[:space:]' <"$cache" 2>/dev/null || true)
      if [ -n "$tab" ] && ro=$(wave_db_ro) && [ "$(sqlite3 "$ro" \
            "SELECT count(*) FROM db_tab WHERE oid='${tab//\'/}';" 2>/dev/null)" = "1" ]; then
        printf '%s\n' "$tab"
        return 0
      fi
      rm -f "$cache" 2>/dev/null || true
    fi
  fi
  tab=$(resolve_live_tab) || return 1
  if [ -n "$sess" ]; then
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf '%s\n' "$tab" >"$cache" 2>/dev/null || true
  fi
  printf '%s\n' "$tab"
}

# Drop a session's cached tab — called from teardown_session (stop/gc) so a
# closed cockpit never hands a future `open` a stale/recycled tab id.
tab_cache_invalidate() { rm -f "$(tab_cache_file "$1")" 2>/dev/null || true; }

# Per-session state of the Wave block-id `open` last created, same slug
# convention as tab_cache_file. Lets teardown_session close the block itself
# instead of leaving it to a manual `wsh deleteblock` the agent can forget.
block_id_file() { printf '%s/block-%s\n' "$STATE_DIR" "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_')"; }

block_id_store() {
  local sess="$1" id="$2"
  [ -n "$sess" ] && [ -n "$id" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s\n' "$id" >"$(block_id_file "$sess")" 2>/dev/null || true
}

# Best-effort close of a block-<slug> marker given its PATH directly — the
# primitive block_id_close(sess) below wraps. Split out (step-1.7) so gc's
# marker-hygiene pass can close a DEAD session's block the same way even
# though it only ever has the marker file (a slug), never the session's
# original un-slugified name that block_id_file(sess) would need to
# re-derive the same path.
block_id_close_path() {  # $1 marker path (block-<slug>)
  local bf="$1" id
  [ -f "$bf" ] || return 0
  id=$(tr -d '[:space:]' <"$bf" 2>/dev/null || true)
  rm -f "$bf" 2>/dev/null || true
  [ -n "$id" ] || return 0
  command -v wsh >/dev/null 2>&1 || return 0
  wsh deleteblock -b "$id" >/dev/null 2>&1 || true
}

# Best-effort close of the block remembered for $sess, called from
# teardown_session. Never fails the caller: no state file, no `wsh`, or a
# block that already auto-closed ("not found") are all silently fine — only
# the specific id `open` recorded is ever targeted, never a pane scan.
block_id_close() {
  block_id_close_path "$(block_id_file "$1")"
}

# Print "NAME|COUNT" for a tab oid: its display name (e.g. "T2") and the TOTAL
# number of tabs in Wave. Used so `open` can tell the human EXACTLY which tab to
# click — critical because Wave does NOT persist the active-tab switch to the
# state DB (so resolve_live_tab can return a tab the user isn't looking at) and
# there is NO wsh command to move the UI focus. Naming the tab is the only robust
# way to make the freshly-opened block findable. Prints nothing on failure.
tab_describe() {
  local oid="$1" ro name count
  ro=$(wave_db_ro) || return 1
  name=$(sqlite3 "$ro" \
    "SELECT json_extract(data,'\$.name') FROM db_tab WHERE oid='${oid//\'/}';" 2>/dev/null)
  count=$(sqlite3 "$ro" "SELECT count(*) FROM db_tab;" 2>/dev/null)
  [ -n "$name" ] || return 1
  printf '%s|%s\n' "$name" "${count:-1}"
}

# Delete a Wave block by id (used by `stop` so killing the cockpit also removes
# the visible block, not just the tmux session). `wsh` needs an RPC context: from
# a non-Wave shell (the agent's tool shell) WAVETERM_* is unset and wsh errors
# "no workspaces found", so we resolve the block's own tab + workspace from the
# state DB (read-only) and pass them via env — mirroring how `open` runs `wsh run`.
# Best-effort: silent no-op if wsh/sqlite3 is missing, the block is already gone,
# or no context can be resolved (never blocks `stop`). Returns non-zero when the
# block was NOT actually deleted, so callers can report an accurate status
# instead of assuming success.
wave_delete_block() {
  local bid="$1" ro tab ws
  [ -n "$bid" ] || return 1
  # bid comes from a user-writable state file and is interpolated into a LIKE
  # query below — reject anything that isn't a UUID-like hex/dash string before
  # it ever reaches sqlite3.
  case "$bid" in *[!0-9a-fA-F-]*) return 1 ;; esac
  command -v wsh >/dev/null 2>&1 || return 1
  ro=$(wave_db_ro) || ro=""
  if [ -n "$ro" ]; then
    tab=$(sqlite3 "$ro" "SELECT oid FROM db_tab WHERE data LIKE '%${bid//\'/}%' LIMIT 1;" 2>/dev/null)
    [ -n "$tab" ] || tab=$(resolve_live_tab 2>/dev/null || true)
    [ -n "$tab" ] && ws=$(sqlite3 "$ro" \
      "SELECT oid FROM db_workspace WHERE data LIKE '%${tab//\'/}%' LIMIT 1;" 2>/dev/null)
  fi
  WAVETERM_TABID="${tab:-${WAVETERM_TABID:-}}" \
  WAVETERM_WORKSPACEID="${ws:-${WAVETERM_WORKSPACEID:-}}" \
    wsh deleteblock -b "$bid" >/dev/null 2>&1
}
