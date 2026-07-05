#!/usr/bin/env bash
# lib/doctor.sh — read-only diagnostic of the whole cockpit chain.
# Sourced by wsh-live.sh; not meant to be run standalone.

# Read-only diagnostic of the whole cockpit chain: 11 checks, no mkdir/touch/
# remember_session, no need_session (must run on a machine with nothing spawned
# yet). Every check that CAN fail is wrapped in `if` or ends `|| true` so a
# missing tmux/wsh/sqlite3/tmux-server never kills the script under set -e.
cmd_doctor() {
  local fails=0
  local DOC_OK DOC_WARN DOC_FAIL DOC_R
  if [ -t 1 ]; then
    DOC_OK=$(printf '\033[1;32m'); DOC_WARN=$(printf '\033[1;33m')
    DOC_FAIL=$(printf '\033[1;31m'); DOC_R=$(printf '\033[0m')
  else
    DOC_OK=""; DOC_WARN=""; DOC_FAIL=""; DOC_R=""
  fi
  doc_line() {  # $1 ok|warn|fail  $2 label  $3 detail
    local st="$1" label="$2" detail="$3" color="$DOC_R"
    case "$st" in
      ok)   color="$DOC_OK" ;;
      warn) color="$DOC_WARN" ;;
      fail) color="$DOC_FAIL"; fails=$((fails + 1)) ;;
    esac
    printf '%s%-4s%s %s — %s\n' "$color" "$st" "$DOC_R" "$label" "$detail"
  }

  local HAVE_TMUX=0
  command -v tmux >/dev/null 2>&1 && HAVE_TMUX=1

  # 0. Which mux backend this invocation drives (WSH_MUX).
  if [ "$MUX" = tmux ]; then
    doc_line ok "backend (WSH_MUX)" "tmux (référence, toutes fonctionnalités)"
  else
    doc_line warn "backend (WSH_MUX)" "zellij (expérimental — keys/audit-log/web indisponibles)"
  fi

  # 1. tmux present + version.
  local ver
  if [ "$HAVE_TMUX" -eq 1 ]; then
    ver=$(tmux -V 2>/dev/null || true)
    doc_line ok "tmux" "${ver:-present}"
  else
    doc_line fail "tmux" "introuvable — brew install tmux"
  fi

  # 2. tmux server reachable (a cold "no server" is normal, not a failure).
  if [ "$HAVE_TMUX" -eq 1 ]; then
    if tmux list-sessions >/dev/null 2>&1; then
      doc_line ok "serveur tmux" "joignable"
    else
      doc_line warn "serveur tmux" "pas de serveur actif (normal si rien n'a encore été spawné)"
    fi
  else
    doc_line warn "serveur tmux" "skip (tmux absent)"
  fi

  # 3. Live cockpit-* sessions: count + per-session attached clients / age.
  local sessions n nm cl cr when
  if [ "$HAVE_TMUX" -eq 1 ]; then
    sessions=$(tmux list-sessions -F '#{session_name}|#{session_attached}|#{session_created}' 2>/dev/null \
      | grep '^cockpit-' || true)
    if [ -z "$sessions" ]; then
      doc_line ok "sessions cockpit-*" "aucune"
    else
      n=$(printf '%s\n' "$sessions" | grep -c . || true)
      doc_line ok "sessions cockpit-*" "${n:-0} active(s)"
      while IFS='|' read -r nm cl cr; do
        [ -n "$nm" ] || continue
        when=$(date -r "$cr" '+%H:%M:%S' 2>/dev/null || printf '%s' "$cr")
        doc_line ok "  $nm" "${cl:-0} client(s) attaché(s), créée $when"
      done < <(printf '%s\n' "$sessions")
    fi
  else
    doc_line warn "sessions cockpit-*" "skip (tmux absent)"
  fi

  # 4. wsh present (needed for auto-open).
  if command -v wsh >/dev/null 2>&1; then
    doc_line ok "wsh" "présent ($(command -v wsh))"
  else
    doc_line warn "wsh" "absent (mode live dégradé : pas d'auto-open)"
  fi

  # 5. sqlite3 present (needed to read Wave's state DB).
  if command -v sqlite3 >/dev/null 2>&1; then
    doc_line ok "sqlite3" "présent ($(command -v sqlite3))"
  else
    doc_line warn "sqlite3" "absent (lecture DB Wave impossible)"
  fi

  # 6. Wave DB readable + a live tab resolves (reuses resolve_live_tab/tab_describe).
  local TAB DESC TNAME
  if TAB=$(resolve_live_tab 2>/dev/null); then
    DESC=$(tab_describe "$TAB" 2>/dev/null || true)
    TNAME="${DESC%%|*}"
    doc_line ok "Wave DB / tab actif" "${TNAME:-$TAB}"
  else
    doc_line warn "Wave DB / tab actif" "résolution impossible (auto-open indisponible — attacher à la main)"
  fi

  # 7. State dir writable + last-session for the current agent still alive.
  if [ -d "$STATE_DIR" ]; then
    if [ -w "$STATE_DIR" ]; then
      doc_line ok "state dir" "$STATE_DIR (inscriptible)"
    else
      doc_line fail "state dir" "$STATE_DIR existe mais n'est pas inscriptible"
    fi
  else
    doc_line warn "state dir" "$STATE_DIR absent (sera créé au prochain spawn/send)"
  fi
  local s SF dead
  if s=$(last_session 2>/dev/null); then
    doc_line ok "last-session (agent courant)" "$s (vivante)"
  else
    SF=$(state_file)
    if [ -f "$SF" ]; then
      dead=$(tr -d '[:space:]' <"$SF" 2>/dev/null || true)
      doc_line warn "last-session (agent courant)" "${dead:-?} (périmée → prochain spawn recréera)"
    else
      doc_line ok "last-session (agent courant)" "aucune (jamais spawné)"
    fi
  fi

  # 8. Helpers present under $STATE_DIR/helpers with the expected versions.
  local HELPER_SEP HELPER_STEP
  HELPER_SEP=$(helper_path sep "$SEP_HELPER_VERSION")
  if [ -f "$HELPER_SEP" ]; then
    doc_line ok "helper sep v$SEP_HELPER_VERSION" "$HELPER_SEP"
  else
    doc_line warn "helper sep v$SEP_HELPER_VERSION" "absent (régénéré au prochain send)"
  fi
  HELPER_STEP=$(helper_path step "$STEP_HELPER_VERSION")
  if [ -f "$HELPER_STEP" ]; then
    doc_line ok "helper step v$STEP_HELPER_VERSION" "$HELPER_STEP"
  else
    doc_line warn "helper step v$STEP_HELPER_VERSION" "absent (régénéré au prochain send)"
  fi

  # 9. Audit logs: dir present, total size, count of files older than 30 days
  # (should be 0 — audit_log_start purges on every session start).
  local LOG_DIR size old
  LOG_DIR="${WSH_LIVE_LOG_DIR:-$HOME/Library/Logs/wsh-cockpit}"
  if [ -d "$LOG_DIR" ]; then
    size=$(du -sh "$LOG_DIR" 2>/dev/null | awk '{print $1}' || true)
    old=$(find "$LOG_DIR" -name '*.log' -type f -mtime +30 2>/dev/null | wc -l | tr -d ' ' || true)
    case "$old" in ''|*[!0-9]*) old=0 ;; esac
    if [ "$old" -gt 0 ]; then
      doc_line warn "logs d'audit" "$LOG_DIR (${size:-?}), $old fichier(s) >30j (purge attendue)"
    else
      doc_line ok "logs d'audit" "$LOG_DIR (${size:-?}), 0 fichier >30j"
    fi
  else
    doc_line ok "logs d'audit" "$LOG_DIR absent (rien loggé pour l'instant)"
  fi

  # 10. Optional extras — never fail on absence, just note it.
  if command -v ttyd >/dev/null 2>&1; then
    doc_line ok "ttyd" "présent ($(command -v ttyd)) — utilisé par la sous-commande 'web'"
  else
    doc_line warn "ttyd" "absent (optionnel, requis pour la sous-commande 'web' : brew install ttyd)"
  fi
  if command -v zellij >/dev/null 2>&1; then
    doc_line ok "zellij" "présent ($(command -v zellij))"
  else
    doc_line warn "zellij" "absent (optionnel)"
  fi

  echo
  if [ "$fails" -gt 0 ]; then
    echo "doctor: $fails check(s) en échec" >&2
    exit 1
  fi
  echo "doctor: ok"
}
