# wsh-cockpit

Faire exécuter des commandes par Claude **sous vos yeux**, dans un bloc [Wave
Terminal](https://waveterm.dev) visible — sur votre Mac ou sur un hôte distant
joignable via Wave — au lieu du shell caché de l'agent. Vous voyez chaque
commande et sa sortie en direct, vous pouvez scroller, et à tout moment
**reprendre le clavier**.

> Ce README s'adresse à l'humain qui utilise le skill. Le protocole que suit
> l'agent (règles impératives, bannières, cadrage) est dans [`SKILL.md`](SKILL.md) ;
> le détail par sujet est dans [`docs/`](docs/).

## Les deux modes

| Mode | Ce que ça fait | Quand |
|---|---|---|
| **`rexec`** (one-shot) | Une commande, un bloc visible, stdout/stderr + code de sortie capturés. Le bloc reste affiché ~60 s après la fin pour vous laisser lire, sans bloquer l'agent. | Par défaut, pour tout ce qui est ponctuel. |
| **`live`** (cockpit partagé) | Une session tmux persistante sur le Mac : l'agent y tape ses commandes, vous la rejoignez dans un bloc Wave et partagez le même terminal. | Travail interactif, multi-étapes, co-pilotage. |

```bash
# rexec — local ou via une connexion Wave
scripts/wsh-rexec.sh local 'sw_vers; ls ~/Git'
scripts/wsh-rexec.sh user@1.2.3.4 'docker ps; uname -a'
```

## Le mode live en 60 secondes

```bash
C=wsh-cockpit/scripts/wsh-live.sh
$C spawn                      # ouvre (ou réutilise) un cockpit + un bloc Wave attaché
$C send 'uname -a 2>&1'       # tape la commande dans le pane, cadrée ┌─[#N] … └─[#N] exit 0
$C wait-done                  # bloque jusqu'au footer "exit" du dernier send
$C output                     # relit le résultat exact, borné par les marqueurs
$C stop                       # tue la session + ferme le bloc Wave + nettoie l'état
```

Chaque `send` est **cadré** : un en-tête `┌─[#N]` avant, un pied `└─[#N] exit <code>`
après. C'est ce cadrage qui permet à `wait-done`/`output` de lire un résultat
sans deviner un nombre de lignes. Toujours terminer les commandes par `2>&1`
pour que stderr arrive avant le footer.

## Sous-commandes de `wsh-live.sh`

| Commande | Rôle |
|---|---|
| `spawn [prefix] [--force] [--tab NOM]` | Le point d'entrée recommandé : réutilise un cockpit vivant et sûr (le sien, puis un cockpit pré-ouvert offert en adoption, puis une session libre plus ancienne), sinon en crée un (nom auto `cockpit-<prefix>-<ts>`), et ouvre le bloc Wave. `--force` en ouvre un deuxième. |
| `start [nom] [--reuse]` | Crée une session nommée (sans bloc Wave). Refuse un nom déjà pris ; `--reuse` le reprend explicitement. |
| `open [session] [--tab NOM]` | Ouvre un bloc Wave attaché à la session (gère les env Wave périmés) ; `--tab` l'ancre sur un onglet Wave nommé plutôt que l'onglet courant. |
| `send '<cmd>' [session]` | Tape la commande dans le pane, avec cadrage. |
| `keys '<touches>' [session]` | Envoie des touches tmux brutes (`C-c`, `Up`, …). |
| `read [session] [lignes]` | Instantané brut des dernières lignes du pane. |
| `output [session] [seq] [--full]` | Le résultat d'un `send`, borné par ses marqueurs (tronqué tête+queue au-delà de `WSH_READ_MAX`, `--full` pour tout). |
| `wait-done [session] [timeout] [seq] [--print]` | Attend le footer `exit` du dernier `send` ; `--print` émet aussi le résultat. |
| `step-run <id> '<label>' '<cmd>' [session] [timeout]` | Bannière d'étape + send + wait-done en un seul appel. |
| `banner <type> <texte…> [session]` | Bannières visuelles dans le pane ; `<type>` : `header`, `phase`, `step` ou `done`. |
| `push <local> <chemin-distant> [session]` / `pull` | Transfert de fichiers avec l'hôte enregistré de la session (moteur : `wsh-push.sh` — jamais de base64 dans le pane). |
| `remote-init <session> <hôte>` / `local-init` | Après un hop SSH dans le cockpit : bascule le cadrage en mode distant (et retour). |
| `stop [session]` | Tue la session, ferme le bloc Wave, nettoie l'état — ou la relâche (`release`) au lieu de la tuer si elle est marquée `keep`. |
| `release <session>` | Relâche une session : adoptée → rétrogradée/ré-adoptable ; créée/legacy → claim retiré (re-scannable). Jamais de session par défaut — argument obligatoire. |
| `gc [--dry-run] [--idle=S] [--only-session=N]` | Balaye les cockpits orphelins (détachés et inactifs depuis 24 h par défaut ; 24 h minimum aussi pour une session `keep`, quel que soit `--idle`). |
| `status` / `current` / `doctor` | État des sessions / la session courante / diagnostic de l'environnement. |
| `web <action>` | Miroir navigateur du cockpit via ttyd (lecture seule par défaut) ; `<action>` : `start`, `stop` ou `status`. |
| `selftest-*` | Suites d'auto-test (voir plus bas). |

**`--session NOM` / `-s NOM` / `--session=NOM`** : toutes les commandes qui
acceptent un `[session]` positionnel acceptent aussi ce flag, non ambigu par
construction — à préférer dans les scripts, indispensable pour les noms libres
qui ne commencent pas par `cockpit-`.

## Pré-ouvrir des cockpits pour l'agent — `claude-cockpit`

Le wrapper `scripts/claude-cockpit.sh` (symlinké en `claude-cockpit` sur le
`$PATH` une fois installé) vous permet d'ouvrir vous-même un ou plusieurs
cockpits **avant** de lancer l'agent, puis de les lui confier :

```bash
claude-cockpit theo-plan --keep --and deploy -- <args claude...>
```

Chaque groupe séparé par `--and` ouvre un cockpit distinct (les flags de
`spawn` restent utilisables à l'intérieur d'un groupe) ; l'agent démarre
ensuite avec ces sessions offertes en adoption. `--keep` marque une session
comme protégée : l'agent peut l'utiliser pleinement mais ne peut jamais la
détruire, seulement la relâcher — pratique pour garder la main sur un cockpit
que vous voulez continuer d'utiliser après la tâche. Une session sans
`--keep` peut être fermée par l'agent en fin de tâche. À la sortie de
l'agent (succès ou échec), le wrapper nettoie lui-même ce qu'il a ouvert :
détruit les sessions sans `--keep` restées ouvertes, relâche celles avec
`--keep`.

Installation (une fois) :

```bash
ln -sf "$(cd wsh-cockpit/scripts && pwd)/claude-cockpit.sh" ~/.local/bin/claude-cockpit
```

## Garde-fous

Le skill refuse de *deviner* et refuse de se *mordre la queue* :

- **Garde « propre session »** (exit 8) : l'agent tourne lui-même dans une
  session tmux (Wave enveloppe chaque bloc). `start --reuse`, `stop`, `send`,
  `keys`, `step-run` et `banner` **refusent** de cibler cette session — sous
  n'importe quel alias (nom exact, préfixe, motif, `=nom`, session groupée
  partageant le pane). Sans cette garde, un `send` mal ciblé taperait du texte
  dans le CLI de l'agent lui-même, et un `stop` le tuerait. `gc` saute sa
  propre session et refuse tout balayage destructif quand l'identité de
  l'appelant est invérifiable.
