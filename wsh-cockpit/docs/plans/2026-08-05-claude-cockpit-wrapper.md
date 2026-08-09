# Lot — wrapper `claude-cockpit` : adoption de cockpits pré-ouverts par l'utilisateur

**Statut :** à implémenter (chantier relais, branche `feat/claude-cockpit-wrapper`,
fiches `execution/step-1.x-*.md`).
**Spec de référence :** `docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md`
(**v12**, 2026-08-05 — les 5 findings CodeRabbit de la PR #16 y sont intégrés ; la spec
fait foi sur tout détail de comportement, ce plan fait foi sur le découpage).
**Dépend de :** socle mergé sur `main` — garde own-session (exit 8), discrimination par la
forme (`looks_like_session`, exit 4), flag `--session`/`-s`, `mux_session_name`/
`mux_session_panes`, `selftest-guard` (41 cas). Le lot ne réimplémente rien de tout cela.
**Précédent de forme :** `docs/plans/2026-08-02-desambiguisation-argument-session.md`.

---

## 1. Le problème, en une phrase

L'utilisateur qui a préparé lui-même son cockpit (session tmux + bloc Wave, nommé, hoppé,
placé sur le bon onglet) ne peut pas le donner à claude : `spawn` en crée toujours un
nouveau — le wrapper `claude-cockpit` doit ouvrir ces cockpits, les offrir via
`WSH_COCKPIT_ADOPT`, et le skill doit savoir les adopter sans jamais en voler un à un
autre agent ni en détruire un qui appartient à l'utilisateur.

## 2. Ce qui existe, ce qui manque

Existe (lots précédents, vert sur `main`) : `spawn`/`start`/`stop`/`gc`/`open` et les
gardes citées ci-dessus ; `mux_pane_command` ; la sonde `--situate` et le framing
auto-porté (`WSH_LIVE_SEP_REINIT`) ; `resolve_live_tab_cached` (lecture DB Wave `?mode=ro`).

Manque (ce lot, = §7 lot 2 de la spec) : le registre des claims et ses primitives
atomiques ; l'ordre de résolution en 3 étapes de `spawn` (registre → adoption → scan) ;
la sous-commande `release` et la sémantique `--keep` (sticky, v12) ; la passe d'hygiène
des marqueurs dans `gc` ; `open --tab <nom>` ; le wrapper `claude-cockpit.sh` lui-même ;
les selftests `claim`/`adopt`/`wrapper` ; les amendements de docs.

## 3. Design retenu

Le design complet est dans la spec v12 — points cardinaux, pour lecture rapide :

- **Le registre des claims est l'autorité de résolution** (`adopt-claim-<slug>`,
  ligne 1 = clé agent) ; `last-session` est rétrogradé en mémo. Résolution `spawn` en
  3 étapes : mes sessions (registre) → adoption (`WSH_COCKPIT_ADOPT`, pré-claims
  `user-preopen-*`/`released`) → scan/création excluant toute session claimée.
- **Transitions de claim = primitives no-clobber nommées** (v12, table « Primitives des
  transitions ») : O_EXCL à la création, `mv` pour la consommation (exclusion par
  disparition de la source), `ln`+`rm` pour rollback/restauration (destination-exclusif),
  consommation préalable pour le remplacement d'orphelin. Invariants I1-I4.
- **Adoption = consommation + vérification de contenu + sonde systématique**
  (`hostname; pwd; whoami`, framing auto-porté), garde busy-pane élargie (shell nu OU
  hop ssh/tailscale/mosh), rollback no-clobber sur tout échec.
- **Propriété** : défaut = pleine propriété claude ; `--keep` = la fenêtre reste à
  l'utilisateur, marqueur **sticky** (v12) — `stop` sur keep passe par `release`, jamais
  teardown, quel que soit l'adoptant.
- **Le wrapper** : groupes `--and`, pass-through vers `spawn` (`--force` systématique,
  clés `user-preopen-<n>` jamais exportées vers claude), export `WSH_COCKPIT_ADOPT` +
  `WSH_COCKPIT_AGENT=claude-<runid>`, claude en avant-plan, balayage à la sortie.
- **`open --tab <nom>`** : résolution par la DB Wave vivante (`wsh wavepath data`),
  requête bornée au workspace courant, ordre déterministe, neutralisation `sql_quote()`
  (v12).
- **Hygiène `gc`** : marqueurs de sessions mortes balayés sur listing FIABLE uniquement,
  seuil d'âge 5 min, passe dédiée `.won-*` (pid mort ET âge > 2×`WSH_WAIT_TIMEOUT`).

## 4. Découpage en étapes (une fiche = une session relais)

