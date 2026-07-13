#!/usr/bin/env bash
# collect.sh — extraction DÉTERMINISTE de l'état final des sessions Claude Code.
#
# Parcourt ~/.claude/projects/*/*.jsonl et sort UNE ligne par session, champs séparés par « | » :
#   PROJET|ID8|DERNIERE_ACTIVITE|TAILLE|TYPE_DERNIERE_ENTREE|intr=N|TAG|SUJET|…FIN
#
#   TYPE_DERNIERE_ENTREE : file-history-snapshot ≈ tour terminé proprement ; autre chose = à examiner
#   intr=N               : occurrences de « Request interrupted » dans les 8 dernières lignes
#   TAG                  : HUMAIN | AUTO_SECREVIEW | SIDECHAIN
#   FIN                  : queue (~260 car.) du dernier texte assistant — la matière première du verdict
#
# Usage : collect.sh [--days N] [--project SUBSTR] [--include-sidechains]
# Ne lit JAMAIS un fichier en entier (head/tail seulement) : coût constant même sur des .jsonl de 8 Mo.
set -euo pipefail

DAYS=7
PROJECT=""
INCLUDE_SIDECHAINS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --include-sidechains) INCLUDE_SIDECHAINS=1; shift ;;
    *) echo "argument inconnu : $1" >&2; exit 2 ;;
  esac
done

PROJ_DIR="$HOME/.claude/projects"

find "$PROJ_DIR" -maxdepth 2 -name "*.jsonl" -mtime -"$DAYS" | sort | while IFS= read -r f; do
  proj=$(basename "$(dirname "$f")")
  if [ -n "$PROJECT" ]; then
    case "$proj" in *"$PROJECT"*) ;; *) continue ;; esac
  fi
  id=$(basename "$f" .jsonl | cut -c1-8)
  tag=""

  if head -c 4000 "$f" | grep -q '"isSidechain":true'; then
    [ "$INCLUDE_SIDECHAINS" = 1 ] || continue
    tag="SIDECHAIN"
  fi

  ts=$(tail -n 30 "$f" | jq -r 'select(.timestamp) | .timestamp' 2>/dev/null | tail -n 1 | cut -c1-16 || true)
  [ -n "$ts" ] || ts=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M' "$f")
  size_kb=$(( $(stat -f '%z' "$f") / 1024 ))
  ltype=$(tail -n 1 "$f" | jq -r '.type // "?"' 2>/dev/null || echo '?')
  intr=$(tail -n 8 "$f" | grep -c 'Request interrupted' || true)

  subject=$(head -n 40 "$f" \
    | jq -r 'select(.type=="user") | .message.content | if type=="string" then . else (.[]? | select(.type=="text") | .text) end' 2>/dev/null \
    | grep -v -e '^<' -e '^Caveat' -e '^\[' | head -n 1 | cut -c 1-110 || true)
  [ -n "$subject" ] || subject="(pas de sujet)"

  if [ -z "$tag" ]; then
    case "$subject" in
      "Review this change for security vulnerabilities."*) tag="AUTO_SECREVIEW" ;;
      *) tag="HUMAIN" ;;
    esac
  fi

  fin=$(tail -n 120 "$f" \
    | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' 2>/dev/null \
    | tr '\n' ' ' | sed 's/  */ /g' || true)
  fin=$(printf '%s' "$fin" | tail -c 260)
  [ -n "$fin" ] || fin="(aucun texte assistant en fin de fichier)"

  printf '%s|%s|%s|%sKo|%s|intr=%s|%s|%s|…%s\n' \
    "$proj" "$id" "$ts" "$size_kb" "$ltype" "$intr" "$tag" "$subject" "$fin"
done
