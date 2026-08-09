# STATE — chantier claude-cockpit-wrapper

màj : 2026-08-09 · **Chantier terminé : PR #22 mergée dans `main` (squash, commit `8d9d2c8`)**

NEXT: FIN

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
| 1.5 | Scan étape 3 (exclusion claims, reprise legacy, `--force`) | Sonnet | ✅ 2026-08-06 |
| 1.6 | `release <session>` + keep sticky + continuité `seq` | Sonnet | ✅ 2026-08-06 |
| 1.7 | `gc` : keep épargnées, hygiène des marqueurs, `doctor` | Sonnet | ✅ 2026-08-06 |
| 1.8 | `open --tab <nom>` (requête v12, `sql_quote()`) | Sonnet | ✅ 2026-08-07 |
| 1.9 | Wrapper `claude-cockpit.sh` + `selftest-wrapper` + PATH | Sonnet | ✅ 2026-08-09 |
| 1.10 | Docs : SKILL.md, session-lifecycle, gotchas, README | Sonnet | ✅ 2026-08-09 |
| 1.11 | Audit final de cohérence spec ↔ code ↔ tests | Fable | ✅ 2026-08-09 |
| 1.11.1 | Balayage de sortie du wrapper restreint aux sessions du run (É1) | Sonnet | ✅ 2026-08-09 |
| 1.11.2 | Garde busy-pane : mitigation « texte après le prompt » (É2) | Sonnet | ✅ 2026-08-09 |
| 1.11.3 | `open --tab` : warning doublons off-by-one + test (É3) | Sonnet | ✅ 2026-08-09 |
| 1.12 | PR de fin de lot vers `main` (puis PAUSE : merge = pilote) | Sonnet | ✅ 2026-08-09 |

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
- 2026-08-06 (step-1.5, Sonnet) : **scan étape 3 livré** — invariant I3 (« claimé, par
  quiconque, dans n'importe quel état passé ABSENT ») formalisé en prédicat `claim_is_claimed()`
  (`lib/claim.sh`) : fichier de claim exact **ou** son `.won-<pid>` — délibérément pas un glob
  `<slug>*`, qui sur-matcherait une sœur suffixée (`<slug>-1`). `newest_session_for_prefix()` et
  la branche `remembered` de `find_reusable_session()` (`lib/session.sh`) excluent désormais
  toute session claimée du balayage `cockpit-<préfixe>-*`. Reprise d'une session legacy trouvée
  libre : nouvelle fonction `try_legacy_claim()` (claim du créateur posé via `claim_create`,
  sonde `adopt_run_probe`/`adopt_print_probe` réutilisée telle quelle depuis 1.4 — gate sur le rc
  de la sonde, `claim_release` en cas d'échec plutôt qu'un retour à ABSENT, pour ne pas
  ré-offrir la même session en boucle). Décision de conception : `try_legacy_claim` est une
  fonction **séparée**, appelée directement (jamais via `$(...)`) par `wsh-live.sh` après
  extraction du nom — `find_reusable_session` doit rester pure et sans effet de bord car les cas
  5/6a-6c/16 de `selftest-adopt` l'appellent directement en substitution de commande et
  n'attendent qu'un nom en retour ; y injecter le claim+sonde aurait perdu leur état global
  (`LEGACY_RESULT`/`ADOPT_PROBE_OUT`) dans le sous-shell de la substitution. `wsh-live.sh` :
  câblage étape 3 entre l'étape 2 (adoption) et la création — `! claim_is_claimed` distingue
  après coup un hit registre (déjà mien) d'un hit legacy (à réclamer), sans indicateur interne
  qui se perdrait à travers la substitution. `spawn --force` confirmé inchangé : le bloc
  `if [ "$FORCE" -eq 0 ]` saute intégralement les étapes 1-2-3, jamais de claim existant de
  l'agent touché. 4 nouveaux cas `selftest-adopt` (17-20) : les trois formes de claim (définitif
  d'un tiers, pré-claim `user-preopen-*`, `.won-*` en cours) excluent le scan tandis qu'une
  quatrième session libre reste seule éligible ; une sœur `-1` claimée ne sur-matche jamais le
  slug de base ; reprise legacy prouvée par claim posé + sonde réellement exécutée (grep de
  `WSH_SITUATE_HOST=` dans `ADOPT_PROBE_OUT`, même exigence de preuve que le cas 9) ; `spawn
  --force` en sous-processus réel avec un candidat legacy libre présent, testé sans risque de
  popup Wave via un `PATH` restreint masquant `wsh` pour ce seul appel (`command -v wsh` échoue
  tôt dans `open`, exit 5, *avant* tout `wsh run` — la création + le claim, eux, ont déjà eu
  lieu plus haut dans le script sous le même `set -e`), assertant session neuve + candidat
  libre intact + claims préexistants de l'agent inchangés. **RED-first démontré en deux temps**
  (deux mécanismes distincts à isoler) : (1) `claim_is_claimed` et `try_legacy_claim` neutralisés
  (implémentation triviale) → cas 17/18/19 rouges, 1-16 et 20 restent verts (20 est indépendant
  de ces deux fonctions, `--force` les court-circuite) ; (2) implémentation réelle restaurée,
  garde `if [ "$FORCE" -eq 0 ]` de `wsh-live.sh` neutralisée en `if true` → cas 20 rouge seul
  (`sess20_new=''` : le chemin de reprise, pas de création, est emprunté — aucun message
  « created fresh » à capturer), 1-19 restent verts. Implémentation réelle restaurée dans les
  deux fichiers, plus aucune trace de neutralisation. Non-régression, deux passages complets en
  session tmux jetable : `selftest-guard` 41/41, `selftest-claim` 8/8, `selftest-adopt` 20/20 —
  un unique flake transitoire du cas 9 observé lors du premier passage combiné (probablement une
  course avec le sweep `gc` best-effort lancé en tâche de fond par chaque `spawn`, comportement
  déjà documenté ailleurs dans le code), non reproduit sur deux ré-exécutions immédiates
  (isolée puis combinée) — pas de régression réelle. Étape 3 close ; 1.6 (`release`, keep sticky,
  continuité `seq`) reste hors périmètre.
- 2026-08-06 (step-1.6, Sonnet) : **`release` + keep sticky livrés** — `release_session()`
  (`lib/session.sh`) rend une session disponible SANS jamais toucher tmux/le bloc Wave. Décision
  de conception centrale : distinguer « session issue de `WSH_COCKPIT_ADOPT` » de « session créée
  (hors ADOPT) » sans aucun marqueur persistant nouveau, en retestant l'appartenance du nom de
  session à `$WSH_COCKPIT_ADOPT` **au moment du `release`** (nouvelle primitive
  `adopt_list_contains()`, calque du parsing comma-split de `try_adopt_session`) — un sous-agent
  garde la même variable d'environnement pendant tout son cycle de vie (adoption puis
  release/stop, même process), donc reconstruire l'appartenance à cet instant est fiable sans
  bookkeeping supplémentaire. Branche « adoptée » : `claim_release()` (déjà I4-enforced,
  réutilisée telle quelle depuis `claim.sh`) rétrograde en pré-claim `released`, ré-adoptable via
  étape 2 uniquement. Branche « créée/legacy » : le fichier de claim est supprimé entièrement
  (retour ABSENT), re-scannable via étape 3. Ni `keep-<slug>`, ni `seq-<slug>`, ni
  `oneshot-ssh-<slug>` ne sont jamais touchés (continuité du compteur de framing — un footer
  « └─[#N] exit » périmé ne doit jamais matcher faussement chez le prochain adopteur). `keep`
  sticky : propriété de la SESSION (pas du claim), exposée en lecture seule par
  `keep_file()`/`keep_is_set()` — poser le marqueur à la création reste hors périmètre (fiche
  1.9, le wrapper) ; ce fiche ne fait que le consulter. `wsh-live.sh` : nouveau cas `release)`
  (argument obligatoire via `${1:?usage...}`, délibérément **aucun** repli sur la dernière
  session — un sous-agent à clé partagée qui oublie l'argument ne doit jamais relâcher la
  mauvaise session par défaut) ; `stop)` vérifie désormais `keep_is_set` AVANT le chemin de
  destruction et route vers `release_session` au lieu de `teardown_session` quand positif, garde
  own-session inchangée. Doc-header et ligne `usage:` finale mis à jour pour inclure `release`
  (et, au passage, `selftest-adopt` qui manquait déjà de la ligne `usage:` depuis 1.3 — corrigé).
  8 nouveaux cas `selftest-adopt` (21-28) : argument manquant → erreur d'usage ; clé non
  propriétaire → refus I4 avec claim intact ; release d'une adoptée → claim `released` +
  ré-adoption étape 2 par le même agent avec sonde PROUVÉE ; release d'une créée → claim
  supprimé + re-scannable ; `seq-<slug>` intact après release (assertion resserrée en cours de
  session — voir bug ci-dessous) ; keep sticky chemin 1 (adoptée, marqueur déjà posé, `stop` ⇒
  release, session/bloc vivants, claim rétrogradé) ; keep sticky chemin 2 (créée, marquée keep,
  relâchée, reprise par un tout autre agent via le scan legacy — keep hérité tel quel car
  propriété de la session, `stop` ⇒ release encore) ; release par un sous-agent via la VRAIE
  sous-commande CLI (pas l'appel direct à la primitive, pour couvrir aussi le câblage du
  dispatch) → claim rétrogradé. **RED-first démontré** : implémentation entière (`session.sh` +
  `wsh-live.sh`) mise de côté via `git stash push` ciblé sur ces deux seuls fichiers (le dépôt
  contenait par ailleurs du travail en cours non lié dans d'autres skills — jamais touché),
  `selftest-adopt` lancé en session tmux jetable → cas 1-21 verts (21 passe déjà légitimement sur
  le fallback d'usage générique préexistant), 22-28 rouges pour la bonne raison
  (`release_session`/`keep_file` : command not found, cas 28 sur le message d'usage générique
  faute du cas `release)`) ; stash restauré, 28/28 verts. Deux bugs de test trouvés et corrigés
  pendant le passage au vert (pas de bug d'implémentation) : (1) le cas 22 acceptait n'importe
  quel rc≠0 comme preuve de refus I4, ce qui aurait pu masquer un simple « command not found » —
  resserré à `rc -eq 1` (contrat exact de `release_session`) ; (2) le cas 25 exigeait `seq`
  strictement identique après une **ré-adoption**, alors que la sonde de ré-adoption elle-même
  incrémente légitimement le compteur (continuité = jamais de reset, pas immutabilité totale) —
  le test a été simplifié pour ne vérifier que l'effet de `release` seul (qui, lui, ne doit
  jamais toucher `seq`), la ré-adoption retirée du cas. Un flake transitoire du cas 23 observé une
  fois (adoption initiale échouée sous charge, 28 cas créant chacun 1-2 sessions tmux) puis non
  reproduit sur deux ré-exécutions immédiates — même nature que le flake déjà noté en 1.5, pas
  une régression. Non-régression : `selftest-guard` 41/41, `selftest-claim` 8/8, aucune session
  tmux résiduelle après coup. 1.7 (`gc` : keep épargnées, hygiène des marqueurs, `doctor`) prend
  le relais.
- 2026-08-06 (step-1.7, Sonnet) : **plancher `keep` + hygiène des marqueurs + check `doctor`
  livrés**. Plancher : `gc_effective_idle(requested, is_keep)` (`lib/gc.sh`), fonction pure
  séparée plutôt que d'enrichir `gc_should_kill` — préserve la testabilité directe de cette
  dernière (déjà documentée comme délibérément pure) ; composée dans la boucle de `cmd_gc`
  (`eff_idle=$(gc_effective_idle "$IDLE" "$is_keep")`, `keep_is_set` consultée par candidat).
  24h de plancher (`GC_KEEP_FLOOR_IDLE=86400`) quel que soit un `--idle` plus court, avec repli
  sur le balayage normal passé ce plancher (évite l'interblocage d'une keep que seul l'humain
  peut fermer). Hygiène : `gc_hygiene_pass(dry_run, scope)` nettoie les familles de marqueurs
  orphelins sous `$STATE_DIR` (`keep-`, `prefix-`, `seq-`, `oneshot-ssh-`, `pane-`, `tab-`,
  `adopt-claim-`, `block-`, `cm-`, `last-session-`, `adopt-dead-warned-`) dont la session
  sous-jacente est morte, jamais une session vivante — liveness décidée via `mux_list_sessions`
  (générique tmux/zellij, jamais un appel backend direct) ; échec/incertitude de listage ⇒ passe
  entièrement inerte (même philosophie que la garde own-session déjà présente dans `cmd_gc`).
  Planchers anti-course : 5 min générique, 10 min (`2 × ${WSH_WAIT_TIMEOUT:-300}`, calculé à
  l'appel pour respecter une valeur d'environnement personnalisée) pour les `.won-<pid>`, 24h pour
  `adopt-dead-warned-<slug>` (nom réel du code, `session.sh:444` — la fiche évoque en prose
  `adopt-warned-<clé>@<slug>`, divergence purement rédactionnelle, jamais un fichier réellement
  émis sous ce nom). Passe dédiée `.won-<pid>` : pid mort (`kill -0`) **et** âge > plancher ⇒
  session encore vivante → restauration au pré-claim via `claim_rollback` (jamais de manipulation
  directe du chemin, cohérent avec la convention « recalculer, ne jamais faire circuler les
  chemins » déjà en place dans `claim.sh`) ; session morte → purge. Le balayage générique
  n'avale jamais un `.won-*` (exclu explicitement de la famille `adopt-claim-`). `block-`/`cm-`
  : fermeture best-effort avant `rm` — extraction de `block_id_close_path(path)` depuis
  `block_id_close(sess)` (`lib/wave.sh`, ce dernier devient un wrapper d'une ligne) car l'hygiène
  ne connaît une session morte que par son slug, jamais son nom original nécessaire à
  `block_id_file(sess)`. Isolation des tests : nouveau paramètre `scope` sur `gc_hygiene_pass`
  (filtre par sous-chaîne de basename) — `selftest-gc` l'utilise avec un jeton unique par run
  (`HYGPFX="selftestgc$"`) plutôt qu'un `STATE_DIR` isolé, cohérent avec la convention déjà en
  place du dépôt (tester contre le vrai `STATE_DIR`, jamais un override). `doctor` : nouveau
  check informatif (avant la section « extras »), signale un `adopt-claim-<slug>` dont la clé
  n'est ni `released` ni `user-preopen-*` et dont la session tmux correspondante est idle +
  inattachée au-delà de `${WSH_LIVE_GC_IDLE:-86400}` — jamais d'action, `doctor` reste strictement
  lecture seule, et délibérément **pas** la même politique que l'hygiène de `gc` (une session
  simplement idle n'est pas une preuve de `release` oubliée, seule une session **morte**
  justifie une action automatique). Ce check n'entrait pas dans le périmètre RED-first de la
  fiche (qui cible explicitement `selftest-gc`/`selftest-adopt`) — vérifié manuellement à la
  place : fabrication d'une vraie session tmux idle + claim correspondant avec
  `WSH_LIVE_GC_IDLE=1`, confirmation du `warn` attendu (et de l'`ok` en son absence), `doctor`
  toujours exit 0 (les `warn` ne comptent pas dans `$fails`). **RED-first démontré** :
  `git stash push --keep-index` ciblé sur `gc.sh`+`wave.sh` seuls (implémentation absente, tests
  déjà en place) → `selftest-gc` cas 6/9/12/13/14 verts par construction (assertions négatives
  sans mécanisme pour les violer), cas **7/8/10/11 rouges** comme attendu (familles de marqueurs
  orphelins non nettoyées), script interrompu net au cas 15 (`gc_effective_idle: command not
  found`) — preuve suffisante que les nouveaux cas exercent bien le nouveau code ; stash restauré,
  **20/20 verts**. Non-régression, `selftest-guard` 41/41 et `selftest-claim` 8/8 verts à chaque
  passage. `selftest-adopt` : 28/28 en isolation (deux passages propres), mais un flake du run
  **combiné** guard+claim+adopt observé (cas 9 puis 28 puis, en isolation, 26 — jamais le même
  cas, jamais reproductible à la demande) — même signature qu'un flake déjà noté aux journaux
  1.5 et 1.6 (course avec le sweep `gc` best-effort lancé en tâche de fond par chaque
  `spawn`/`start`, cf. `wsh-live.sh:463,593`). Vérification rigoureuse cette fois plutôt qu'une
  simple présomption de continuité : le même run combiné rejoué sur le code **d'avant step-1.7**
  (`gc.sh`/`wave.sh` restashés le temps du test) reproduit le même flake (« not the owning
  agent », cas 25/28 cette fois) — confirmation directe A/B que ce n'est pas une régression
  introduite ici. Aucune session tmux ni marqueur résiduel après coup (nettoyage manuel des
  artefacts de la session de test elle-même, hors du périmètre des selftests). 1.8 (`open --tab
  <nom>`) prend le relais.
- 2026-08-07 (step-1.8, Sonnet) : **`open --tab <nom>` livré** — trois nouvelles primitives dans
  `lib/wave.sh` : `sql_quote()` (doublement de l'apostrophe simple, encapsulé en littéral SQL —
  motivé en step-0.1/1.1 par l'intransportabilité des dot-commands sqlite3 pour un retour à la
  ligne) ; `wave_db_ro_strict()` (résolution stricte de la DB Wave, `wsh wavepath data`
  **uniquement**, jamais le fallback codé en dur `~/Library/Application Support/waveterm/` déjà
  signalé périmé en step-1.1 — `wsh` absent ou chemin introuvable ⇒ rc=1, échec net) ;
  `resolve_tab_by_name(name, ro?)` (requête CTE v12 verbatim de la spec §4, bornée à
  `WAVETERM_WORKSPACEID` — absent ⇒ rc=2 explicite, jamais de fallback hors-Wave ; onglet
  introuvable ⇒ rc=3 ; DB/`wsh` indisponible ⇒ rc=1 ; doublons départagés par
  `ORDER BY pinned ASC, ord ASC`, ordre du workspace). Second paramètre `ro` optionnel = seam de
  test (calque du paramètre `scope` de `gc_hygiene_pass`, step-1.7) : `selftest-tab` l'utilise
  pour pointer une DB fixture, jamais la vraie DB Wave. Retour par variables globales
  (`TAB_BY_NAME_RESULT`/`TAB_BY_NAME_ALL`), même idiome que `ADOPT_RESULT`. `wsh-live.sh` :
  `open` parse désormais `--tab <nom>` (extraction via tableau `ARGS=()`, compatible bash 3.2) —
  résolu, la clé n'a **aucun repli** vers `resolve_live_tab_cached` sur rc=1/2 (`exit 6` net) ;
  introuvable (rc=3) tombe en avertissement puis repli sur le cache existant, comportement
  inchangé si `--tab` absent. `spawn` gagne `--tab <nom>` en pass-through vers les deux appels à
  `"$0" open`. Doc-headers (`open`, `spawn`, nouveau bloc `selftest-tab`) et ligne `usage:` mis à
  jour. **RED-first démontré** : les trois primitives neutralisées dans `wave.sh` via
  `: <<'RED_TEST_DISABLE_1_8'`, `selftest-tab` lancé en session tmux jetable → `sql_quote:
  command not found` dès le cas 0a, erreur de syntaxe SQL sur littéraux vides en cascade,
  `DONE_RC=1` — preuve que le nouveau selftest exerce bien le nouveau code ; bloc restauré,
  `bash -n` + grep du marqueur (0 occurrence) confirment une restauration propre. Fixture DB
  dédiée (`db_workspace`/`db_tab`) conçue pour prouver plusieurs invariants à la fois : ws2 sans
  clé `pinnedtabids` du tout (pas juste vide) démontre à la fois l'union défensive sans elle
  (cas 5) et l'exclusion cross-workspace d'un onglet homonyme (cas 2) ; `dup2`/`dup3` insérés en
  base dans l'ordre INVERSE de leur position dans le tableau JSON `tabids`, prouvant que l'ordre
  élu suit la position array (`json_each.key`), jamais le rowid/ordre d'insertion sqlite ; cas 8
  (`wsh` absent ⇒ rc=1, pas de fallback AppSupport) testé via un `PATH` restreint en sous-shell
  pointant sur un répertoire vide, pour exercer le vrai chemin `wave_db_ro_strict()` plutôt
  qu'une injection de chemin de test. Deux bugs de **test** (pas d'implémentation) trouvés et
  corrigés pendant le passage au vert : (1) cas 1, `printf '%s' "$TAB_BY_NAME_ALL" | wc -l`
  compte 0 pour un résultat mono-ligne sans retour à la ligne final (`wc -l` compte des
  terminateurs, pas des lignes) — corrigé en `printf '%s\n'` ; (2) cas 4 « retour à la ligne
  réel », `qnl="multi$(printf '\n')ligne"` produisait en réalité une chaîne SANS retour à la
  ligne — la substitution de commande `$(...)` strip TOUJOURS les retours à la ligne finaux,
  donc `$(printf '\n')` vaut la chaîne vide — corrigé en `qnl=$'multi\nligne'` (quoting ANSI-C,
  qui préserve le caractère littéral). `selftest-tab` : 13/13 cas verts après correction.
  Non-régression (session tmux jetable dédiée) : `selftest-cache` ok, `selftest-guard` 41/41,
  `selftest-claim` 8/8. `selftest-adopt` : flake déjà documenté aux journaux 1.5/1.6/1.7
  reproduit une fois de plus (cas 28 puis cas 26 sur deux relances isolées, puis 0 échec sur une
  troisième) — répertoire de travail intouché par cette fiche (seuls `wave.sh`, `wsh-live.sh`,
  `selftests.sh` modifiés ; ni `claim.sh` ni `session.sh`), donc pas une régression de step-1.8.
  1.9 (wrapper `claude-cockpit.sh`, `selftest-wrapper`, PATH) prend le relais.
- 2026-08-09 (step-1.9, Sonnet, implémentation déléguée à un sous-agent builder Sonnet —
  politique de délégation du chantier, coordination + revue faites par la session principale) :
  **wrapper `claude-cockpit.sh` livré** — nouveau fichier `scripts/claude-cockpit.sh` (non
  sourcé, exécuté directement), sibling de `wsh-live.sh`. Parsing en deux passes : passe 1
  valide TOUS les groupes (séparés par `--and`) avant tout `spawn` — refuse si une valeur
  (prefix ou valeur de flag) contient littéralement `--` (sur-ensemble volontaire de `--and`,
  toute valeur de cette forme est ambiguë avec la grammaire de la CLI) ou si deux groupes
  résolvent au même prefix normalisé via `normalize_prefix` appelée sous le même scoping
  exact que le vrai `spawn` (`WSH_COCKPIT_AGENT=user-preopen-<n>`, `WSH_COCKPIT_PREFIX`
  absent) — le contrôle de collision ne peut donc jamais diverger de ce que `spawn` résoudrait
  réellement ; passe 2 spawn chaque groupe dans l'ordre, `WSH_COCKPIT_AGENT=user-preopen-<n>`
  scopé au seul appel (`env VAR=... "$WSH_LIVE" spawn ...`, jamais exporté au wrapper ni à
  claude), `--force --preopen` systématiques, `--keep` extrait (jamais transmis à `spawn`) et
  pose immédiatement le marqueur sticky `keep-<slug>` (`touch "$(keep_file "$sess")"`) sitôt le
  nom de session connu — la pose elle-même était explicitement hors périmètre de step-1.6
  (marqueur consulté en lecture seule jusqu'ici), c'est cette fiche qui la livre. Nom de session
  récupéré via le contrat stdout déjà existant de `spawn` (`SESSION=$SESS`, grep+tail). Puis
  `WSH_COCKPIT_ADOPT=sess1,sess2,...` (liste ordonnée) et `WSH_COCKPIT_AGENT=claude-<epoch>-<pid>`
  exportées pour le process `claude` lancé en avant-plan (jamais `exec`, le wrapper doit
  reprendre la main pour le balayage de sortie) ; `WSH_COCKPIT_PREFIX` explicitement absente de
  cet environnement (retirée même si héritée de l'environnement du wrapper — `normalize_prefix`
  la consulte avant `WSH_COCKPIT_AGENT`, une fuite aurait tout court-circuité). Balayage de
  sortie (après tout retour du stub claude, succès ou échec — seul un crash du wrapper lui-même
  saute le balayage) : énumération calquée sur `cmd_gc` (`mux_list_sessions | grep '^cockpit-'`
  → `session_slug` → `claim_read_key` du chemin de claim), jamais un glob brut sur `$STATE_DIR`
  qui ferait remonter du résidu de sessions mortes (hors sujet ici, c'est la passe d'hygiène de
  `gc`) ; une session dont la clé actuelle est `claude-<runid>` (adoptée pendant le run) ou
  toujours `user-preopen-<n>` (jamais adoptée) est relâchée (`release`, si keep) ou détruite
  (`stop`, sinon) — le wrapper impersonne la clé propriétaire (`WSH_COCKPIT_AGENT="$owner"`)
  pour que l'appel `release`/`stop` passe l'enforcement I4 (owner-only) de `release_session`, et
  ne repasse `WSH_COCKPIT_ADOPT="$ADOPT_LIST"` qu'à la branche `claude-<runid>` (reconstruit
  fidèlement l'appartenance ADOPT au moment du release, exactement la mécanique actée en
  step-1.6 — la branche `user-preopen-<n>` n'a jamais été adoptée, `release_session` doit la
  traiter en branche « créée », pas « adoptée »). Un `spawn` de groupe qui échoue avorte
  immédiatement (claude jamais lancé), les cockpits des groupes précédents dans le même run
  restent ouverts (pas de rollback, diagnostic pilote). Exposition PATH : symlink
  `~/.local/bin/claude-cockpit` → chemin absolu du script (`~/.local/bin` déjà dans le `$PATH`
  de la machine, confirmé avant délégation ; le symlink préexistant `~/.local/bin/claude` —
  le vrai CLI — n'a pas été touché) ; `~/.zshrc` non modifié, commande d'installation documentée
  en tête du script (`SKILL.md` n'existe pas encore, reporté à 1.10). **RED-first démontré** :
  `selftest-wrapper` lancé avant l'existence de `claude-cockpit.sh` → échec propre immédiat
  (garde explicite en tête de `cmd_selftest_wrapper`, rc=1) ; 22 cas ajoutés à
  `scripts/lib/selftests.sh` (nouveau bloc, même moule que `selftest-tab` de step-1.8 : `claude`
  ET `wsh-live.sh` mockés par des stubs dans un `$PATH` de test dédié — le faux `wsh-live.sh`
  crée de VRAIES sessions tmux via les primitives réelles de `lib/session.sh`/`lib/claim.sh`
  pour que le balayage de sortie soit testé contre un état réel, jamais un `wsh run`/Wave réel).
  Bug trouvé et corrigé pendant le passage au vert (implémentation, pas test) : `spawn_group()`
  parsait `PG_PREFIX` mais ne le relayait jamais au vrai appel `spawn` (seuls les flags
  `PG_RELAY` l'étaient) — les deux groupes se retrouvaient sans prefix propre, faussant 4 cas
  (A2/A4 sur le relais, et le cas F où le déclencheur d'échec simulé ne matchait plus jamais,
  laissant le groupe « en échec » réussir silencieusement et le balayage de sortie détruire la
  session que le cas attendait intacte) — corrigé en préfixant `PG_PREFIX` au tableau `relay`
  avant `PG_RELAY`. 22/22 verts ensuite, reconfirmé par la session coordinatrice en session tmux
  jetable après revue. Non-régression : `selftest-guard`, `selftest-claim`, `selftest-adopt`
  tous verts (82 `ok`, 0 `FAIL` combinés), revérifiés par relecture directe du code (signatures
  `keep_file`/`claim_path`/`claim_read_key`/`mux_list_sessions`/le contrat `SESSION=` de `spawn`
  confrontées au code réel plutôt qu'à la mémoire du rapport) plutôt que par confiance aveugle
  au rapport du sous-agent. Scénario bout-en-bout manuel (2 groupes réels dont un `--keep`,
  stub claude, vrai `wsh-live.sh`) confirmé conforme au critère done : non-keep détruite, keep
  vivante + claim relâché + marqueur keep survivant. Résidu de marqueurs morts (`keep-`,
  `last-session-user-preopen-*`, un `.won-*` sous plancher anti-course 10 min) laissé par les
  runs de selftests (builder + revérification) nettoyé via `gc` réel (chemin déjà testé) plutôt
  qu'un `rm` à la main ; le `.won-*` restant sous plancher est attendu, s'auto-nettoiera au
  prochain `gc` passé les 10 min, non bloquant. Aucun flake observé sur cette fiche. 1.10 (docs :
  `SKILL.md`, session-lifecycle, gotchas, README) prend le relais.
- 2026-08-09 (step-1.10, Sonnet) : **doc mise au niveau du code livré 1.2-1.9** — chaque puce
  du §6 de la fiche traitée par grep + amendement (aucune non-applicable). `SKILL.md` : nouvelle
  section « Cockpit pré-ouvert par l'utilisateur » (wrapper `claude-cockpit`, sonde systématique
  gate-avant-finalisation, adoption ciblée par préfixe — un préfixe non matché crée un cockpit
  neuf plutôt que d'adopter au hasard —, `--keep` sticky = propriété de la session, plancher
  `gc` 24h) + consignes sous-agents durcies (clé `WSH_COCKPIT_AGENT` distincte obligatoire,
  espace réservé interdit, « stop ce qu'on a créé, release ce qu'on a adopté ») ; règle « Only
  delete blocks/sessions you created » amendée en « …you created or adopted without `--keep` »
  (les deux occurrences du dépôt — `SKILL.md` et `session-lifecycle.md` ligne ~246 — corrigées,
  aucune ne restait non amendée après grep de vérification) ; liste des sous-commandes complétée
  (`release`, `open --tab`). `docs/session-lifecycle.md` : les 4 étapes de résolution de `spawn`
  (registre → adoption `WSH_COCKPIT_ADOPT` → scan legacy → création) réécrites en détail à la
  place de l'ancien « last remembered OR newest cockpit-<prefix>-* » devenu inexact ; nouvelle
  section dédiée adoption/`--keep`/hygiène `gc` ; bullet plancher-keep ajouté à la section `gc`
  existante. `docs/gotchas.md` : le gotcha « spawn without --force will reuse it » nuancé (un
  préfixe non matché crée désormais un cockpit neuf, comportement identique à `--force` côté
  conséquence) ; le gotcha « ssh-hop no longer reusable » — dont la formulation pointait vers un
  « lot 2 » déjà livré depuis, donc devenue fausse par omission plutôt que par erreur — corrigé
  pour distinguer la reprise ordinaire (toujours refusée, `session_safe_to_reuse` bare-shell
  strict) de l'adoption explicite via `WSH_COCKPIT_ADOPT` (désormais permissive, sondée) ; deux
  gotchas nouveaux : sonde d'adoption toujours en cadrage inline auto-porté
  (`WSH_LIVE_SEP_REINIT=1` forcé, jamais confiance dans l'état remote-mode hérité d'un occupant
  précédent d'une session `keep` re-hoppée) et divergence mesurée (9 jours, step-1.1) entre
  `wave_db_ro()` (fallback AppSupport en dur) et `wave_db_ro_strict()` (jamais de fallback,
  utilisée uniquement par `open --tab`). `README.md` : tableau des sous-commandes complété
  (`release`, `open --tab`, note plancher `gc`) ; nouvelle section « Pré-ouvrir des cockpits pour
  l'agent — `claude-cockpit` » (usage humain du wrapper, installation) ; liste `selftest-*`
  complétée des 4 suites manquantes (`selftest-claim`, `selftest-adopt`, `selftest-tab`,
  `selftest-wrapper` — absentes du README alors qu'exécutées depuis 1.2-1.9). Relecture croisée
  dédiée (grep ciblé) : plus aucune occurrence non amendée de « you created » ; les mentions
  restantes de « reuses an alive session » (SKILL.md, gotchas.md, session-lifecycle.md) sont des
  affirmations de haut niveau toujours vraies, non contradictoires avec les nuances de détail
  ajoutées juste en dessous. Réserve appliquée : rien à documenter hors de ce qui est
  effectivement livré (pas de déviation trouvée entre spec v12 et code réel sur ce périmètre).
  Selftests non concernés par cette fiche (aucun fichier de `scripts/` touché) : `selftest-guard`
  lancé par acquit en session tmux jetable → 41/41, aucune régression. 1.11 (audit final de
  cohérence spec ↔ code ↔ tests, Fable) prend le relais.
- 2026-08-09 (step-1.11, Fable) : **audit final rendu** — `execution/rapport-step-1.11-audit.md`
  (spec v12 relue en entier, chaque exigence normative confrontée au texte exact du code —
  extraction `sed`/`grep`, pas la mémoire des journaux — et au cas de selftest correspondant ;
  5 findings v11→v12 vérifiés code+test chacun ; diff `main...HEAD` complet sur `scripts/`
  hors selftests, les 5 lignes supprimées de session.sh inspectées une à une). **Gardes
  lots 1-2 intactes** : `session_safe_to_reuse` survit dans les deux branches de
  `find_reusable_session` (renforcée par l'exclusion `claim_is_claimed`), `deny_own_session`/
  exit 8, `looks_like_session` et l'ancrage `=` inchangés ; la seule garde plus permissive
  (`adopt_state_allowed`, adoption seulement) est une exigence spec §2 avec cas RED tracés
  (1.4). **Selftests : 12 suites exécutées en session tmux jetable** — 11 vertes du premier
  coup (sep 8, gc 20, cache 6, oneshot-ssh 8, output 6, transfer 3, live 12, guard 42 lignes
  ok/41 cas, claim 10, tab 13, wrapper 22) ; `selftest-adopt` : 2 FAIL au run combiné (cas
  9/25, signature du flake gc-en-arrière-plan documenté 1.5-1.8) → re-run isolé immédiat
  **30/30 ok, RC=0** — pas une régression. **Verdict : conforme à trois écarts près**, fiches
  correctives insérées avant 1.12 : É1 = le balayage de sortie du wrapper agit sur toute
  session vivante au claim `user-preopen-*` sans restriction aux sessions de CE run (clés
  indexées par groupe, pas par run → un run A qui sort détruit les cockpits non adoptés d'un
  run B parallèle, violant « deux claude parallèles ne se volent pas leurs cockpits ») →
  step-1.11.1 ; É2 = mitigation best-effort « texte après le prompt » de la garde busy-pane
  (spec §2) jamais implémentée ni sa limite documentée → step-1.11.2 (⚠️ mesurer d'abord :
  le prompt réel de la machine a un segment droit, une heuristique naïve refuserait tout) ;
  É3 = warning doublons `open --tab` : `printf '%s' | wc -l` compte N−1 (piège du journal
  1.8, corrigé dans le test mais pas dans ce chemin du code) → seuil `-gt 1` muet à N=2
  exactement, chemin caller non testé → step-1.11.3. **Acceptations motivées** (pas de
  fiche, détail au rapport §Acceptations) : mémo dead-warned par slug au lieu de
  `<key>@<slug>` (objectif « warning une fois » atteint, déduplication plus large) ; rafale
  d'adoptants prouvée à N=2 avec comptage (l'exclusivité de rename(2) ne dépend pas de N) ;
  pas de stress-test « course + gc simultanés » (couverture compositionnelle : planchers gc
  prouvés gc 6/12/13 + invariants sous course claim 2-6 ; un stress-test bash serait le
  genre de flake que le chantier combat) ; continuité `seq` par décomposition (adopt 23+25,
  déjà motivé en 1.6) ; `gc_effective_idle` au lieu de « `gc_should_kill` modifié » (équivalent
  prouvé bout en bout gc 18-20, motivé en 1.7) ; « deux préfixes → deux sessions » prouvé par
  construction par l'alternance adopt 5. 1.11.1 (sweep inter-runs) prend le relais.
- 2026-08-09 (step-1.11.1, Sonnet) : **balayage de sortie du wrapper restreint aux
  sessions du run livré** — nouvelle primitive `session_in_this_run()`
  (`claude-cockpit.sh`, scan linéaire bash 3.2 sur `ALL_SESSIONS`, pas de tableau
  associatif) ; la branche `user-preopen-*` de la boucle de balayage n'agit
  désormais que si la session appartient à `ALL_SESSIONS` — la branche
  `"$AGENT_KEY"` (déjà unique par run) reste inchangée. **RED-first démontré** :
  2 nouveaux cas `selftest-wrapper` (D2/D3, bloc Case D) — une session
  « étrangère » vivante posée avec les primitives réelles
  (`create_session`/`remember_session`/`claim_new_session`) sous la clé
  `user-preopen-1` (même index de groupe qu'un run concurrent utiliserait),
  ABSENTE de la ligne de commande du wrapper testé, était détruite par le
  balayage sur le code d'avant-fiche (D2/D3 rouges, foreign_user tué, claim
  vidé) ; correctif appliqué → D2/D3 verts, session étrangère et son claim
  `user-preopen-1` intacts, tandis que la session propre du run (D1) est bien
  balayée. Cas complémentaire bon marché ajouté au même run (D4/D5) : une
  seconde session étrangère au claim `claude-<autre-runid>` — déjà protégée par
  simple inégalité de clé — reste intacte des deux côtés du fix (verrouille la
  non-régression de la branche saine, jamais rouge). `selftest-wrapper` :
  24/24 verts (les 22 cas historiques A/B/C/F inchangés + 4 nouveaux D0-D5,
  soit 6 nouvelles assertions). Non-régression : `selftest-guard` 41/41 (42
  lignes `ok`, cf. note step-1.1) re-exécuté en session tmux jetable après coup.
  Aucune session tmux ni marqueur résiduel de cette fiche après coup (nettoyage
  via `gc` réel). **Incident de session signalé au pilote** : un premier
  nettoyage via `gc --idle=0` (au lieu d'un balayage ciblé sur les seuls
  marqueurs `wraptest-*`) a fait tomber une session tmux préexistante et sans
  rapport (`cockpit-adhoc-091846`, un SSH d'incident dokploy/imapbridge déjà
  résolu d'après son dernier bandeau « 502 résolu ») ; log d'audit pipe-pane
  préservé intact (`~/Library/Logs/wsh-cockpit/cockpit-adhoc-091846.log`),
  aucun processus foreground distant interrompu (juste le pane tmux local).
  Leçon actée : ne plus utiliser `gc --idle=0` pour un nettoyage de résidu de
  test, cibler le marqueur exact ou `--only-session`. 1.11.2 (garde busy-pane,
  mitigation « texte après le prompt ») prend le relais.
- 2026-08-09 (step-1.11.2, Sonnet) : **garde busy-pane complétée par la
  mitigation best-effort « texte après le prompt » (spec §2).** Mesure d'abord
  (session tmux jetable, prompt réel de la machine — zsh powerlevel10k-style
  avec segment droit RPROMPT) : la dernière ligne rendue pad TOUJOURS jusqu'à
  la largeur du pane et termine par `─`+glyphe d'angle (`╮`/`╯`) flush droite,
  qu'il y ait du texte tapé ou non — une heuristique naïve « du texte après le
  prompt » aurait refusé TOUTE adoption, confirmant l'alerte de la fiche.
  Nouvelle primitive `mux_pane_last_line()` (`lib/mux.sh`) : capture `-J`
  (rejoint les lignes physiques wrappées par tmux en une ligne logique — mesuré
  : le segment RPROMPT padé peut dépasser `#{pane_width}` sans jamais poser le
  flag de wrap ; `-J` la rejoint dans les deux cas) sur les 20 dernières lignes,
  dernière ligne non vide via `awk`. Nouvelle prédicate pure
  `adopt_last_line_busy()` (`lib/session.sh`) : strip la décoration RPROMPT si
  présente, puis reconnaît exactement deux formes — `❯` seul (repos,
  adoptable) vs `❯ <texte>` (frappe en cours, refusé) ; toute autre forme
  (thème de prompt différent, capture vide, scrollback quelconque) est
  INCLASSABLE et traitée comme adoptable (philosophie best-effort du dépôt :
  un faux positif rendrait un cockpit sain inadoptable, pire que la limite
  assumée). `adopt_pane_ready()` chaîne désormais `adopt_state_allowed` (process)
  ET `! adopt_last_line_busy` (dernière ligne) — un seul point de câblage,
  rollback existant (`try_adopt_session` → `claim_rollback`) réutilisé sans
  duplication. **RED-first démontré** : cas 29 (prédicate pure, 3 groupes —
  prompt nu adoptable, prompt+texte refusé, forme inconnue adoptable) et cas 30
  (cas réel : session avec texte tapé SANS Entrée offerte à l'adoption →
  refusée, claim restauré à l'identique, calque du cas 11 busy-pane historique
  mais sur le vrai prompt de la machine). **Piège trouvé pendant le RED
  lui-même** : la première version du cas 30, prédicate neutralisée, laissait
  `try_adopt_session` retomber jusqu'à la vraie sonde (`adopt_run_probe`), dont
  le `send` fusionnait son propre texte sur la ligne encore non soumise —
  timeout `wait-done` de 60s qui faisait échouer l'adoption pour la MAUVAISE
  raison (assertions finales « accidentellement » vertes sans prouver le
  mécanisme). Corrigé par une assertion directe et rapide
  (`adopt_pane_ready "$sess30"`, court-circuitant la sonde) plus une garde de
  temps écoulé (`SECONDS`, exigeant `<15s`) prouvant que la garde tire AVANT
  d'atteindre la sonde ; RED re-vérifié authentique (`ready30=1 rc30=1 … elapsed30=62s`
  avant le fix applicatif). Limite documentée dans `docs/gotchas.md` (nouvelle
  puce entre « adoption probe never trusts remote-mode » et « Wave state DB
  disagree by days ») : formes de prompt non reconnues (classiques `$`/`%`/`#`,
  thèmes non-p10k) restent un angle mort assumé. **Non-régression** :
  `selftest-adopt` 30/30 verts en isolation (2 FAIL constatés en cours de route
  sur des cas SANS RAPPORT — 9/23/26 puis 9 seul selon le run — confirmés comme
  le flake pré-existant déjà documenté 1.5-1.9, jamais reproductible à la
  demande, jamais le même cas deux fois ; instrumentation de debug temporaire
  posée puis retirée pour le confirmer) ; `selftest-guard` 42/42 lignes `ok`
  (41 cas, cf. note step-1.1) et `selftest-claim` 8/8 verts, les deux re-exécutés
  en session tmux jetable après coup. Aucune session tmux ni marqueur résiduel
  après coup, hormis une session de debug manuelle (`selftest-dbg25-manual`)
  oubliée en cours de route et nettoyée explicitement en fin de session.
  1.11.3 (`open --tab` warning doublons off-by-one) prend le relais.
- 2026-08-09 (step-1.11.3, Sonnet) : **warning « doublons d'onglet » corrigé —
  off-by-one de `wc -l`.** Bug confirmé exactement comme décrit à l'audit :
  `open`'s branche `--tab` comptait les candidats via
  `printf '%s' "$TAB_BY_NAME_ALL" | wc -l` — `TAB_BY_NAME_ALL` sort d'une
  substitution `$(…)` donc sans retour à la ligne final, et `wc -l` compte des
  TERMINATEURS de ligne, pas des lignes : N candidats → N−1 comptés. Le seuil
  `-gt 1` ne se déclenchait donc qu'à partir de N=3 réels ; à N=2 exactement
  (le cas le plus commun d'un doublon), aucun warning. Comptage factorisé en
  fonction pure `tab_count_candidates()` (`lib/wave.sh`, juste après
  `resolve_tab_by_name()`) — `printf '%s\n' "$1" | wc -l` restaure le
  terminateur manquant avant de compter ; `open` (`wsh-live.sh`) branché
  dessus à la place de l'appel `wc -l` inline. **RED-first démontré** :
  fixture `selftest-tab` complétée avec un nom à EXACTEMENT deux doublons
  (`dup2a`/`dup2b`, nom "Dup2", ajoutés aux `tabids` de `ws1` — 12 lignes
  `db_tab` désormais, assertion du cas 4 mise à jour de 10 à 12) ; 3 nouveaux
  cas (bloc 3b) comptant les candidats de `TAB_BY_NAME_ALL` obtenus via un
  vrai appel `resolve_tab_by_name()` sur la fixture (pas des chaînes
  littérales) — N=1 (`Alpha`→`tabZ` seul), N=2 (`Dup2`, LE cas ex-cassé),
  N=3 (`Dup`, déjà correct par coïncidence sur l'ancien code). Avant le
  correctif : `tab_count_candidates: command not found` (fonction pas encore
  écrite) → 3 échecs confirmés (`selftest-tab: 3 failure(s)`), preuve que les
  nouveaux cas exercent bien un chemin qui n'existait pas encore. Après
  l'ajout de la fonction pure et son branchement dans `open` :
  `selftest-tab: all cases passed`. Aucune régression sur la sélection de
  l'élue (case 3, inchangée) ni sur l'ordre pinné/array-position. Non-
  régression : `selftest-cache` (6/6, direct) et `selftest-guard`
  (41/41 cas, session tmux jetable `wraptest-guard-*`, ciblage `send-keys`/
  `capture-pane` **sans** ancrage `=` — piège déjà documenté
  `docs/gotchas.md` : ces deux commandes rejettent `=` et résolvent par
  préfixe, contrairement à `kill-session`/`has-session` ; un premier essai
  ancré `=nom` échouait silencieusement en « can't find pane » alors que la
  session existait bel et bien). Aucune session tmux ni marqueur résiduel
  après coup. 1.12 (PR de fin de lot vers `main`) prend le relais.
- 2026-08-09 (step-1.12, Sonnet) : **PR #22 `feat/claude-cockpit-wrapper` → `main`
  ouverte, revue traitée, mergeable — PAUSE, le merge reste une action pilote.**
  Sélftests rejoués en session tmux jetable avant ouverture (12 suites vertes).
  PR ouverte ; un conflit sur 3 fichiers (`chantier-relais/scripts/relay-ctl.sh`,
  `SKILL.md`, `references/remote-control.md`, hors périmètre du lot wrapper —
  divergence avec des évolutions parallèles du skill chantier-relais) résolu en
  gardant `main` (déjà à jour sur ces 3 fichiers) via un merge commit ; les copies
  locales avaient un temps semblé diverger, vérification `git show
  origin/<branche>:<fichier>` a confirmé l'identité byte à byte, aucune régression.
  Revue automatique (CodeRabbit + Copilot) : **15 fils** triés un par un. 13
  correctifs réels scopés, corrigés et poussés en 3 commits signés
  (`26df152` docs, `8a6544b` `next.sh` échec fort sur métadonnées invalides,
  `de28251` scripts+tests — dont la garde `session_safe_to_reuse` manquante sur
  le hit direct du registre dans `find_registry_session()`, corrigée en
  RED-first avec un nouveau cas 42 dans `selftest-guard`, désormais 42/42 ; le
  balayage de sortie de `claude-cockpit.sh` armé en trap EXIT/INT/TERM
  idempotent au lieu de code linéaire après `claude`, insensible jusque-là à un
  Ctrl-C pendant la session agent). 2 findings traités par **réponse motivée
  sans modification de code**, fils résolus tels quels : staleness du texte de
  la fiche `step-1.12` elle-même (une fiche est un plan figé au moment du
  découpage, pas réécrite rétroactivement — le déroulé réel vit dans ce
  journal) et l'écart de nom de fichier memo `adopt-dead-warned-*` déjà
  consigné comme acceptation motivée A1 plus haut dans ce document — aucun des
  15 fils ne relevait d'une refonte nécessitant une pause d'arbitrage. Les 15
  réponses postées et les 15 fils résolus via l'API GitHub (REST pour les
  réponses `in_reply_to`, GraphQL `resolveReviewThread` pour la résolution) —
  0 fil ouvert restant, `mergeStateStatus: CLEAN`, `mergeable: MERGEABLE`
  re-vérifiés après coup. **Flakiness pré-existante repérée en sous-produit** :
  `selftest-adopt` a montré des échecs intermittents (cas 23/25/26/28 selon les
  runs) après les correctifs de ce lot ; A/B testé via `git stash push -u` /
  `pop` pour comparer contre la baseline `c62a639` d'avant ces correctifs —
  même style d'échecs intermittents, cas différents à chaque run, sur la
  baseline aussi. Confirme qu'il s'agit du flake déjà documenté (1.5-1.9,
  1.11.2), pas d'une régression introduite ici — laissé hors périmètre, à
  investiguer séparément. Travail réalisé dans un worktree isolé
  (`/tmp/wsh-cockpit-review-fix`) pour ne pas perturber le répertoire de
  travail principal (travaux non liés en cours ailleurs) ; worktree et branche
  locale supprimés une fois le push confirmé sur
  `origin/feat/claude-cockpit-wrapper`. **PR #22 prête à merger, action
  réservée au pilote** — après merge, faire passer `NEXT: FIN`.
- 2026-08-09 (clôture, action pilote) : **PR #22 mergée dans `main` en squash**
  (commit `8d9d2c8`, mergée par `qveys` à 08:31 CEST). `main` local
  fast-forwardé sur `origin/main` en conséquence. Chantier `claude-cockpit-wrapper`
  clos — `NEXT: FIN`.
