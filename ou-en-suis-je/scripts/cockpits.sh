#!/usr/bin/env bash
# cockpits.sh — état RÉEL des cockpits tmux autonomes (sessions cockpit-*, relay-*,
# wave-*, selftest-*, diag-*, ou tout préfixe fourni via OEJ_TMUX_PATTERN).
# Lecture seule : list-panes/capture-pane uniquement, jamais de send-keys (réflexe read-avant-send).
# Parcourt TOUS les panes de TOUTES les fenêtres de chaque session (pas seulement le pane
# actif) : un pane non actif figé serait sinon invisible, contraire à l'objectif du script.
# Usage : cockpits.sh [N]   (N = lignes de pane à montrer, défaut 12)
#   OEJ_TMUX_PATTERN=<regex grep -E> pour restreindre/étendre le filtrage des sessions
#   (défaut : ^(cockpit|relay|wave|selftest|diag)-)
set -euo pipefail

LINES=${1:-12}
# Validation : LINES doit être un entier strictement positif (sinon `tail -n` échoue de façon cryptique).
case "$LINES" in
  ''|*[!0-9]*|0) echo "usage : cockpits.sh [N]" >&2; exit 2 ;;
esac
PATTERN="${OEJ_TMUX_PATTERN:-^(cockpit|relay|wave|selftest|diag)-}"
# Un motif ERE invalide ferait de « grep -E … || true » une liste vide silencieuse (« aucune
# session ») : on valide le motif d'emblée — grep sort avec 2 sur motif invalide, 1 sur simple
# absence de correspondance (cas normal, toléré plus bas).
rc=0
printf '' | grep -E -- "$PATTERN" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
  echo "OEJ_TMUX_PATTERN invalide (ERE) : $PATTERN" >&2
  exit 2
fi

if ! command -v tmux >/dev/null 2>&1 || ! tmux ls >/dev/null 2>&1; then
  echo "(aucun serveur tmux actif)"
  exit 0
fi

# Une seule capture de la liste : évite la course « dernière session cockpit-* disparue
# entre deux tmux ls », qui ferait tomber le script sous pipefail.
listing=$(tmux ls -F '#{session_name}|#{session_created}|#{session_attached}' 2>/dev/null \
  | grep -E -- "$PATTERN" || true)
if [ -z "$listing" ]; then
  echo "(aucune session correspondant à $PATTERN)"
  exit 0
fi

printf '%s\n' "$listing" | while IFS='|' read -r s created attached; do
  when=$(date -r "$created" '+%d/%m %H:%M' 2>/dev/null \
      || date -d "@$created" '+%d/%m %H:%M' 2>/dev/null \
      || echo "epoch $created")
  echo "=== $s (créée $when ; attached=$attached) ==="
  panes=$(tmux list-panes -s -t "$s" -F '#{window_index}.#{pane_index}|#{pane_current_command}' 2>/dev/null || true)
  if [ -z "$panes" ]; then
    echo "(session disparue entre-temps)"
    echo
    continue
  fi
  pane_count=$(printf '%s\n' "$panes" | grep -c '|' || true)
  printf '%s\n' "$panes" | while IFS='|' read -r pid pcmd; do
    if [ "$pane_count" -gt 1 ]; then
      echo "--- pane $pid ($pcmd) ---"
    fi
    tmux capture-pane -p -t "$s:$pid" 2>/dev/null | sed -e 's/[[:space:]]*$//' | grep -v '^$' | tail -n "$LINES" || true
  done
  echo
done
