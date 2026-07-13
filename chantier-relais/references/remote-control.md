# Pilotage à distance — chantier-relais

Tout l'état du chantier est pilotable à distance parce qu'il vit dans deux choses accessibles par SSH : le fichier `STATE.md` et le pane tmux du relais. `relay-ctl.sh` est la télécommande unique.

## Depuis une autre machine du tailnet

```bash
RC='~/.claude/skills/chantier-relais/scripts/relay-ctl.sh'
H='<user>@<hôte>'             # l'hôte qui fait tourner le relais
P='~/chemin/vers/le/projet'   # le projet qui contient execution/

tailscale ssh $H "$RC status --dir $P"   # où en est-on ?
tailscale ssh $H "$RC watch 40 --dir $P" # voir le pane
tailscale ssh $H "$RC set step-0.2 --dir $P && $RC go --dir $P"
tailscale ssh $H "$RC say 'Oui, option 1, config globale' --dir $P"
tailscale ssh $H "$RC exit --dir $P"     # /exit à distance → étape suivante
```

Le cycle complet à distance : `status` → (la session pose une question ? `say`) → (elle annonce la fin ? `exit`) → le relais enchaîne seul → `status`.

Pour une immersion complète plutôt que des one-shots : `tailscale ssh $H` puis `tmux attach -t <session>` (détache : `Ctrl+b d`).

## Depuis un iPhone

- **App Tailscale** installée et connectée (l'appareil apparaît sur le tailnet).
- Un client SSH (Termius, Blink, a-Shell…) → se connecter à l'hôte du relais via son IP/nom tailnet → mêmes commandes `relay-ctl.sh` que ci-dessus. `say` et `exit` suffisent pour débloquer/enchaîner les étapes depuis un canapé.
- Lecture seule sans clavier : la vue navigateur ci-dessous.

## Vue navigateur en lecture seule (ttyd)

Si le skill **wsh-cockpit** est présent sur l'hôte et que la session relais est une session cockpit :

```bash
~/.claude/skills/wsh-cockpit/scripts/wsh-live.sh web start <session>   # ttyd sur 127.0.0.1:7681, read-only
tailscale serve --bg 7681                                              # exposé au tailnet en HTTPS
# ... puis depuis l'iPhone : https://<hôte>.<tailnet>.ts.net
# arrêt : tailscale serve reset && wsh-live.sh web stop <session>
```

**Jamais `tailscale funnel`** — le pane montre tout (y compris d'éventuels secrets affichés) et ne doit jamais toucher l'internet public. Même prudence pour les journaux (`~/Library/Logs/wsh-cockpit/`).

## Sécurité et limites

- `say`/`exit` refusent d'écrire si aucun Claude ne tourne dans le pane (sinon le texte serait exécuté par le shell) ; `go` refuse si le pane est occupé (sinon la commande serait tapée dans le chat de la session en cours). Ces gardes reposent sur la détection d'un processus `claude` sous le pane — fiable pour le relais standard, à revérifier si le pane fait tourner autre chose d'exotique.
- Tout ce qui passe par `say` arrive comme message utilisateur dans la session Claude, avec les mêmes pouvoirs que le clavier local : ne l'utiliser que sur un canal de confiance (tailnet).
- `set` ne prend effet qu'au prochain tour de boucle du relais : si une session est en cours, elle termine sa fiche d'abord — c'est voulu (jamais d'interruption à chaud ; pour interrompre vraiment : `stop`).
- Si l'hôte wrappe ses blocs Wave en tmux avec GC : la session relais survit tant qu'elle n'est PAS nommée `wave-*` et n'est PAS liée (`link-window`) dans un groupe `wave-*`.
