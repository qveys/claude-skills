# Step 1.8 — `open --tab <nom>` : résolution d'onglet Wave par nom

Phase 1 · après step-1.7 · **Modèle : Sonnet**

## Objectif

`open` (et `spawn`, par pass-through) accepte `--tab <nom>` : résolution de l'onglet
Wave par nom via la DB SQLite vivante, bornée au workspace courant, déterministe et
inerte face aux noms hostiles.

## Contexte minimal (extraits spec v12, §4)

- **DB vivante = celle que `wsh wavepath data` désigne** — chemin résolu dynamiquement,
  JAMAIS codé en dur ; `~/Library/Application Support/waveterm/` héberge une DB
  divergente qui a déjà faussé une vérification. Si `wsh wavepath` échoue, `--tab`
  échoue proprement — il n'hérite PAS du fallback codé en dur de `wave_db_ro`
  (wave.sh:23-30, fallback ligne 26). Accès `?mode=ro`.
- **Requête v12** (spec §4, bloc SQL — la reprendre telle quelle) : CTE `workspace_tabs`
  bornée à `:ws` = `WAVETERM_WORKSPACEID`, union `pinnedtabids` (pinned=0) puis
  `tabids` (pinned=1), `ORDER BY pinned ASC, ord ASC`, **sans LIMIT** — la 1re ligne
  est l'élue, les suivantes alimentent le warning doublons. `$.pinnedtabids` peut être
  absent des blobs (pattern Go `omitempty`) : l'union défensive est obligatoire.
- **Neutralisation `sql_quote()` (v12)** : doubler chaque `'`, envelopper de quotes
  simples, requête passée en UN SEUL argument argv à `sqlite3` (jamais recomposée via
  echo/heredoc interprétés). `:ws` passe par le même `sql_quote()`. Pas de
  `.parameter set` (dot-commands ligne à ligne : un retour à la ligne est
  intransportable).
- **Erreurs** : hors de Wave (`WAVETERM_WORKSPACEID` absent) → échec propre, erreur
  explicite, pas de fallback arbitraire (le `LIMIT 1` de wave.sh:84-85 ne convient
  pas ici) ; onglet introuvable → warning + fallback comportement actuel (onglet
  courant/vivant) ; doublons → premier match dans l'ordre défini + warning listant
  TOUS les candidats ; nom ne résolvant que hors fenêtre courante → warning +
  fallback (inter-fenêtres hors périmètre v1).
- Une fois le tab résolu : même mécanique que l'existant — `open` exporte
  `WAVETERM_TABID` vers `wsh run` (wsh-live.sh:754).
- `--tab` est une option native de `open`/`spawn` (le wrapper la relaie telle quelle,
  fiche 1.9). Utiliser les mesures du rapport 1.1 (wavepath, pinnedtabids réels).

## Tâches

- [ ] **RED d'abord** : selftest sur **DB fixture** SQLite créée par le test (schéma
      minimal `db_workspace`/`db_tab`, jamais la vraie DB en écriture) — cas montrés
      rouges puis verts : résolution simple par nom ; homonyme dans un AUTRE workspace
      → ne matche pas ; doublons dans le workspace → élue = première dans l'ordre
      épinglés-puis-tabids (déterminisme vérifié sur ordre d'insertion inversé) +
      warning listant tous les candidats ; noms hostiles (`'`, `%`, retour à la ligne,
      `x'; DROP TABLE db_tab;--`) → résolution ou zéro ligne, jamais d'erreur de
      syntaxe ni d'altération ; `pinnedtabids` absent du blob → union toujours
      valide ; `WAVETERM_WORKSPACEID` absent → erreur explicite ; introuvable →
      warning + fallback.
- [ ] Implémenter `--tab` dans `open` (+ pass-through `spawn`), `sql_quote()` dans
      wave.sh, résolution `wsh wavepath data` sans fallback.
- [ ] `selftest-cache` (cache tab existant) et `selftest-guard` restent verts.

## Critère done

Cas fixture ci-dessus verts (RED documenté), la vraie DB n'est jamais ouverte
qu'en `?mode=ro`, échec propre hors Wave prouvé, selftests existants verts.

## Fin de session

Mettre à jour `STATE.md` (statut, `NEXT: step-1.9`) → commit signé → push de la branche
→ annoncer de taper `/exit`.
