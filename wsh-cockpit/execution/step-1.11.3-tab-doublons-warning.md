# Step 1.11.3 — `open --tab` : warning doublons cassé (off-by-one) + test manquant

Phase 1 · corrective issue de l'audit 1.11 (É3) · après step-1.11.2 · **Modèle : Sonnet**

## Objectif

Le warning « plusieurs onglets portant ce nom » doit se déclencher dès 2 doublons
(spec §4 : premier match dans l'ordre défini + warning listant TOUS les candidats),
et ce comportement doit être testé.

## Contexte minimal (rapport d'audit É3)

- Bug : wsh-live.sh (open, branche `TAB_RC=0`) compte les doublons par
  `printf '%s' "$TAB_BY_NAME_ALL" | wc -l` — `wc -l` compte des TERMINATEURS de
  ligne, et `TAB_BY_NAME_ALL` (sorti d'une substitution `$(…)`) n'a pas de retour à
  la ligne final : N candidats → N−1. Le seuil `-gt 1` ne déclenche donc qu'à N≥3 ;
  avec exactement 2 doublons, aucun warning. C'est LE piège `wc -l` déjà documenté au
  journal 1.8… où il avait été corrigé dans le test, pas dans ce chemin du code.
- Le chemin caller (warning + élue) n'est couvert par aucun test : `selftest-tab`
  n'exerce que la primitive `resolve_tab_by_name` (fixture DB via le seam `ro`).
- Correctif suggéré : factoriser le comptage en petite fonction pure de `lib/wave.sh`
  (entrée = contenu de `TAB_BY_NAME_ALL`, sortie = nombre de candidats — idiome
  `printf '%s\n' … | wc -l` ou boucle), utilisée par `open` — la fonction pure entre
  dans `selftest-tab` (même logique de seam que `resolve_tab_by_name`). La fixture
  contient déjà `dup1`/`dup2`/`dup3` : ajouter un nom à exactement DEUX doublons pour
  le cas N=2.
- Ne rien changer à la sélection de l'élue (1re ligne, ordre `pinned, ord` — tab 3
  la couvre déjà).

## Tâches

- [ ] **RED d'abord** : cas `selftest-tab` — comptage de candidats : N=1 → 1 (pas de
      warning), N=2 → 2 (warning dû, le cas qui échoue sur le code actuel), N=3 → 3.
- [ ] Factoriser le comptage en fonction pure de `wave.sh`, brancher `open` dessus.
- [ ] `selftest-tab` complet + `selftest-cache` + `selftest-guard` verts.

## Critère done

Cas N=2 vert (RED documenté sur le code actuel), le warning liste tous les candidats
dès 2 doublons, aucun cas existant ne régresse.

## Fin de session

Mettre à jour `STATE.md` (statut, `NEXT: step-1.12`) → commit signé → push de la
branche → annoncer de taper `/exit`.
