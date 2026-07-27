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
| Cycle de vie côté wrapper | **`--force` systématique** : chaque run crée des cockpits neufs, jamais de réutilisation inter-runs (dissout claims orphelins post-crash et collisions entre deux claude parallèles) |

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
   **Isolation de clé obligatoire** : chaque spawn du wrapper tourne sous
   `WSH_COCKPIT_AGENT=user-preopen-<n>` (n = index du groupe), **portée limitée à
   l'appel de spawn — jamais exportée vers claude**. Sans cela, le wrapper écrirait
   `last-session-default`, et le premier `spawn` de l'agent principal (clé `default`
   elle aussi) trouverait la session par la voie 1 — court-circuitant claim ET sonde
   systématique.
   **`--force` systématique** : le wrapper passe toujours `--force` à ses spawns —
   chaque run crée des cockpits neufs, **jamais de réutilisation d'un run précédent**.
   C'est ce qui rend structurellement impossibles le cockpit zombie inadoptable
   (claim orphelin d'un claude crashé sur une session ré-offerte) et le vol de
   cockpit entre deux claude parallèles (un run n'offre que des sessions qu'il vient
   de créer). Coût assumé : après un crash de claude, les fenêtres du run précédent
   restent ouvertes jusqu'au `gc` (24 h) ou fermeture manuelle.
2. `export WSH_COCKPIT_ADOPT=sess1[,sess2...]` puis `exec claude [args après --]`.
3. **Un spawn échoue → claude n'est pas lancé.** Message d'erreur clair ; les cockpits
   déjà ouverts restent visibles pour diagnostic (pas de rollback automatique).

## 2. Adoption côté skill (`spawn`)

**Ordre de résolution de `spawn [prefix]`** (l'adoption s'insère en 2, pas en tête —
sinon un agent qui re-spawne alors que sa `last-session` est déjà une session adoptée
en adopterait une deuxième) :

1. **Réutilisation existante, rendue sensible au préfixe** : la `last-session-<key>`
   de l'agent, si vivante ET compatible avec le préfixe demandé — c'est-à-dire si
   aucun préfixe n'est demandé, si le préfixe **enregistré** de la session est égal au
   préfixe demandé, **ou si la session porte un `adopt-claim` de cet agent** : une
   session adoptée est exempte du filtre de préfixe (tes noms ne matcheront jamais les
   préfixes des agents, par conception — sans cette exemption, tout re-spawn avec
   préfixe évincerait la session adoptée vers la voie 3 ; caveat des clés `default`
   partagées inchangé).
   **Préfixe enregistré, pas parsé** : `spawn` écrit le préfixe normalisé dans
   `~/.cache/wsh-cockpit/prefix-<slug>` à la création ; le test de compatibilité lit
   ce fichier. Le parsing de nom (`^cockpit-(.+)-[0-9]{6}(-[0-9]+)?$`) ne sert que de
   fallback pour les sessions antérieures à ce chantier — il est ambigu par
   construction (un préfixe finissant par 6 chiffres, ex. `foo-123456`, matche aussi
   le motif du préfixe `foo`).
   **Changement de comportement vérifié le 2026-07-27 et voulu** : aujourd'hui
   `find_reusable_session()` (session.sh:76-89) consulte `last_session()`
   (session.sh:36-44) qui retourne la session mémorisée sans regarder le préfixe —
   `spawn audit-nas` puis `spawn local` rend deux fois la première session, ce qui
   rendrait le multi-cockpit inutilisable par un même agent. En cas d'incompatibilité
   de préfixe → voies 2/3. La voie 1 couvre le re-spawn après adoption
   (`remember_session` aura enregistré la session adoptée).
2. **Adoption** : sessions de `WSH_COCKPIT_ADOPT` vivantes et non réclamées.
3. **Logique actuelle** : scan `cockpit-<prefix>-*` puis création.

Règles d'adoption :

- Claim par session via marqueur `~/.cache/wsh-cockpit/adopt-claim-<slug>` (contenu :
  clé agent + pid, pour le debug). **Le claim est atomique** : création en
  `set -o noclobber` (O_EXCL) — jamais de test-puis-écriture ; le perdant de la course
  passe à la candidate suivante. Le claim n'a pas de rôle de re-reconnaissance (c'est
  la voie 1 qui s'en charge) : c'est un verrou one-shot anti-double-adoption.
- **La variable étant héritée par tous les shells de la session claude, les sous-agents
  (scout/builder/mech…) peuvent aussi adopter** : premier arrivé, premier servi via le
  claim atomique. C'est voulu — les sous-agents travaillent pour le compte de la même
  session. **Limite connue et assumée** : la clé agent par défaut est `"default"`
  (session.sh:26) ; un sous-agent qui n'exporte pas son propre `WSH_COCKPIT_AGENT`
  partage la clé — et donc la `last-session` — de l'agent principal (voie 1), défaut
  préexistant du skill que l'adoption n'aggrave ni ne corrige. Le SKILL.md devra
  durcir la recommandation : tout sous-agent qui spawne un cockpit **doit** exporter
  un `WSH_COCKPIT_AGENT` distinct.
- Choix : **chemin nominal = première session libre de la liste** (le préfixe de
  l'agent ne matchera généralement pas tes noms). Exception prioritaire : match
  **ancré** du préfixe demandé sur le motif `^cockpit-<prefix>-[0-9]{6}(-[0-9]+)?$`
  (forme produite par `unique_session_name`, session.sh:7-18 — le motif reste exact
  même avec des tirets dans le préfixe). Aucune adoptable → voie 3.
- Session morte dans la liste → warning stderr **au premier constat seulement**
  (mémorisé par agent, pas répété à chaque spawn) + fallback sur la logique normale.
- **`--force` saute les voies 1 ET 2** : c'est le geste « donne-moi un cockpit neuf,
  pas celui de l'utilisateur » (aujourd'hui `--force` ne saute que la voie 1).
- **Un sous-agent qui adopte doit relâcher** : la règle de cleanup du skill s'étend —
  en fin de tâche, un sous-agent `stop`/`release_session` ce qu'il a créé **ou
  adopté** ; sinon son claim ne se libère jamais et le cockpit pré-ouvert est consommé
  définitivement. Consigne SKILL.md + selftest.
- **Sonde auto-portante** : la sonde systématique d'adoption utilise le framing
  auto-porté (`WSH_LIVE_SEP_REINIT=1`, même mécanique que le probe de `remote-init`,
  wsh-live.sh:789) — une session `--keep` que l'utilisateur a ssh-hoppée à la main
  entre deux runs n'a pas le flag sticky remote-mode, et une sonde en framing normal y
  vomirait des erreurs de helpers dans la fenêtre de l'utilisateur.
- Garde-fou : ne jamais adopter la session tmux qui héberge claude lui-même.
  **Constat re-vérifié le 2026-07-27 (revue indépendante) : RÉGRESSION.** La garde
  `own_tmux_session` / `session_safe_to_reuse` a été mergée sur `main` (`a920197`,
  présente jusqu'à `7057950`) puis **supprimée silencieusement de session.sh par
  `9863c07`** (« auto-close the Wave block on stop/gc »), dont le message ne dit rien
  de cette suppression ; `gc.sh:25` la cite encore en commentaire ;
  `mux_pane_command` (mux.sh:93) a survécu. **Prérequis de ce chantier (lot 1)** : la
  réintroduire par réimplémentation sur la base actuelle (le cherry-pick de `a920197`
  ne s'applique plus proprement), appliquée à l'adoption ET à `find_reusable_session`,
  avec un message de commit nommant la régression.
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
- **`--keep`** : le wrapper pose `~/.cache/wsh-cockpit/keep-<slug>` ; `stop` passe par
  un **nouveau chemin de nettoyage partiel `release_session()`** (session.sh, à côté de
  `teardown_session()`) : supprime `last-session-<key>` (si elle pointe cette session)
  **et le claim** — la session redevient adoptable par un autre agent de la même
  session claude (`WSH_COCKPIT_ADOPT` est toujours dans l'environnement) — mais ne
  touche ni le tmux, ni le bloc Wave, ni `keep-<slug>`, **ni `seq-<slug>` /
  `oneshot-ssh-<slug>`** : ces fichiers sont *par session* (pas « de l'agent ») et le
  compteur de framing doit rester continu — le remettre à zéro ferait matcher au
  prochain adoptant un footer `└─[#N] exit` périmé du scrollback (`wait-done`
  menteur, `output` extrayant le mauvais segment). `gc` ignore la session.
  L'utilisateur ferme lui-même quand il veut.

### Cycle de vie des marqueurs (`adopt-claim-<slug>`, `keep-<slug>`)

Aucun marqueur ne doit survivre à sa session — même après un crash de claude :

- `teardown_session()` (session.sh, déjà point de passage unique du nettoyage cache)
  supprime `adopt-claim-<slug>` avec les autres state files. `keep-<slug>` n'y passe
  pas (par définition, `teardown_session` ne tourne pas sur une session keep).
- `gc` gagne une passe d'hygiène : tout marqueur `adopt-claim-*` ou `keep-*` dont la
  session tmux correspondante est morte est supprimé (la session keep elle-même n'est
  jamais tuée par `gc` tant qu'elle vit — seul son marqueur orphelin est balayé après
  fermeture manuelle par l'utilisateur). Correspondance marqueur↔session : slugifier
  les noms des sessions vivantes (même fonction de slug que l'écriture) et supprimer
  tout marqueur dont le slug n'apparaît pas — jamais de dé-slugification. La même
  passe balaie les `last-session-user-preopen-*` du wrapper pointant une session
  morte (inoffensifs — `last_session()` vérifie la vivacité — mais autant les tenir
  propres), ainsi que les `tab-`, `block-`, `cm-` et `prefix-` de sessions mortes —
  aujourd'hui nettoyés uniquement par `teardown_session`, donc jamais pour une
  session keep fermée à la main par l'utilisateur.
- Un claim dont l'agent a disparu (claude crashé) est couvert par ces deux voies : la
  session finit soit `stop`-ée par un autre agent, soit balayée par `gc` (idle 24 h),
  et le claim part avec elle.

## 4. `open --tab <nom>`

Nouvelle option de `open`, relayée par `spawn` : résolution de l'onglet Wave **par
nom** via la DB SQLite Wave déjà lue en lecture seule par `resolve_live_tab_cached`.

**Faisabilité vérifiée le 2026-07-27** — avec un piège découvert par la revue
indépendante : la DB vivante est celle que **`wsh wavepath data` désigne**
(aujourd'hui `~/.local/share/waveterm/db/waveterm.db`) ;
`~/Library/Application Support/waveterm/` héberge un snapshot périmé qui a faussé une
première vérification. **Le chemin est donc résolu dynamiquement via
`wsh wavepath data` — jamais codé en dur.** Requête re-validée sur la DB vivante
(accès `?mode=ro`) :

```sql
-- Vivacité OBLIGATOIRE : ne retenir que les onglets référencés par un workspace.
-- (la validation actuelle de wave.sh:113 ne teste que l'existence dans db_tab —
--  insuffisant pour une résolution par nom.)
WITH workspace_tabs AS (
  SELECT DISTINCT json_each.value AS tabid
  FROM db_workspace, json_each(db_workspace.data, '$.tabids')
)
SELECT oid FROM db_tab
WHERE json_extract(data, '$.name') = :nom
  AND oid IN (SELECT tabid FROM workspace_tabs);
```

`$.pinnedtabids` **n'existe pas** dans `db_workspace` (vérifié sur la DB vivante) —
pas d'union à faire. `wsh` CLI n'offre pas de listing nom→tab id (`wsh blocks list`
ne montre que les ids) ; la DB est donc la seule voie. **Périmètre v1 : la fenêtre
Wave courante uniquement** — `open` exporte `WAVETERM_TABID` avec le workspace
courant (wsh-live.sh:696), un onglet d'une autre fenêtre ferait échouer `wsh run` ;
si le nom ne résout que hors de la fenêtre courante → warning + fallback,
l'inter-fenêtres est hors périmètre. **Pas de contrainte d'unicité sur les noms** :
en cas de doublon dans la fenêtre courante, premier match + warning listant les
candidats. Onglet introuvable → warning + fallback sur le comportement actuel
(onglet courant/vivant). Bénéfice collatéral : les
agents peuvent aussi cibler un onglet (ex. la discipline « ops sur T5 »).

## 5. Gestion d'erreurs (récapitulatif)

| Situation | Comportement |
|---|---|
| `WSH_COCKPIT_ADOPT` absent/vide | Comportement actuel strictement inchangé |
| Session listée morte | Warning stderr au premier constat (mémorisé, pas répété), fallback logique normale |
| Toutes les sessions déjà réclamées | Fallback logique normale |
| Session listée = tmux hébergeant claude | Refus d'adoption, warning, fallback |
| `--tab` introuvable | Warning + fallback onglet courant |
| Plusieurs onglets portant le nom `--tab` | Premier match **dans la fenêtre courante** + warning listant les candidats ; matches d'autres fenêtres ignorés (hors périmètre v1) |
| Claim perdu (course entre deux agents) | Passage atomique à la candidate suivante |
| `spawn --force` d'un agent | Saute les voies 1 ET 2 — cockpit neuf garanti, jamais celui de l'utilisateur |
| Crash de claude | Cockpits du run laissés ouverts (gc 24 h ou fermeture manuelle) ; le run suivant du wrapper n'en réutilise aucun (`--force` systématique) |
| `last-session` vivante mais préfixe incompatible | Voies 2/3 — sauf session adoptée par cet agent (`adopt-claim`), qui reste en voie 1 |
| Session `--keep` relâchée (`release_session`) puis re-demandée | Ré-adoptable via voie 2 (claim libéré), y compris par l'agent qui l'a relâchée |
| Échec d'un `spawn` dans le wrapper | claude non lancé, erreur claire, pas de rollback |

## 6. Docs et tests

- `SKILL.md` : section « Cockpit pré-ouvert par l'utilisateur » (wrapper, adoption,
  sonde systématique, propriété). **Amendement obligatoire de la règle existante**
  « Only delete blocks/sessions **you** created » → « …you created **or adopted
  without `--keep`** » — sinon deux consignes contradictoires cohabitent.
- `docs/session-lifecycle.md` : règles de cycle de vie de l'adoption (`--keep`, claim
  atomique, hygiène des marqueurs par `gc`) — **et amender le passage décrivant la
  réutilisation inconditionnelle de `spawn`**, désormais filtrée par préfixe.
- `docs/gotchas.md` : même amendement (« spawn without `--force` will reuse it » n'est
  plus vrai pour un préfixe incompatible) + gotcha sonde auto-portante sur session
  keep re-hoppée.
- Nouveau `selftest-adopt` dans la lignée des selftests existants : adoption simple,
  claim multi-agents (course atomique), `--keep` vs défaut, session morte, fallback
  `--tab`, **sonde systématique effectivement exécutée à l'adoption**, **voie 1
  sensible au préfixe** (deux `spawn` de préfixes différents → deux sessions ; même
  préfixe → réutilisation ; **re-spawn avec un autre préfixe après adoption → la
  session adoptée est conservée, pas évincée**), **continuité du compteur `seq` après
  `release_session` + ré-adoption** (aucun match de footer périmé), **`--force` saute
  l'adoption**, **release par un sous-agent** (claim libéré en fin de tâche).
- **`selftest-wrapper`** : le wrapper lui-même — parsing des groupes `--and`,
  extraction `--keep`/`--tab` vs pass-through, contenu de `WSH_COCKPIT_ADOPT`, abort
  sans lancement de claude si un spawn échoue (claude mocké par un stub dans le PATH).
- `SKILL.md` (rappel du §2) : durcir la consigne `WSH_COCKPIT_AGENT` — tout sous-agent
  qui spawne un cockpit doit exporter une clé distincte — et ajouter la règle « un
  sous-agent relâche en fin de tâche ce qu'il a créé ou adopté ».

## 7. Découpage de l'implémentation

Le chantier a grossi ; l'ordre d'implémentation est en deux lots, le premier étant un
prérequis autonome :

1. **Lot 1 — réintroduction de la garde `own_tmux_session`** (commit isolé, testable
   seul) : mergée via `a920197`, supprimée par la régression silencieuse `9863c07` —
   réimplémentation sur la base actuelle (`mux_pane_command` a survécu, mux.sh:93),
   appliquée à `find_reusable_session`, selftest dédié, message de commit nommant la
   régression. Rien d'autre ne bouge.
2. **Lot 2 — le reste** : `release_session()`, adoption dans `spawn`, wrapper,
   `open --tab`, hygiène `gc`, docs, `selftest-adopt` + `selftest-wrapper`.
