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
# Session ciblée : --session, ou env RELAY_SESSION, sinon la plus récente session du
# PROJET — relay-<slug>* ou cockpit-<slug>*, <slug> dérivé du nom de dossier de --dir.
# Une session dont le slug ne correspond pas au projet n'est jamais choisie d'office.
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

project_slug() {
  basename "$DIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-*$//;s/^-*//'
}

# La session du relais de CE projet, la plus récente d'abord. Pas de repli sur « la
# dernière session cockpit-* de la machine » : elle appartient presque toujours à un
# autre travail (souvent un shell distant), et y envoyer go/say/exit écrit à l'aveugle
# dans le mauvais pane. Sans candidate, on le dit et on s'arrête.
session() {
  if [ -n "$SESS" ]; then echo "$SESS"; return; fi
  slug=$(project_slug)
  # Slug vide (nom de dossier sans [a-z0-9]) : la regex matcherait les sessions
  # « relay--* » d'un autre projet sans slug — aucune sélection auto dans ce cas.
  [ -n "$slug" ] || return 1
  "$TMUX_BIN" list-sessions -F '#{session_created} #{session_name}' 2>/dev/null \
    | awk -v s="$slug" '$2 ~ "^(relay|cockpit)-" s "(-|$)"' \
    | sort -n | tail -1 | cut -d' ' -f2-
}

# tmux ne retrouve pas toujours une session par son nom juste après sa création (même
# ancré `=nom`) ; son session_id (`$N`) répond tout de suite et ne bouge plus. Toutes
# les commandes ciblent donc l'id, résolu une seule fois.
resolve_sid() {
  [ -n "${1:-}" ] || return 1
  "$TMUX_BIN" list-sessions -F '#{session_id} #{session_name}' 2>/dev/null \
    | awk -v n="$1" '$2 == n { print $1; found = 1 } END { exit !found }'
}

need_sid() {
  S=$(session)
  SID=$(resolve_sid "$S") || die "aucune session relais pour « $(project_slug) » — 'go' pour la lancer, ou --session <nom> / RELAY_SESSION"
}

pane_pid() { "$TMUX_BIN" display-message -p -t "$1" '#{pane_pid}' 2>/dev/null; }
pane_busy() { pgrep -P "$1" >/dev/null 2>&1; }

# Un shell qui déroule encore son profil compte comme occupé — laisser à une session
# fraîchement créée le temps d'arriver à son prompt (~5 s max) avant d'écrire dedans.
wait_idle() {
  i=0
  while [ "$i" -lt 25 ] && pane_busy "$(pane_pid "$1")"; do sleep 0.2; i=$((i + 1)); done
}

# Un claude tourne-t-il quelque part sous le pane ? (il peut être enfant direct
# du shell, ou petit-enfant via next.sh — pane_current_command ne suffit pas)
# Comparaison sur le basename, exacte (pas de sous-chaîne) : c'est la garde de
# say/exit, un faux positif (ex. un wrapper "claude-notify") écrirait à l'aveugle
# dans un shell nu.
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
      case "${comm##*/}" in claude) return 0 ;; esac
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
    SID=$(resolve_sid "$S") || {
      echo "session  : aucune pour « $(project_slug) » (lancer : relay-ctl.sh go --dir $DIR, ou préciser --session <nom> / RELAY_SESSION)"; exit 0
    }
    PP=$(pane_pid "$SID")
    if claude_under "$PP"; then ACT="session Claude ACTIVE"
    elif pane_busy "$PP"; then ACT="occupé (relais/commande en cours, pas de claude)"
    else ACT="au repos (prompt shell)"; fi
    echo "session  : $S — $ACT"
    echo "--- dernières lignes ---"
    "$TMUX_BIN" capture-pane -p -t "$SID" 2>/dev/null | grep -v '^$' | tail -8
    ;;
  watch)
    need_sid
    N="${TEXT:-30}"
    case "$N" in ''|*[!0-9]*) die "nombre de lignes invalide « $N » (entier attendu)" ;; esac
    "$TMUX_BIN" capture-pane -p -t "$SID" 2>/dev/null | tail -n "$N"
    ;;
  set)
    [ -r "$STATE" ] || die "pas de $STATE"
    printf '%s' "$TEXT" | grep -Eq '^step-[0-9]+(\.[0-9]+)+$|^(PAUSE|FIN)$' \
      || die "valeur invalide « $TEXT » (attendu : step-X.Y, PAUSE ou FIN)"
    tmp="$STATE.tmp.$$"
    sed "s/^NEXT:.*/NEXT: $TEXT/" "$STATE" > "$tmp" && mv "$tmp" "$STATE" && echo "✓ $(next_line)"
    ;;
  go)
    [ -x "$DIR/execution/next.sh" ] || die "pas de $DIR/execution/next.sh exécutable"
    S=$(session)
    if SID=$(resolve_sid "$S"); then
      pane_busy "$(pane_pid "$SID")" && die "le pane de $S est occupé — 'watch' pour voir, 'stop' pour interrompre d'abord"
    else
      # --session nomme la session à créer ; sinon relay-<slug du projet>-<hhmmss>.
      [ -n "$SESS" ] || [ -n "$(project_slug)" ] || die "slug de projet vide pour « $DIR » — nommer la session : --session <nom>"
      S="${SESS:-relay-$(project_slug)-$(date +%H%M%S)}"
      "$TMUX_BIN" new-session -d -s "$S" -c "$DIR" || die "création de session tmux impossible"
      SID=$(resolve_sid "$S") || die "session $S créée mais introuvable dans list-sessions"
      echo "session créée : $S"
      wait_idle "$SID"  # personne d'autre ne peut l'occuper : c'est son shell qui démarre
      pane_busy "$(pane_pid "$SID")" && die "le pane de $S reste occupé après son démarrage"
    fi
    "$TMUX_BIN" send-keys -t "$SID" -l "(cd -- $(printf %q "$DIR") && ./execution/next.sh) 2>&1"
    "$TMUX_BIN" send-keys -t "$SID" Enter
    echo "✓ relais lancé dans $S — $(next_line)"
    ;;
  say|exit)
    need_sid
    PP=$(pane_pid "$SID")
    claude_under "$PP" || die "aucune session Claude active dans $S — refuser d'écrire dans un shell"
    [ "$CMD" = exit ] && TEXT="/exit"
    [ -n "$TEXT" ] || die "texte vide"
    "$TMUX_BIN" send-keys -t "$SID" -l "$TEXT"
    "$TMUX_BIN" send-keys -t "$SID" Enter
    echo "✓ envoyé à $S : $TEXT"
    ;;
  stop)
    need_sid
    "$TMUX_BIN" send-keys -t "$SID" C-c
    echo "✓ Ctrl+C envoyé à $S"
    ;;
  *)
    sed -n '2,/^set -u/p' "$0" | sed '$d'; exit 2
    ;;
esac
