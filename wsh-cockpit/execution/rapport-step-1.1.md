# Rapport — step-1.1 : inventaire de réalité et mesures préalables

Date : 2026-08-05 · Modèle : Sonnet · Base : `main` mergé dans `feat/claude-cockpit-wrapper`

Verdict global : **aucune contradiction bloquante**. Toutes les références de la spec v12
retrouvent une définition actuelle (dérive de quelques lignes seulement, comme anticipé),
les trois mesures confirment exactement les affirmations de la spec, et le décompte
`selftest-guard` corrige une inquiétude soulevée par le scout d'inventaire de step-0.1 (pas
un vrai écart). Deux observations secondaires méritent l'attention des fiches suivantes
(non bloquantes, détaillées en fin de rapport).

## 1. Table des références spec → code actuel

Vérifiées par nom de fonction (grep), pas par numéro de ligne. Racine : `wsh-cockpit/scripts/`.

| Référence spec | Fichier:ligne actuel | Note |
|---|---|---|
| `normalize_prefix` | `lib/session.sh:47` | inchangé dans son principe |
| Clé agent par défaut `"default"` | `lib/session.sh:26` | `state_file()` : `${WSH_COCKPIT_AGENT:-${WSH_COCKPIT_PREFIX:-default}}` |
| `last_session` | `lib/session.sh:36` | inchangé |
| `find_reusable_session` | `lib/session.sh:259` | dérive ~session.sh:76-89 (spec) → :259 (actuel) |
| `teardown_session` | `lib/session.sh:520-569` | fichiers supprimés : `seq_file`, `oneshot_ssh_file`, `tab_cache` (via `tab_cache_invalidate`), 6 `tmux set-option` de framing, `control_path` (ControlMaster ssh), `block_id` (via `block_id_close`), `state_file` conditionnel (si `last-session-<key>` pointait cette session) ; **`prefix-*` et `adopt-claim-*` n'y sont PAS encore nettoyés** — conforme à la spec, qui attribue explicitement cet ajout au lot 2 (§ Cycle de vie des marqueurs) |
| `mux_pane_command` | `lib/mux.sh:104` | dérive :93 (spec) → :104 (actuel) |
| `mux_list_sessions` | `lib/mux.sh:30` | inchangé dans son principe |
| `gc_should_kill` | `lib/gc.sh:21-38` | règle session attachée : `[ "$attached" = "0" ] \|\| return 1` (ligne 35) — une session avec ≥1 client attaché n'est jamais tuée |
| Commentaire « never act on uncertain state » | `lib/gc.sh:60` | littéral, present tel quel |
| `wave_db_ro` | `lib/wave.sh:23-30` | fallback codé en dur ligne 26 : `$HOME/Library/Application Support/waveterm` si `wsh wavepath data` échoue |
| `resolve_live_tab_cached` | `lib/wave.sh:107-127` | pas de `LIMIT 1` propre ; délègue à `resolve_live_tab()` (ligne 32) qui en contient un ligne 60 (fallback BLOCKID) |
| Validation tab actuelle | `lib/wave.sh:62-64, 88-90, 113-114` | `SELECT count(*) FROM db_tab WHERE oid=…` — teste l'existence seule, pas la résolution par nom (confirme le besoin de la requête v12 §4) |
| `block_id_close` | `lib/wave.sh:149-158` | inchangé dans son principe |
| `SESS_DEFAULT` | `wsh-live.sh:166` | valeur `"cockpit"` |
| Chemin `--force` de `spawn` | `wsh-live.sh:440` | `if [ "$FORCE" -eq 0 ] && SESS=$(find_reusable_session "$PREFIX")` — `--force` saute cette branche |
| `gc` en arrière-plan au spawn | `wsh-live.sh:425` | `( cmd_gc >/dev/null 2>&1 & ) \|\| true`, avant même le parsing des flags |
| `WSH_WAIT_TIMEOUT` | `wsh-live.sh:703, 1126` | pas de définition dédiée ; `${WSH_WAIT_TIMEOUT:-300}` aux deux sites (défaut 300 s confirmé) |
| `WSH_LIVE_SEP_REINIT` / probe `remote-init` | `wsh-live.sh:847` (probe), `982-986` (logique de précédence) | probe : `WSH_LIVE_SEP_REINIT=1 "$0" send 'printf "WSH_REMOTE_HOME=%s\n" "$HOME"' ...` |
| Export `WAVETERM_TABID` dans `open` | `wsh-live.sh:754` | `OUT=$(WAVETERM_TABID="$TAB" wsh run -c "$EXEC_CMD" 2>&1)` |
| Comportement `--situate` | `wsh-live.sh:213` (fonction `situate_session`), `433` (parsing flag), `458` (appel `if [ "$SITUATE" -eq 1 ]`) | confirmé aux trois sites |

