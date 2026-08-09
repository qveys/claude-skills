# Step 1.12 — PR de fin de lot vers `main`

Phase 1 · après step-1.11 (audit conforme) · dernière fiche · **Modèle : Sonnet**

## Objectif

Ouvrir la PR `feat/claude-cockpit-wrapper` → `main`, la mettre en état d'être mergée
(revue traitée, fils résolus), et rendre la main au pilote pour le merge.

## Contexte minimal

- `main` est protégée par ruleset : commits signés, revue Copilot, résolution de TOUS
  les fils de revue ; merge commits autorisés. **Jamais de push sur `main`**
  (CONVENTIONS, règle non négociable). Précédent de forme : PR #16-#17 du dépôt.
- La branche contient : spec v12, plan, fiches, et le lot 1.1-1.11 (dont selftests).
- Outil : `gh` CLI.

## Tâches

- [ ] Vérifier l'état : branche poussée à jour, tous selftests verts (session tmux
      jetable — coller le tableau de l'audit 1.11 si encore exact, sinon relancer),
      `git log` propre (signé, sans attribution IA).
- [ ] Ouvrir la PR (`gh pr create --base main`) : titre et corps en français — résumé
      du lot (wrapper, adoption, registre des claims, `release`/keep, hygiène `gc`,
      `open --tab`), renvoi à la spec v12 et au rapport d'audit 1.11, tableau des
      selftests. Pas de mention d'IA générative dans le corps.
- [ ] Suivre la revue (Copilot + CodeRabbit s'il passe) : traiter chaque fil — fix
      committé (signé) ou réponse motivée, puis résoudre le fil. Un finding qui exige
      de re-designer (pas juste corriger) → le consigner dans STATE.md et passer en
      `PAUSE` pour arbitrage pilote plutôt que d'improviser.
- [ ] Ne PAS merger : le merge est le geste du pilote.

## Critère done

La PR existe, CI/ruleset au vert hors approbation finale, tous les fils de revue
ouverts sont traités et résolus (ou un blocage de re-design est consigné), STATE.md
récapitule l'URL de la PR et l'état des fils.

## Fin de session

Mettre à jour `STATE.md` (statut, **`NEXT: PAUSE`** — bloqué sur le merge, action
pilote ; après merge le pilote passera `NEXT: FIN`) → commit signé → push de la
branche → annoncer de taper `/exit`.
