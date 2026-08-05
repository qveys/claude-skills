# Lot — Désambiguïsation de l'argument `[session]` : échouer fort plutôt que deviner

**Statut :** implémenté (lot 2, 2026-08-04, branche `feat/wsh-cockpit-session-disambiguation`) —
gardes destruction (`stop` exit 8, `gc` skip own) et écriture (`send`/`keys`/`step-run`/`banner`
exit 8), discrimination par la forme (`looks_like_session`, exit 4), flag `--session`/`-s`
(formes espace et `=`) ; couvert par `selftest-guard` cas 22-41. Le §3 bis ci-dessous est FERMÉ ;
le texte est conservé tel quel comme trace de la mesure d'origine.
**Dépend de :** Task 6 du lot 1 (ancrage `=` de `mux_has`/`mux_kill`) — ce lot traite la
conséquence ergonomique de cet ancrage.
**Spec de référence :** `docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md` (v11).
**Précédent de forme :** `docs/plans/2026-07-05-hardening.md`.

---

## 1. Le problème, en une phrase

Un même token en ligne de commande change de signification selon qu'une session est vivante ou
morte — et quand il cesse d'être reconnu comme session, il est **absorbé silencieusement** par une
autre catégorie d'argument au lieu de produire une erreur.

## 2. Ce qui est mesuré

L'argument `[session]` est positionnel et optionnel, et il cohabite avec d'autres positionnels
optionnels du même type lexical :

```
banner {header|phase|step|done} <texte…> [session]
output   [session] [seq] [--full]
wait-done [session] [timeout] [seq] [--print]
step-run <id> '<label>' '<command>' [session] [timeout_sec]
read [session] [lines]   |   send '<cmd>' [session]   |   keys '<keys>' [session]
```

Les 4 sites qui font la discrimination (`wsh-live.sh:596`, `:645`, `:976`, `:1008`) partagent la
même boucle :

```bash
for arg in "$@"; do
  if   [ -z "$local_sess" ]  && mux_has "$arg";            then local_sess="$arg"
  elif [ -z "$timeout_sec" ] && [[ "$arg" =~ ^[0-9]+$ ]];  then timeout_sec="$arg"
  elif [ -z "$target_seq" ]  && [[ "$arg" =~ ^[0-9]+$ ]];  then target_seq="$arg"
  fi
done
```

**La faute de conception est visible dans ces trois lignes :** les nombres sont discriminés par leur
**forme** (`^[0-9]+$`), critère stable et local ; la session est discriminée par son **existence**
(`mux_has`), critère qui dépend de l'état du système à l'instant T. Mélanger les deux dans la même
boucle rend l'interprétation d'une ligne de commande non déterministe — la même commande, tapée deux
fois, se lit différemment si la session est morte entre-temps.

Aujourd'hui la conséquence est déjà présente mais masquée : `mux_has` non ancré rattrape les
préfixes, donc le token « retombe » rarement. Après la Task 6, l'ancrage rendra le décrochage
fréquent et **muet** : un nom de session presque juste sera traité comme du texte de bannière ou
ignoré, et `resolve_session` retombera sur la dernière session connue — c'est-à-dire **une autre
session que celle visée**, sans un mot.

### Deux constats qui élargissent la portée

- `resolve_session` (`lib/session.sh:205-213`) est un **pur passthrough** : il renvoie l'argument
  tel quel, sans aucune résolution ni validation.
- La revue de la Task 5 (2026-08-02, constat 7) a établi que ce même passthrough est **le dernier
  chemin par lequel on peut désigner sa propre session sans être refusé**, via
  `send`/`keys`/`read`/`output`/`step-run`, qui ne passent pas par la garde.

Le point d'entrée à corriger est donc le même pour l'ergonomie et pour la sécurité. C'est ce qui
justifie un lot dédié plutôt qu'une rustine dans la Task 6.

## 3. Design retenu

**Principe : discriminer par la forme, valider par l'existence, échouer explicitement entre les
deux.** Trois cas, au lieu de deux aujourd'hui :

| Le token… | Aujourd'hui | Après |
|---|---|---|
| ressemble à une session **et** existe | session | session (inchangé) |
| ressemble à une session **et** n'existe pas | absorbé en texte/nombre, ou ignoré | **erreur « session inconnue », exit 4** |
| ne ressemble pas à une session | texte/nombre | texte/nombre (inchangé) |

« Ressemble à une session » = `^cockpit-` (la forme produite par `spawn`/`start`), la valeur
`$SESS_DEFAULT` (`cockpit`, `wsh-live.sh:163`), ou une forme ancrée `=…`.

**L'optionalité est intégralement préservée :** on n'exige jamais de nom de session, on ne rend
jamais l'argument obligatoire. On refuse seulement de *deviner* quand l'intention est manifeste.

