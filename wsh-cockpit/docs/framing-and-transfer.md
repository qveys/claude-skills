# Framing des `send` et transfert de fichiers

## Pousser des fichiers vers un remote — jamais base64 dans `send`

Le cockpit (`send` / `send-keys`) est fait pour des **commandes courtes** visibles
dans Wave. Y coller du base64, des `printf '%s' '…'` géants ou des heredocs :

- casse le shell (`cursh quote>`),
- dépasse la limite tmux,
- pollue l'écran que l'utilisateur regarde.

**Séparer transfert et exécution :**

| Étape | Outil | Visible dans Wave ? |
|-------|-------|-------------------|
| Pousser un fichier local → remote | `wsh-push.sh` ou `wsh file cp` | Non (agent shell) |
| Vérifier + utiliser le fichier | `wsh-live.sh send 'wc -c …; head …'` | Oui (cockpit) |

### Méthode 1 — `wsh-push.sh` (recommandé)

```bash
PUSH=/Users/qveys/.claude/skills/wsh-cockpit/scripts/wsh-push.sh

# local → remote absolu ; connexion = Tailscale SSH par défaut
$PUSH /tmp/theo-tools.md /Users/qveys/agents/theo-marceau/TOOLS.md
$PUSH ./patch.json5 /Users/qveys/theo-patch.json5 qveys@macbook-openclaw

# Puis vérifier dans le cockpit (bannière + commande courte) :
COCKPIT=.../wsh-live.sh
$COCKPIT banner step 2.2 "TOOLS.md déployé"
$COCKPIT send 'wc -c ~/agents/theo-marceau/TOOLS.md && head -5 ~/agents/theo-marceau/TOOLS.md'
```

Ordre de fallback dans `wsh-push.sh` :

1. **`wsh file cp`** — si Wave a déjà une route (`wsh conn status` → connected)
2. **`tailscale ssh … "cat > tmp && mv"`** — pipe stdin, testé sur `macbook-openclaw`
3. **`scp`** — dernier recours

