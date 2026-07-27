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
| Autorité de résolution | **Le registre des claims** (sessions créées ET adoptées, claim posé à la création) ; `last-session` = simple mémo « dernière utilisée », jamais l'autorité |
| Situation du shell | **Sonde `hostname; pwd; whoami` systématique et non optionnelle à l'adoption** (comportement `--situate` appliqué d'office) |
| Cycle de vie côté wrapper | **`--force` systématique** : chaque run crée des cockpits neufs, jamais de réutilisation inter-runs (dissout claims orphelins post-crash et collisions entre deux claude parallèles) |
| Clé agent | Le wrapper exporte `WSH_COCKPIT_AGENT=claude-<runid>` vers claude → registre par run (crash isolé, claudes parallèles disjoints) ; claude lancé sans wrapper = clé `default` héritée, garanties réduites (§5) |

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
   de créer).
   **Pré-claim immédiat** : sitôt la session créée, le spawn du wrapper pose le
   claim sous sa clé `user-preopen-<n>` (c'est le comportement général « la création
   pose le claim du créateur », §2 étape 3) — aucune fenêtre entre création et
   adoption pendant laquelle le scan d'un autre claude pourrait saisir la session.
   L'adoption transfère ce pré-claim atomiquement (§2 étape 2).
   Coût assumé : après un crash de claude, les fenêtres du run précédent restent
   ouvertes **jusqu'à fermeture manuelle** — le bloc Wave attaché maintient la
   session et `gc` ne tue jamais une session attachée (`gc_should_kill`, gc.sh:26) ;
   c'est après la fermeture du bloc que le balayage (idle) et l'hygiène des
   marqueurs prennent le relais.
   Limite de parsing assumée : une valeur d'option contenant littéralement `--and`
   ou `--` casserait le découpage des groupes — le parseur refuse ces valeurs avec
   une erreur claire.