- **Échec fort plutôt qu'absorption** (exit 4) : un argument qui *ressemble* à
  un nom de session (`cockpit-…`, `cockpit`, `=…`) mais ne correspond à aucune
  session vivante produit une erreur — avant, il était silencieusement absorbé
  et la commande partait vers la dernière session connue. Un flag `--session`
  contredit par un positionnel en forme de session échoue aussi (exit 2).
- **Ciblage exact** : les résolutions de session sont ancrées (`=nom`) — un
  préfixe ne peut plus tuer ou corrompre une session voisine homonyme.
- **Journal d'audit** : tout ce qui s'affiche dans un cockpit est journalisé
  dans `~/Library/Logs/wsh-cockpit/<session>.log` (répertoire 700, fichiers
  600, purge à 30 jours). `WSH_LIVE_LOG=0` désactive.

## Hôtes distants

- Un hôte joignable par Wave (`wsh ssh`) fonctionne même quand votre `ssh`
  local échoue (clés dans Wave/1Password).
- Dans un cockpit `live`, on peut ouvrir une session SSH persistante puis
  `remote-init <session> <hôte>` pour que le cadrage continue de fonctionner à
  l'autre bout ; `push`/`pull` mémorisent l'hôte de la session.
- Pour un diagnostic ponctuel, préférer un one-shot
  (`send 'tailscale ssh hôte "cmd 2>&1"'`) — jamais de shell interactif sans
  footer.

