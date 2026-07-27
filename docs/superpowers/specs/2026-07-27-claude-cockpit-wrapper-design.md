# Design — wrapper `claude-cockpit` (cockpit pré-ouvert par l'utilisateur)

Date : 2026-07-27
Statut : validé par Quentin (brainstorming du 2026-07-27)
Portée : skill `wsh-cockpit` (`wsh-cockpit/scripts/`, `wsh-cockpit/SKILL.md`, `wsh-cockpit/docs/`)

## Objectif

Permettre à l'utilisateur de démarrer `claude` en ayant lui-même paramétré et ouvert le
cockpit (session tmux + bloc Wave) **avant** le démarrage de claude. La session Claude
Code adopte alors ce(s) cockpit(s) pré-ouvert(s) au lieu d'en spawner de nouveaux.

## Décisions actées

| Question | Décision |
|---|---|
| Geste utilisateur | Wrapper tout-en-un `claude-cockpit` (ouvre le(s) cockpit(s) puis lance claude) |
| Propriété du cockpit adopté | Configurable : défaut = pleine propriété claude (`stop` ferme, `gc` balaie) ; `--keep` = reste à l'utilisateur |
| Paramétrage | Pass-through complet des options de `spawn` + options propres : `--keep`, `--tab <nom>`, multi-cockpits `--and` |
| Canal d'adoption | Variable d'environnement héritée `WSH_COCKPIT_ADOPT` (jamais de marqueur global : deux claude parallèles ne doivent pas se voler leurs cockpits) |
| Situation du shell | **Sonde `hostname; pwd; whoami` systématique et non optionnelle à l'adoption** (comportement `--situate` appliqué d'office) |

## 1. Le wrapper `claude-cockpit`

Fichier : `wsh-cockpit/scripts/claude-cockpit.sh`, versionné avec le skill, exposé dans
le PATH de l'utilisateur : lien symbolique `~/.local/bin/claude-cockpit` si ce dossier
est déjà dans le PATH, sinon alias dans `~/.zshrc` (constat à faire à l'implémentation,
dans cet ordre de préférence).

```bash
claude-cockpit [cockpit-1] [--and cockpit-2]... [-- args-claude]
# chaque groupe cockpit = [prefix] [--keep] [--tab <nom>] [+ tout flag de spawn relayé
#                          tel quel : --pre <host>, --situate, --force, …]

# Exemple :
claude-cockpit audit-nas --pre nas-de-quentin --tab T5 --and local -- --resume
```

Comportement :

1. Pour chaque groupe (séparé par `--and`) : appel de `wsh-live.sh spawn <opts>` — qui
   crée la session tmux et ouvre le bloc Wave — et collecte du nom de session retourné.
   Les flags propres au wrapper (`--keep`, `--tab`) sont extraits ; tout le reste est
   relayé tel quel à `spawn` (pass-through futur-proof).
2. `export WSH_COCKPIT_ADOPT=sess1[,sess2...]` puis `exec claude [args après --]`.
3. **Un spawn échoue → claude n'est pas lancé.** Message d'erreur clair ; les cockpits
   déjà ouverts restent visibles pour diagnostic (pas de rollback automatique).

## 2. Adoption côté skill (`spawn`)

`spawn [prefix]` consulte `WSH_COCKPIT_ADOPT` **en priorité**, avant sa logique
actuelle (`find_reusable_session`) :

- Candidates : sessions de la liste, vivantes, non encore réclamées par un autre agent.
  Claim par session via marqueur `~/.cache/wsh-cockpit/adopt-claim-<slug>` (contenu :
  clé agent), pour que des agents parallèles se répartissent les cockpits ; un même
  agent qui re-spawn retrouve la sienne.
- Choix : si le `prefix` demandé matche le nom d'une session adoptable → celle-là ;
  sinon la première libre ; sinon comportement actuel inchangé.
- Session morte dans la liste → warning stderr + fallback sur la logique normale.
- Garde-fou : ne jamais adopter la session tmux qui héberge claude lui-même
  (comparaison avec `$TMUX` / session courante). Vérifier au passage l'état réel de la
  garde `own_tmux_session` mentionnée en mémoire mais introuvable dans le code installé.
- À l'adoption : **sonde de situation systématique** (`hostname; pwd; whoami` +
  `remote-init` auto best-effort si hôte distant détecté — le comportement `--situate`
  est appliqué même sans le flag). Une session pré-ouverte est d'état inconnu pour
  l'agent : l'opt-in devient un défaut obligatoire.
- Sortie : `spawn` annonce `adopted user cockpit: <sess>` puis la sortie de la sonde.

## 3. Propriété / cycle de vie

- **Défaut** : la session adoptée devient une session claude à part entière — `stop` la
  ferme (bloc Wave inclus via `teardown_session`), `gc` la balaie selon les règles
  existantes.
- **`--keep`** : le wrapper pose `~/.cache/wsh-cockpit/keep-<slug>` ; `stop` oublie
  l'état agent (state files) mais ne tue ni le tmux ni le bloc Wave ; `gc` ignore la
  session. L'utilisateur ferme lui-même quand il veut.

## 4. `open --tab <nom>`

Nouvelle option de `open`, relayée par `spawn` : résolution de l'onglet Wave **par
nom** via la DB SQLite Wave déjà lue en lecture seule par `resolve_live_tab_cached`.
Onglet introuvable → warning + fallback sur le comportement actuel (onglet
courant/vivant). Bénéfice collatéral : les agents peuvent aussi cibler un onglet (ex.
la discipline « ops sur T5 »).

## 5. Gestion d'erreurs (récapitulatif)

| Situation | Comportement |
|---|---|
| `WSH_COCKPIT_ADOPT` absent/vide | Comportement actuel strictement inchangé |
| Session listée morte | Warning stderr, fallback logique normale |
| Toutes les sessions déjà réclamées | Fallback logique normale |
| Session listée = tmux hébergeant claude | Refus d'adoption, warning, fallback |
| `--tab` introuvable | Warning + fallback onglet courant |
| Échec d'un `spawn` dans le wrapper | claude non lancé, erreur claire, pas de rollback |

## 6. Docs et tests

- `SKILL.md` : section « Cockpit pré-ouvert par l'utilisateur » (wrapper, adoption,
  sonde systématique, propriété).
- `docs/session-lifecycle.md` : règles de cycle de vie de l'adoption (`--keep`, claim,
  gc).
- Nouveau `selftest-adopt` dans la lignée des selftests existants : adoption simple,
  claim multi-agents, `--keep` vs défaut, session morte, fallback `--tab`.
