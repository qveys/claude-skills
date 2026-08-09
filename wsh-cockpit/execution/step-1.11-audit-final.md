# Step 1.11 — Audit final de cohérence spec ↔ code ↔ tests

Phase 1 · après step-1.10 · fiche de jugement · **Modèle : Fable**

## Objectif

Vérifier, en adversaire, que le lot livré tient la spec v12 en entier — et redécouper
en fiches correctives ce qui ne la tient pas, AVANT la PR.

## Contexte minimal

- Spec : `docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md` (v12) —
  cette fiche est la seule de la phase 1 qui la relit EN ENTIER.
- Livré par 1.2-1.10 : `lib/claim.sh`, résolution 3 étapes de `spawn`, `release`/keep
  sticky, hygiène `gc` + `doctor`, `open --tab`, `claude-cockpit.sh`, selftests
  `claim`/`adopt`/`wrapper`, docs. Journal des décisions et déviations : `STATE.md`.
- Findings d'origine : `execution/findings-revue-spec-v11.md` (5 findings, intégrés en
  v12 — l'audit vérifie leur couverture par du CODE et un TEST, pas par du texte).

## Tâches

- [ ] Relire la spec v12 section par section ; pour chaque exigence normative, vérifier
      l'existence du code ET du cas de selftest correspondants (la liste §6 de la spec
      sert de checklist minimale ; la table d'états et les invariants I1-I4 se vérifient
      dans `claim.sh` et `selftest-claim`).
- [ ] Vérifier chaque finding v11 → v12 : primitives no-clobber, keep sticky, requête
      bornée au workspace, `sql_quote()`, doublons déterministes — code + test chacun.
- [ ] Lancer TOUS les selftests (session tmux jetable) et consigner le tableau des
      résultats ; `selftest-guard` inclus.
- [ ] Traquer les affaiblissements : diff de la branche sur les gardes des lots
      précédents (`session_is_own`, `deny_own_session`, `looks_like_session`,
      ancrage `=`) — toute modification doit avoir son cas de selftest rouge-d'abord
      tracé dans l'historique (CONVENTIONS, règle non négociable).
- [ ] Écrire `execution/rapport-step-1.11-audit.md` : conformités, écarts, verdict.
- [ ] **Si écarts** : créer les fiches correctives `step-1.11.x-<slug>.md` (Modèle :
      Sonnet, gabarit des fiches existantes), les insérer dans le tableau Avancement de
      STATE.md avant 1.12, et pointer `NEXT: step-1.11.1`. **Si conforme** :
      `NEXT: step-1.12`.

## Critère done

Le rapport d'audit existe et couvre spec entière + 5 findings + selftests (tableau de
résultats réel, pas déclaratif) ; chaque écart a sa fiche corrective OU une acceptation
motivée consignée dans STATE.md ; `NEXT:` pointe la bonne cible.

## Fin de session

Mettre à jour `STATE.md` (statut, `NEXT:` selon verdict) → commit signé → push de la
branche → annoncer de taper `/exit`.
