#!/usr/bin/env bash
# collect.sh — extraction DÉTERMINISTE de l'état final des sessions Claude Code.
#
# Parcourt ~/.claude/projects/*/*.jsonl et sort UNE ligne par session, champs séparés par « | » :
#   PROJET|ID8|DERNIERE_ACTIVITE|TAILLE|TYPE_DERNIERE_ENTREE|intr=N|TAG|SUJET|…FIN
#   (les « | » présents dans SUJET/FIN sont remplacés par « ¦ » : les colonnes restent stables)
#
#   TYPE_DERNIERE_ENTREE : file-history-snapshot ≈ tour terminé proprement ; autre chose = à examiner
#                          (PARSE_ERROR = dernière ligne illisible par jq — ne pas juger cette session)
#   intr=N               : occurrences de « Request interrupted » dans les 8 dernières lignes
#   TAG                  : HUMAIN | AUTO_SECREVIEW | SIDECHAIN
#   FIN                  : queue (~260 car.) du dernier texte assistant — la matière première du verdict
#
# Usage : collect.sh [--days N] [--project SUBSTR] [--exclude ID8] [--include-sidechains]
# Ne lit JAMAIS un fichier en entier (head/tail seulement) : coût constant même sur des .jsonl de 8 Mo.
set -euo pipefail

DAYS=7
PROJECT=""
EXCLUDE=""
INCLUDE_SIDECHAINS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --exclude) EXCLUDE="$2"; shift 2 ;;
    --include-sidechains) INCLUDE_SIDECHAINS=1; shift ;;
    *) echo "argument inconnu : $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq est requis (brew install jq / apt install jq)" >&2; exit 3; }

PROJ_DIR="$HOME/.claude/projects"
if [ ! -d "$PROJ_DIR" ]; then
  echo "(pas de dossier $PROJ_DIR : aucune session Claude Code sur cette machine)"
  exit 0
fi

find "$PROJ_DIR" -maxdepth 2 -name "*.jsonl" -mtime -"$DAYS" | sort | while IFS= read -r f; do
  proj=$(basename "$(dirname "$f")")
  if [ -n "$PROJECT" ]; then
    case "$proj" in *"$PROJECT"*) ;; *) continue ;; esac
  fi
  id=$(basename "$f" .jsonl | cut -c1-8)
  if [ -n "$EXCLUDE" ] && [ "$id" = "$EXCLUDE" ]; then continue; fi
  tag=""

  if head -c 4000 "$f" | grep -Eq '"isSidechain":[[:space:]]*true'; then
    [ "$INCLUDE_SIDECHAINS" = 1 ] || continue
    tag="SIDECHAIN"
  fi

  ts=$(tail -n 30 "$f" | jq -r 'select(.timestamp) | .timestamp' 2>/dev/null | tail -n 1 | cut -c1-16 || true)
  [ -n "$ts" ] || ts=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M' "$f" 2>/dev/null \
                    || stat -c '%y' "$f" 2>/dev/null | cut -c1-16 | tr ' ' 'T')
  size_kb=$(( $(stat -f '%z' "$f" 2>/dev/null || stat -c '%s' "$f") / 1024 ))
  ltype=$(tail -n 1 "$f" | jq -r '.type // "?"' 2>/dev/null || echo 'PARSE_ERROR')
  intr=$(tail -n 8 "$f" | grep -c 'Request interrupted' || true)

  subject=$(head -n 40 "$f" \
    | jq -r 'select(.type=="user") | .message.content | if type=="string" then . else (.[]? | select(.type=="text") | .text) end' 2>/dev/null \
    | grep -v -e '^<' -e '^Caveat' -e '^\[' | head -n 1 | cut -c 1-110 | sed 's/|/¦/g' || true)
  [ -n "$subject" ] || subject="(pas de sujet)"

  if [ -z "$tag" ]; then
    case "$subject" in
      "Review this change for security vulnerabilities."*) tag="AUTO_SECREVIEW" ;;
      *) tag="HUMAIN" ;;
    esac
  fi

  fin=$(tail -n 120 "$f" \
    | jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' 2>/dev/null \
    | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/|/¦/g' || true)
  fin=$(printf '%s' "$fin" | tail -c 260)
  [ -n "$fin" ] || fin="(aucun texte assistant en fin de fichier)"

  printf '%s|%s|%s|%sKo|%s|intr=%s|%s|%s|…%s\n' \
    "$proj" "$id" "$ts" "$size_kb" "$ltype" "$intr" "$tag" "$subject" "$fin"
done
