#!/usr/bin/env bash
# relay-ctl.sh — pilotage local ou distant d'un relais chantier-relais.
#
# Usage : relay-ctl.sh <commande> [texte] [--dir <projet>] [--session <tmux>]
#   status            NEXT, session tmux, activité, dernières lignes du pane
#   watch [n]         afficher les n dernières lignes du pane (défaut 30)
#   set <valeur>      changer NEXT: (step-X.Y | PAUSE | FIN)
#   go                (re)lancer ./execution/next.sh — refuse si le pane est occupé
#   say <texte>       taper une réponse dans la session Claude en cours — refuse si shell
#   exit              envoyer /exit (passage de relais) — refuse si shell
#   stop              envoyer Ctrl+C (interrompre relais/compte à rebours)
#
# À distance : tailscale ssh <user>@<host> '~/.claude/skills/chantier-relais/scripts/relay-ctl.sh status --dir <projet>'
# Session ciblée : --session, ou env RELAY_SESSION, sinon la plus récente cockpit-*/relay-*.
set -u

TMUX_BIN="$(command -v tmux 2>/dev/null || true)"
if [ -z "$TMUX_BIN" ]; then
  for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
    [ -x "$p" ] && TMUX_BIN="$p" && break
  done
fi
[ -z "$TMUX_BIN" ] && { echo "tmux introuvable" >&2; exit 1; }

CMD="${1:-}"; [ $# -gt 0 ] && shift
DIR=""; SESS="${RELAY_SESSION:-}"; TEXT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)     DIR="${2:?--dir exige un chemin}"; shift 2 ;;
    --session) SESS="${2:?--session exige un nom}"; shift 2 ;;
    *)         TEXT="${TEXT:+$TEXT }$1"; shift ;;
  esac
done
DIR="${DIR:-$PWD}"
STATE="$DIR/execution/STATE.md"

die() { echo "✗ $*" >&2; exit 1; }

session() {
  if [ -n "$SESS" ]; then echo "$SESS"; return; fi
  "$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null | grep -E '^(cockpit|relay)-' | tail -1
}

pane_pid() { "$TMUX_BIN" display-message -p -t "$1" '#{pane_pid}' 2>/dev/null; }
pane_busy() { pgrep -P "$1" >/dev/null 2>&1; }

# Un claude tourne-t-il quelque part sous le pane ? (il peut être enfant direct
# du shell, ou petit-enfant via next.sh — pane_current_command ne suffit pas)
claude_under() {
  ps_out=$(ps -axo pid=,ppid=,comm=)
  set_pids=" $1 "; grew=1
  while [ "$grew" = 1 ]; do
    grew=0
    while read -r pid ppid comm; do
      case "$set_pids" in *" $ppid "*) : ;; *) continue ;; esac
      case "$set_pids" in *" $pid "*) continue ;; esac
      set_pids="$set_pids$pid "
      grew=1
      case "$comm" in *claude*) return 0 ;; esac
    done <<EOF
$ps_out
EOF
  done
  return 1
}

next_line() { grep -m1 '^NEXT:' "$STATE" 2>/dev/null || echo "NEXT: (introuvable)"; }

case "$CMD" in
  status)
    [ -r "$STATE" ] || die "pas de $STATE — mauvais --dir ?"
    S=$(session); echo "projet   : $DIR"
    echo "état     : $(next_line)"
    grep -m1 '^màj' "$STATE" 2>/dev/null | sed 's/^/état     : /'
    if [ -z "$S" ] || ! "$TMUX_BIN" has-session -t "=$S" 2>/dev/null; then
      echo "session  : aucune (lancer : relay-ctl.sh go --dir $DIR)"; exit 0
    fi
    PP=$(pane_pid "$S")
    if claude_under "$PP"; then ACT="session Claude ACTIVE"
    elif pane_busy "$PP"; then ACT="occupé (relais/commande en cours, pas de claude)"
    else ACT="au repos (prompt shell)"; fi
    echo "session  : $S — $ACT"
    echo "--- dernières lignes ---"
    "$TMUX_BIN" capture-pane -p -t "$S" 2>/dev/null | grep -v '^$' | tail -8
    ;;
  watch)
    S=$(session); [ -n "$S" ] || die "aucune session relais"
    N="${TEXT:-30}"
    case "$N" in ''|*[!0-9]*) die "nombre de lignes invalide « $N » (entier attendu)" ;; esac
    "$TMUX_BIN" capture-pane -p -t "$S" 2>/dev/null | tail -n "$N"
    ;;
  set)
    [ -r "$STATE" ] || die "pas de $STATE"
    case "$TEXT" in step-*|PAUSE|FIN) : ;; *) die "valeur invalide « $TEXT » (attendu : step-X.Y, PAUSE ou FIN)" ;; esac
    tmp="$STATE.tmp.$$"
    sed "s/^NEXT:.*/NEXT: $TEXT/" "$STATE" > "$tmp" && mv "$tmp" "$STATE" && echo "✓ $(next_line)"
    ;;
  go)
    [ -x "$DIR/execution/next.sh" ] || die "pas de $DIR/execution/next.sh exécutable"
    S=$(session)
    if [ -z "$S" ] || ! "$TMUX_BIN" has-session -t "=$S" 2>/dev/null; then
      slug=$(basename "$DIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-*$//;s/^-*//')
      S="relay-${slug}-$(date +%H%M%S)"
      "$TMUX_BIN" new-session -d -s "$S" -c "$DIR" || die "création de session tmux impossible"
      echo "session créée : $S"
    fi
    PP=$(pane_pid "$S")
    pane_busy "$PP" && die "le pane de $S est occupé — 'watch' pour voir, 'stop' pour interrompre d'abord"
    "$TMUX_BIN" send-keys -t "$S" -l "(cd -- $(printf %q "$DIR") && ./execution/next.sh) 2>&1"
    "$TMUX_BIN" send-keys -t "$S" Enter
    echo "✓ relais lancé dans $S — $(next_line)"
    ;;
  say|exit)
    S=$(session); [ -n "$S" ] || die "aucune session relais"
    PP=$(pane_pid "$S")
    claude_under "$PP" || die "aucune session Claude active dans $S — refuser d'écrire dans un shell"
    [ "$CMD" = exit ] && TEXT="/exit"
    [ -n "$TEXT" ] || die "texte vide"
    "$TMUX_BIN" send-keys -t "$S" -l "$TEXT"
    "$TMUX_BIN" send-keys -t "$S" Enter
    echo "✓ envoyé à $S : $TEXT"
    ;;
  stop)
    S=$(session); [ -n "$S" ] || die "aucune session relais"
    "$TMUX_BIN" send-keys -t "$S" C-c
    echo "✓ Ctrl+C envoyé à $S"
    ;;
  *)
    sed -n '2,14p' "$0"; exit 2
    ;;
esac
