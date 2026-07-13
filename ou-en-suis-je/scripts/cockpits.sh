#!/usr/bin/env bash
# cockpits.sh — état RÉEL des cockpits tmux autonomes (sessions « cockpit-* »).
# Lecture seule : capture-pane uniquement, jamais de send-keys (réflexe read-avant-send).
# Usage : cockpits.sh [N]   (N = lignes de pane à montrer, défaut 12)
set -euo pipefail

LINES=${1:-12}

if ! command -v tmux >/dev/null 2>&1 || ! tmux ls >/dev/null 2>&1; then
  echo "(aucun serveur tmux actif)"
  exit 0
fi

count=$(tmux ls -F '#{session_name}' | grep -Ec '^cockpit-' || true)
if [ "$count" -eq 0 ]; then
  echo "(aucune session cockpit-* vivante)"
  exit 0
fi

tmux ls -F '#{session_name}|#{session_created}|#{session_attached}' | grep -E '^cockpit-' \
| while IFS='|' read -r s created attached; do
  echo "=== $s (créée $(date -r "$created" '+%d/%m %H:%M') ; attached=$attached) ==="
  tmux capture-pane -p -t "$s" 2>/dev/null | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n "$LINES" || true
  echo
done
