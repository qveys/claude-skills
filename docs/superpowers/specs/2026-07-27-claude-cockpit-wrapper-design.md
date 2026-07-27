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
# chaque groupe cockpit = [prefix] [--keep] [+ tout flag de spawn relayé tel quel :
#                          --tab <nom>, --pre <host>, --situate, …]

# Exemple :
claude-cockpit audit-nas --pre nas-de-quentin --tab T5 --and local -- --resume
```

Comportement :

1. Pour chaque groupe (séparé par `--and`) : appel de `wsh-live.sh spawn <opts>` — qui
   crée la session tmux et ouvre le bloc Wave — et collecte du nom de session retourné.
   Le flag propre au wrapper (`--keep`) est extrait ; tout le reste — `--tab` compris,
   qui est une option native de `spawn`/`open` (§4), pas du wrapper — est relayé tel
   quel à `spawn` (pass-through futur-proof).
   **Isolation de clé obligatoire** : chaque spawn du wrapper tourne sous
   `WSH_COCKPIT_AGENT=user-preopen-<n>` (n = index du groupe), **portée limitée à
   l'appel de spawn — jamais exportée vers claude**. Sans cela, le wrapper écrirait
   `last-session-default`, et le premier `spawn` de l'agent principal (clé `default`
   elle aussi) trouverait la session par l'étape 1 — court-circuitant claim ET sonde
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

**Ordre de résolution de `spawn [prefix]`** — quatre étapes : la réutilisation propre
d'abord, l'anti-éviction en dernier recours seulement (placée plus tôt, elle
neutraliserait le multi-cockpit : après adoption d'`audit-nas`, `spawn local` doit
atteindre le cockpit `local`, pas re-rendre `audit-nas`) :

1. **Réutilisation par préfixe** : la `last-session-<key>` de l'agent, si vivante ET
   si aucun préfixe n'est demandé, ou si son préfixe **enregistré** est égal au
   préfixe demandé.
2. **Adoption, ciblée puis nominale** : parmi les sessions de `WSH_COCKPIT_ADOPT`
   vivantes et non réclamées — celle dont le préfixe enregistré est égal au préfixe
   demandé s'il y en a une, sinon la première libre de la liste.
3. **Anti-éviction** : si la `last-session-<key>` est vivante et porte un
   `adopt-claim` de cet agent, la garder — même préfixe incompatible. Sans cette
   étape, tout re-spawn préfixé (`spawn theo-plan`) larguerait la session adoptée
   vers l'étape 4 ; placée APRÈS l'étape 2, elle ne vole plus la priorité à une
   candidate adoptable qui matche vraiment. Caveat des clés `default` partagées
   inchangé.
4. **Logique actuelle** : scan `cockpit-<prefix>-*` puis création — **en excluant
   toute session portant un `adopt-claim` d'un autre agent** (sinon deux agents
   finissent entrelacés dans le même pane avec un seul compteur `seq`) ; extension
   naturelle de la `session_safe_to_reuse` réintroduite au lot 1.

Précisions sur l'étape 1 :
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
   de préfixe → étapes 2 à 4 (le re-spawn d'une session adoptée est couvert par
   l'étape 1 sans préfixe, ou par l'étape 3 avec préfixe incompatible).

Règles d'adoption :

- Claim par session via marqueur `~/.cache/wsh-cockpit/adopt-claim-<slug>`. **Format
  = contrat parsé** (pas une simple aide au debug) : ligne 1 = clé agent, ligne 2 =
  pid (debug uniquement). Le test de propriété « de cet agent » (étape 3,
  `release_session`) = égalité de la clé — avec des clés `default` partagées, la
  propriété est partagée aussi (même caveat que ci-dessous). **Le claim est
  atomique** : création en `set -o noclobber` (O_EXCL) — jamais de
  test-puis-écriture ; le perdant de la course passe à la candidate suivante. Double
  rôle : verrou anti-double-adoption (étapes 2 et 4) et preuve de propriété
  (étape 3, release).
- **La variable étant héritée par tous les shells de la session claude, les sous-agents
  (scout/builder/mech…) peuvent aussi adopter** : premier arrivé, premier servi via le
  claim atomique. C'est voulu — les sous-agents travaillent pour le compte de la même
  session. **Limite connue et assumée** : la clé agent par défaut est `"default"`
  (session.sh:26) ; un sous-agent qui n'exporte pas son propre `WSH_COCKPIT_AGENT`
  partage la clé — et donc la `last-session` — de l'agent principal (étape 1), défaut
  préexistant du skill que l'adoption n'aggrave ni ne corrige. Le SKILL.md devra
  durcir la recommandation : tout sous-agent qui spawne un cockpit **doit** exporter
  un `WSH_COCKPIT_AGENT` distinct.
- Session morte dans la liste → warning stderr **au premier constat seulement**
  (mémorisé par agent via `~/.cache/wsh-cockpit/adopt-warned-<key>`, balayé par la
  passe d'hygiène `gc`) + fallback sur la suite de l'ordre de résolution.
- **`--force` saute les étapes 1 à 3 — création directe (étape 4)** : c'est le geste « donne-moi un cockpit neuf,
  pas celui de l'utilisateur » (aujourd'hui `--force` ne saute que l'étape 1).
- **Un sous-agent qui adopte doit relâcher** : la règle de cleanup du skill s'étend —
  en fin de tâche, un sous-agent `stop`/`release_session` ce qu'il a créé **ou
  adopté** ; sinon son claim ne se libère jamais et le cockpit pré-ouvert est consommé
  définitivement. Consigne SKILL.md + selftest.
- **Sonde auto-portante** : la sonde systématique d'adoption utilise le framing
  auto-porté (`WSH_LIVE_SEP_REINIT=1`, même mécanique que le probe de `remote-init`,
  wsh-live.sh:789). Scénario visé : une session `--keep` relâchée puis ré-adoptée
  **dans le même run**, dans laquelle l'utilisateur a fait un hop SSH à la main
  entre-temps — elle n'a pas le flag sticky remote-mode, et une sonde en framing
  normal y vomirait des erreurs de helpers dans la fenêtre de l'utilisateur. (Le
  scénario inter-runs n'existe plus : `--force` systématique du wrapper, §1.)
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
  propres), ainsi que les `tab-`, `block-`, `cm-`, `prefix-` et `adopt-warned-` de
  sessions/clés mortes — aujourd'hui nettoyés uniquement par `teardown_session`, donc
  jamais pour une session keep fermée à la main par l'utilisateur. **Placement** : la
  passe s'exécute AVANT les early-returns de `cmd_gc` (backend zellij, aucun serveur
  tmux — gc.sh:58-67), sinon elle ne tournerait jamais dans ces deux cas.
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
courant (wsh-live.sh:696), un onglet d'une autre fenêtre ferait échouer `wsh run`.
Conséquences d'implémentation : (a) la CTE ci-dessus doit être **jointe au workspace
courant** (résolu via `WAVETERM_WORKSPACEID` / le workspace du tab courant), pas
agrégée sur tous les workspaces ; (b) hors de Wave (`WAVETERM_WORKSPACEID` absent),
`--tab` **échoue proprement** avec une erreur explicite — pas de fallback arbitraire
(le `LIMIT 1` de wave.sh:84-85 ne convient pas ici) ; (c) si `wsh wavepath` échoue,
`--tab` échoue proprement aussi — il n'hérite **pas** du fallback codé en dur de
`wave_db_ro` (wave.sh:25-27) vers le snapshot AppSupport périmé. Si le nom ne résout
que hors de la fenêtre courante → warning + fallback, l'inter-fenêtres est hors
périmètre. **Pas de contrainte d'unicité sur les noms** :
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
| `spawn --force` d'un agent | Saute les étapes 1 à 3, création directe — cockpit neuf garanti, jamais celui de l'utilisateur |
| Crash de claude | Cockpits du run laissés ouverts (gc 24 h ou fermeture manuelle) ; le run suivant du wrapper n'en réutilise aucun (`--force` systématique) |
| `last-session` vivante mais préfixe incompatible | Étapes 2→4 ; la session adoptée n'est conservée (étape 3) que si aucune candidate adoptable ne matche le préfixe demandé |
| Session claimée par un autre agent rencontrée au scan (étape 4) | Exclue — jamais réutilisée ni tuée par un tiers |
| Session `--keep` relâchée (`release_session`) puis re-demandée | Ré-adoptable via l'étape 2 (claim libéré), y compris par l'agent qui l'a relâchée |
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
  `--tab`, **sonde systématique effectivement exécutée à l'adoption**, **ordre de
  résolution en 4 étapes** (deux `spawn` de préfixes différents → deux sessions ;
  même préfixe → réutilisation ; re-spawn préfixé après adoption → la candidate
  adoptable qui matche gagne [étape 2], sinon la session adoptée est conservée
  [étape 3], jamais évincée vers une création), **le scan de l'étape 4 ne rend jamais
  une session claimée par un autre agent**, **continuité du compteur `seq` après
  `release_session` + ré-adoption** (aucun match de footer périmé), **`--force` saute
  l'adoption**, **release par un sous-agent** (claim libéré en fin de tâche).
- **`selftest-wrapper`** : le wrapper lui-même — parsing des groupes `--and`,
  extraction `--keep` vs pass-through (dont `--tab`), contenu de `WSH_COCKPIT_ADOPT`,
  abort sans lancement de claude si un spawn échoue (claude mocké par un stub dans le
  PATH).
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
