# Rapport step-1.11 — Audit final de cohérence spec v12 ↔ code ↔ tests

Date : 2026-08-09 · Modèle : Fable · Fiche : `execution/step-1.11-audit-final.md`

## Méthode

- Spec v12 relue EN ENTIER (595 lignes), section par section ; chaque exigence
  normative confrontée au code réel (texte exact extrait par `sed`/`grep`, jamais la
  mémoire des journaux) ET au cas de selftest correspondant (inventaire des 94+ cas
  par en-têtes numérotés de `lib/selftests.sh`).
- Les 5 findings v11→v12 vérifiés chacun par code + test (section dédiée).
- Les 12 suites de selftests exécutées depuis une session tmux jetable
  (`selftest-audit-111-*`, send-keys + fichier de sortie) — tableau réel plus bas.
- Affaiblissement des gardes lots 1-2 : diff complet `main...HEAD` sur `scripts/`
  (hors selftests), toutes les lignes supprimées inspectées une à une.

## Conformités (par section de spec)

| Spec | Exigence | Code | Test |
|---|---|---|---|
| §1 | Extraction `--keep`, pass-through (dont `--tab`) | claude-cockpit.sh `parse_group`/`spawn_group` | wrapper A2/A4 |
| §1 | `WSH_COCKPIT_AGENT=user-preopen-<n>` scopé au seul spawn | `env -u WSH_COCKPIT_PREFIX WSH_COCKPIT_AGENT=… "$WSH_LIVE" spawn` | wrapper A3/A5/A11 |
| §1 | `--force --preopen` systématiques | spawn_group | wrapper A2/A4 |
| §1 | Pré-claim immédiat à la création | `claim_new_session` appelé par `spawn`/`start` | adopt 1, wrapper A14 |
| §1 | Refus valeur contenant `--` / deux groupes même préfixe | passe 1 (validate) — collision via `normalize_prefix` sous scoping exact | wrapper B, C |
| §1 | `WSH_COCKPIT_ADOPT` + `WSH_COCKPIT_AGENT=claude-<runid>` exportés, `WSH_COCKPIT_PREFIX` neutralisé, pas d'`exec` | bloc lancement claude | wrapper A8/A9/A10 |
| §1 | Spawn échoue → claude jamais lancé, pas de rollback | `exit 1` avant claude | wrapper F (2 cas) |
| §1 | Symlink `~/.local/bin/claude-cockpit` | vérifié présent, pointe le script versionné | — (install) |
| §2 | Résolution 3 étapes, ambiguïté N>1 → rc=2 explicite | wsh-live.sh:536-585 | adopt 5/6a-6c/7 |
| §2 | Étape 2 : consume → verify (I2) → pane-ready → sonde → finalize, rollback sinon | `try_adopt_session` (session.sh) | adopt 9-16 |
| §2 | Table d'états + I1-I4, une primitive par transition | lib/claim.sh (`claim_create/consume/verify_won/finalize/rollback/replace_orphan/release`) | claim 1-8 |
| §2 | Format claim = contrat 2 lignes (clé, pid) | `claim__excl_write`/`claim_read_key` | claim 8 |
| §2 | Espace de clés réservé + levée `--preopen` | `claim_key_reserved`, refus dans spawn/start | claim 7, adopt 3/4 |
| §2 | Session morte offerte → warning une seule fois | `adopt_warn_dead_once` | adopt 14 |
| §2 | `--force` = création directe, claims intacts | garde `if [ "$FORCE" -eq 0 ]` englobe étapes 1-2-3 | adopt 20 |
| §2 | Sonde auto-portante (`WSH_LIVE_SEP_REINIT=1`) | `adopt_run_probe` | adopt 9 (grep `WSH_SITUATE_HOST=`) |
| §2 | Garde busy-pane élargie (shell nu OU ssh/tailscale/mosh) | `adopt_state_allowed` | adopt 11/12 |
| §2 | Jamais adopter sa propre session | `session_is_own` par candidat dans `try_adopt_session` | adopt 13 |
| §2 | Pas de re-`open` si client attaché ; `audit_log_start` ; annonce `adopted user cockpit:` | wsh-live.sh:581-586, session.sh:546 | adopt 9 (annonce) |
| §2 | Étape 3 : exclusion I3 (exact + `.won-*`, pas de glob nu) ; reprise legacy = claim + sonde | `claim_is_claimed`, `try_legacy_claim` | adopt 17/18/19 |
| §3 | `release <session>` arg obligatoire, jamais de défaut | `${1:?usage…}` | adopt 21 |
| §3 | Adoptée → pré-claim `released` (I4) ; créée → ABSENT ; `last-session` purgée si pointait la session | `release_session` (relu en texte exact) | adopt 22/23/24 |
| §3 | `release` ne touche ni tmux/bloc/keep/seq/oneshot | release_session (aucun appel mux/wave) | adopt 25 |
| §3 | Keep sticky (propriété de session, 2 chemins) ; `stop`-sur-keep ⇒ release | `keep_file`/`keep_is_set`, routage `stop` | adopt 26/27, wrapper A13/A16 |
| §3 | Plancher keep 24 h puis balayage normal (anti-deadlock) | `gc_effective_idle`, `GC_KEEP_FLOOR_IDLE=86400` | gc 15-20 |
| §3 | Hygiène des marqueurs : familles, liveness via `mux_list_sessions`, listing fiable requis, seuil 5 min, passe `.won` dédiée (pid mort ET âge > 2×timeout), `block-`/`cm-` fermés avant `rm` | `gc_hygiene_pass`, `block_id_close_path` | gc 6-14 |
| §3 | `teardown_session` nettoie claim + prefix (+ seq/oneshot déjà là) | teardown_session (relu) | adopt 8 |
| §4 | Requête CTE v12 verbatim, bornée `:ws`, ORDER BY pinned/ord, sans LIMIT | `resolve_tab_by_name` (diff visuel avec la spec : identique) | tab 1/2/3/5 |
| §4 | `sql_quote()` (doublement `'`, un seul argv, `?mode=ro`), `:ws` aussi | `sql_quote`, `wave_db_ro_strict` | tab 0/4 |
| §4 | Hors Wave → rc=2 échec net ; DB/wsh KO → rc=1 sans fallback AppSupport ; introuvable → rc=3 warning + repli | resolve_tab_by_name + open (exit 6 / warning) | tab 6/7/8 |
| §5 | Tableau d'erreurs | re-formulations des points ci-dessus | couverts par les mêmes cas |
| §6 | Amendements docs (« you created or adopted without `--keep` » ×2, spawn-réutilisation nuancé, gotcha sonde auto-portante, divergence DB 9 jours, consignes sous-agents durcies, adoption ciblée) | SKILL.md:275, session-lifecycle.md:246, gotchas.md:208-228 (grep re-vérifié) | — (docs) |
| §6 | `doctor` : claims sans activité récente, informatif, lecture seule | check dédié (1.7) | vérif manuelle 1.7 (hors périmètre RED de la fiche) |

