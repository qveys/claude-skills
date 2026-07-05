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
  #   b. else look the spawning block (WAVETERM_BLOCKID) up in db_tab.blockids
  #      to find the tab that CURRENTLY contains it (survives block moves).
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    sessname=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_name}' 2>/dev/null || true)
    case "$sessname" in
      wave-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
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
