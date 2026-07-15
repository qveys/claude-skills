#!/usr/bin/env bash
# dispose.sh — enregistre le retour de Quentin sur une session du récap /ou-en-suis-je.
# Ce feedback rend les récaps suivants plus justes : une session CLOSE ne réapparaît
# plus jamais (filtrée dès collect.sh), une note ATTEND/REPRENDRE est ré-affichée.
#
# Usage : dispose.sh ID8 STATUT ["note libre"]
#   STATUT : CLOS       — ne plus jamais remonter (fait, caduc, abandonné, traité hors Claude)
#            ATTEND     — reste 🟡, la note remplace/complète le « reste à faire »
#            REPRENDRE  — reste ⏸️, la note précise quoi reprendre
#
# Les dispositions vivent HORS du repo du skill (survivent aux réinstallations) :
#   ~/.claude/ou-en-suis-je/dispositions.tsv   (ID8 <tab> STATUT <tab> date <tab> note)
set -euo pipefail

[ $# -ge 2 ] || { echo "usage : dispose.sh ID8 CLOS|ATTEND|REPRENDRE [\"note\"]" >&2; exit 2; }
case "$2" in CLOS|ATTEND|REPRENDRE) ;; *) echo "STATUT invalide : $2 (CLOS|ATTEND|REPRENDRE)" >&2; exit 2 ;; esac

DIR="$HOME/.claude/ou-en-suis-je"
mkdir -p "$DIR"
printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$(date '+%Y-%m-%d')" "${3:-}" >> "$DIR/dispositions.tsv"
echo "noté : $1 → $2${3:+ ($3)}"
