# Step 1.11.1 — Balayage de sortie du wrapper : ne toucher que les sessions du run

Phase 1 · corrective issue de l'audit 1.11 (É1) · après step-1.11 · **Modèle : Sonnet**

## Objectif

Le balayage de sortie de `claude-cockpit.sh` ne doit jamais toucher une session d'un
AUTRE run de `claude-cockpit` : deux claude parallèles ne doivent pas se voler leurs
cockpits (décision actée, spec §1 « le wrapper balaie SES sessions »).

## Contexte minimal (rapport d'audit É1)

- Bug : la boucle finale de `claude-cockpit.sh` énumère `mux_list_sessions | grep
  '^cockpit-'` et agit sur toute session dont le claim porte une clé `user-preopen-*`
  — or ces clés sont indexées par GROUPE (`user-preopen-<n>`), pas par run : deux
  runs parallèles produisent les mêmes clés. Quand le run A sort pendant que le run B
  tourne, A détruit (`stop`) ou relâche les cockpits de B **non encore adoptés** (ils
  gardent leur pré-claim `user-preopen-<n>` tant que claude-B ne les adopte pas —
  potentiellement tout le run).
- La branche `owner = "$AGENT_KEY"` (`claude-<runid>`) est SAINE et ne doit pas
  changer : la clé est unique par run, et elle couvre volontairement aussi les
  sessions que claude a créées lui-même pendant le run (spec §1 : registre par run).
- Correctif : dans la boucle, la branche `user-preopen-*` n'agit que si `$s` fait
  partie de `ALL_SESSIONS` (les sessions que CE run a spawnées, déjà collectées).
  Appartenance testée par boucle bash 3.2 (pas de tableau associatif), comparaison
  d'égalité stricte de noms.
- Le moule de test existe : `selftest-wrapper` (selftests.sh, bloc step-1.9) stubbe
  `claude` et `wsh-live.sh` dans un PATH dédié, le faux `wsh-live.sh` crée de VRAIES
  sessions tmux via les primitives réelles — y ajouter les cas ci-dessous.

## Tâches

- [ ] **RED d'abord** : nouveau cas `selftest-wrapper` — fabriquer une session
      « étrangère » vivante `cockpit-…` avec un claim `user-preopen-1` posé par les
      primitives réelles, ABSENTE de la ligne de commande du wrapper ; lancer le
      wrapper (1 groupe + stub claude) ; après le balayage : la session étrangère est
      toujours vivante ET son claim est intact, tandis que la session du run a bien
      été balayée. Montrer le cas rouge sur le code actuel avant le fix.
- [ ] Cas complémentaire bon marché : session étrangère au claim `claude-<autre-runid>`
      (autre run, déjà protégée par l'inégalité de clé) → intacte — verrouille la
      non-régression de la branche saine.
- [ ] Implémenter la restriction d'appartenance à `ALL_SESSIONS` (branche
      `user-preopen-*` seulement).
- [ ] `selftest-wrapper` complet + `selftest-guard` verts.

## Critère done

Les nouveaux cas passent (RED documenté), la session étrangère survit avec claim
intact, aucun cas existant ne régresse.

## Fin de session

Mettre à jour `STATE.md` (statut, `NEXT: step-1.11.2`) → commit signé → push de la
branche → annoncer de taper `/exit`.
