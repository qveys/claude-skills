# Step 1.5 — Scan (étape 3) : exclusion des sessions claimées, reprise legacy, `--force`

Phase 1 · après step-1.4 · **Modèle : Sonnet**

## Objectif

Le scan `cockpit-<prefix>-*` de `spawn` exclut toute session claimée par quiconque, la
réutilisation d'une session legacy la fait entrer au registre (claim + sonde), et
`--force` garde sa sémantique de création directe sans orpheliner les claims.

## Contexte minimal (extraits spec v12, §2)

- **« Claimée » (I3)** = existence du fichier `adopt-claim-<slug>` **exact** OU d'un
  `adopt-claim-<slug>.won-*` — PAS un glob `<slug>*` nu (il sur-matcherait le claim
  d'une session sœur suffixée `-1`). Pré-claims du wrapper ET consommations en cours
  incluses : ni la fenêtre pré-adoption ni la fenêtre de transfert ne rendent la
  session saisissable (sinon vol possible, et deux agents entrelacés dans un même pane
  partageraient un seul compteur `seq`). Extension naturelle de
  `session_safe_to_reuse` (session.sh:232-256).
- **Reprise d'une session legacy non claimée trouvée au scan** : pose le claim du
  créateur (toute session utilisée entre au registre — le parc antérieur cesse d'être
  partageable dès sa première réutilisation) ET exécute la **sonde** (session non créée
  à l'instant = état inconnu ; même argument que l'adoption, mécanique de la fiche 1.4).
- **`--force` = création directe** : saute les étapes 1 et 2 ET le scan — cockpit neuf
  garanti, jamais celui de l'utilisateur (sémantique actuelle étendue à l'adoption :
  wsh-live.sh:440-466). Les claims existants de l'agent **restent en place** — les
  sessions déjà possédées restent au registre pour les spawns suivants, pas de claim
  orphelin.
- La création (avec ou sans `--force`) pose toujours le claim du créateur (fiche 1.3).

## Tâches

- [ ] **RED d'abord** : cas `selftest-adopt` montrés rouges puis verts — le scan ne rend
      JAMAIS une session claimée par quiconque (claim définitif d'un tiers, pré-claim
      wrapper, `.won-*` en cours — les trois formes testées) ; le glob exact ne
      sur-matche pas une sœur `-1` ; reprise legacy → claim posé + sonde exécutée ;
      `spawn --force` → session neuve même avec candidate d'adoption libre ET les
      claims existants de l'agent intacts après coup.
- [ ] Implémenter l'exclusion dans le scan de `find_reusable_session` (ou son
      successeur issu de 1.3), la reprise-avec-claim+sonde, et le contournement
      `--force` étendu.
- [ ] `selftest-guard`, `selftest-claim`, cas 1.3-1.4 de `selftest-adopt` restent verts.

## Critère done

Cas ci-dessus verts (RED documenté), aucune session claimée n'est jamais rendue par le
scan (prouvé par les trois formes de claim), `--force` n'orpheline rien, selftests
existants verts.

## Fin de session

Mettre à jour `STATE.md` (statut, `NEXT: step-1.6`) → commit signé → push de la branche
→ annoncer de taper `/exit`.
