# STATE — chantier claude-cockpit-wrapper

màj : 2026-08-06 · **Étape courante : step-1.4 terminée et commitée (8a2689d), au tour de step-1.5**

NEXT: step-1.5

> Ligne lue par `execution/next.sh` — la tenir à jour en fin de CHAQUE session.
> Valeurs : `step-X.Y` · `PAUSE` (bloqué sur action humaine) · `FIN`.

## Bloqueurs actifs

- aucun.

  *(résolu 2026-08-06 : le commit signé de step-1.4 échouait en deux temps distincts.
  D'abord `1Password: failed to fill whole buffer` — le process 1Password était resté figé en
  `--just-updated --should-restart` après une mise à jour, un `quit`/`open -a` en douceur ne
  suffisait pas à le déloger ; il a fallu un `kill` dur du process bloqué puis une relance
  propre. Ensuite, une fois l'IPC rétablie, `op-ssh-sign` répondait précisément
  `1Password: No SSH private key found for the specified public key` — le vault contenant
  `id_ed25519_github_signing` n'était plus coché dans 1Password → Réglages → Développeur →
  Agent SSH après la mise à jour ; re-cocher le vault dans l'UI (action pilote) a résolu le
  point. Par ailleurs, `ssh-add -l` dans l'environnement sandboxé de l'agent pointe sur l'agent
  SSH macOS par défaut, pas sur le socket 1Password (`~/Library/Group
  Containers/2BUA8C4S2C.com.1password/t/agent.sock`) — un `ssh-add -l` négatif depuis ce
  contexte ne prouve donc rien sur l'état réel de l'agent 1Password ; seul `git commit -S` (ou
  un `ssh-add -l` visant explicitement ce socket) est un test fiable. Le commit signé a fini
  par passer avec `dangerouslyDisableSandbox` sur l'appel `git commit -S` — un sandbox par
  défaut peut couper l'IPC avec l'app 1Password même quand tout le reste (vault déverrouillé,
  clé présente) est correct.)*

## Avancement

| Étape | Titre | Modèle | Statut |
|---|---|---|---|
| 0.1 | Amender la spec (findings v11) + plan du lot + découpage en fiches | Fable | ✅ 2026-08-05 |
| 1.1 | Inventaire de réalité et mesures préalables (`ln` no-clobber, DB Wave, `sql_quote`) | Sonnet | ✅ 2026-08-05 |
| 1.2 | Primitives du claim (`lib/claim.sh`) + `selftest-claim` | Sonnet | ✅ 2026-08-06 |
| 1.3 | Registre à la création (`spawn`/`start`, `prefix-<slug>`, étape 1) | Sonnet | ✅ 2026-08-06 |
| 1.4 | Adoption étape 2 (`WSH_COCKPIT_ADOPT`, sonde, rollback) | Sonnet | ✅ 2026-08-06 |
| 1.5 | Scan étape 3 (exclusion claims, reprise legacy, `--force`) | Sonnet | ☐ |
| 1.6 | `release <session>` + keep sticky + continuité `seq` | Sonnet | ☐ |
| 1.7 | `gc` : keep épargnées, hygiène des marqueurs, `doctor` | Sonnet | ☐ |
| 1.8 | `open --tab <nom>` (requête v12, `sql_quote()`) | Sonnet | ☐ |
| 1.9 | Wrapper `claude-cockpit.sh` + `selftest-wrapper` + PATH | Sonnet | ☐ |
| 1.10 | Docs : SKILL.md, session-lifecycle, gotchas, README | Sonnet | ☐ |
| 1.11 | Audit final de cohérence spec ↔ code ↔ tests | Fable | ☐ |
| 1.12 | PR de fin de lot vers `main` (puis PAUSE : merge = pilote) | Sonnet | ☐ |

## Ordre recommandé

