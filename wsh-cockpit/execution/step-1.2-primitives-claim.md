# Step 1.2 — Primitives du claim (`lib/claim.sh`) + `selftest-claim`

Phase 1 · après step-1.1 · **Modèle : Sonnet**

## Objectif

Livrer la machine d'états du claim (`adopt-claim-<slug>`) sous forme de primitives
atomiques encapsulées dans `wsh-cockpit/scripts/lib/claim.sh`, prouvées par un nouveau
`selftest-claim` — sans encore toucher à `spawn`/`stop` (intégration : fiches 1.3+).

## Contexte minimal (extraits spec v12, §2)

- **Format du claim = contrat parsé** : ligne 1 = clé agent, ligne 2 = pid (debug).
  États : ABSENT → PRÉ-CLAIM (clé `user-preopen-<n>` ou `released`) → EN-COURS
  (`.won-<pid>`, contenu = pré-claim d'origine) → POSSÉDÉ (clé de l'agent). La table
  d'états de la spec fait foi.
- **Primitives des transitions (v12)** — une fonction par transition, aucun site
  d'appel ne compose `mv`/`ln` à la main :
  - création (→ PRÉ-CLAIM/POSSÉDÉ) : `set -o noclobber` + redirection (O_EXCL) ;
  - consommation (→ EN-COURS) : purge/restauration préalable d'un `.won-<pid>`
    résiduel de MON pid (espace mono-écrivain, pré-vérification sans course), puis
    `mv claim .won-<pid>` — un seul `mv` réussit, le perdant a ENOENT ;
  - **vérification de contenu obligatoire après le rename gagnant** (I2,
    anti-ré-armement) : le `.won` DOIT contenir un pré-claim
    (`user-preopen-*`/`released`), sinon rollback et abandon ;
  - claim définitif (→ POSSÉDÉ) : écriture O_EXCL puis `rm .won` ;
  - rollback/restauration (`.won` → PRÉ-CLAIM) : `ln .won claim` (EEXIST si un claim
    définitif existe → supprimer le `.won` seul, jamais écraser — I1) puis `rm .won` ;
  - remplacement d'orphelin (session morte, nom recyclé) : `mv claim .stale-<pid>`
    puis O_EXCL puis `rm .stale-<pid>` ; échec O_EXCL → restauration `ln`/`rm`.
- **`release`** : rétrogradation POSSÉDÉ → PRÉ-CLAIM `released`, mono-écrivain
  (propriétaire seul, I4), temp + `mv`.
- **Clés réservées** : une `WSH_COCKPIT_AGENT` commençant par `user-preopen-` ou valant
  `released` doit être refusable (fonction de test fournie ici ; le refus effectif dans
  `spawn`/`start` et le flag interne `--preopen` sont en fiche 1.3).
- Invariants I1-I4 (spec §2). Slug : même mécanique que l'existant
  (`session.sh:27,55` — `tr` ; vérifier le rapport 1.1). Marqueurs dans
  `~/.cache/wsh-cockpit/`. bash 3.2, `set -euo pipefail`.

## Tâches

- [ ] **RED d'abord** : écrire `selftest-claim` (nouvelle sous-commande, pattern des
      selftests existants — `lib/selftests.sh`, cas numérotés type `report_*_case`) avec
      les cas ci-dessous, le montrer rouge, puis implémenter `lib/claim.sh` jusqu'au vert.
- [ ] Cas imposés : cycle nominal complet (création → consommation → vérif → définitif →
      release → re-consommation) ; course A/B sur un même pré-claim (exactement un
      gagnant, vérifié par comptage) ; anti-ré-armement (B rename APRÈS le claim
      définitif de A → détecté par la vérif de contenu, rename inverse, aucune double
      adoption) ; `.won-<pid>` résiduel de pid recyclé (purgé/restauré avant
      consommation) ; rollback face à un claim définitif apparu entre-temps (`.won`
      supprimé, claim intact) ; remplacement d'orphelin sous course (O_EXCL perdu →
      restauration) ; refus de clé réservée ; format à deux lignes relu correctement.
- [ ] `selftest-guard` reste vert (aucun script existant modifié hors sourcing de la lib).

## Critère done

`selftest-claim` vert (tous les cas ci-dessus), passage RED documenté dans STATE.md,
`selftest-guard` vert, `lib/claim.sh` seul nouveau fichier de code, aucun appel `mv`/`ln`
sur un claim hors de `claim.sh`.

## Fin de session

Mettre à jour `STATE.md` (statut, `NEXT: step-1.3`) → commit signé → push de la branche
→ annoncer de taper `/exit`.
