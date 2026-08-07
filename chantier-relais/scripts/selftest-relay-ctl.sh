#!/usr/bin/env bash
# selftest-relay-ctl.sh — vérifie relay-ctl.sh (même répertoire) sur un
# projet factice et un serveur tmux ISOLÉ (socket dédié « selftest-rc »).
# Ne crée/ne touche jamais une session du serveur tmux par défaut.
#
# Sortie : « ok N — description » / « FAIL N — description », compteur final.
# Exit non-zéro si au moins un échec.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELAY_CTL="$SCRIPT_DIR/relay-ctl.sh"
SOCK=selftest-rc

REAL_TMUX="$(command -v tmux 2>/dev/null)"
[ -n "$REAL_TMUX" ] || { echo "tmux introuvable — selftest impossible" >&2; exit 1; }
[ -x "$RELAY_CTL" ] || { echo "$RELAY_CTL introuvable ou non exécutable" >&2; exit 1; }

n=0; fail=0
ok() { n=$((n + 1)); echo "ok $n — $1"; }
ko() { n=$((n + 1)); fail=$((fail + 1)); echo "FAIL $n — $1" >&2; }

# --- environnement isolé -------------------------------------------------
WRAP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/selftest-rc-wrap.XXXXXX")
PROJ=$(mktemp -d "${TMPDIR:-/tmp}/selftest-rc-proj.XXXXXX")
PROJ2=$(mktemp -d "${TMPDIR:-/tmp}/selftest-rc-proj2.XXXXXX")

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1 || true
  # tmux ne supprime pas son fichier socket à kill-server — le retirer nous-
  # mêmes. Emplacement selon tmux(1) : TMUX_TMPDIR ou /tmp, PAS $TMPDIR.
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCK" 2>/dev/null || true
  rm -rf "$WRAP_DIR" "$PROJ" "$PROJ2"
}
trap cleanup EXIT

# relay-ctl.sh résout son binaire via `command -v tmux` : un wrapper sur le
# PATH qui redirige vers le socket isolé lui fait croire que c'est LE tmux.
cat > "$WRAP_DIR/tmux" <<WRAPEOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
WRAPEOF
chmod +x "$WRAP_DIR/tmux"
export PATH="$WRAP_DIR:$PATH"

rc() { "$RELAY_CTL" "$@"; }
isotmux() { "$REAL_TMUX" -L "$SOCK" "$@"; }

mkdir -p "$PROJ/execution" "$PROJ2/execution"
STATE="$PROJ/execution/STATE.md"
reset_state() { printf '# STATE — chantier factice\nNEXT: step-0.1\n' > "$STATE"; }
reset_state
printf '# STATE — chantier factice 2\nNEXT: step-0.1\n' > "$PROJ2/execution/STATE.md"

