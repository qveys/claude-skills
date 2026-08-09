# Step 0.1 — Amender la spec, écrire le plan du lot, découper en fiches

Phase 0 · première fiche · bloquante (elle génère toutes les autres) · **Modèle : Fable**

## Objectif

Transformer la spec v11 du wrapper claude-cockpit en un plan d'implémentation exécutable,
après y avoir intégré les 5 findings de revue, puis découper ce plan en fiches `step-1.x…`
autoportantes pour le relais.

## Contexte minimal

- Spec : `docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md` (v11) — LA lire en
  entier est le travail de CETTE fiche (les suivantes n'en recevront que des extraits).
- Findings prérequis : `execution/findings-revue-spec-v11.md` (5 findings CodeRabbit, PR #16 :
  transitions de claim sans no-clobber, état `keep` à la ré-adoption, requête d'onglet non bornée
  au workspace, quoting SQL, doublons de noms d'onglets).
- Le socle existe et est vert : `scripts/wsh-live.sh` + `scripts/lib/*` (lots 1-2 mergés sur
  main) — gardes own-session (exit 8), échec fort sur token en forme de session (exit 4), flag
  `--session`/`-s`, `selftest-guard` 41 cas. Précédent de forme pour le plan :
  `docs/plans/2026-08-02-desambiguisation-argument-session.md`.
- Historique utile : `docs/gotchas.md` (sémantique `=` mesurée, dérive `#S` en sessions
  groupées, pièges Wave).

## Tâches

- [ ] Lire la spec v11 en entier, puis les 5 findings ; amender la spec (v12, en tête de
      fichier : changelog daté) pour intégrer chaque finding — ou consigner, finding par
      finding, pourquoi il est traité autrement (au plan, ou réfuté avec mesure).
- [ ] Écrire `docs/plans/2026-08-05-claude-cockpit-wrapper.md` : périmètre, non-périmètre,
      design par étapes, tests (RED-first), contraintes (reprendre §6 du plan précédent).
- [ ] Découper en fiches `execution/step-1.x-*.md` (gabarit : fiches existantes + skill
      chantier-relais) : une fiche = un livrable vérifiable, modèle par fiche (défaut Sonnet),
      fiche d'inventaire/réalité en premier, fiche PR de fin de lot en dernier.
- [ ] Remplir le tableau Avancement et l'Ordre recommandé de `STATE.md` ; `NEXT: step-1.1`.

## Critère done

La spec est amendée (ou chaque finding tracé), le plan existe, chaque fiche `step-1.x` a un
critère done vérifiable et une ligne « Modèle : », et `STATE.md` pointe `NEXT: step-1.1`.

## Fin de session

Mettre à jour `STATE.md` → commit signé → push de la branche → annoncer de taper `/exit`
(relais) — ou `/clear` hors relais.