Gardes lots 1-2 : le diff `main...HEAD` (hors selftests) supprime 5 lignes de
session.sh — toutes appartiennent aux refactors journalisés (find_reusable_session
réécrit AUTOUR de `session_safe_to_reuse`, qui survit dans ses deux branches et se
trouve RENFORCÉE par l'exclusion `claim_is_claimed` ; `block_id_close` devenu wrapper
de `block_id_close_path`). `deny_own_session`/exit 8 (5 call sites), `looks_like_session`
et l'ancrage `=` sont inchangés. La seule garde nouvelle plus permissive
(`adopt_state_allowed`, adoption uniquement) est une exigence explicite de la spec §2,
avec ses cas RED-first tracés (journal 1.4). **Aucun affaiblissement.**

## Findings v11→v12 — code + test chacun

| Finding | Code | Test |
|---|---|---|
| 3721135340 primitives no-clobber | claim.sh : une fonction par ligne du tableau des transitions ; aucun `mv`/`ln` sur claim hors de ce fichier (grep) | claim 4 (`.won` pid recyclé), 5 (rollback face claim définitif), 6 (remplacement sous course), 2/3 (course, anti-ré-armement) |
| 3721135346 keep sticky | `keep_file`/`keep_is_set` (session), pose wrapper, routage `stop` | adopt 26 (adoptée), 27 (créée-relâchée, reprise scan), wrapper A13/A16 |
| 3721135353 requête bornée workspace | CTE `WHERE db_workspace.oid = $(sql_quote "$ws")`, rc=2 sans `WAVETERM_WORKSPACEID` | tab 1/2/5/6 |
| 3721135358 sql_quote | `sql_quote()` + requête en un argv + `?mode=ro` | tab 0/4 (quote, `%`, retour-ligne réel `$'…'`, injection) |
| 3721135363 doublons déterministes | `ORDER BY pinned ASC, ord ASC`, élue = 1re ligne, `TAB_BY_NAME_ALL` pour le warning | tab 3 (ordre d'insertion inversé) — **mais voir É3 : le warning caller est cassé et non testé** |

## Résultats des selftests (session tmux jetable, run réel)

Exécution réelle du 2026-08-09, session tmux jetable `selftest-audit-111-*`,
sortie intégrale conservée le temps de la session dans le scratchpad
(`selftests-out.txt`, `adopt-rerun1.txt`).

| Suite | Lignes `ok` | RC | Verdict |
|---|---|---|---|
| selftest-sep | 8 | 0 | ✅ |
| selftest-gc | 20 | 0 | ✅ |
| selftest-cache | 6 | 0 | ✅ |
| selftest-oneshot-ssh | 8 | 0 | ✅ |
| selftest-output | 6 | 0 | ✅ |
| selftest-transfer | 3 | 0 | ✅ |
| selftest-live | 12 | 0 | ✅ |
| selftest-guard | 42 (cas 1-41, un cas à double assertion) | 0 | ✅ |
| selftest-claim | 10 | 0 | ✅ |
| selftest-adopt | run combiné : 28 ok, 2 FAIL (cas 9 : adoption échouée, pré-claim intact ; cas 25) → **re-run isolé immédiat : 30/30 ok, RC=0** | 1 puis 0 | ✅ (flake du run combiné, signature identique aux journaux 1.5-1.8 — jamais le même cas, non reproductible en isolation ; le déclencheur — sweep `gc` best-effort en arrière-plan de chaque `spawn` — est documenté et n'est pas une régression de ce lot) |
| selftest-tab | 13 | 0 | ✅ |
| selftest-wrapper | 22 | 0 | ✅ |

## Écarts

### É1 — Balayage de sortie du wrapper : interférence entre deux runs parallèles

`claude-cockpit.sh` (bloc final) balaie **toute** session `cockpit-*` vivante dont le
claim porte une clé `user-preopen-*` — sans restriction aux sessions créées par CE
run (`ALL_SESSIONS`). Les clés `user-preopen-<n>` sont indexées par groupe, pas par
run : deux `claude-cockpit` parallèles produisent les mêmes clés. Quand le run A se
termine pendant que le run B tourne encore, A détruit (`stop`) ou relâche les
cockpits de B non encore adoptés (qui portent leur pré-claim `user-preopen-<n>`
pendant tout le run si claude-B ne les adopte pas). Viole la décision actée « deux
claude parallèles ne doivent pas se voler leurs cockpits » et le §1 (« le wrapper
balaie SES sessions ») — la formulation du §1 (« toute session vivante au claim
`claude-<runid>` ou `user-preopen-<n>` ») est elle-même ambiguë, mais l'intention est
sans équivoque (registres par run disjoints). La branche `claude-<runid>` est saine
(clé unique par run). Non détecté par selftest-wrapper : aucun cas ne simule une
session étrangère au run. → **fiche `step-1.11.1`**.

### É2 — Garde busy-pane : mitigation « texte après le prompt » absente

Spec §2 : une commande en cours de frappe étant indétectable par
`pane_current_command`, « mitigation best-effort : capturer la dernière ligne du pane
et refuser si du texte suit le prompt ; limite documentée ». `adopt_pane_ready()` ne
consulte que `mux_pane_command` ; aucune capture de dernière ligne, et la limite
n'est documentée nulle part (grep gotchas/SKILL). → **fiche `step-1.11.2`**.

### É3 — Warning doublons `open --tab` : off-by-one + chemin non testé

wsh-live.sh (open, comptage des doublons) : `printf '%s' "$TAB_BY_NAME_ALL" | wc -l`
compte les terminateurs de ligne — pour N candidats (N lignes sans retour final,
sortie de `$(…)`), il rend N−1. Le seuil `-gt 1` ne déclenche donc qu'à partir de
N≥3 : avec exactement 2 doublons (le cas le plus courant), **aucun warning**, alors
que la spec §4 et la fiche 1.8 exigent « warning listant TOUS les candidats » dès le
premier doublon. C'est précisément le piège `wc -l` documenté au journal 1.8… corrigé
dans le test, pas dans ce chemin du code. Le chemin caller (warning + repli rc=3)
n'est couvert par aucun test — seule la primitive l'est. → **fiche `step-1.11.3`**.

### Acceptations motivées (pas de fiche — consignées ici et dans STATE.md)

- **A1 — mémo dead-warned par slug.** Spec : `adopt-warned-<key>@<slug>` (un mémo par
  couple) ; code : `adopt-dead-warned-<slug>` (par slug seul). L'objectif normatif
  (§5 : « warning au premier constat seulement, mémorisé ») est atteint — la
  déduplication est même plus large (inter-agents). Le rationale du séparateur `@`
  (découpage déterministe clé/slug) est sans objet dès lors que la clé n'entre pas
  dans le nom. Hygiène par âge 24 h présente (gc.sh:179-185). Écart de forme, pas de
  fond.
- **A2 — « rafale de N adoptants » prouvée à N=2.** claim 2 et adopt 10 vérifient
  « exactement un gagnant » **par comptage** (l'exigence anti-« absence de
  symptôme »). L'exclusivité repose sur rename(2), dont la garantie ne dépend pas de
  N ; un N plus grand n'exercerait aucun code supplémentaire.
- **A3 — pas de stress-test « course + gc simultanés ».** La seule surface
  d'interaction entre gc et une course en vol est le couple claim/`.won` ; les
  planchers anti-course de gc sont prouvés individuellement (gc 6 : marqueur frais
  jamais mangé ; gc 12 : `.won` jeune intouché ; gc 13 : `.won` de pid vivant
  intouché), et les invariants sous course le sont par claim 2-6. Un stress-test
  combiné en bash serait précisément le genre de test flaky que le chantier combat
  déjà (flakes gc-en-arrière-plan documentés aux journaux 1.5-1.8) sans couvrir de
  nouvelle transition.
- **A4 — continuité `seq` testée par décomposition** (adopt 25 : release ne touche
  pas `seq` ; adopt 23 : ré-adoption étape 2 avec sonde prouvée) — déjà motivé au
  journal 1.6 : la sonde de ré-adoption incrémente légitimement le compteur,
  « continuité » = jamais de remise à zéro, pas immutabilité.
- **A5 — `gc_should_kill` non modifié pour keep** (spec §6 : « `gc_should_kill`
  modifié, lot 2 ») : remplacé par `gc_effective_idle` composée dans `cmd_gc` —
  fonctionnellement équivalent (plancher 24 h, gc 18-20 le prouvent bout en bout),
  motivé au journal 1.7 (préserve la pureté testée de `gc_should_kill`).
- **A6 — « deux spawn de préfixes différents → deux sessions »** : pas de cas
  littéral, mais adopt 5 (alternance A→B→A entre deux sessions de préfixes
  distincts) le prouve par construction — l'alternance ne peut réussir que si les
  deux préfixes ont produit deux sessions distinctes.

## Verdict

**Conforme à trois écarts près, tous corrigeables en fiches Sonnet courtes.** Le cœur
du design (machine d'états du claim, invariants I1-I4, résolution 3 étapes, keep
sticky, hygiène gc, `--tab`) est fidèle à la spec, testé, et les gardes des lots
précédents sont intactes. Les écarts É1 (interférence inter-runs du balayage wrapper),
É2 (mitigation busy-pane absente) et É3 (warning doublons cassé + non testé) reçoivent
les fiches `step-1.11.1` à `step-1.11.3`, insérées avant 1.12. `NEXT: step-1.11.1`.
