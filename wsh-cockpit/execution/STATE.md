# STATE — chantier claude-cockpit-wrapper

màj : 2026-08-05 · **Étape courante : step-1.2 — step-1.1 terminée**

NEXT: step-1.2

> Ligne lue par `execution/next.sh` — la tenir à jour en fin de CHAQUE session.
> Valeurs : `step-X.Y` · `PAUSE` (bloqué sur action humaine) · `FIN`.

## Bloqueurs actifs

(aucun — si la signature 1Password échoue : ouvrir/déverrouiller l'app 1Password sur le Mac,
c'est le seul remède, puis relancer la fiche)

## Avancement

| Étape | Titre | Modèle | Statut |
|---|---|---|---|
| 0.1 | Amender la spec (findings v11) + plan du lot + découpage en fiches | Fable | ✅ 2026-08-05 |
| 1.1 | Inventaire de réalité et mesures préalables (`ln` no-clobber, DB Wave, `sql_quote`) | Sonnet | ✅ 2026-08-05 |
| 1.2 | Primitives du claim (`lib/claim.sh`) + `selftest-claim` | Sonnet | ☐ |
| 1.3 | Registre à la création (`spawn`/`start`, `prefix-<slug>`, étape 1) | Sonnet | ☐ |
| 1.4 | Adoption étape 2 (`WSH_COCKPIT_ADOPT`, sonde, rollback) | Sonnet | ☐ |
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
