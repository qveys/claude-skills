# STATE — chantier claude-cockpit-wrapper

màj : 2026-08-05 · **Étape courante : step-0.1 (non démarrée)**

NEXT: step-0.1

> Ligne lue par `execution/next.sh` — la tenir à jour en fin de CHAQUE session.
> Valeurs : `step-X.Y` · `PAUSE` (bloqué sur action humaine) · `FIN`.

## Bloqueurs actifs

(aucun — si la signature 1Password échoue : ouvrir/déverrouiller l'app 1Password sur le Mac,
c'est le seul remède, puis relancer la fiche)

## Avancement

| Étape | Titre | Statut |
|---|---|---|
| 0.1 | Amender la spec (findings v11) + écrire le plan du lot + découper en fiches | ☐ |

## Ordre recommandé

step-0.1 d'abord — elle GÉNÈRE les fiches suivantes (step-1.x…) et remplit ce tableau.
Prévoir dans le découpage une fiche d'inventaire/réalité tôt (ce que wsh-live.sh couvre déjà),
et une fiche PR de fin de lot (main est protégée, voir CONVENTIONS).

## Journal des décisions en cours de chantier

- 2026-08-05 (contrôleur du lot 2, mise en place du relais) : chantier lancé sur la branche
  `feat/claude-cockpit-wrapper` ; les 5 findings CodeRabbit sur la spec v11 (PR #16) sont copiés
  dans `execution/findings-revue-spec-v11.md` et déclarés prérequis du plan.
