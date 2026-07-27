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
  agent qui re-spawn retrouve la sienne. **Le claim est atomique** : création en
  `set -o noclobber` (O_EXCL) — jamais de test-puis-écriture ; le perdant de la course
  passe à la candidate suivante.
- **La variable étant héritée par tous les shells de la session claude, les sous-agents
  (scout/builder/mech…) peuvent aussi adopter** : premier arrivé, premier servi via le
  claim atomique. C'est voulu — les sous-agents travaillent pour le compte de la même
  session ; le claim garantit qu'un cockpit en cours d'usage n'est jamais volé.
- Choix : **chemin nominal = première session libre de la liste** (le préfixe de
  l'agent ne matchera généralement pas tes noms). Exception prioritaire : si le
  `prefix` demandé est exactement le segment `<prefix>` d'un nom `cockpit-<prefix>-*`
  adoptable, cette session-là est choisie. Aucune adoptable → comportement actuel
  inchangé.
- Session morte dans la liste → warning stderr + fallback sur la logique normale.
- Garde-fou : ne jamais adopter la session tmux qui héberge claude lui-même.
  **Constat vérifié le 2026-07-27 : la garde `own_tmux_session` /
  `session_safe_to_reuse` n'existe PAS sur `main`** — elle vit sur la branche non
  mergée `feat/wsh-cockpit-session-workflow` (commit `a920197`) ; `gc.sh:25` la
  mentionne en commentaire comme si elle existait. **Prérequis de ce chantier** : la
  porter (cherry-pick ou réimplémentation) sur `main` et l'appliquer à l'adoption ET à
  `find_reusable_session`.
- À l'adoption : **sonde de situation systématique** (`hostname; pwd; whoami` +
  `remote-init` auto best-effort si hôte distant détecté — le comportement `--situate`
  est appliqué même sans le flag). Une session pré-ouverte est d'état inconnu pour
  l'agent : l'opt-in devient un défaut obligatoire.
- Sortie : `spawn` annonce `adopted user cockpit: <sess>` puis la sortie de la sonde.

## 3. Propriété / cycle de vie

- **Défaut** : la session adoptée devient une session claude à part entière — `stop` la
  ferme (bloc Wave inclus via `teardown_session`), `gc` la balaie selon les règles
  existantes. **Conséquence UX assumée** (décision explicite de Quentin) : la fenêtre
  pré-ouverte disparaît immédiatement au `stop`, sans linger — contrairement au bloc
  `rexec` et ses 60 s.
- **`--keep`** : le wrapper pose `~/.cache/wsh-cockpit/keep-<slug>` ; `stop` oublie
  l'état agent (state files) mais ne tue ni le tmux ni le bloc Wave ; `gc` ignore la
  session. L'utilisateur ferme lui-même quand il veut.

### Cycle de vie des marqueurs (`adopt-claim-<slug>`, `keep-<slug>`)

Aucun marqueur ne doit survivre à sa session — même après un crash de claude :

- `teardown_session()` (session.sh, déjà point de passage unique du nettoyage cache)
  supprime `adopt-claim-<slug>` avec les autres state files. `keep-<slug>` n'y passe
  pas (par définition, `teardown_session` ne tourne pas sur une session keep).
- `gc` gagne une passe d'hygiène : tout marqueur `adopt-claim-*` ou `keep-*` dont la
  session tmux correspondante est morte est supprimé (la session keep elle-même n'est
  jamais tuée par `gc` tant qu'elle vit — seul son marqueur orphelin est balayé après
  fermeture manuelle par l'utilisateur).
- Un claim dont l'agent a disparu (claude crashé) est couvert par ces deux voies : la
  session finit soit `stop`-ée par un autre agent, soit balayée par `gc` (idle 24 h),
  et le claim part avec elle.

## 4. `open --tab <nom>`

Nouvelle option de `open`, relayée par `spawn` : résolution de l'onglet Wave **par
nom** via la DB SQLite Wave déjà lue en lecture seule par `resolve_live_tab_cached`.

**Faisabilité vérifiée le 2026-07-27** sur la DB réelle
(`~/Library/Application Support/waveterm/db/waveterm.db`, accès `?mode=ro`) :

```sql
SELECT oid FROM db_tab WHERE json_extract(data, '$.name') = 'T46';
-- → ae9dc6f9-05bb-4145-a2ee-b730b95ff4bd
```

`wsh` CLI n'offre pas de listing nom→tab id (`wsh blocks list` ne montre que les ids) ;
la DB est donc la seule voie. **Pas de contrainte d'unicité sur les noms** : en cas de
doublon, premier match + warning listant les candidats. Onglet introuvable → warning +
fallback sur le comportement actuel (onglet courant/vivant). Bénéfice collatéral : les
agents peuvent aussi cibler un onglet (ex. la discipline « ops sur T5 »).

## 5. Gestion d'erreurs (récapitulatif)

| Situation | Comportement |
|---|---|
| `WSH_COCKPIT_ADOPT` absent/vide | Comportement actuel strictement inchangé |
| Session listée morte | Warning stderr, fallback logique normale |
| Toutes les sessions déjà réclamées | Fallback logique normale |
| Session listée = tmux hébergeant claude | Refus d'adoption, warning, fallback |
| `--tab` introuvable | Warning + fallback onglet courant |
| Plusieurs onglets portant le nom `--tab` | Premier match + warning listant les candidats |
| Claim perdu (course entre deux agents) | Passage atomique à la candidate suivante |
| Échec d'un `spawn` dans le wrapper | claude non lancé, erreur claire, pas de rollback |

## 6. Docs et tests

- `SKILL.md` : section « Cockpit pré-ouvert par l'utilisateur » (wrapper, adoption,
  sonde systématique, propriété). **Amendement obligatoire de la règle existante**
  « Only delete blocks/sessions **you** created » → « …you created **or adopted
  without `--keep`** » — sinon deux consignes contradictoires cohabitent.
- `docs/session-lifecycle.md` : règles de cycle de vie de l'adoption (`--keep`, claim
  atomique, hygiène des marqueurs par `gc`).
- Nouveau `selftest-adopt` dans la lignée des selftests existants : adoption simple,
  claim multi-agents (course atomique), `--keep` vs défaut, session morte, fallback
  `--tab`, **sonde systématique effectivement exécutée à l'adoption**.
- **`selftest-wrapper`** : le wrapper lui-même — parsing des groupes `--and`,
  extraction `--keep`/`--tab` vs pass-through, contenu de `WSH_COCKPIT_ADOPT`, abort
  sans lancement de claude si un spawn échoue (claude mocké par un stub dans le PATH).