| Fiche | Livrable vérifiable | Modèle |
|---|---|---|
| step-1.1 inventaire-et-mesures | Rapport `execution/rapport-step-1.1.md` : références de code de la spec re-vérifiées sur la base actuelle, mesures Wave DB (`wsh wavepath data`, requête workspace, doublons) et primitive `ln` no-clobber mesurée sur APFS | Sonnet |
| step-1.2 primitives-claim | `scripts/lib/claim.sh` (machine d'états + primitives I1-I4) + `selftest-claim` vert, RED-first | Sonnet |
| step-1.3 registre-creation | Claims posés à la création (`spawn`/`start`), `prefix-<slug>`/sentinelle `(named)`, étape 1 de résolution (registre remplace le mémo-autorité), nettoyage `teardown_session` ; cas selftest alternance A→B→A | Sonnet |
| step-1.4 adoption-etape-2 | Étape 2 complète : parsing `WSH_COCKPIT_ADOPT`, adoption ciblée/nominale, garde busy-pane élargie, sonde systématique, rollback, warning session morte ; cas selftest course A/B | Sonnet |
| step-1.5 scan-etape-3 | Étape 3 : exclusion des sessions claimées (I3), reprise legacy = claim + sonde, `--force` = création directe sans orpheliner ; cas selftest | Sonnet |
| step-1.6 release-et-keep | Sous-commande `release <session>`, chemin `stop`-sur-keep, keep sticky (v12), continuité `seq` ; cas selftest | Sonnet |
| step-1.7 gc-hygiene | `gc` épargne les keep (attachée toujours, détachée < 24 h), passe d'hygiène des marqueurs + `.won`, `doctor` informatif ; cas selftest | Sonnet |
| step-1.8 open-tab | `open --tab <nom>` (requête v12, `sql_quote()`, erreurs propres) ; selftest sur DB fixture | Sonnet |
| step-1.9 wrapper | `scripts/claude-cockpit.sh` + `selftest-wrapper` (claude stubbé) + exposition PATH | Sonnet |
| step-1.10 docs | SKILL.md (section adoption + règle « created **or adopted without `--keep`** » + consignes sous-agents), `session-lifecycle.md`, `gotchas.md` | Sonnet |
| step-1.11 audit-final | Audit de cohérence spec v12 ↔ code ↔ selftests, findings couverts, redécoupage si trous | Fable |
| step-1.12 pr-de-fin-de-lot | PR vers `main` (ruleset : signatures, revue Copilot, fils résolus), selftests verts prouvés | Sonnet |

Ordre strictement séquentiel : 1.2 fournit les primitives à 1.3-1.7 ; 1.8 est
indépendante mais reste en séquence (relais série) ; 1.9 consomme tout ; 1.11 juge tout.
Si une mesure de 1.1 contredit la spec : consigner dans STATE.md ; contradiction qui
invalide une fiche → `NEXT: PAUSE` + proposition d'arbitrage (fiche Fable).

## 5. Tests

- **RED-first systématique** : tout comportement nouveau montre son test rouge avant le
  fix (consigné dans STATE.md ou le rapport de fiche).
- Nouveaux selftests : `selftest-claim` (machine d'états, primitives, courses),
  `selftest-adopt` (la liste complète du §6 de la spec v12), `selftest-wrapper`
  (parsing, env, abort, balayage — claude mocké par stub dans le PATH).
- **`selftest-guard` (41 cas) reste vert à chaque fin de fiche touchant `scripts/`** ;
  les gardes des lots précédents ne sont jamais affaiblies sans cas rouge préalable.
- Les selftests se lancent depuis une session tmux jetable, jamais depuis le terminal
  réel (convention du chantier).

## 6. Non-périmètre

- `--tab` inter-fenêtres / inter-workspaces (périmètre v1 : fenêtre Wave courante).
- Toute retouche des gardes des lots précédents au-delà de leur consommation.
- La canonicalisation généralisée des noms (`mux_session_name` propagé aux commandes
  *target-pane*) — backlog préexistant, hors lot.
- Parité zellij complète : le lot respecte le backend (`mux_list_sessions`, passe
  d'hygiène fail-safe), sans étendre les fonctionnalités zellij.

## 7. Contraintes permanentes du chantier

- Commits signés (`git commit -S`) ; jamais `--no-gpg-sign`, jamais de modification de la
  config git ; app 1Password ouverte et déverrouillée requise (sinon `NEXT: PAUSE`).
- Aucune attribution IA dans les messages de commit.
- `git push` de la **branche** `feat/claude-cockpit-wrapper` en fin de chaque session de
  relais ; **jamais de push sur `main`** (PR obligatoire, fiche 1.12).
- bash 3.2 (macOS), `set -euo pipefail`, `${TMUX:-}` / `${TMUX_PANE:-}`, idiome
  `${ARR[@]+"${ARR[@]}"}`.
- Aucun `kill-session` sans cible explicite ancrée `-t "=nom"`, jamais de `kill-server` ;
  sessions de test à préfixe dédié, nettoyées par `trap … EXIT`.
- Sémantique tmux `=` : mesurer avant d'affirmer (`docs/gotchas.md`), jamais déduire.