Doc Wave : [wsh file write/cp](https://docs.waveterm.dev/wsh-reference#file-write)

### Méthode 2 — `wsh file` directement (si connexion Wave active)

```bash
wsh file cp -f ~/Git/mon-fichier.md wsh://qveys@macbook-openclaw/Users/qveys/cible.md
cat contenu.md | wsh file write wsh://qveys@macbook-openclaw/Users/qveys/cible.md
wsh file cat wsh://qveys@macbook-openclaw/Users/qveys/cible.md   # lire
```

### Interdit dans le cockpit

```bash
# NON — base64 dans send
send 'python3 -c "import base64; ... decode('\''GIANT...'\'')..."'
# NON — printf base64 en morceaux
send "printf '%s' 'IyBUT09M...' > /tmp/x.b64"
# NON — cat/heredoc du contenu d'un fichier à travers le pane, même "juste pour lire"
send "cat /remote/path/big-file.log"
```

### Méthode 3 — `push`/`pull` (voie officielle quand le pane est en SSH)

Une fois que le pane a fait un hop SSH (`remote-init`/`--pre <host>` a
enregistré l'hôte pour la session), `wsh-push.sh` n'est plus appelé
directement : `scripts/wsh-live.sh push`/`pull` déduisent l'hôte de l'état de
session — pas besoin de le redonner à la main, et impossible de se tromper
d'hôte entre deux appels.

```bash
scripts/wsh-live.sh push "$SESS" ./local-file.md /remote/absolute/path.md
scripts/wsh-live.sh pull "$SESS" /remote/absolute/path.log ./local-copy.log
```

Sous le capot, ces deux commandes shellent vers `wsh-push.sh` (le même moteur
que la méthode 1, étendu pour supporter les deux sens et un `--control-path`)
avec l'hôte enregistré et le socket `ControlMaster` de la session (voir
« Remote shell / lost helpers » plus bas). Ordre de fallback, identique dans
les deux sens, choisi automatiquement et **annoncé sur stderr** :

1. **`wsh file cp`** — si Wave a déjà une route pour la connexion
2. **Socket `ControlMaster` de la session** (`ssh -O check` local, pas de
   round-trip réseau) — réutilise la connexion OpenSSH déjà authentifiée du
   hop du pane, zéro nouvelle auth FIDO2. Absent/skip silencieusement si le
   hop était un `tailscale ssh` (pas de ControlMaster côté tailscale) ou si le
   pane n'a pas encore hopé.
3. **`tailscale ssh`** — pipe stdin (push) / `cat` (pull), pas de multiplexage
   mais l'auth tailnet est transparente
4. **`scp` nu** — dernier recours ; avertissement sur stderr, ré-auth probable

`push`/`pull` tournent depuis le shell agent (jamais via `send`) : ils ne
comptent **jamais** pour l'avertissement one-shot SSH de la tâche 09 — ce
compteur ne surveille que ce qui passe par `send`. Sans hôte enregistré pour
la session (`remote-init`/`--pre` jamais appelé), `push`/`pull` échouent avec
un message clair plutôt que de deviner.

## Command framing (visual delimiters)

Because the user *watches* the same pane you type into, successive `send`s would
otherwise run together. So each `send` is wrapped in a banner — a header before
the command and a footer after it finishes — with blank-line breathing room:

```
────────────────────────────────────────────────────────────
┌─[#3] 18:05:59          ← incremental seq + timestamp
│$ ls /nonexistent-xyz   ← the command, echoed
────────────────────────────────────────────────────────────
                          ← blank line before output
ls: /nonexistent-xyz: No such file or directory   ← real output
                          ← blank line before footer
└─[#3] exit 1            ← footer: same seq + exit code
────────────────────────────────────────────────────────────
```

- The rule width tracks the pane's `COLUMNS` (capped at 100). When the pane is a
  TTY: séparateurs **bleu ciel**, `[#N]` **cyan électrique**, horodatage bleu,
  `$` **jaune vif**, commande **blanc intense**, footer **vert néon** (exit 0) /
  **rouge vif** (échec). 256 couleurs saturées — dégradé en texte plain hors TTY.
- The framing stores small helper functions in a versioned short-path helper
  like `~/.cache/wsh-cockpit/helpers/wsh-live-sep-vN.sh`. The first framed `send` for a tmux
  session sources it; later sends use one compact `__wsh <seq> <cmd>` call. The
  helper displays the command, runs it with the pane shell, captures `$?`, then
  prints the footer. The footer still only prints after the command returns. An
  interactive command (a `sudo` waiting for a password, a pager, `read`) runs
  normally and the closing banner appears only once it actually finishes; feed
  its input with `keys` in the meantime.
- A per-session counter lives in a state file under `~/.cache/wsh-cockpit/`,
  so the `#N` sequence persists across `send` calls with no temp files; `stop`
  clears it.
- The banners never use the tokens `START`/`END`, so they don't collide with
  `rexec`'s markers, and `read` is just a human-readable `capture-pane` — the
  extra lines are cosmetic and don't interfere with how you re-read output.

**Disable it:** `WSH_LIVE_SEP=0 scripts/wsh-live.sh send '<cmd>' [session]` sends
the raw command with no framing — use it when driving a TUI/REPL that dislikes
the extra echo noise. Default is on (`WSH_LIVE_SEP=1`).

## Lire un résultat sans deviner (`output`, `wait-done --print`)

Ces mêmes marqueurs `┌─[#N]` / `└─[#N] exit <code>` délimitent chaque `send`
de façon déterministe dans le pane — pas besoin de deviner un nombre de lignes
pour le relire :

```bash
scripts/wsh-live.sh send 'seq 1 500' "$SESS"
scripts/wsh-live.sh wait-done "$SESS" 30 --print   # attend le footer PUIS imprime le segment #N — un seul appel
# — équivalent à —
scripts/wsh-live.sh wait-done "$SESS" 30
scripts/wsh-live.sh output "$SESS"                 # imprime le segment #N (défaut = le dernier send)
```

`output [session] [seq] [--full]` extrait exactement le segment du header au
footer inclus (`seq` par défaut = le dernier `send`, lu depuis le compteur
`@[wsh_seq]`). Pas de troncature aveugle : au-delà de `WSH_READ_MAX` lignes
(120 par défaut), il imprime les ~30 premières + une note `« K lignes omises —
relire avec « output --full » ou « read N » »` + les ~60 dernières (la fin
porte les erreurs et le footer). `output --full` désactive le plafond.

Cas dégradés — jamais de mensonge, toujours un message clair sur stderr :
segment sorti du scrollback capturé (`capture-pane` a une limite) → repli
suggéré sur `read N` ; pane sans marqueurs (`WSH_LIVE_SEP=0`, `keys`,
TUI/REPL) → `output` l'explique directement et suggère `read N`. `read [session]
[lines]` reste la voie pour l'inspection libre.

**Remote shell / lost helpers:** once the pane `ssh`/`tailscale ssh`-hops to a
remote host, the local helper file (`~/.cache/wsh-cockpit/helpers/...`) doesn't
exist there, so sourcing it fails ("command not found"). Two ways to get ahead
of it:

**Recommended, when `<host>` is known up front — push BEFORE the hop:**

```bash
scripts/wsh-live.sh remote-init --pre <host> "$SESS"   # or: spawn --pre <host>
scripts/wsh-live.sh send 'tailscale ssh <host>' "$SESS"   # the hop itself
```

`--pre` resolves `<host>`'s `$HOME` directly over `tailscale ssh` (no pane probe
needed — there's no pane content to read yet, the hop hasn't happened) and
registers the remote helper paths on the session right away, so the **first**
`send`/`banner` after the hop already uses the short sourcing form — no extra
`remote-init` round-trip once the pane lands.

**Otherwise — after the hop**, right after the "situer le shell" probe confirms
the pane landed on a different host (`spawn --situate` now does this check and
this call for you automatically — see `docs/session-lifecycle.md`):

```bash
scripts/wsh-live.sh remote-init "$SESS" <host>   # <host> = whatever tailscale ssh/scp accepts
```

Both forms are best-effort and never hard-fail: when `spawn --situate`
auto-detects a hostname mismatch, it passes the pane's own `hostname` output as
`<host>` (stripping a trailing `.local` — macOS's Bonjour/mDNS suffix, which
`tailscale ssh`/`scp` don't resolve) and falls back to inline framing with a
stderr warning if that guess still isn't reachable.

With `<host>`, `remote-init` pushes the sep/step helper files to
`~/.cache/wsh-cockpit/helpers/` on that host (via `scripts/wsh-push.sh` — `wsh
file cp` → `tailscale ssh` pipe → `scp`, same fallback chain as any other file
push) and records the remote paths, so every later `send`/`banner` on this
session keeps using the short `. '<remote-path>' && __wsh ...` sourcing form —
just pointed at the remote copy instead of the local one. It re-sources on
every call (no "loaded once" tracking for the remote case), so there's no
stale-state risk if the pane reconnects. If the push fails for any reason (no
route to `<host>`, `wsh-push.sh` missing, no `$HOME` reachable), `remote-init`
warns on stderr and falls back to inline framing automatically — it never
hard-fails the call. **One hop only:** hopping again from that host to a THIRD
host isn't tracked; it falls back to inline there too, still correct, just not
optimized.

**ControlMaster on the hop itself.** For an OpenSSH hop (not `tailscale
ssh` — see below), send it with multiplexing on:

```bash
scripts/wsh-live.sh send "ssh -o ControlMaster=auto -o ControlPath=~/.cache/wsh-cockpit/cm-$SESS -o ControlPersist=10m <host>" "$SESS"
```

The pane's own interactive session then IS the master connection: `push`/
`pull` (see below) find that same socket by the session name alone
(`control_path_for_session` in `lib/session.sh`) and reuse it — no fresh
FIDO2 prompt for out-of-pane transfers. This does not contradict the
persistent-session rule above; it's the same one session, just also usable
from the agent shell. **`tailscale ssh` does NOT support ControlMaster** — a
session hopped that way simply never has a live socket at that path, so
`push`/`pull` fall through to the `tailscale ssh` transport cleanly (see
`wsh-push.sh`'s `try_control_path`/`control_master_alive` — a purely local,
fast socket check, no special-casing needed to tell the two hop kinds apart).

Without `<host>` (or when you don't know it up front), `scripts/wsh-live.sh
remote-init "$SESS"` still works as a sticky **inline-only** switch: every
later `send`/`banner` defaults to the self-contained one-liner wrapper (no
sourcing, no pane-side state) until you call `local-init "$SESS"` to revert —
e.g. once the pane `exit`s the ssh hop back to the Mac's own shell.

The env vars `WSH_LIVE_SEP_REINIT=1` (for `send`) and `WSH_STEP_INLINE=1` (for
`banner`) remain valid as a **one-off override** — e.g. forcing inline framing
for a single command without flipping the sticky session-wide switch. They
always win over both `remote-init` and the default:

```bash
WSH_LIVE_SEP_REINIT=1 scripts/wsh-live.sh send '<cmd>' [session]
```

**Self-test escaping:** after changing framing or quoting, run
`scripts/wsh-live.sh selftest-sep`. It exercises the helper wrapper under bash
and zsh without tmux.

> **Mainteneur :** après toute retouche du cœur live (framing, `wait-done`,
> `banner`, `stop`, fichiers d'état), lance `scripts/wsh-live.sh selftest-sep`
> **et** `scripts/wsh-live.sh selftest-live` — ce dernier exerce la vraie boucle
> tmux bout-en-bout (start/send/wait-done/read/banner/remote-init/local-init/stop)
> sur une session `cockpit-selftest-$$` jetable, sans jamais ouvrir de bloc Wave.
> `remote-init` avec un `<host>` (le chemin qui pousse les helpers via
> `wsh-push.sh`) n'est PAS couvert par le selftest — il dépend d'un hôte distant
> réel — et a été vérifié manuellement à la place (voir la PR). Si la retouche
> touche `send` (framing, garde one-shot SSH), lance aussi
> `scripts/wsh-live.sh selftest-oneshot-ssh` — pur, sans tmux. Si la retouche
> touche `wsh-push.sh`, `push`/`pull`, ou le socket `ControlMaster` de session
> (`control_path_for_session`, `remote_host_*` dans `lib/session.sh`), lance
> aussi `scripts/wsh-live.sh selftest-transfer` — les cas d'erreur (fichier
> local absent, hôte injoignable) sont couverts sans hôte distant réel ; le
> round-trip checksum et le cas fichier-distant-absent tournent en plus si ce
> Mac accepte le ssh loopback vers lui-même (sinon `skip` explicite), et le
> transport `ControlMaster` a été vérifié manuellement contre un hôte réel du
> tailnet (voir la PR) — même limitation que `remote-init <host>` ci-dessus.
