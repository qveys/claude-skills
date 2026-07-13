# Gabarits — chantier-relais

À adapter au projet ; conserver les invariants signalés. Tout est en français si l'utilisateur travaille en français.

## execution/CONVENTIONS.md

```markdown
# Conventions d'exécution — chantier <NOM>

Source maîtresse : <lien vers le plan/la doc de référence>. Les fiches `step-X.Y` n'en copient que le strict nécessaire.

## Rituel de session (obligatoire)

1. Charger UNIQUEMENT, dans cet ordre : `CONVENTIONS.md` (ce fichier) + `STATE.md` + la fiche `step-X.Y` courante.
2. **Contrôle modèle** (filet — le relais lance normalement le bon) : comparer le modèle actif à la ligne « Modèle : » de la fiche ; mismatch → s'arrêter et demander `/model <bon modèle>` (l'agent ne peut pas le faire lui-même).
3. Exécuter la fiche. Ne pas déborder sur l'étape suivante, même si « il ne reste qu'un petit truc ».
4. Fin de session : mettre à jour `STATE.md` (statut, **ligne `NEXT:`**, décisions, bloqueurs), commit, push, puis **annoncer de taper `/exit`** (hors relais : `/clear`).

## Relais entre sessions — `execution/next.sh`
<résumé du fonctionnement : boucle NEXT → modèle → claude → /exit ; arrêt PAUSE/FIN/Ctrl+C ;
filet : session morte sans MAJ de NEXT → même fiche rejouée (les fiches restent rejouables)>

## Règles non négociables
<les règles du projet pour lesquelles « on virerait quelqu'un » — courtes>

## Modèle par session
Pas d'opusplan : le blueprint a déjà été payé au découpage, chaque fiche EST le plan.
| Cas | Modèle |
|---|---|
| Défaut (implémentation au contrat clair) | Sonnet |
| Fiches de jugement (audit, arbitrage qui redécoupe le plan) | Opus (ou mieux) |
| Mécanique pur, credentials en place | Haiku possible |
| Blocage réel en cours de session | Consigner dans STATE.md, escalader, redescendre |

## Décisions actées (ne PAS re-questionner)
<numérotées, une ligne chacune — évite qu'un agent frais re-litige>
```

## execution/STATE.md

```markdown
# STATE — chantier <NOM>

màj : <AAAA-MM-JJ> · **Étape courante : step-0.1 (non démarrée)**

NEXT: step-0.1

> Ligne lue par `execution/next.sh` — la tenir à jour en fin de CHAQUE session.
> Valeurs : `step-X.Y` · `PAUSE` (bloqué sur action humaine) · `FIN`.

## Bloqueurs actifs
<liste datée ; inclure les actions humaines en attente avec le détail pour les faire>

## Avancement
| Étape | Titre | Statut |
|---|---|---|
| 0.1 | … | ☐ |

## Ordre recommandé
<séquence + étapes indépendantes faisables à tout moment>

## Journal des décisions en cours de chantier
(consigner ici, daté, toute décision prise en session)
```

## Fiche execution/step-X.Y-<slug>.md

```markdown
# Step X.Y — <Titre>

Phase X · après <Y.Z> · <particularités : bloquant, clôt la phase…> · **Modèle : Sonnet**

## Objectif
<une phrase>

## Contexte minimal
<3-10 lignes MAX extraites de la doc maîtresse : uniquement les services/fichiers/
gotchas touchés par CETTE étape ; jamais la doc entière>

## Tâches
- [ ] …

## Critère done
<vérifiable objectivement ; si la fiche clôt une phase, le dire>

## Fin de session
Mettre à jour `STATE.md` → commit → push → annoncer de taper `/exit` (relais) — ou `/clear` hors relais.
```

## Points de vigilance au découpage

- Une fiche trop grosse se repère à son critère done : s'il faut « et » trois fois pour l'énoncer, découper.
- Prévoir une **fiche d'inventaire/réalité** tôt (qu'est-ce que l'outil/l'existant couvre déjà ?) et noter dans STATE.md qu'elle peut réduire ou annuler des fiches suivantes.
- Les étapes exigeant l'humain (créer des tokens, fournir une liste) : les isoler dans leur propre fiche en début de chaîne, et documenter dans STATE.md le détail exact pour les faire — c'est ce qui rend `PAUSE` actionnable à distance.
- Numéroter phase.étape (`step-2.3`) et garder le slug parlant : le relais matche `step-X.Y-*.md`.
```