Tous les écarts constatés sont des dérives de numéro de ligne (attendu, spec datée du
2026-07-27) — aucun n'invalide un mécanisme cité par la spec v12.

## 2. Absence de release/claim/wrapper

Confirmé par grep exhaustif sur `wsh-cockpit/` :
- **Sous-commande `release`** : ABSENTE de `wsh-live.sh`.
- **Code claim/adopt** (`adopt-claim-*`, fonctions `*claim*`/`*adopt*`) : ABSENT du code ;
  n'existe que dans les fiches de planification `execution/step-1.2-*` etc.
- **`claude-cockpit.sh`** : ABSENT du dépôt.

Rien à signaler — le terrain est net pour 1.2 et suivantes.

## 3. `selftest-guard` : 41 cas confirmés (pas 28)

Le comptage préliminaire de step-0.1 (« 28 appels `report_guard_case` ») sous-comptait —
probablement un grep partiel. Deux vérifications convergent :

- **Comptage statique** : les labels des cas dans `lib/selftests.sh` sont numérotés en
  continu de `1` à `41` (le cas `20` a deux sous-assertions `20a`/`20b`, comptées comme un
  seul cas numéroté — d'où 41 numéros distincts pour 84 appels `report_guard_case` au total,
  soit ~2 appels par cas, if/else réussite-échec).
- **Exécution réelle** (règle CONVENTIONS.md : mesurer, pas déduire) : `selftest-guard`
  lancé dans une session tmux **jetable** (`selftest-step1-1-<pid>`, créée par
  `new-session -d`, alimentée par `send-keys` non ancré vers un fichier de sortie, détruite
  ensuite) — **41/41 cas `ok`, `selftest-guard: all cases passed`, `DONE_RC=0`**.

**Verdict : `CONVENTIONS.md` a raison (41 cas) — aucune correction nécessaire.** Le chiffre
« 28 » de STATE.md (step-0.1) était une estimation préliminaire erronée, à ne plus citer.

## 4. Mesure 1 — primitives no-clobber (`ln`/`mv`)

Testé dans `~/.cache/wsh-cockpit/` (APFS, même filesystem que les marqueurs de claim) avec
des fichiers jetables :