**Le coût d'implémentation est faible, et c'est voulu :** `need_session` (`lib/session.sh:215-218`)
produit **déjà** le bon message et le bon code de sortie :

```
no tmux session 'X' — run: wsh-live.sh start X     (exit 4)
```

Le travail n'est donc pas d'écrire une nouvelle erreur, mais de faire en sorte que le token
**atteigne** `SESS` au lieu d'être absorbé en route. `need_session` fait le reste.

### Points tranchés le 2026-08-02

1. **`--session <nom>` / `-s <nom>` : ajouté**, positionnel conservé pour la frappe interactive et
   la compatibilité. Motif : `start <nom>` accepte des noms libres que `^cockpit-` ne couvre pas, et
   l'essentiel des appels de ce script sont programmatiques (agents, scripts) — c'est là que
   deviner coûte le plus cher. Le flag est non ambigu par construction et court-circuite toute la
   discrimination positionnelle.
2. **La garde ne va PAS dans `resolve_session` : elle va par classe d'effet, au site d'appel.**
   Mettre la garde dans le résolveur mélangerait des cas de nature différente, et un résolveur qui
   refuse ment sur son nom. Répartition retenue :

   | Effet | Commandes | Garde |
   |---|---|---|
   | Écriture | `send`, `keys`, `step-run` | **refus** — s'envoyer des touches à soi-même est toujours une récursion |
   | Lecture | `read`, `output` | **aucune** — lire son propre scrollback est inoffensif, parfois utile |
   | Destruction | `stop` | **refus** — voir §3 bis |

3. **`banner` : code correct, commentaire faux.** `[ $# -gt 1 ]` protège bien le texte
   (`banner header "cockpit-mort"` garde son texte). Mais `wsh-live.sh:595` affirme « Optional
   session is only recognized when it is the sole remaining argument », alors que le code fait
   l'inverse : reconnue seulement si ce n'est **pas** le seul argument restant. Corrigé en Task 5b
   du lot 1 (même famille que les deux *Important* de la revue : un commentaire qui ment sur le
   mécanisme).

## 3 bis. Trou confirmé : `stop` n'a aucune garde

Mesuré le 2026-08-02, non couvert par le lot 1 :

- `stop <ma-propre-session>` va droit à `teardown_session` → `mux_kill` : **l'appelant tue sa propre
  session**. L'ancrage de la Task 6 n'y change rien, le nom étant exact.
- `stop` **sans argument** lit le state file, et retombe sur `SESS_DEFAULT="cockpit"`
  (`wsh-live.sh:163`) si celui-ci est vide. Avec `mux_kill` non ancré, `cockpit` résout par préfixe
  et **tue une session arbitraire**. Ce second cas-là, la Task 6 le ferme.

Le premier cas relève de ce lot : c'est le même thème (points d'entrée qui devinent au lieu de
refuser) et la même zone de code. Il est **prioritaire sur le volet ergonomique** — c'est le seul
des trois effets qui soit irréversible.

## 4. Tests

- Session `cockpit-x-1` **vivante** : `output cockpit-x-1 3` → session reconnue, seq 3 (non-régression).
- Session `cockpit-x-1` **morte** : `output cockpit-x-1 3` → **exit 4**, message « no tmux session ».
  *C'est le test qui échoue avant le fix* : aujourd'hui le token est ignoré et `output` cible
  silencieusement la dernière session connue.
- `banner header "texte quelconque"` → le texte reste du texte, aucune erreur.
- `banner header "cockpit-mort"` (seul argument restant) → reste du texte, protection `$# -gt 1`.
- `wait-done 30 7` → timeout 30, seq 7 : les nombres ne sont pas affectés (non-régression).
- `output` sans argument → comportement par défaut inchangé (`last_session`).
- Si `--session` est retenu : `output --session cockpit-mort` → exit 4 ; `--session` sans valeur → erreur d'usage.

## 5. Non-périmètre

- Ne pas rendre l'argument session obligatoire.
- Ne pas toucher à la résolution tmux elle-même (c'est la Task 6).
- Ne pas entreprendre la canonicalisation généralisée des noms (`mux_session_name` propagé partout) :
  c'est le lot identifié en backlog pour les commandes *target-pane*, qui rejettent l'ancre `=`.

## 6. Contraintes permanentes du chantier

- Commits signés (`git commit -S`) ; jamais `--no-gpg-sign`, jamais de modification de la config git.
- Aucune attribution IA dans les messages de commit.
- Aucun `git push` : le push appartient à l'utilisateur.
- bash 3.2 (macOS), `set -euo pipefail`, `${TMUX:-}` / `${TMUX_PANE:-}`.
- Aucun `kill-session` sans cible explicite, jamais de `kill-server` ; sessions de test à préfixe
  dédié, nettoyées par `trap … EXIT`.
