# Step 1.1 — Inventaire de réalité et mesures préalables

Phase 1 · après step-0.1 · **Modèle : Sonnet**

## Objectif

Vérifier que les références de code et les affirmations mesurables de la spec v12 tiennent
sur la base actuelle (`main` mergé dans `feat/claude-cockpit-wrapper`), et mesurer les
trois mécanismes que le lot va exploiter — AVANT d'écrire la moindre ligne du lot.

## Contexte minimal

- Spec : `docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md` (v12, racine
  du dépôt). Elle cite des lignes de code datant du 2026-07-27 qui ont pu dériver.
- Décision actée n° 3 (CONVENTIONS.md) : mesurer avant d'affirmer, ne jamais déduire.
- Code : `wsh-cockpit/scripts/wsh-live.sh` + `wsh-cockpit/scripts/lib/{session,mux,gc,wave}.sh`.

## Tâches

- [ ] Re-vérifier chaque référence `fichier:ligne` citée par la spec (grep par nom de
      fonction, pas par numéro) et dresser la table « référence spec → référence
      actuelle » : `normalize_prefix`, clé agent par défaut, `last_session`,
      `find_reusable_session`, `teardown_session` (liste exacte des fichiers de cache
      supprimés), `mux_pane_command`, `mux_list_sessions`, `gc_should_kill` (règle
      session attachée), commentaire « never act on uncertain state », `wave_db_ro`
      (fallback codé en dur), `resolve_live_tab_cached` (LIMIT 1), validation de tab,
      `block_id_close`, `SESS_DEFAULT`, chemin `--force` de `spawn`, `gc` en arrière-plan
      au spawn, `WSH_WAIT_TIMEOUT` (défaut 300 s), `WSH_LIVE_SEP_REINIT` / probe
      `remote-init`, export `WAVETERM_TABID` dans `open`, comportement `--situate`.
- [ ] Confirmer l'absence de : sous-commande `release`, code claim/adopt,
      `claude-cockpit.sh` (sinon, consigner ce qui existe déjà — c'est un changement de
      donne à signaler).
- [ ] Trancher le compte de `selftest-guard` : CONVENTIONS.md annonce 41 cas, un
      comptage préliminaire (2026-08-05) trouve 28 appels `report_guard_case` — compter
      les cas EXÉCUTÉS (lancer le selftest en session jetable) et corriger CONVENTIONS.md
      ou consigner l'explication dans le rapport.
- [ ] **Mesure 1 — primitive no-clobber** (spec §2 « Primitives des transitions ») : sur
      APFS dans `~/.cache/wsh-cockpit/` (fichiers de test jetables), vérifier que
      `ln src dst` échoue bien (EEXIST, rc≠0) quand `dst` existe, réussit sinon ; que
      `mv -n` sort 0 même sans déplacer (la raison du choix de `ln`) ; que `mv` sur
      source disparue rend ENOENT rc≠0.
- [ ] **Mesure 2 — DB Wave** (spec §4) : `wsh wavepath data` rend-il toujours le chemin
      de la DB vivante ? `WAVETERM_WORKSPACEID` est-il présent dans l'environnement d'un
      bloc Wave ? Exécuter la requête v12 (avec `:ws`/`:nom` substitués à la main sur des
      valeurs réelles, lecture `?mode=ro` uniquement) : résout-elle l'onglet courant ?
      `$.pinnedtabids` existe-t-il dans les blobs actuels ?
- [ ] **Mesure 3 — `sql_quote()`** : prototyper la fonction (doubler `'`, envelopper de
      quotes) et prouver sur la DB en `?mode=ro` (ou une DB fixture) qu'un nom contenant
      `'`, `%`, un retour à la ligne et `x'; DROP TABLE db_tab;--` passe en littéral
      inerte (résolution ou zéro ligne — jamais d'erreur de syntaxe ni d'effet).
- [ ] Écrire `execution/rapport-step-1.1.md` : table des références, résultats des trois
      mesures, écarts avec la spec. Écart mineur (numéro de ligne) → noter simplement ;
      contradiction qui invalide un mécanisme du lot → le dire en tête du rapport, le
      consigner dans STATE.md et mettre `NEXT: PAUSE` (arbitrage pilote) au lieu de
      step-1.2.

## Critère done

`execution/rapport-step-1.1.md` existe, chaque référence citée par la spec y a une
correspondance actuelle (ou un écart signalé), les trois mesures ont un verdict
mesuré (pas déduit), et STATE.md consigne tout écart. Aucun fichier de `scripts/` modifié.

## Fin de session

Mettre à jour `STATE.md` (statut 1.1, `NEXT: step-1.2` — ou `PAUSE` si contradiction
majeure) → commit signé → push de la branche → annoncer de taper `/exit`.
