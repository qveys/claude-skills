# Audit trail, backend Zellij, diagnostic et vue navigateur

## Audit trail

**`live` mode only.** Every tmux session auto-logs everything displayed in the pane
to `~/Library/Logs/wsh-cockpit/<session-slug>.log`. The log file name is a sanitized slug of the session name (characters outside `[A-Za-z0-9_.-]` replaced with `_`), so the path remains safe for shell interpolation. Logs are **retained for 30 days**
then auto-purged. Disable logging with `WSH_LIVE_LOG=0`; customize the log
directory with `WSH_LIVE_LOG_DIR=/path`. **⚠️ Audit logs contain everything the
pane displays — treat them as sensitive** (stored with `chmod 700` on the
directory and `chmod 600` on each log file). Review periodically if the session
runs sensitive commands; delete manually with `rm ~/Library/Logs/wsh-cockpit/<session-slug>.log`.

## Backend Zellij (expérimental)

`WSH_MUX=zellij scripts/wsh-live.sh …` pilote une session **Zellij** au lieu de
tmux, avec le même cœur de boucle : `spawn`/`start`/`send`/`read`/`wait-done`/
`stop`/`status`/`open` (le bloc Wave exécute alors `zellij attach`). Détails :

- Une session Zellij background n'a **pas de pane** tant qu'un `run` n'en crée
  pas un ; le script le fait et mémorise le pane-id (`~/.cache/wsh-cockpit/pane-*`),
  car les actions Zellij headless doivent cibler le pane explicitement.
- Restent **tmux-only** avec refus explicite : `keys` (noms de touches tmux) et
  `web` (ttyd a besoin de l'attach lecture seule ; Zellij a son propre
  `zellij web`). Le journal d'audit (`pipe-pane`) est aussi tmux-only, mais ne
  bloque pas la session : elle démarre quand même, non journalisée, avec un
  avertissement explicite sur stderr (`UNLOGGED`) plutôt qu'un refus silencieux.
- Le framing `send` re-source le helper à chaque appel (pas de store d'options
  par session côté Zellij) : ligne visible un peu plus longue, comportement sûr.
- Gate de non-régression : `WSH_MUX=zellij scripts/wsh-live.sh selftest-live`
  doit passer, comme la version tmux, après toute retouche du cœur live.
- Le rendu headless Zellij peut être paresseux au premier write : `wait-done`
  (polling adaptatif) l'absorbe ; ne pas réduire ses timeouts sous zellij.

## Auto-open (`live open`)

`open` already handles every Wave-internals edge case for you — stale
`WAVETERM_TABID`, the WAL-aware `?mode=ro` read of the live active tab, the
absolute-path `tmux` exec (Wave blocks lack the homebrew PATH), and the
attach-landed check with a manual-`tmux attach` fallback. You don't run any of
this by hand; just call `scripts/wsh-live.sh open <session>`. (Implementation:
`resolve_live_tab` / `tab_describe` in the script — touch those if Wave changes.)

**Le bloc s'ouvre sur l'onglet du shell INITIATEUR** (celui où tourne le Claude
Code qui a lancé `spawn`/`open`), pas sur l'onglet « actif » de la DB : la
résolution privilégie les signaux vivants — nom de session tmux `wave-<tab8>`
du wrapping wave-init, puis onglet contenant `WAVETERM_BLOCKID` — car l'env
`WAVETERM_TABID` peut être périmé tout en existant encore en DB (fenêtre tmux
qui survit au bloc qui l'a créée).

The one thing that's on **you**: when `open` reports the cockpit is on tab «T4»
(it prints this when >1 tab exists, because no wsh command can move the UI focus),
**relay that tab name to the user** — never just say "it's open."

## `doctor` — diagnostiquer le cockpit

`scripts/wsh-live.sh doctor` déroule 11 checks read-only (tmux, serveur, sessions
`cockpit-*` vivantes, `wsh`/`sqlite3`, DB Wave/tab actif, state dir, helpers,
logs d'audit, extras `ttyd`/`zellij`) et n'écrit jamais rien — sûr à lancer
n'importe quand, même sans session. Utilise-le quand `open` échoue, qu'une
session semble invisible côté utilisateur, ou que l'état parait périmé. Sortie
une ligne par check (`ok|warn|fail — libellé — détail`), rc 0 si tout est `ok`/
`warn`, rc 1 si au moins un `fail`.

## Cockpit dans le navigateur (`web`)

`scripts/wsh-live.sh web {start|stop|status} [session]` expose le pane d'une
session cockpit dans un navigateur via [`ttyd`](https://github.com/tsl0922/ttyd)
(`brew install ttyd`), pour un utilisateur qui préfère un onglet web à un
`tmux attach`.

```bash
scripts/wsh-live.sh web start cockpit-theo-plan-225108
# web view started: http://127.0.0.1:7681 (pid 84403, session '...')
# mode: read-only (default) — set WSH_WEB_WRITE=1 for a writable view
# loopback only ; from the tailnet: tailscale serve --bg 7681 (never 'funnel' — see below)

scripts/wsh-live.sh web status cockpit-theo-plan-225108   # running/stopped + URL
scripts/wsh-live.sh web stop   cockpit-theo-plan-225108   # kill + supprime le pidfile
```

- **Lecture seule par défaut.** `ttyd` tourne sans `-W` et le client tmux
  s'attache avec `attach -r` (client read-only) : quiconque ouvre l'URL peut
  **regarder mais pas taper**. `WSH_WEB_WRITE=1 scripts/wsh-live.sh web start
  <session>` bascule les deux à la fois (`-W` sur ttyd, `attach` sans `-r`) —
  n'importe qui avec l'URL peut alors **piloter** la session, à activer
  uniquement en connaissance de cause.
- **Port** : `WSH_WEB_PORT` (défaut `7681`).
- **Sécurité — bind loopback strict.** `ttyd` n'écoute que sur `127.0.0.1` : il
  n'est **jamais** exposé directement sur le réseau. Le flux montre **tout ce
  que montre le pane** (mêmes garde-fous que l'audit trail — traiter comme
  sensible). Pour un accès depuis le tailnet, utiliser **uniquement**
  `tailscale serve --bg <port>` (proxy HTTPS tailnet → `127.0.0.1:<port>`,
  arrêt avec `tailscale serve reset`) — **jamais `tailscale funnel`**, qui
  exposerait le pane sur l'internet public.
- `web start` est idempotent : un pid déjà vivant pour la session → message +
  rc 0 (pas de doublon). Après le lancement, le script vérifie que ttyd répond
  (`curl` sur `http://127.0.0.1:<port>` → `200`, jusqu'à 3s) ; sinon rc 1 et le
  pidfile est nettoyé.
- `doctor` signale la présence/absence de `ttyd` (extra optionnel, requis
  uniquement par `web`).
