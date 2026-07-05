# wsh-cockpit hardening — plan d'exécution

Date : 2026-07-05 · Branche : `feat/wsh-cockpit-hardening` · Repo : `~/.claude/skills` (qveys/claude-skills)

## Contraintes globales (s'appliquent à CHAQUE tâche)

- **bash 3.2 macOS** : pas de `${x,,}`, pas de tableaux associatifs, pas de `local -n`. `tr` pour lowercase.
- **Chaque commit est signé** : `git commit -S`. Si la signature échoue (1Password verrouillé), STOP et remonter BLOCKED.
- Conventional Commits (`fix:`, `feat:`, `test:`, `docs:`) préfixés `wsh-cockpit:`.
- **Ne jamais casser les selftests existants** : `scripts/wsh-live.sh selftest-sep` et `scripts/wsh-step.sh selftest-step` doivent passer après chaque tâche.
- `shellcheck -S warning scripts/*.sh` : ne pas introduire de nouveau finding.
- **Aucun bloc Wave ne doit s'ouvrir pendant les tests** : ne jamais appeler `spawn` ni `open` dans un test — uniquement `start <nom-unique>` (détaché, sans UI).
- Sessions de test : préfixe `cockpit-selftest-` + `$$`, toujours détruites en fin de test (`trap`).
- Docs dans le même commit : toute nouvelle sous-commande / env var apparaît dans `SKILL.md` (et l'en-tête du script).
- Fichiers d'état : `$STATE_DIR` = `${WSH_COCKPIT_STATE_DIR:-$HOME/.cache/wsh-cockpit}`. Logs : `~/Library/Logs/wsh-cockpit/`, dir 700, fichiers 600.
- Le répertoire de travail est `~/.claude/skills/wsh-cockpit/`. Ne toucher à RIEN hors de ce dossier (sauf `.gitignore` racine, tâche 1 uniquement).

## Task 1: fix bug `local` auto-référent + hygiène shellcheck

**Bug prouvé** : `scripts/wsh-live.sh:109` — dans `local prefix="$1" pattern="cockpit-${prefix}-"`, `${prefix}` s'expanse AVANT l'assignation de `$1` → `pattern="cockpit--"` → `newest_session_for_prefix` ne matche jamais rien → le fallback de réutilisation de `spawn` est mort.

**Test RED d'abord** (doit échouer avant le fix, réussir après) — l'exécuter depuis `~/.claude/skills/wsh-cockpit` :

```bash
bash -c '
  tmux() { case "$1" in list-sessions) printf "cockpit-grok-111111\ncockpit-zed-222222\n" ;; has-session) return 0 ;; esac; }
  eval "$(sed -n "/^newest_session_for_prefix()/,/^}/p" scripts/wsh-live.sh)"
  out=$(newest_session_for_prefix grok)
  [ "$out" = "cockpit-grok-111111" ] && echo PASS || { echo "FAIL: got [$out]"; exit 1; }
'
```

**Fix exact** dans `scripts/wsh-live.sh` (fonction `newest_session_for_prefix`) :

```bash
# AVANT
  local prefix="$1" pattern="cockpit-${prefix}-" best=""
# APRÈS (deux `local` : l'expansion de $prefix doit suivre son assignation)
  local prefix="$1" best=""
  local pattern="cockpit-${prefix}-"
```

**Hygiène** (même commit) :
1. `scripts/wsh-step.sh` lignes ~272, 278, 279, 280, 283 : l'argument littéral `done` de `cmp_case` doit être quoté `'done'` (SC1010).
2. Ajouter à la racine du repo (`~/.claude/skills/.gitignore`, le créer s'il n'existe pas) la ligne `.superpowers/`.

**Vérification** : test RED→GREEN ci-dessus ; `shellcheck -S warning scripts/*.sh` ne rapporte plus SC2318 ni SC1010 (les SC2016 niveau info restent tolérés) ; les deux selftests passent.

**Commit** : `fix(wsh-cockpit): self-referential local killed spawn's prefix fallback (SC2318)`

## Task 2: journal d'audit pipe-pane

Objectif : chaque session cockpit journalise tout ce qui s'affiche dans le pane vers `~/Library/Logs/wsh-cockpit/<session>.log`, désactivable par `WSH_LIVE_LOG=0`.

**Code exact à ajouter** dans `scripts/wsh-live.sh`, après la fonction `need_session()` :

```bash
# Audit trail: pipe the pane's rendered output to a per-session log file.
# WSH_LIVE_LOG=0 disables. Best-effort by design (`|| return 0` everywhere):
# a cockpit must open even if the log dir is unwritable. pipe-pane -o is
# idempotent (only opens a pipe when none exists), so calling this on reuse
# is safe. Logs can contain whatever the pane shows — treat them as sensitive
# (dir 700 / files 600) and purge after 30 days.
audit_log_start() {
  [ "${WSH_LIVE_LOG:-1}" = "1" ] || return 0
  local sess="$1" dir f
  dir="${WSH_LIVE_LOG_DIR:-$HOME/Library/Logs/wsh-cockpit}"
  mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || return 0
  f="$dir/${sess}.log"
  ( umask 077; : >>"$f" ) 2>/dev/null || return 0
  find "$dir" -name '*.log' -type f -mtime +30 -delete 2>/dev/null || true
  tmux pipe-pane -o -t "$sess" "cat >> '$f'" 2>/dev/null || true
}
```

**Factorisation (règle de trois déjà atteinte)** : les 3 sites `tmux new-session -d -s "$SESS" \; set-option -t "$SESS" history-limit 50000 >/dev/null` (spawn, start sans nom, start nommé) sont remplacés par un appel à :

```bash
create_session() {
  tmux new-session -d -s "$1" \; set-option -t "$1" history-limit 50000 >/dev/null
  audit_log_start "$1"
}
```

(placer `create_session` juste après `audit_log_start` ; les `remember_session` restent aux sites d'appel). Dans la branche « reuse » de `spawn` (après `remember_session "$SESS"`), ajouter `audit_log_start "$SESS"` (idempotent, rattrape une session créée avant cette version).

**Test RED d'abord** (script complet, échoue avant implémentation) :

```bash
SESS="cockpit-selftest-$$"; LOG="$HOME/Library/Logs/wsh-cockpit/${SESS}.log"
trap 'scripts/wsh-live.sh stop "$SESS" >/dev/null 2>&1' EXIT
WSH_COCKPIT_AGENT=selftest scripts/wsh-live.sh start "$SESS"
WSH_COCKPIT_AGENT=selftest scripts/wsh-live.sh send 'echo AUDIT_MARK_42' "$SESS"
WSH_COCKPIT_AGENT=selftest scripts/wsh-live.sh wait-done "$SESS" 30
sleep 1
grep -q AUDIT_MARK_42 "$LOG" && echo PASS || { echo FAIL; exit 1; }
stat -f '%Lp' "$LOG" | grep -qx 600 || { echo "FAIL perms"; exit 1; }
```

**Docs** : section « Journal d'audit » dans SKILL.md (emplacement, WSH_LIVE_LOG/WSH_LIVE_LOG_DIR, rétention 30 j, caveat secrets : le log contient tout ce que le pane affiche).

**Commit** : `feat(wsh-cockpit): per-session audit log via pipe-pane`

## Task 3: état hors /tmp et hors options tmux + wait-done réactif

Trois changements dans `scripts/wsh-live.sh` :

**3a — helpers `/tmp` → `$STATE_DIR/helpers/`.** Remplacer `helper_path` :

```bash
# AVANT
helper_path()   { printf '/tmp/wsh-live-%s-%s-v%s.sh\n' "$1" "${UID:-$(id -u)}" "$2"; }
# APRÈS ($STATE_DIR est per-user : plus d'UID dans le nom, plus de tmpreaper,
# plus de pré-création possible par un autre compte local dans /tmp partagé)
helper_path()   { printf '%s/helpers/wsh-live-%s-v%s.sh\n' "$STATE_DIR" "$1" "$2"; }
```

et dans `helper_ensure`, avant l'écriture du fichier : `mkdir -p "$STATE_DIR/helpers"`. Le commentaire au-dessus de `helper_loaded` (« tmpreaper purge ») reste vrai (garde-fou), le raccourcir en « a purge of the state dir mid-session must force a re-source ».

**3b — compteur de séquence : option tmux → fichier.** Remplacer `sep_next_seq` et ses lecteurs :

```bash
seq_file() { printf '%s/seq-%s\n' "$STATE_DIR" "$(printf '%s' "$1" | tr -cs 'A-Za-z0-9_.-' '_')"; }

sep_next_seq() {
  local sess="$1" f n
  f=$(seq_file "$sess"); mkdir -p "$STATE_DIR"
  n=$(cat "$f" 2>/dev/null || true)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  printf '%s\n' "$n" >"$f"
  printf '%s\n' "$n"
}
```

- Dans `wait-done` : `target_seq=$(tmux show-option -gqv ...)` devient `target_seq=$(cat "$(seq_file "$SESS")" 2>/dev/null || true)`.
- Dans `stop` : la ligne `tmux set-option -gu "@wsh_seq_${SESS}" ...` devient `rm -f "$(seq_file "$SESS")" 2>/dev/null || true`.
- Les flags « helpers loaded » (`@wsh_sep_helpers_*`) restent des options tmux **volontairement** : c'est un état runtime qui doit mourir avec la session (un fichier survivrait à tort). Ne pas les migrer.
- Mettre à jour le commentaire de tête du bloc sep (« Per-session incremental counter lives in a tmux user option ») → fichier d'état.

**3c — `wait-done` réactif.** Remplacer la boucle à intervalle fixe 2 s : premiers polls rapides puis palier. Utiliser `SECONDS` (builtin bash, entier) pour le timeout :

```bash
  echo "waiting for send #[${target_seq}] in '${SESS}' (timeout ${TIMEOUT}s)..."
  SECONDS=0
  set -- 0.2 0.3 0.5 1
  while [ "$SECONDS" -lt "$TIMEOUT" ]; do
    pane=$(tmux capture-pane -pt "$SESS" -S -120 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g')
    if printf '%s\n' "$pane" | grep -qE "└─\\[#${target_seq}\\] exit [0-9]+"; then
      rc=$(printf '%s\n' "$pane" | grep -oE "└─\\[#${target_seq}\\] exit [0-9]+" | tail -1 | grep -oE '[0-9]+$')
      echo "done: #[${target_seq}] exit ${rc} (${SECONDS}s)"
      [ "${rc:-1}" -eq 0 ] && exit 0 || exit "${rc:-1}"
    fi
    if [ $# -gt 0 ]; then sleep "$1"; shift; else sleep 2; fi
  done
  echo "timeout: #[${target_seq}] footer not seen after ${TIMEOUT}s" >&2
  exit 124
```

(supprimer `INTERVAL`/`ELAPSED`). `sleep 0.2` fonctionne sur macOS.

**Docs** : SKILL.md mentionne `/tmp/wsh-live-step-*.sh` (~l.134) et `/tmp/wsh-live-sep-<uid>-v4.sh` (~l.364) → remplacer par `~/.cache/wsh-cockpit/helpers/wsh-live-{step,sep}-vN.sh` ; mention `@wsh_seq_<session>` (~l.371-373) → « a per-session state file under ~/.cache/wsh-cockpit/ ».

**Tests** : (1) `selftest-sep` + `selftest-step` passent ; (2) test live : `start` session jetable, deux `send`+`wait-done`, `read 40` montre `#1` puis `#2` ; le fichier `~/.cache/wsh-cockpit/seq-<sess>` contient `2` ; helper créé sous `~/.cache/wsh-cockpit/helpers/` en 600 ; `stop` supprime le fichier seq. (3) chronométrer `wait-done` d'un `send 'true'` : doit rendre la main en < 1,5 s (avant : ~2 s).

**Commit** : `feat(wsh-cockpit): state files under ~/.cache (helpers, seq) + adaptive wait-done polling`

## Task 4: sous-commande `doctor`

Nouvelle sous-commande **read-only** de `scripts/wsh-live.sh` : diagnostic complet de la chaîne cockpit. Aucune modification d'état (pas de mkdir, pas de spawn, rien).

Format de sortie, une ligne par check : `ok|warn|fail  <libellé> — <détail>` ; code retour 0 si aucun `fail`, 1 sinon. Checks dans l'ordre :

1. `tmux` présent (`command -v`) + version (`tmux -V`) — fail sinon.
2. Serveur tmux joignable (`tmux list-sessions` rc 0 ou « no server ») — warn si pas de serveur (normal à froid).
3. Sessions `cockpit-*` vivantes : nombre + pour chacune, clients attachés + âge — info via ok/warn (0 session = ok « aucune »).
4. `wsh` présent — warn sinon (mode live dégradé : pas d'auto-open).
5. `sqlite3` présent — warn sinon.
6. DB Wave lisible (`wave_db_ro`) et `resolve_live_tab` rend un tab — via `tab_describe`, afficher le nom du tab actif ; warn si échec (auto-open indisponible, attach manuel).
7. `$STATE_DIR` : existe + inscriptible (`[ -w ]`) ; fichier last-session pour l'agent courant : pointe-t-il vers une session vivante ? warn si périmé (« stale state → prochain spawn recréera »).
8. Helpers présents sous `$STATE_DIR/helpers/` avec les versions attendues (`$SEP_HELPER_VERSION`/`$STEP_HELPER_VERSION`) — ok/warn (« régénérés au prochain send »).
9. Logs d'audit : dir présent, taille totale, nombre de fichiers > 30 j (devrait être 0).
10. Optionnels : `ttyd` présent (pour `web`), `zellij` présent — ok/info, jamais fail.

Réutiliser les fonctions existantes (`wave_db_ro`, `resolve_live_tab`, `tab_describe`, `state_file`, `helper_path`) — ne pas dupliquer leur logique. Ajouter `doctor` au `usage` et à l'en-tête du script + une sous-section SKILL.md (« `doctor` — diagnostiquer un cockpit qui ne s'ouvre pas / n'affiche rien »).

**Test** : `scripts/wsh-live.sh doctor` s'exécute sans erreur (rc 0 ou 1 selon machine) ; avec `WSH_COCKPIT_STATE_DIR=/nonexistent-ro scripts/wsh-live.sh doctor` → la ligne state dir passe en warn/fail sans crash ; `doctor` ne crée AUCUN fichier (vérifier avec `find "$STATE_DIR" -newer /tmp/marker`).

**Commit** : `feat(wsh-cockpit): doctor subcommand — read-only cockpit diagnostics`

## Task 5: `selftest-live` bout-en-bout

Nouvelle sous-commande `selftest-live` de `scripts/wsh-live.sh` : exercer la boucle réelle complète sur le serveur tmux par défaut, avec une session jetable, **sans aucun bloc Wave** (jamais spawn/open).

Déroulé (chaque étape imprime `ok <étape>` ou `FAIL <étape>` + sortie ; compteur d'échecs, rc final ≠ 0 si échec) :

```
SESS="cockpit-selftest-$$"
export WSH_COCKPIT_AGENT=selftest   # isole le fichier last-session
trap : stop "$SESS" en EXIT (au cas où) + rm état selftest
1.  $0 start "$SESS"            → sortie contient SESSION=$SESS
2.  $0 send 'echo LIVE_OK_$((6*7))' "$SESS" ; $0 wait-done "$SESS" 30 → rc 0
3.  $0 read "$SESS" 40          → contient LIVE_OK_42 ET '└─[#1] exit 0'
4.  $0 send 'sh -c "exit 3" 2>&1' "$SESS" ; $0 wait-done "$SESS" 30 → rc EXACTEMENT 3
5.  $0 banner step 9.9 'selftest banner' "$SESS" ; sleep 1 ; $0 read "$SESS" 30 → contient '[9.9]'
6.  audit log: si WSH_LIVE_LOG != 0 → ~/Library/Logs/wsh-cockpit/$SESS.log contient LIVE_OK_42
7.  seq file: ~/.cache/wsh-cockpit/seq-<slug> contient 2
8.  $0 stop "$SESS"             → tmux has-session -t "$SESS" échoue ; seq file supprimé
```

Notes d'implémentation : entre send et wait-done aucun sleep nécessaire (wait-done poll) ; à l'étape 4 `wait-done` sort avec le code du process (design existant) — capturer avec `set +e`. Ajouter au `usage`, à l'en-tête, et une ligne dans SKILL.md (« après toute retouche du cœur live, lancer selftest-sep + selftest-live »).

**Test** : `scripts/wsh-live.sh selftest-live` → `selftest-live: ok` rc 0 ; le relancer aussitôt (idempotence) ; `tmux list-sessions` ne montre plus de `cockpit-selftest-*` après.

**Commit** : `test(wsh-cockpit): selftest-live — end-to-end loop on a throwaway session`

## Task 6: cockpit web via ttyd (`web`)

Prérequis : `brew install ttyd` (l'installer dans la tâche). Nouvelle sous-commande `web {start|stop|status} [session]` dans `scripts/wsh-live.sh` :

- `web start [session]` : résout la session (comme send/read), exige ttyd. Port `${WSH_WEB_PORT:-7681}`. **Lecture seule par défaut** : `ttyd -p PORT -i 127.0.0.1 <tmux-abs> attach -rt SESS` en arrière-plan (`nohup … >/dev/null 2>&1 & disown`), SANS `-W`. `WSH_WEB_WRITE=1` → ajoute `-W` à ttyd et retire le `-r` de l'attach. PID → `$STATE_DIR/web-<slug>.pid`. Si un pid vivant existe déjà pour cette session → le dire et sortir 0 (idempotent). Attendre ~1 s puis vérifier que le process écoute (`curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:PORT` → 200) sinon FAIL rc 1. Imprimer l'URL et une note : « loopback uniquement ; pour y accéder depuis le tailnet : tailscale serve (voir SKILL.md) ».
- `web stop [session]` : kill le pid du pidfile (puis rm) ; message si rien à arrêter.
- `web status [session]` : pid vivant ? port ? URL.
- tmux en **chemin absolu** dans la commande ttyd (même piège PATH que `open`).
- SKILL.md : section « Cockpit dans le navigateur » — lecture seule par défaut, WSH_WEB_WRITE=1, port, **sécurité** : bind 127.0.0.1 strict, exposition tailnet via `tailscale serve` uniquement (jamais funnel), le flux montre tout ce que montre le pane.
- `doctor` : le check ttyd existe déjà (tâche 4) — vérifier qu'il mentionne `web`.

**Test** : session jetable `start`, `web start` → curl 200 sur le port ; `web status` → running ; entrée refusée par défaut (readonly) — vérification manuelle non requise, mais confirmer que la ligne de commande ttyd générée ne contient PAS `-W` sans WSH_WEB_WRITE ; `web stop` → curl échoue, pidfile supprimé ; `stop` session.

**Commit** : `feat(wsh-cockpit): web subcommand — read-only browser view via ttyd (loopback)`

## Task 7: backend Zellij derrière une abstraction mux (exécutée par le contrôleur, pas un sous-agent)

Scope : `WSH_MUX=tmux|zellij` (défaut tmux, autodétection non — explicite). Extraire `mux_spawn/send_line/send_enter/read/has/clients/kill/attach_cmd` ; backend zellij : `attach --create-background` + `run -- $SHELL` (pane-id → `$STATE_DIR/pane-<slug>`), `action write-chars -p`/`write -p 13`, `action dump-screen --full -p` (stdout), `action list-clients` (moins l'en-tête), `kill-session`+`delete-session --force`. Gates : `selftest-sep` (inchangé), `selftest-live` DOIT passer sous `WSH_MUX=zellij` (tolérance rendu headless : wait-done déjà adaptatif). `open` : bloc Wave `exec /opt/homebrew/bin/zellij attach <sess>`. Hors scope : session groups Wave-init, GC zellij.

## Ordre d'exécution

1 → 2 → 3 → 4 (doctor) → 5 (selftest-live, gate pour la suite) → 6 (ttyd) → 7 (zellij, contrôleur).
