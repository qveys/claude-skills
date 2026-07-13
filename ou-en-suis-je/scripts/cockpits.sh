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

# Une seule capture de la liste : évite la course « dernière session cockpit-* disparue
# entre deux tmux ls », qui ferait tomber le script sous pipefail.
listing=$(tmux ls -F '#{session_name}|#{session_created}|#{session_attached}' 2>/dev/null \
  | grep -E '^cockpit-' || true)
if [ -z "$listing" ]; then
  echo "(aucune session cockpit-* vivante)"
  exit 0
fi

printf '%s\n' "$listing" | while IFS='|' read -r s created attached; do
  when=$(date -r "$created" '+%d/%m %H:%M' 2>/dev/null \
      || date -d "@$created" '+%d/%m %H:%M' 2>/dev/null \
      || echo "epoch $created")
  echo "=== $s (créée $when ; attached=$attached) ==="
  tmux capture-pane -p -t "$s" 2>/dev/null | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n "$LINES" || true
  echo
done