Strictement séquentiel 1.1 → 1.12 : 1.2 fournit les primitives à 1.3-1.7, 1.9 consomme
tout, 1.11 juge tout et peut insérer des fiches correctives `step-1.11.x` avant 1.12.
Si une mesure de 1.1 contredit un mécanisme de la spec v12 → `NEXT: PAUSE` + bloqueur
ici (arbitrage pilote) au lieu d'enchaîner.

## Journal des décisions en cours de chantier

- 2026-08-05 (contrôleur du lot 2, mise en place du relais) : chantier lancé sur la branche
  `feat/claude-cockpit-wrapper` ; les 5 findings CodeRabbit sur la spec v11 (PR #16) sont copiés
  dans `execution/findings-revue-spec-v11.md` et déclarés prérequis du plan.
- 2026-08-05 (step-0.1, Fable) : **spec amendée en v12** (changelog en tête) — les 5 findings
  intégrés : (1) primitives no-clobber nommées par transition de claim — `mv` pour la
  consommation (exclusion par disparition de la source), `ln`+`rm` pour rollback/restauration
  (destination-exclusif), consommation préalable pour le remplacement d'orphelin ; (2) `keep`
  rendu **sticky** (propriété de la session, pas du claim — adoption par défaut d'une keep =
  propriété réduite, `stop` ⇒ `release`) ; (3) requête `--tab` bornée à `WAVETERM_WORKSPACEID` ;
  (4) binding `:nom` remplacé par un échappement de littéral SQL encapsulé (`sql_quote()`,
  motivé : dot-commands sqlite3 intransportables pour un retour à la ligne) ; (5) doublons
  d'onglets départagés par `ORDER BY pinned, ord` (ordre du workspace). Plan écrit :
  `docs/plans/2026-08-05-claude-cockpit-wrapper.md`. Découpage : 12 fiches step-1.1 … step-1.12.
- 2026-08-05 (step-0.1, inventaire scout) : le socle est bien sur la branche (gardes lot 1-2
  mergées, `own_tmux_session`/`session_is_own` session.sh:81-220) ; RIEN du lot wrapper
  n'existe (ni `release`, ni claims, ni `claude-cockpit.sh`). Écarts relevés : les références
  de lignes de la spec ont dérivé de quelques lignes (ex. `SESS_DEFAULT` :163→:166,
  `mux_pane_command` :93→:104-110) — fiche 1.1 dresse la table exacte ; **`selftest-guard` :
  28 appels `report_guard_case` comptés vs « 41 cas » annoncés par CONVENTIONS.md** — à
  trancher en 1.1 (compter les cas exécutés, corriger CONVENTIONS.md ou expliquer).
- 2026-08-05 (step-1.1, Sonnet) : **aucune contradiction avec la spec v12** — voir
  `execution/rapport-step-1.1.md`. Table de références vérifiée par nom de fonction (dérives
  de numéro de ligne seulement, attendu). Absence confirmée de `release`, claim/adopt,
  `claude-cockpit.sh`. `selftest-guard` : exécution réelle en session tmux jetable →
  **41/41 cas passent** ; CONVENTIONS.md a raison, le « 28 » de step-0.1 était un
  sous-comptage préliminaire, à ne plus citer. Mesure 1 (no-clobber `ln`/`mv`) : les 4
  garanties de la spec confirmées sur APFS. Mesure 2 (DB Wave) : résolution dynamique
  `wsh wavepath data` confirmée, requête `--tab` v12 exécutée avec succès sur la DB vivante,
  `pinnedtabids` bien absent des blobs actuels ; note secondaire non bloquante — le fallback
  codé en dur de `wave_db_ro` pointe vers une DB observée à 9 jours de retard sur la DB
  vivante (renforce, sans la contredire, la prudence déjà présente dans le code). Mesure 3
  (`sql_quote()`) : prototype validé contre 5 cas hostiles (quote, `%`, retour-ligne,
  tentative d'injection, contrôle) sur DB fixture — neutralisation complète, table cible
  intacte ; piège de prototypage documenté dans le rapport (`${s//\'/\'\'}` insère des
  backslashes littéraux — passer par une variable intermédiaire). Gotcha secondaire noté :
  un point littéral dans un nom de session tmux casse le ciblage `-t`, même ancré `=` —
  cibler par `session_id` (`$N`) en remède ; sans impact sur le lot (nos noms de session
  n'ont jamais de point) mais à garder en tête pour les selftests des fiches suivantes.
  Aucun fichier de `scripts/` modifié.
- 2026-08-06 (step-1.2, Sonnet) : **`lib/claim.sh` livré** — machine d'états du claim
  (ABSENT → PRÉ-CLAIM → EN-COURS → POSSÉDÉ) encapsulée en primitives (`claim_create`,
  `claim_consume`, `claim_verify_won`, `claim_finalize`, `claim_rollback`,
  `claim_replace_orphan`, `claim_release`, `claim_key_reserved`, `claim_read_key`,
  `claim_read_pid`), invariants I1-I4 respectés (jamais de `mv` écrasant sur un claim,
  toujours O_EXCL/no-clobber ou destination-exclusif via `ln`). Décision de périmètre :
  les primitives prennent un **slug opaque** (chaîne quelconque) — la dérivation
  session-name→slug (mécanique `tr -cs 'A-Za-z0-9_.-' '_'` groupée par la spec avec
  `seq-<slug>`/`oneshot-ssh-<slug>`, spec v12 ligne ~352) est repoussée à la fiche 1.3,
  qui devra introduire le pont réel ; le rapport 1.1 ne tranchait pas cette question,
  la citation `session.sh:27,55` de la fiche 1.2 s'est révélée être les DEUX AUTRES
  normaliseurs (clé agent, préfixe) — non pertinents pour le slug de claim.
  **RED-first démontré** : sourcing de `lib/claim.sh` commenté dans `wsh-live.sh`,
  `selftest-claim` lancé en session tmux jetable → échec immédiat rc=127
  (`claim_path: command not found`) dès le cas 1a, script interrompu par `set -e` avant
  même d'atteindre les cas 2-8 — sourcing restauré, mêmes 8 cas imposés tous verts
  ensuite (`selftest-claim: all cases passed`). Bug trouvé et corrigé pendant le passage
  au vert : le cas 6 (comptage des `.stale-<pid>` résiduels) utilisait `ls glob | wc -l`
  — sous `set -euo pipefail`, un glob sans résultat fait échouer `ls` et le pipeline
  entier abandonne le script ; remplacé par une boucle `for f in glob; do [ -e "$f" ]...`
  qui tolère un glob vide. `selftest-guard` (41 cas) re-exécuté en session tmux jetable
  après coup → toujours 41/41. Gotcha tmux confirmé en pratique (déjà noté en 1.1) :
  cibler `send-keys`/`capture-pane` par nom de session fraîchement créée peut échouer
  (`can't find pane`) même ancré `-t "=nom"` juste après `new-session` — cibler par
  `session_id` (`$N`, lu via `list-sessions -F '#{session_id} #{session_name}'`) est le
  remède fiable, à réutiliser pour les selftests des fiches suivantes. Seul nouveau
  fichier de code : `scripts/lib/claim.sh` ; aucun appel `mv`/`ln` sur un claim hors de
  ce fichier ; `spawn`/`stop`/le registre-à-la-création restent intouchés (fiche 1.3).
- 2026-08-06 (step-1.3, Sonnet) : **registre à la création livré** — pont session→slug
  formalisé en fonction partagée `session_slug()` (`lib/session.sh`), consommé par
  `teardown_session` en plus des familles `seq-`/`oneshot-ssh-` déjà existantes (le
  report 1.2 avait repoussé cette décision ici). Nouvelles primitives dans
  `lib/session.sh` : `agent_claim_key()` (= `${WSH_COCKPIT_AGENT:-default}`, "ma clé" —
  tranché en relisant la spec v12 §2, la fiche seule ne le précisait pas assez),
  `prefix_file`/`prefix_write`/`prefix_read` (préfixe **enregistré, pas reparsé**,
  spec v12 §2), `claim_new_session()` (pose claim+préfixe à la création, best-effort,
  factorisée pour être appelée à l'identique par `spawn` ET `start` — évite une
  divergence des deux call sites et permet de tester la logique de pose sans passer
  par un vrai `spawn`), `find_registry_session()` (étape 1 : parmi mes sessions
  vivantes au registre, filtrage par préfixe enregistré si demandé, sinon
  last-session-si-au-registre puis unique-candidate, sinon **rc=2 explicite** si
  N>1 sans départage — jamais un (N+1)-ième cockpit silencieux). `find_reusable_session`
  devient un wrapper : étape 1 (registre) d'abord, rc=0/2 court-circuitent, rc=1
  (miss registre) retombe sur l'ancien chemin last-session/newest-for-prefix inchangé
  (sessions antérieures à 1.3, hors registre). `wsh-live.sh` : `spawn`/`start` gagnent
  un indicateur interne `--preopen` (portée à l'appel, jamais exporté — réservé au futur
  wrapper 1.9) qui lève le refus des clés réservées (`user-preopen-*`, `released`) ;
  `spawn` capture désormais le rc de `find_reusable_session` et sort en erreur explicite
  (exit 2) sur ambiguïté au lieu de retomber dessus silencieusement ; `start` refuse en
  outre un nom dont le slug collisionne avec celui d'une session vivante différente.
  Nouvelle sous-commande `selftest-adopt` (8 cas, dispatch + doc header ajoutés) :
  mélange volontaire d'appels réels en sous-processus à `start`/`stop`/`spawn` (aucun
  effet Wave — `start`/`stop` n'appellent jamais `"$0" open`, et les deux seuls appels
  réels à `spawn` testés sortent *avant* d'atteindre son chemin de création/ouverture :
  refus de clé réservée, ambiguïté registre) et d'appels directs en process aux
  primitives (`find_registry_session`, `find_reusable_session`, `prefix_write`) pour
  isoler l'étape 1 de son repli legacy quand nécessaire. **RED-first démontré** : le
  bloc de primitives ajouté à `session.sh` neutralisé via `: <<'RED_TEST_DISABLE_1_3'`,
  `selftest-adopt` lancé en session tmux jetable → échec immédiat rc=127
  (`session_slug: command not found`) dès le cas 1, bloc restauré ensuite. Bug
  trouvé et corrigé pendant le passage au vert : le cas 7 (« session créée par `start`
  inatteignable par préfixe ») utilisait d'abord le wrapper `find_reusable_session`,
  qui retombe légitimement sur `last-session` — or le vrai sous-processus `start` du
  cas 7 vient justement de réécrire cette last-session vers la session qu'on voulait
  prouver inatteignable, faussant le test ; corrigé en testant `find_registry_session`
  directement (l'étape 1 seule, sans le repli legacy). `selftest-guard` (41/41),
  `selftest-claim` (8/8), `selftest-live`, `selftest-cache` re-passés en session tmux
  jetable après coup → tous verts, aucune régression. Étapes 2 (adoption) et 3 (scan)
  restent hors périmètre, reportées à 1.4/1.5 comme prévu.
- 2026-08-06 (step-1.4, Sonnet) : **adoption étape 2 livrée** — `try_adopt_session()` et ses
  primitives (`lib/session.sh`) consomment `WSH_COCKPIT_ADOPT` (liste séparée par virgules)
  strictement via la machine d'états de `lib/claim.sh` (`claim_consume` → `claim_verify_won`
  (I2 anti-ré-armement) → sonde → `claim_finalize`/`claim_rollback`, jamais de `mv`/`ln` ad hoc
  hors de ce fichier). Garde de pane élargie pour l'adoption (`adopt_state_allowed` : shell nu
  OU `ssh`/`tailscale`/`mosh` au premier plan) — plus permissive que la garde stricte
  shell-nu utilisée ailleurs pour la réutilisation silencieuse, car une keep « libérée » a pu
  être sauteuse-ssh sans jamais repasser par `remote-init`. Sonde systématique et non
  optionnelle (`adopt_run_probe` : hostname/pwd/whoami, `WSH_LIVE_SEP_REINIT=1` forcé pour un
  cadrage inline auto-porté) : le rc de la sonde **gate** `claim_finalize` (jamais de claim
  conservé sans sonde réussie, conformément à la fiche) — décision architecturale corrigée en
  cours de session : un premier jet appelait `claim_finalize` avant la sonde, relecture littérale
  de la fiche → sonde scindée en `adopt_run_probe` (exécute + capture, aucune sortie) et
  `adopt_print_probe` (imprime la capture + auto-détection remote-init), appelées dans l'ordre
  consume → verify → pane-ready → probe → check rc → finalize → annonce. Idiome retour par
  variables globales (`ADOPT_RESULT`/`ADOPT_PROBE_OUT`/`ADOPT_PROBE_RC`, calque de
  `SESSION_OWN_CANON`) pour préserver la pureté de stdout des fonctions atteintes via `$(...)`.
  `WSH_COCKPIT_ADOPT` absent/vide ⇒ étape 2 n'existe pas du tout (rétrocompatibilité totale,
  premier `return 1` de `try_adopt_session`). `wsh-live.sh` : `spawn` câble désormais la
  résolution en 3 temps — étape 1 (`find_registry_session`) → étape 2 (`try_adopt_session`) →
  repli legacy (`find_reusable_session`), avec un indicateur `ADOPTED_NOW` qui supprime le
  message « reusing existing » (déjà annoncé par `try_adopt_session` lui-même). 8 nouveaux cas
  `selftest-adopt` (9-16, tous en appels directs en process à `try_adopt_session`/
  `adopt_state_allowed` — jamais via un vrai sous-processus `spawn`, pour éviter l'effet Wave
  `"$0" open` sur une session synthétique sans client) : adoption simple avec preuve que la
  sonde a réellement tourné (grep de `WSH_SITUATE_HOST=` dans `ADOPT_PROBE_OUT`) ; course A/B
  avec repli propre du perdant (technique du `$` suffixé, calque de `selftest-claim`) ; rollback
  sur pane occupé (`tmux ... 'exec top'` + boucle de scrutation, calque de `GUARD_BUSY`) avec
  claim restauré à l'identique ; adoptabilité d'un pane sauteuse-ssh ; refus de sa propre
  session ; avertissement une seule fois sur session offerte mais morte ; jamais d'adoption
  nominale sur préfixe non correspondant ; priorité du candidat libre sur la last-session
  résiduelle (démonstration de l'ordre réel câblé dans `spawn`, `find_reusable_session` servant
  de témoin positif du chemin legacy qui existe mais n'est jamais atteint le premier). **RED-first
  démontré** : bloc `adopt_*`/`try_adopt_session` neutralisé dans `session.sh` → cas 1-8
  toujours verts, cas 9-16 échouent immédiatement (`try_adopt_session: command not found`,
  `ADOPT_PROBE_OUT`/`ADOPT_RESULT: unbound variable`, RC=1) — preuve que les nouveaux cas
  exercent bien le nouveau code ; bloc restauré ensuite, 16/16 verts au premier essai, aucun bug
  trouvé pendant le passage au vert. Non-régression : `selftest-guard` 41/41, `selftest-claim`
  8/8, aucune session tmux ni fichier temporaire résiduel après coup. Étape 3 (scan) reste hors
  périmètre, reportée à 1.5 comme prévu.
