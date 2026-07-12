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
```

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
> `scripts/wsh-live.sh selftest-oneshot-ssh` — pur, sans tmux.
