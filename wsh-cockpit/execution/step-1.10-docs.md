# Step 1.10 — Documentation : SKILL.md, session-lifecycle, gotchas

Phase 1 · après step-1.9 · **Modèle : Sonnet**

## Objectif

Mettre la documentation du skill au niveau du code livré (fiches 1.2-1.9) : section
adoption dans SKILL.md, amendement des règles devenues fausses, gotchas nouveaux.

## Contexte minimal (spec v12, §6 — la liste ci-dessous est exhaustive)

- **SKILL.md** :
  - nouvelle section « Cockpit pré-ouvert par l'utilisateur » : wrapper, adoption,
    sonde systématique, propriété (`--keep` sticky = propriété réduite : usage plein,
    destruction interdite) ;
  - **amendement OBLIGATOIRE de la règle existante** « Only delete blocks/sessions
    **you** created » → « …you created **or adopted without `--keep`** » (sinon deux
    consignes contradictoires cohabitent) ;
  - consignes sous-agents durcies : tout sous-agent qui spawne un cockpit DOIT exporter
    un `WSH_COCKPIT_AGENT` distinct (espace réservé `user-preopen-*`/`released`
    interdit) ; « `stop` ce qu'on a créé, `release` ce qu'on a adopté, en fin de
    tâche » ; adoption ciblée : quand l'utilisateur a nommé ses cockpits, reprendre ces
    préfixes dans `spawn` — un préfixe explicite non matché CRÉE un cockpit neuf, seul
    un `spawn` sans préfixe adopte en nominal ;
  - règle keep/`gc` : une keep détachée ET idle > 24 h retombe dans le balayage.
- **docs/session-lifecycle.md** : même amendement de la règle « Only delete… »
  (ligne ~176, à re-localiser) ; règles de cycle de vie de l'adoption (`--keep`, claim
  atomique, hygiène des marqueurs par `gc`) ; **amender le passage décrivant la
  réutilisation inconditionnelle de `spawn`** — désormais filtrée par préfixe/registre.
- **docs/gotchas.md** : « spawn without `--force` will reuse it » n'est plus vrai pour
  un préfixe incompatible ; gotcha sonde auto-portante sur session keep re-hoppée ;
  gotcha DB Wave vivante vs snapshot AppSupport (`wsh wavepath data`, jamais en dur) si
  absent.
- **README.md** du skill : vérifier la cohérence (tableau des commandes : `release`,
  `open --tab`, wrapper) — corriger si le lot l'a rendu inexact.
- Réserve : ne documenter QUE ce qui est effectivement livré — si une fiche précédente
  a dévié (voir STATE.md, journal), la doc suit le code, pas la spec.

## Tâches

- [ ] Passer chaque puce du contexte ci-dessus : localiser (grep), amender, cocher.
- [ ] Relire les diffs : aucune contradiction résiduelle entre deux passages de doc
      (chercher les autres occurrences de « you created », « reuse », « last-session »).
- [ ] `docs/` du skill uniquement — les artefacts de chantier restent dans `execution/`
      (décision actée n° 5).
- [ ] Selftests non concernés mais lancer `selftest-guard` par acquit (aucun script
      touché attendu).

## Critère done

Chaque item du §6 de la spec v12 listé ci-dessus est soit amendé (diff à l'appui), soit
consigné comme non applicable avec motif dans STATE.md ; plus aucune occurrence de la
règle non amendée ; README cohérent.

## Fin de session

Mettre à jour `STATE.md` (statut, `NEXT: step-1.11`) → commit signé → push de la branche
→ annoncer de taper `/exit`.
