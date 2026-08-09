# Step 1.3 — Registre à la création : claims posés par `spawn`/`start`, étape 1 de résolution

Phase 1 · après step-1.2 · **Modèle : Sonnet**

## Objectif

Toute session créée entre au registre de son créateur (claim + préfixe enregistré), et
`spawn` résout d'abord dans SON registre (étape 1) — `last-session` cesse d'être
l'autorité. Adoption (étape 2) et scan filtré (étape 3) restent pour les fiches 1.4-1.5.

## Contexte minimal (extraits spec v12, §2)

- **La création pose le claim du créateur** (POSSÉDÉ, primitive O_EXCL de `claim.sh`,
  fiche 1.2). Collision de nom recyclé sur claim orphelin de session morte →
  primitive « remplacement d'orphelin ».
- **Préfixe enregistré, pas parsé** : `spawn` écrit le préfixe normalisé dans
  `~/.cache/wsh-cockpit/prefix-<slug>` à la création ; `start` (nom complet) écrit la
  sentinelle `(named)`, jamais matchable, et refuse un nom dont le slug collisionne
  avec celui d'une session vivante différente. Le parsing
  `^cockpit-(.+)-[0-9]{6}(-[0-9]+)?$` n'est qu'un fallback legacy (ambigu par
  construction).
- **Étape 1 (registre)** : parmi les sessions vivantes dont le claim porte ma clé —
  préfixe demandé → préfixe enregistré égal ; aucun préfixe demandé → la
  `last-session` si elle appartient au registre, sinon l'unique session du registre ;
  **N>1 sans préfixe ni `last-session` au registre → erreur explicite** (jamais de
  (N+1)-ième cockpit silencieux). Égalité de préfixe au registre (possible via
  `--force`) → `last-session` si elle en fait partie, sinon erreur explicite.
- **« Aucun préfixe demandé »** = positionnel absent AVANT `normalize_prefix`
  (session.sh:47-59 : `$1` > `WSH_COCKPIT_PREFIX` > `WSH_COCKPIT_AGENT` > `live`).
- **Clés réservées** : `spawn`/`start` refusent `WSH_COCKPIT_AGENT` en `user-preopen-*`
  ou `released` avec une erreur claire ; le flag interne `--preopen` lève le refus
  (garde-fou anti-méconfiguration, pas une frontière de sécurité).
- **`teardown_session`** (session.sh:520-569, point de passage unique du nettoyage)
  supprime désormais aussi `adopt-claim-<slug>` et `prefix-<slug>` (`keep-<slug>`
  n'y passe pas : teardown ne tourne jamais sur une keep).
- Changement de comportement voulu (vérifié 2026-07-27) : aujourd'hui
  `find_reusable_session` (session.sh:259-272) consulte `last_session`
  (session.sh:36-44) sans regarder le préfixe — `spawn audit-nas` puis `spawn local`
  rend deux fois la première session. Le registre remplace ce mémo-autorité ;
  préfixe sans possession → étapes 2-3 (provisoirement : scan/création actuels).
- Chemin spawn actuel : wsh-live.sh:440-466 (`FORCE=0` → réutilisation, sinon création).

## Tâches

- [ ] **RED d'abord** : cas de selftest (nouvelle sous-commande `selftest-adopt`, même
      pattern que les selftests existants) montrés rouges avant l'implémentation :
      alternance A→B→A (deux sessions possédées de préfixes différents → chaque `spawn
      <prefix>` retrouve LA bonne, jamais de misroute) ; deux `spawn` de préfixes
      différents → deux sessions ; N>1 au registre sans préfixe ni `last-session` →
      erreur explicite ; sessions de `start` atteignables uniquement par nom (sentinelle
      `(named)`) ; refus de collision de slug par `start` ; refus des clés réservées et
      levée par `--preopen`.
- [ ] Implémenter : pose du claim + `prefix-<slug>` à la création (`spawn` et `start`),
      étape 1 dans la résolution de `spawn`, nettoyage `teardown_session`, refus des
      clés réservées + flag `--preopen`.
- [ ] `last_session` reste écrite (mémo) mais ne fait plus autorité.
- [ ] `selftest-guard`, `selftest-live`, `selftest-cache` restent verts.

## Critère done

Cas `selftest-adopt` ci-dessus verts (RED documenté), anti-misroute prouvé par
l'alternance A→B→A, `stop` d'une session créée ne laisse ni claim ni `prefix-<slug>`
orphelin, selftests existants verts.

## Fin de session

Mettre à jour `STATE.md` (statut, `NEXT: step-1.4`) → commit signé → push de la branche
→ annoncer de taper `/exit`.