SLUG=$(basename "$PROJ" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-*$//;s/^-*//')

pane_pid() { isotmux display-message -p -t "$1" '#{pane_pid}' 2>/dev/null; }
wait_idle() {
  i=0
  while [ "$i" -lt 25 ] && pgrep -P "$(pane_pid "$1")" >/dev/null 2>&1; do
    sleep 0.2
    i=$((i + 1))
  done
}

# --- 1. l'astuce PATH → wrapper → socket isolé fonctionne ----------------
tmux new-session -d -s "wrapper-check-$$" -c "${TMPDIR:-/tmp}"
if isotmux has-session -t "wrapper-check-$$" 2>/dev/null; then
  ok "wrapper tmux (PATH) route bien vers le socket isolé $SOCK"
else
  ko "wrapper tmux (PATH) ne route pas vers le socket isolé $SOCK"
fi
isotmux kill-session -t "wrapper-check-$$" >/dev/null 2>&1 || true

# --- 2. validation de « set » ---------------------------------------------
reset_state
rc set step-1.5 --dir "$PROJ" >/dev/null 2>&1
if grep -q '^NEXT: step-1.5$' "$STATE"; then
  ok "set step-1.5 réécrit NEXT:"
else
  ko "set step-1.5 n'a pas réécrit NEXT: ($(cat "$STATE"))"
fi

reset_state
rc set PAUSE --dir "$PROJ" >/dev/null 2>&1
if grep -q '^NEXT: PAUSE$' "$STATE"; then
  ok "set PAUSE accepté"
else
  ko "set PAUSE non accepté ($(cat "$STATE"))"
fi

reset_state
rc set FIN --dir "$PROJ" >/dev/null 2>&1
if grep -q '^NEXT: FIN$' "$STATE"; then
  ok "set FIN accepté"
else
  ko "set FIN non accepté ($(cat "$STATE"))"
fi

for bad in 'step-1&/x' 'step-' 'nimportequoi'; do
  reset_state
  before=$(cat "$STATE")
  rc set "$bad" --dir "$PROJ" >/dev/null 2>&1
  code=$?
  after=$(cat "$STATE")
  if [ "$code" -ne 0 ] && [ "$before" = "$after" ]; then
    ok "set « $bad » refusé, STATE.md inchangé"
  else
    ko "set « $bad » : code=$code, STATE.md $([ "$before" = "$after" ] && echo inchangé || echo modifié)"
  fi
done

# --- 3. sélection par slug : aucune session au bon slug -------------------
# Une session d'un AUTRE projet existe sur le serveur isolé : elle ne doit
# jamais être choisie à la place d'une candidate absente pour $PROJ.
isotmux new-session -d -s "relay-autreprojet" -c "${TMPDIR:-/tmp}"

for cmd in watch exit stop; do
  out=$(rc "$cmd" --dir "$PROJ" 2>&1)
  code=$?
  if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -q 'aucune session relais'; then
    ok "$cmd refuse sans session au slug « $SLUG » (autre projet présent)"
  else
    ko "$cmd aurait dû refuser (code=$code) : $out"
  fi
done

isotmux kill-session -t "relay-autreprojet" >/dev/null 2>&1 || true

# --- 3bis. slug vide : jamais de sélection automatique ---------------------
# Un dossier sans aucun [a-z0-9] donne un slug vide ; une session « relay--… »
# (créée par le go sans slug d'un autre projet) ne doit pas être choisie.
NOSLUG="$PROJ2/____"
mkdir -p "$NOSLUG/execution"
printf '# STATE — chantier sans slug\nNEXT: step-0.1\n' > "$NOSLUG/execution/STATE.md"
isotmux new-session -d -s "relay--123456" -c "${TMPDIR:-/tmp}"
out=$(rc watch --dir "$NOSLUG" 2>&1)
code=$?
if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -q 'aucune session relais'; then
  ok "slug vide : watch refuse malgré une session relay--* présente"
else
  ko "slug vide : watch aurait dû refuser (code=$code) : $out"
fi
isotmux kill-session -t "relay--123456" >/dev/null 2>&1 || true

# --- 4. garde say/exit face à un shell nu ---------------------------------
isotmux new-session -d -s "relay-$SLUG" -c "$PROJ"
wait_idle "relay-$SLUG"

out=$(rc say hello --dir "$PROJ" 2>&1)
code=$?
if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -Eq 'refuser|aucune session Claude'; then
  ok "say refuse d'écrire dans un shell nu"
else
  ko "say aurait dû refuser (code=$code) : $out"
fi

out=$(rc exit --dir "$PROJ" 2>&1)
code=$?
if [ "$code" -ne 0 ] && printf '%s' "$out" | grep -Eq 'refuser|aucune session Claude'; then
  ok "exit refuse d'écrire dans un shell nu"
else
  ko "exit aurait dû refuser (code=$code) : $out"
fi

# --- 5. watch valide son argument -----------------------------------------
rc watch abc --dir "$PROJ" >/dev/null 2>&1
code=$?
if [ "$code" -ne 0 ]; then
  ok "watch abc refusé (nombre de lignes invalide)"
else
  ko "watch abc aurait dû être refusé (code=$code)"
fi

rc watch 5 --dir "$PROJ" >/dev/null 2>&1
code=$?
if [ "$code" -eq 0 ]; then
  ok "watch 5 accepté sur la session $SLUG"
else
  ko "watch 5 aurait dû réussir (code=$code)"
fi

isotmux kill-session -t "relay-$SLUG" >/dev/null 2>&1 || true

# --- 6. status sans session au bon slug ------------------------------------
out=$(rc status --dir "$PROJ2" 2>&1)
code=$?
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -qi 'aucune'; then
  ok "status sans session signale « aucune », exit 0"
else
  ko "status aurait dû signaler « aucune » avec exit 0 (code=$code) : $out"
fi

echo "----"
echo "selftest-relay-ctl : $n cas, $fail échec(s)"
[ "$fail" -eq 0 ] || exit 1