| Cas | Attendu (spec) | Mesuré |
|---|---|---|
| `ln src dst` avec `dst` existant | échec EEXIST, rc≠0 | ✅ `ln: dst1: File exists`, rc=1 |
| `ln src dst` avec `dst` absent | succès | ✅ rc=0 |
| `mv -n src dst` avec `dst` existant | rc=0 **sans** déplacer (gagnant/perdant indiscernables — c'est la raison du choix de `ln` pour le rollback) | ✅ rc=0, `src` toujours présent, `dst` inchangé |
| `mv src dst` avec `src` disparue | échec ENOENT, rc≠0 | ✅ `mv: rename src4 to dst4-target: No such file or directory`, rc=1 |

Les quatre primitives du tableau « Primitives des transitions » (spec §2, v12) reposent
exactement sur ces garanties — confirmées, rien à amender.

## 5. Mesure 2 — DB Wave

Exécuté depuis un bloc Wave réel (variables d'environnement disponibles :
`WAVETERM_WORKSPACEID`, `WAVETERM_TABID`, `WAVETERM_BLOCKID`).

- `wsh wavepath data` → `<home>/.local/share/waveterm` (répertoire ; la DB vivante est
  `.../db/waveterm.db`) — résolution dynamique confirmée fonctionnelle.
- `WAVETERM_WORKSPACEID` présent et valide (`5242b696-…`), résout à un workspace réel
  (1 seul workspace, 8 tabs sur cette machine au moment du test).
- Requête v12 (§4, `:ws`/`:nom` substitués à la main) exécutée en `?mode=ro` sur la DB
  vivante : résout correctement un nom d'onglet existant (`T16` → oid attendu) et rend un
  jeu vide pour un nom absent — comportement conforme.
- `$.pinnedtabids` : **absent des blobs `db_workspace` actuels** (clé inexistante dans le
  JSON, pas juste `null`) — confirme littéralement l'affirmation de la spec ; l'union
  défensive `pinnedtabids UNION ALL tabids` de la CTE reste nécessaire par prudence (aucun
  onglet épinglé disponible pour tester le chemin `pinned=0`, mais l'absence de la clé ne
  fait pas échouer `json_each` — `SELECT` vide silencieux — donc pas de risque de plantage).

**Deux observations secondaires (non bloquantes)** :

1. **Écart avec l'affirmation « snapshot périmé pas prouvée »** (spec §4) : sur cette
   machine, à l'instant du test, `~/Library/Application Support/waveterm/db/waveterm.db`
   (le fallback codé en dur de `wave_db_ro`) a pour dernière écriture le **27 juillet
   16:36**, contre le **5 août 15:41** pour la DB vivante (`~/.local/share/waveterm/...`)
   — soit 9 jours d'écart, alors que la spec dit ne pas avoir prouvé que ce fallback est un
   « snapshot périmé ». Ceci ne contredit aucun mécanisme : la spec exige déjà la résolution
   dynamique via `wsh wavepath data` et interdit explicitement d'hériter de ce fallback pour
   `--tab` (§4, point c) — la mesure renforce cette prudence, elle ne l'invalide pas.
2. **`WAVETERM_TABID` de l'environnement absent de la DB vivante au moment du test** — ni
   par égalité d'oid, ni par recherche `LIKE` du `WAVETERM_BLOCKID` dans les blobs
   `db_tab.data`. Comportement déjà anticipé et documenté dans `lib/wave.sh:5-22`
   (`resolve_live_tab`, commentaire : « robust to a stale env ») — la requête v12 de `--tab`
   ne dépend pas de `WAVETERM_TABID` (seulement de `WAVETERM_WORKSPACEID` + nom), donc sans
   impact sur le mécanisme du lot. Signalé pour mémoire, aucune action requise en 1.1.

## 6. Mesure 3 — `sql_quote()`

Prototype (`s="${s//$q/$q$q}"` avec `q="'"`, puis enveloppe de quotes simples) testé contre
une **DB fixture** dédiée (schéma `db_workspace`/`db_tab` minimal, pour ne jamais écrire
dans la DB Wave réelle), requête passée en **un seul argument argv** à `sqlite3` (jamais de
echo/heredoc interprété), lecture `?mode=ro`.

| Nom testé | Résultat |
|---|---|
| `it's a tab` (quote simple) | ✅ résolu, littéral inerte |
| `100% done` (pourcent) | ✅ résolu, `%` inerte sous `=` (confirmé, pas un `LIKE`) |
| `multi\nligne` (retour à la ligne réel) | ✅ requête valide (rc=0), zéro ligne (aucun tab de ce nom dans la fixture) — pas d'erreur de syntaxe |
| `x'; DROP TABLE db_tab;--` (tentative d'injection) | ✅ résolu comme chaîne littérale ordinaire (matche la ligne fixture portant ce nom exact) — **aucune altération** : la table `db_tab` compte encore 4 lignes après coup |
| `T16` (contrôle) | ✅ résolu normalement |

**Bug de prototypage rencontré et corrigé en cours de mesure** : une première écriture
`s="${s//\'/\'\'}"` insérait des **backslashes littéraux** dans le remplacement
(`it\'\'s a tab`, requête cassée) au lieu de doubler proprement la quote — l'échappement
bash `\'` dans le champ *replacement* d'une substitution de paramètre n'est pas fiable ;
passer par une variable intermédiaire (`q="'"`) lève l'ambiguïté. Corrigé avant les mesures
définitives ci-dessus. **À retenir pour l'implémentation de `sql_quote()` en 1.8** : utiliser
la forme par variable, jamais `${s//\'/\'\'}` en dur.

**Verdict : le flux `sql_quote()` de la spec v12 (finding 3721135358) est validé** —
neutralisation complète, jamais d'erreur de syntaxe ni d'altération, y compris sous
tentative d'injection explicite.

## 7. Observation secondaire — gotcha tmux hors périmètre de la spec

En préparant la session tmux jetable pour la mesure du §3, un nom de session contenant un
point littéral (`selftest-step1.1-<pid>`) a cassé le ciblage `-t` de tmux : `tmux` interprète
le `.` comme séparateur fenêtre.pane même sans `:` explicite, y compris avec l'ancrage `=`
(`can't find window: selftest-step1` sur `-t "=selftest-step1.1-23695"`). Contournement
mesuré : cibler par `session_id` stable (`$N`, sans point) plutôt que par nom pour tuer une
session dont le nom contiendrait un point. **Non lié au mécanisme du lot wrapper** (les
noms de session `cockpit-<prefix>-<HHMMSS>` n'ont jamais de point) — signalé uniquement
parce que les fiches 1.2+ relanceront des selftests en sessions jetables et pourraient
retomber sur le même piège si un préfixe de test contient un point. Candidat pour
`docs/gotchas.md` si une fiche ultérieure y touche déjà.

## Conclusion

Aucun `NEXT: PAUSE`. Rien dans `scripts/` n'a été modifié (conforme au critère done).
`STATE.md` est mis à jour : statut 1.1 ✅, `NEXT: step-1.2`, correction du chiffre
« 28 » en 41 confirmé.