## Variables d'environnement principales

| Variable | Défaut | Rôle |
|---|---|---|
| `WSH_MUX` | `tmux` | Backend (`zellij` expérimental, périmètre réduit). |
| `WSH_COCKPIT_PREFIX` | — | Préfixe des noms auto (`cockpit-<prefix>-<ts>`). |
| `WSH_COCKPIT_AGENT` | — | Clé d'état par agent (session mémorisée). |
| `WSH_WAIT_TIMEOUT` | `300` | Timeout de `wait-done`/`step-run` (s). |
| `WSH_READ_MAX` | `120` | Seuil de troncature d'`output` (lignes). |
| `WSH_LIVE_GC_IDLE` | `86400` | Seuil d'inactivité du `gc` (s). |
| `WSH_LIVE_LOG` / `WSH_LIVE_LOG_DIR` | `1` / `~/Library/Logs/wsh-cockpit` | Journal d'audit. |
| `WSH_REXEC_TIMEOUT` | `60` | Attente max d'un `rexec` (s). |
| `WSH_REXEC_LINGER` | `60` | Durée d'affichage du bloc `rexec` après la fin (s) ; `0` = fermeture immédiate. |
| `WSH_WEB_PORT` / `WSH_WEB_WRITE` | `7681` / lecture seule | Miroir `web`. |

## Auto-tests

```bash
scripts/wsh-live.sh selftest-guard     # gardes propre-session + désambiguïsation (41 cas)
scripts/wsh-live.sh selftest-live      # boucle complète sur une session jetable
scripts/wsh-live.sh selftest-gc        # logique du balayage gc
scripts/wsh-live.sh selftest-sep       # cadrage ┌─/└─
scripts/wsh-live.sh selftest-output    # extraction bornée d'output
scripts/wsh-live.sh selftest-cache     # cache de résolution d'onglet Wave
scripts/wsh-live.sh selftest-transfer  # push/pull (partie opportuniste en loopback ssh)
scripts/wsh-live.sh selftest-claim     # machine d'états du claim atomique (lib/claim.sh)
scripts/wsh-live.sh selftest-adopt     # registre, adoption (WSH_COCKPIT_ADOPT), scan legacy, release/keep
scripts/wsh-live.sh selftest-tab       # résolution `open --tab` (requête DB Wave, sql_quote())
scripts/wsh-live.sh selftest-wrapper   # claude-cockpit.sh : groupes, --keep, balayage de sortie
```

À noter : `selftest-guard` travaille sur le serveur tmux par défaut et groupe
brièvement une session jetable sur la session appelante (cas 10) — le lancer
depuis une session jetable si votre terminal réel ne doit pas voir passer ça.

## Pour aller plus loin

- [`SKILL.md`](SKILL.md) — le protocole complet côté agent.
- [`docs/session-lifecycle.md`](docs/session-lifecycle.md) — spawn/réutilisation/stop/gc.
- [`docs/framing-and-transfer.md`](docs/framing-and-transfer.md) — cadrage et transferts.
- [`docs/banners.md`](docs/banners.md) — bannières de phases/étapes.
- [`docs/gotchas.md`](docs/gotchas.md) — les pièges, mesurés, avec le pourquoi.
- [`docs/advanced.md`](docs/advanced.md) — cas avancés.