2. `export WSH_COCKPIT_ADOPT=sess1[,sess2...]` **et
   `export WSH_COCKPIT_AGENT=claude-<runid>`** (runid = horodatage+pid du wrapper),
   puis `exec claude [args après --]`. La clé de run unique donne à l'agent
   principal (et aux sous-agents qui n'exportent pas la leur) un **registre par
   run** : les claims d'un claude crashé restent sous la clé du run mort — jamais
   revus à l'étape 1 — et deux claude parallèles ont des registres disjoints. Le
   wrapper **neutralise aussi `WSH_COCKPIT_PREFIX`** (unset, pour ses spawns comme
   dans l'environnement transmis) : `normalize_prefix` la consulte AVANT
   `WSH_COCKPIT_AGENT` (session.sh:47-49) et un préfixe ambiant de l'utilisateur
   fausserait les préfixes enregistrés.
3. **Un spawn échoue → claude n'est pas lancé.** Message d'erreur clair ; les cockpits
   déjà ouverts restent visibles pour diagnostic (pas de rollback automatique).

## 2. Adoption côté skill (`spawn`)

**Le registre des claims est l'autorité de résolution.** Un agent peut posséder N
sessions ; un slot unique `last-session` ne peut pas les arbitrer — c'est la racine
des défauts des itérations précédentes de ce design. Généralisation : **toute session
créée par `spawn`/`start` reçoit un claim de son créateur** (le wrapper pose un
**pré-claim** sous sa clé `user-preopen-<n>`, cf. §1) ; le registre d'un agent = les
`adopt-claim-*` portant sa clé, et il couvre donc les sessions créées ET adoptées.
`last-session` est rétrogradé en simple mémo « dernière utilisée », jamais l'autorité.

**Ordre de résolution de `spawn [prefix]`** :

1. **Mes sessions (registre)** : parmi les sessions vivantes dont le claim porte ma
   clé — préfixe demandé → celle dont le préfixe enregistré (`prefix-<slug>`) est
   égal ; aucun préfixe demandé → la `last-session` si elle appartient au registre,
   sinon l'unique session du registre s'il n'y en a qu'une — **N>1 sans préfixe ni
   `last-session` au registre → erreur explicite** demandant un préfixe (jamais de
   (N+1)-ième cockpit silencieux). Couvre l'alternance
   multi-cockpit sans misroute : `spawn audit-nas` → `spawn local` →
   `spawn audit-nas` retrouve chaque fois la bonne session.
2. **Adoption** : parmi les sessions de `WSH_COCKPIT_ADOPT` vivantes portant un
   pré-claim (clé `user-preopen-*` du wrapper, ou `released` après un
   `release_session`) — ciblée (préfixe enregistré égal au demandé), sinon nominale
   (première libre de la liste). **Adopter = consommation atomique du pré-claim par
   rename de la SOURCE** : `mv adopt-claim-<slug> adopt-claim-<slug>.won-<pid>` —
   la source disparaît, un seul rename réussit ; le gagnant écrit alors son claim
   définitif (O_EXCL) et supprime le `.won-<pid>`, le perdant (ENOENT) passe à la
   candidate suivante. (Un `mv` PAR-DESSUS le pré-claim serait du last-writer-wins :
   deux adoptants pourraient chacun relire leur propre clé et « gagner ».)
   Une candidate libre **prime** sur toute `last-session` résiduelle hors registre
   (session d'un run précédent encore vivante) — le cockpit que l'utilisateur vient
   de pré-ouvrir gagne toujours contre l'état résiduel.
3. **Scan/création** : scan `cockpit-<prefix>-*` puis création — **en excluant toute
   session portant un claim de quiconque** (pré-claims du wrapper inclus, sinon un
   autre claude pourrait saisir un cockpit pré-ouvert pendant la fenêtre
   pré-adoption ; et deux agents entrelacés dans un même pane partagent un seul
   compteur `seq`) ; extension naturelle de la `session_safe_to_reuse` réintroduite
   au lot 1. La création pose le claim du créateur — et la **réutilisation d'une
   session legacy non claimée trouvée au scan pose ce claim aussi** : toute session
   utilisée entre au registre, le parc antérieur cesse d'être partageable dès sa
   première réutilisation.

Précisions sur l'étape 1 :
   **« Aucun préfixe demandé »** = argument positionnel absent **avant**
   `normalize_prefix` — qui, lui, retombe sur `WSH_COCKPIT_PREFIX` **puis**
   `WSH_COCKPIT_AGENT` puis `live` et ne produit jamais de vide (session.sh:47-53 ;
   d'où la neutralisation de `WSH_COCKPIT_PREFIX` par le wrapper, §1). Un groupe
   wrapper sans
   préfixe produit donc un préfixe enregistré `user-preopen-<n>`, atteignable
   uniquement en adoption nominale.
   **Préfixe enregistré, pas parsé** : `spawn` écrit le préfixe normalisé dans
   `~/.cache/wsh-cockpit/prefix-<slug>` à la création ; `start` (qui reçoit un nom
   complet, pas un préfixe) écrit la sentinelle `(named)`, jamais matchable — ses
   sessions ne sont atteignables que par nom explicite ou scan. Le test de
   compatibilité lit ce fichier. Le parsing de nom
   (`^cockpit-(.+)-[0-9]{6}(-[0-9]+)?$`) ne sert que de fallback pour les sessions
   antérieures à ce chantier — il est ambigu par construction (un préfixe finissant
   par 6 chiffres, ex. `foo-123456`, matche aussi le motif du préfixe `foo`).
   **Changement de comportement vérifié le 2026-07-27 et voulu** : aujourd'hui
   `find_reusable_session()` (session.sh:76-89) consulte `last_session()`
   (session.sh:36-44) qui retourne la session mémorisée sans regarder le préfixe —
   `spawn audit-nas` puis `spawn local` rend deux fois la première session, ce qui
   rendrait le multi-cockpit inutilisable par un même agent. Le registre remplace ce
   mémo-autorité ; préfixe sans possession → étapes 2 puis 3.

Règles d'adoption :

- Claim par session via marqueur `~/.cache/wsh-cockpit/adopt-claim-<slug>`. **Format
  = contrat parsé** (pas une simple aide au debug) : ligne 1 = clé agent, ligne 2 =
  pid (debug uniquement). Le test de propriété = égalité de la clé — avec des clés
  `default` partagées, la propriété est partagée aussi (même caveat que ci-dessous).
  **Écritures atomiques uniquement** : création d'un claim neuf (étape 3, pré-claim
  wrapper) en `set -o noclobber` (O_EXCL) ; consommation à l'adoption par rename de
  la source (étape 2) ; rétrogradation `released` par le seul propriétaire
  (mono-écrivain, temp + `mv`) — jamais de test-puis-écriture. **Collision de nom
  recyclé** (les `HHMMSS` se répètent d'un jour à l'autre, l'hygiène est
  asynchrone) : O_EXCL qui échoue à la création sur un claim orphelin dont la
  session est morte → remplacement par rename ; session homonyme vivante →
  `unique_session_name` suffixe déjà (`-n`). Triple rôle : registre
  de résolution (étape 1), verrou anti-double-adoption (étapes 2 et 3), preuve de
  propriété (`release_session`, exclusion au scan).
- **La variable étant héritée par tous les shells de la session claude, les sous-agents
  (scout/builder/mech…) peuvent aussi adopter** : premier arrivé, premier servi via le
  claim atomique. C'est voulu — les sous-agents travaillent pour le compte de la même
  session. **Limite connue et assumée** : la clé agent par défaut est `"default"`
  (session.sh:26) ; un sous-agent qui n'exporte pas son propre `WSH_COCKPIT_AGENT`
  partage la clé — et donc la `last-session` — de l'agent principal (étape 1), défaut
  préexistant du skill que l'adoption n'aggrave ni ne corrige. Le SKILL.md devra
  durcir la recommandation : tout sous-agent qui spawne un cockpit **doit** exporter
  un `WSH_COCKPIT_AGENT` distinct.
- **Espace de clés réservé** : `spawn`/`start` refusent avec une erreur claire une
  `WSH_COCKPIT_AGENT` commençant par `user-preopen-` ou valant `released` — sinon un
  agent mal configuré rendrait ses sessions adoptables par n'importe qui à
  l'étape 2.
- Session morte dans la liste → warning stderr **au premier constat seulement** +
  fallback sur la suite de l'ordre de résolution. Mémo : un fichier par couple
  `~/.cache/wsh-cockpit/adopt-warned-<key>-<slug>` (un mémo unique par clé aurait
  son mtime rafraîchi à chaque ajout — jamais purgé). Hygiène : slug mort ET âge
  > 24 h ; edge assumé : un nom recyclé après >24 h re-warne — bénin.
- **`--force` = création directe** : saute les étapes 1 et 2 ET le scan de l'étape 3
  — cockpit neuf garanti, jamais celui de l'utilisateur. (C'est déjà la sémantique
  actuelle : `--force` court-circuite `find_reusable_session` en entier — mémo ET
  scan — et crée directement, wsh-live.sh:432-454 ; la spec étend ce contournement à
  l'adoption.) Les claims existants de l'agent restent en place : les sessions déjà
  possédées restent au registre pour les spawns suivants — pas de claim orphelin.
- **Un sous-agent qui adopte doit relâcher** : en fin de tâche, `stop` ce qu'il a
  **créé** (destruction — pleine propriété) et `release` ce qu'il a **adopté**
  (préservation de la fenêtre de l'utilisateur) ; sinon son claim ne se libère
  jamais et le cockpit pré-ouvert est consommé définitivement. Consigne SKILL.md +
  selftest.
- **Sonde auto-portante** : la sonde systématique d'adoption utilise le framing
  auto-porté (`WSH_LIVE_SEP_REINIT=1`, même mécanique que le probe de `remote-init`,
  wsh-live.sh:789). Scénario visé : une session `--keep` relâchée puis ré-adoptée
  **dans le même run**, dans laquelle l'utilisateur a fait un hop SSH à la main
  entre-temps — elle n'a pas le flag sticky remote-mode, et une sonde en framing
  normal y vomirait des erreurs de helpers dans la fenêtre de l'utilisateur. (Le
  scénario inter-runs n'existe plus : `--force` systématique du wrapper, §1.)
- **Garde busy-pane + rollback** : avant la sonde, `mux_pane_command` (mux.sh:93)
  doit rapporter un shell nu — même critère que la garde du lot 1 ; sinon (vim,
  less, commande en cours de frappe dans un pane keep) l'adoption de cette candidate
  est abandonnée : le claim gagné est re-rétrogradé en pré-claim et on passe à la
  suivante. Idem si la sonde échoue après la consommation du pré-claim — jamais de
  claim conservé sans sonde réussie.
- Garde-fou : ne jamais adopter la session tmux qui héberge claude lui-même.
  **Constat re-vérifié le 2026-07-27 (deux revues indépendantes) : RÉGRESSION.** La
  garde `own_tmux_session` / `session_safe_to_reuse` a été mergée sur `main`
  (`a920197`) et survit jusqu'au parent de `9863c07` (`736b769`) ; `9863c07`
  (« auto-close the Wave block on stop/gc ») la **supprime silencieusement de
  session.sh** — son message n'en dit rien — en laissant un appel résiduel dans
  wsh-live.sh (`|| own=""`), nettoyé ensuite par `e7d09a6` ; `gc.sh:25` la cite
  encore en commentaire ; `mux_pane_command` (mux.sh:93) a survécu. **Prérequis de ce
  chantier (lot 1)** : la réintroduire — le hunk session.sh de `a920197` se
  cherry-pickerait en fait proprement (`git apply --check` OK, précisément parce que
  `9863c07` a restauré l'état antérieur de `find_reusable_session`), mais les hunks
  SKILL.md/mux.sh échouent : réimplémentation ciblée plutôt que cherry-pick aveugle
  — appliquée à l'adoption ET à `find_reusable_session`, avec un message de commit
  nommant la régression (`9863c07`) et le nettoyage résiduel (`e7d09a6`).
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
  une **nouvelle sous-commande `release [session]`** (le chemin `stop`-sur-keep
  l'appelle ; les sous-agents l'invoquent directement) : supprime `last-session-<key>`
  (si elle pointe cette session) et, pour une session issue de `WSH_COCKPIT_ADOPT`,
  **rétrograde le claim en pré-claim** (clé réservée `released`, réécriture
  mono-écrivain temp+`mv` ; l'étape 2 accepte `user-preopen-*` et `released`) — elle
  redevient adoptable par un autre agent de la même session claude, **via l'étape 2
  uniquement** (donc avec sonde), jamais par le scan. Pour une session **créée**
  (hors `WSH_COCKPIT_ADOPT`), `release` supprime le claim : retour au pool
  scannable (étape 3). Dans les deux cas, `release` ne
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
  propres), ainsi que les `seq-`, `oneshot-ssh-`, `pane-` (zellij), `tab-`,
  `block-`, `cm-` et `prefix-` de sessions mortes —
  aujourd'hui nettoyés uniquement par `teardown_session`, donc jamais pour une
  session keep fermée à la main par l'utilisateur. **Pas de `rm` sec pour `block-`
  et `cm-`** : avant suppression, tenter respectivement `block_id_close` (fermer un
  bloc Wave orphelin — même chance que `teardown_session`, qui l'appelle même quand
  `mux_kill` échoue, session.sh:267-268) et `ssh -O exit` (best-effort). Le cas
  `adopt-warned-<key>` est à part : hygiène par âge, cf. §2. **Placement** : la
  passe s'exécute AVANT les early-returns de `cmd_gc` (backend zellij, aucun serveur
  tmux — gc.sh:58-67), sinon elle ne tournerait jamais dans ces deux cas. **Seuil
  d'âge anti-course** : la passe ignore tout marqueur de moins de 5 min — `gc` part
  en arrière-plan à chaque spawn (wsh-live.sh:417), y compris pendant la rafale
  `--and` du wrapper, et un claim/`prefix-`/`keep-` tout frais peut précéder la
  visibilité de sa session.
- Un claim dont l'agent a disparu (claude crashé) : la session reste vivante tant que
  son bloc Wave est attaché (`gc` ne tue jamais une session attachée, gc.sh:26) — le
  claim orphelin est **inoffensif** (le run suivant du wrapper n'offre que des
  sessions neuves, `--force` §1) et part avec la session : `stop` par un autre agent,
  ou fermeture manuelle du bloc puis balayage `gc` (idle) + hygiène des marqueurs.

## 4. `open --tab <nom>`

Nouvelle option de `open`, relayée par `spawn` : résolution de l'onglet Wave **par
nom** via la DB SQLite Wave déjà lue en lecture seule par `resolve_live_tab_cached`.

**Faisabilité vérifiée le 2026-07-27** — avec un piège découvert par la revue
indépendante : la DB vivante est celle que **`wsh wavepath data` désigne**
(aujourd'hui `~/.local/share/waveterm/db/waveterm.db`) ;
`~/Library/Application Support/waveterm/` héberge une DB au contenu divergent —
encore écrite récemment : la caractérisation « snapshot périmé » n'est PAS prouvée —
qui a faussé une première vérification. **Le chemin est donc résolu dynamiquement via
`wsh wavepath data` — jamais codé en dur.** Requête re-validée sur la DB vivante
(accès `?mode=ro`) :

```sql
-- Vivacité OBLIGATOIRE : ne retenir que les onglets référencés par un workspace.
-- (la validation actuelle de wave.sh:113 ne teste que l'existence dans db_tab —
--  insuffisant pour une résolution par nom.)
WITH workspace_tabs AS (
  SELECT json_each.value AS tabid
  FROM db_workspace, json_each(db_workspace.data, '$.tabids')
  UNION
  SELECT json_each.value
  FROM db_workspace, json_each(db_workspace.data, '$.pinnedtabids')
)
SELECT oid FROM db_tab
WHERE json_extract(data, '$.name') = :nom
  AND oid IN (SELECT tabid FROM workspace_tabs);
```

`$.pinnedtabids` est absent des blobs actuels, mais **absence de clé ≠ absence du
champ** (pattern Go `omitempty` — Wave a une fonction « Pin tab » ; un onglet épinglé
sortirait vraisemblablement de `$.tabids`) : d'où l'union défensive ci-dessus — sans
elle, épingler un onglet le ferait passer pour mort. `wsh` CLI n'offre pas de listing nom→tab id (`wsh blocks list`
ne montre que les ids) ; la DB est donc la seule voie. **Périmètre v1 : la fenêtre
Wave courante uniquement** — `open` n'exporte que `WAVETERM_TABID` (le tab résolu, wsh-live.sh:696) ; le
comportement de `wsh run` vers un onglet d'une autre fenêtre n'a **pas été testé** :
le périmètre est un choix prudent, à valider par un test dédié si l'inter-fenêtres
devient un besoin.
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
| `WSH_COCKPIT_ADOPT` absent/vide | Pas d'étape 2 ; le registre, l'exclusion des claims au scan et la garde (lot 1) s'appliquent à TOUS — la réutilisation change aussi hors wrapper (amendements docs, §6) |
| claude lancé SANS le wrapper (clé `default` héritée) | Garanties réduites, documentées : registres partagés entre runs `default` — la sonde systématique d'adoption reste le filet |
| Session listée morte | Warning stderr au premier constat (mémorisé, pas répété), fallback logique normale |
| Toutes les sessions déjà réclamées | Étape 3 (scan excluant toute session claimée, puis création) |
| Session listée = tmux hébergeant claude | Refus d'adoption, warning, fallback |
| `--tab` introuvable | Warning + fallback onglet courant |
| Plusieurs onglets portant le nom `--tab` | Premier match **dans la fenêtre courante** + warning listant les candidats ; matches d'autres fenêtres ignorés (hors périmètre v1) |
| Claim perdu (course entre deux agents) | Passage atomique à la candidate suivante |
| `spawn --force` d'un agent | Saute les étapes 1-2 et le scan — création directe ; les claims existants restent au registre |
| Crash de claude | Cockpits laissés ouverts — bloc Wave attaché ⇒ jamais tués par `gc` (gc.sh:26) : fermeture manuelle puis balayage ; le run suivant du wrapper n'en réutilise aucun (`--force` + pré-claims) |
| `last-session` résiduelle hors registre (run précédent) | Ne fait pas autorité : une candidate d'adoption libre prime ; sans candidate, scan/création |
| Re-spawn d'un préfixe déjà possédé (créé ou adopté) | Étape 1 (registre) — retour garanti à la bonne session, jamais de misroute |
| Session claimée (par quiconque, pré-claims inclus) rencontrée au scan (étape 3) | Exclue — jamais réutilisée ni tuée par un tiers |
| Session `--keep` relâchée (`release_session`) puis re-demandée | Ré-adoptable via l'étape 2 seulement (claim rétrogradé en pré-claim `released` ⇒ sonde systématique), y compris par l'agent qui l'a relâchée |
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
  `--tab`, **sonde systématique effectivement exécutée à l'adoption**, **registre en
  3 étapes** : alternance A→B→A entre deux sessions possédées (créées ou adoptées) →
  retour garanti à la bonne session à chaque fois (anti-misroute) ; deux `spawn` de
  préfixes différents → deux sessions ; une candidate d'adoption libre prime sur une
  `last-session` résiduelle hors registre ; transfert atomique du pré-claim sous
  course (deux agents, un seul gagnant, le perdant passe à la suivante) ; **le scan
  (étape 3) ne rend jamais une session claimée par quiconque** (pré-claims inclus),
  **continuité du compteur `seq` après `release_session` + ré-adoption** (aucun match
  de footer périmé, ré-acquisition via l'étape 2 avec sonde), **`--force` saute
  l'adoption sans orpheliner les claims**, **release par un sous-agent** (claim
  rétrogradé `released` en fin de tâche), **exclusion mutuelle de la consommation
  prouvée sous rafale** (N adoptants simultanés → exactement un gagnant, vérifié par
  comptage — pas par absence de symptôme), **hygiène gc** (seuil d'âge : aucun
  marqueur frais mangé ; orphelins balayés), **`gc` épargne une session keep**
  (`gc_should_kill` modifié, lot 2).
- **`selftest-wrapper`** : le wrapper lui-même — parsing des groupes `--and`,
  extraction `--keep` vs pass-through (dont `--tab`), contenu de `WSH_COCKPIT_ADOPT`,
  abort sans lancement de claude si un spawn échoue (claude mocké par un stub dans le
  PATH).
- `SKILL.md` (rappel du §2) : durcir la consigne `WSH_COCKPIT_AGENT` (clé distincte
  par sous-agent, espace réservé interdit) ; règle « `stop` ce qu'on a créé,
  `release` ce qu'on a adopté, en fin de tâche » ; et consigne d'adoption ciblée :
  quand l'utilisateur a nommé ses cockpits, reprendre ces préfixes dans `spawn` —
  l'adoption nominale peut sinon mettre le travail NAS dans le cockpit « local »
  (la sonde l'affiche, mais autant viser juste).

## 7. Découpage de l'implémentation

Le chantier a grossi ; l'ordre d'implémentation est en deux lots, le premier étant un
prérequis autonome :

1. **Lot 1 — réintroduction de la garde `own_tmux_session`** (commit isolé, testable
   seul) : mergée via `a920197`, supprimée par la régression silencieuse `9863c07` —
   réimplémentation sur la base actuelle (`mux_pane_command` a survécu, mux.sh:93),
   appliquée à `find_reusable_session`, selftest dédié, message de commit nommant la
   régression. Rien d'autre ne bouge.
2. **Lot 2 — le reste** : registre/claims dans `spawn`+`start`, sous-commande
   `release`, wrapper, `open --tab`, modification de `gc_should_kill` (sessions
   keep) + passe d'hygiène (seuil d'âge), docs, `selftest-adopt` +
   `selftest-wrapper`.
