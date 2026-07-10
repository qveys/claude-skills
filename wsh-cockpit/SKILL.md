---
name: wsh-cockpit
description: >-
  Run commands on the user's behalf in a VISIBLE Wave Terminal block — local (on
  their Mac) or on a Wave-connected remote host — so the user can watch exactly
  what you run, see the output, and even take the keyboard. Use this whenever the
  user wants to *see how you do something* rather than have it hidden in a tool
  shell: "show me how you'd run this", "do it but let me watch", "open a terminal
  and walk me through it", "run this on my machine / on the server and show me".
  Also use it to execute on a host reachable only through Wave (a `wsh ssh`
  connection, a remote block, `user@ip`, srvXXXX) when plain `ssh` fails with
  "Permission denied (publickey,password)" because the credentials live in Wave /
  1Password, not your local agent. Two modes: `rexec` (one-shot — run a command,
  capture stdout/stderr + exit code, the block lingers ~60s so the user can read
  it) and `live` (a shared tmux session on the Mac that you drive and the user
  joins). Reach for this any time you're acting *for* the user at a terminal and
  they should be able to see and trust what's happening — not just for servers.
  For multi-step work in live mode, always announce phases/steps with airy visual
  banners via `wsh-live.sh banner` / `wsh-step.sh` — never plain `echo` lines.
  To deploy files to a remote host, use `scripts/wsh-push.sh` or `wsh file cp` —
  never base64/python chunks through cockpit `send`.
---

# wsh-cockpit

Do terminal work on the user's behalf **in the open**. Instead of running things
in a hidden tool shell, you run them in a Wave Terminal block the user can see —
local on their Mac or on a host Wave is connected to — so they can watch the
exact commands, read the output, and step in if they want. Transparency is the
whole point.

## Two modes

- **`rexec` (one-shot)** — run a single command, capture stdout/stderr + exit
  code, done. The visible block **lingers ~60s after the command finishes** so
  the user can actually read what ran before it auto-closes — but that linger is
  **detached**, so the script returns to you as soon as the command finishes (you
  are NOT blocked for the linger). Works `local` (the Mac) or against a Wave
  connection. → `scripts/wsh-rexec.sh`
- **`live` (shared cockpit)** — a persistent **tmux session on the Mac** that you
  drive (`send-keys` / `capture-pane`) and the user attaches to. You both share
  one terminal: you type commands, they watch live, scroll, split panes, or take
  the keyboard. Best for interactive, multi-step co-driving. → `scripts/wsh-live.sh`

Default to `rexec`. Use `live` when the work is interactive or the user wants to
sit in the same terminal with you.

## Mode 1 — rexec (one-shot)

```bash
scripts/wsh-rexec.sh <local|connection> <command...>
```

**Local (the user's Mac):**
Input: `scripts/wsh-rexec.sh local 'sw_vers; ls ~/Git'`
Output: the command's stdout/stderr, then `---- exit code: N ----`

**Remote (a Wave connection):**
Input: `scripts/wsh-rexec.sh qveys@187.77.175.117 'docker ps; uname -a'`
Output: same shape, run on the host.

Find connection strings with `wsh conn status`. Quote the whole command as one
argument — it runs under the target shell, so `;`, `&&`, pipes, and `$(...)`
work. Slow command? `WSH_REXEC_TIMEOUT=180 scripts/wsh-rexec.sh ...`.

**The 60s linger is deliberate — and detached.** After the command finishes, the
block stays up for `WSH_REXEC_LINGER` seconds (default 60) so the user can read
it, *then* it auto-deletes. That visible-then-delete window plays out in a
backgrounded orphan, so **the script returns to you as soon as the command
finishes** — you are not blocked for the linger. The block keeps lingering in the
user's Wave tab after your call has already returned. You rarely need to touch
`WSH_REXEC_LINGER`; set it to `0` only to make the block vanish the instant the
command ends (e.g. throwaway internal probes you don't want left on screen).

The mechanics (paused-block + `connection`/`runonce` resync for remote, the
`true __warmup__; START … END$?` wrapper that absorbs Wave's first-statement
mangle, marker-sliced output, detached-linger cleanup) live in `wsh-rexec.sh`'s
header — read it only if you need to adapt the transport. The user-facing
consequences are in **Gotchas** below.

## Mode 2 — live (shared cockpit)

A tmux session **on the Mac** that you and the user share. Your own shell runs on
the Mac, so you talk to the local tmux server directly — no remote dispatcher, no
`wsh file` queue, no SSH resync to freeze anything. tmux only needs to exist on
the Mac (`brew install tmux`).

```bash
scripts/wsh-live.sh spawn [prefix] [--force]   # open cockpit: reuse alive session by default
scripts/wsh-live.sh start [session] [--reuse]  # create session (auto-unique if no name)
scripts/wsh-live.sh open  [session]            # AUTO-OPEN a Wave block attached to it
scripts/wsh-live.sh send  '<command>' [session]  # type a command + Enter
scripts/wsh-live.sh keys  '<tmux-keys>' [session] # raw keys: C-c, Up, q, Enter...
scripts/wsh-live.sh read  [session] [lines]    # snapshot the pane (default 30 lines)
scripts/wsh-live.sh stop  [session]            # kill the session
scripts/wsh-live.sh current                    # print last spawned session for this agent
scripts/wsh-live.sh doctor                     # read-only diagnostic, 11 checks, rc 0/1
scripts/wsh-live.sh web {start|stop|status} [session]  # browser view via ttyd, read-only by default
scripts/wsh-live.sh status [prefix]            # is last session alive? matching sessions?
scripts/wsh-live.sh banner {header|phase|step|done} ... [session]  # airy step banners (required)
scripts/wsh-live.sh wait-done [session] [timeout_sec]              # wait for send exit footer
scripts/wsh-step.sh {header|phase|step|done|cmd|defs}  # renderer / one-liner / pane-side fn defs
```

### Annonces d'étapes aérées — **obligatoire** pour tout plan multi-étapes

Quand tu exécutes un plan dans le cockpit (setup, déploiement, migration, audit…),
**tu dois annoncer chaque phase et chaque étape avec des bannières visuelles aérées**.
L'utilisateur regarde Wave en direct — des `echo "étape 1"` ou des commandes nues
en rafale sont illisibles.

**Interdit :**
```bash
send 'echo "=== PHASE 1 ==="'
send 'echo "ETAPE 1.1 doctor"'
send 'openclaw doctor'    # sans bannière step avant
```

**Obligatoire — utiliser `banner` :**
```bash
COCKPIT=/Users/qveys/.claude/skills/wsh-cockpit/scripts/wsh-live.sh

$COCKPIT banner header "Théo Marceau — OpenClaw" "cockpit-theo-plan-225108"
$COCKPIT banner phase  1 6 "Fondations & isolation"
$COCKPIT banner step   1.1 "openclaw doctor"
$COCKPIT send 'openclaw doctor'
$COCKPIT banner step   1.2 "Archivage workspace parasite"
$COCKPIT send 'mv ~/.openclaw/workspace ~/.openclaw/workspace.bak'
$COCKPIT banner done   "Phase 1 terminée"
$COCKPIT banner phase  2 6 "Identité & outils"
$COCKPIT banner step   2.1 "TOOLS.md"
# ...
```

`banner` **source la fonction `__wsh_banner` une seule fois par session** (helper
`~/.cache/wsh-cockpit/helpers/wsh-live-step-vN.sh`, suivi via une option tmux — même mécanisme que le framing
`send`), puis chaque bannière suivante n'est qu'un **appel court et lisible** :
`__wsh_banner done 'msg'`. Fini le pavé `printf` de ~700 caractères tapé dans le
pane à chaque fois — l'utilisateur voit défiler la commande courte, pas le splat.
Pas de framing `send` autour (la bannière EST le séparateur visuel).

Si le pane a fait un `ssh` / `wsh ssh` vers un hôte **sans** le helper local, la
fonction sourcée n'existe plus là-bas : pose `WSH_STEP_INLINE=1` pour retomber sur
le one-liner autonome (`wsh-step.sh cmd …`), qui marche partout sans rien sourcer.

Rendu attendu dans Wave (couleurs quand le pane est un TTY — dégradé en texte
plain sur pipe / non-TTY) :

```
┌────────────────────────────────────────────────────────────────────────┐   ← cyan dim
│                         PHASE 1 / 6                                    │   ← cyan bold
│                      Fondations & isolation                            │   ← blanc
└────────────────────────────────────────────────────────────────────────┘



────────────────────────────────────────────────────────────────────────   ← jaune dim
  ▸  [1.1]  openclaw doctor                                               ← jaune / blanc
────────────────────────────────────────────────────────────────────────
```

Palette par type de bannière (256 couleurs saturées — percutant dans Wave) :
- **`header`** — bordures **turquoise**, titre **magenta hot**, session bleu ciel.
- **`phase`** — bordures **turquoise**, `PHASE N / T` **cyan électrique**, sous-titre blanc intense.
- **`step`** — bordures **jaune vif**, `▸ [id]` **orange**, libellé blanc intense.
- **`done`** — bordures **vert néon**, `✓ message` **vert lime**.

Règles :
- **`banner header`** une fois au début du workflow (titre + nom de session).
- **`banner phase N/T`** au début de chaque phase — avec lignes vides autour.
- **`banner step X.Y`** avant chaque **groupe logique** de commandes (pas chaque
  sous-commande triviale).
- **`banner done`** à la fin de chaque phase.
- **`send`** pour les vraies commandes — le framing `┌─[#N]` reste actif sur `send`,
  les `banner` restent hors de ce cadre pour ne pas doubler le bruit visuel.
- Prévisualiser localement si besoin : `scripts/wsh-step.sh phase 1 6 "titre"`.
- Sorties longues : garde les bannières **en dehors** des pipes (`| head`, etc.).

> **Mainteneur :** le rendu a une seule source de layout (`__wsh_banner` dans
> `wsh-step.sh defs`) ; le live `banner` et le preview direct l'utilisent, seul le
> fallback `WSH_STEP_INLINE=1` répète la mise en page en `printf` plat. Après toute
> retouche du rendu, lance `scripts/wsh-step.sh selftest-step` (garde
> `direct ≡ cmd ≡ defs`, bash+zsh, couleurs forcées).

Checklist avant chaque phase :
1. `banner phase`
2. `banner step` → `send` (commande)
3. `banner step` → `send` (commande suivante)
4. `banner done`

### Opening a cockpit — never hijack another agent's session

**Use `spawn` to open or continue a cockpit.** Do **not** run bare
`start cockpit` — that name is commonly reused by other agents (Claude, Grok, etc.)
and you will land in their tmux pane.

**`spawn` reuses an alive cockpit by default** — it does **not** open a duplicate
Wave block if your previous session is still running. This is the fix for
accidentally jumping from `cockpit-theo-plan-224847` to `cockpit-theo-plan-225108`
while the first tab was still open.

`spawn` behavior:
1. **If a cockpit is still alive** (last remembered session for this agent, or the
   newest `cockpit-<prefix>-*` tmux session) → **reuse it**. Skip auto-open when
   clients are already attached (the user is still watching that tab).
2. **If nothing is alive** → create a fresh tmux session
   (`cockpit-<prefix>-<HHMMSS>`, e.g. `cockpit-grok-222830`) and auto-open Wave.
3. Prints `SESSION=<name>` — use that name (or rely on `send`/`read` defaults)
   for every subsequent command in this workflow.
4. **`spawn --force`** — only when you intentionally need a *second* cockpit
   window (rare). Never call bare `spawn` again mid-workflow just to "reconnect".

```bash
# First cockpit for this workflow:
WSH_COCKPIT_PREFIX=grok scripts/wsh-live.sh spawn theo-plan
# → SESSION=cockpit-grok-theo-plan-224847

# Later in the SAME workflow — reuses 224847, does NOT create 225108:
WSH_COCKPIT_PREFIX=grok scripts/wsh-live.sh spawn theo-plan
# → reusing existing tmux session 'cockpit-grok-theo-plan-224847'

# Check before spawning (optional):
WSH_COCKPIT_PREFIX=grok scripts/wsh-live.sh status theo-plan

scripts/wsh-live.sh send 'uname -a'   # defaults to last spawned session
scripts/wsh-live.sh read
```

**Situer le shell juste après `spawn` — obligatoire.** Un cockpit n'est pas
toujours sur le Mac de l'utilisateur : une session tmux vivante peut avoir été
laissée sur un serveur (ssh persistant, `su -` déjà fait, `cd` dans un dossier
projet), et un `spawn` qui réutilise cette session atterrit dans ce contexte sans
avertissement. Avant **toute** autre commande, envoie un one-shot de situation
pour savoir sur quelle machine, dans quel répertoire et sous quelle identité tu
parles — sinon tu pilotes à l'aveugle (commandes Docker lancées sur le Mac au
lieu du serveur, `tailscale ssh` redondant vers une machine où tu es déjà, etc.) :

```bash
SESS=cockpit-...        # la valeur retournée par spawn
COCKPIT=/Users/qveys/.claude/skills/wsh-cockpit/scripts/wsh-live.sh
$COCKPIT send 'hostname; pwd; whoami 2>&1' "$SESS"
$COCKPIT wait-done "$SESS" 60
$COCKPIT read "$SESS" 20   # → srv1453980 / /docker/paperclip / root  (ou le Mac)
```

Adapte la suite selon le résultat : shell **local** (Mac) → `tailscale ssh` pour
atteindre un serveur ; shell **déjà sur le serveur** → Docker/psql/commands en
direct, sans re-SHS. Ne présume jamais « je suis sur le Mac » par défaut.

Set `WSH_COCKPIT_PREFIX` or `WSH_COCKPIT_AGENT` so parallel agents keep separate
last-session state under `~/.cache/wsh-cockpit/`.

**Reusing a named session** requires an explicit flag — otherwise `start` errors:

```bash
scripts/wsh-live.sh start cockpit --reuse   # only when continuing YOUR session
```

Flow:
1. **`spawn` is the default entry point.** First call creates + opens; later calls
   in the same workflow **reuse** the alive session instead of spawning duplicates.
2. `start` without a name also auto-generates a unique session. With an explicit
   name, it **refuses to reuse** an existing session unless you pass `--reuse`.
3. **`open` attaches a Wave block to an existing session.** Use after `start`, or
   on its own if the session already exists. It self-heals a stale Wave env and
   falls back to printing the manual `tmux attach` line if it genuinely can't find
   a live tab (see Auto-open below).
4. `send` types a command into the pane and presses Enter; the user sees it
   appear live. By default each `send` is **framed with header/footer banners**
   so the watcher can tell where one call ends and the next begins (see
   "Command framing" below). `keys` sends raw control sequences for interactive
   programs (`keys 'C-c'` to interrupt, `keys 'Up'` to recall history, `keys 'q'`
   to quit a pager) — that's how you use tmux's full interactivity, not just
   one-shots. `keys` is **never** framed (raw by design).
5. `read` is `capture-pane` of the scrollback — that's how you see output. Default
   to short reads: use `read [session] 20` or `read [session] 30` for normal
   command checks, and increase only when the output is clearly truncated or
   you are recovering lost context. Avoid broad reads like 80+ lines for
   routine verification; they bury the relevant result.
6. To co-drive a **remote** host, just open it *inside* the session
   (`send 'wsh ssh -n qveys@1.2.3.4'` or `send 'ssh host'`) and keep going — tmux
   stays on the Mac, the remote shell lives inside it.

The session persists across calls and across detach (Ctrl-b d), which is exactly
what makes it a shared workspace. Kill it with `stop` when you're done.

### Pousser des fichiers vers un remote — **jamais base64 dans `send`**

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

#### Méthode 1 — `wsh-push.sh` (recommandé)

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

#### Méthode 2 — `wsh file` directement (si connexion Wave active)

```bash
wsh file cp -f ~/Git/mon-fichier.md wsh://qveys@macbook-openclaw/Users/qveys/cible.md
cat contenu.md | wsh file write wsh://qveys@macbook-openclaw/Users/qveys/cible.md
wsh file cat wsh://qveys@macbook-openclaw/Users/qveys/cible.md   # lire
```

#### Interdit dans le cockpit

```bash
# NON — base64 dans send
send 'python3 -c "import base64; ... decode('\''GIANT...'\'')..."'
# NON — printf base64 en morceaux
send "printf '%s' 'IyBUT09M...' > /tmp/x.b64"
```

### Command framing (visual delimiters)

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

**Remote shell / lost helpers:** if the pane is inside a shell where the local
helper file cannot be sourced, force a one-command self-contained wrapper with
`WSH_LIVE_SEP_REINIT=1 scripts/wsh-live.sh send '<cmd>' [session]`. That command
is intentionally noisier, but it avoids relying on pane-side helper state.

**Self-test escaping:** after changing framing or quoting, run
`scripts/wsh-live.sh selftest-sep`. It exercises the helper wrapper under bash
and zsh without tmux.

> **Mainteneur :** après toute retouche du cœur live (framing, `wait-done`,
> `banner`, `stop`, fichiers d'état), lance `scripts/wsh-live.sh selftest-sep`
> **et** `scripts/wsh-live.sh selftest-live` — ce dernier exerce la vraie boucle
> tmux bout-en-bout (start/send/wait-done/read/banner/stop) sur une session
> `cockpit-selftest-$$` jetable, sans jamais ouvrir de bloc Wave.

## Cleaning up — but not too fast

Every `rexec` block is a visible pane in the user's Wave tab; leaving strays
behind clutters their workspace and leaks shells. The script auto-cleans via a
`trap`, so prefer it over hand-rolled `wsh run`/`setmeta`.

**Wait at least 60s before sweeping a block you think is an orphan.** A block
that looks abandoned may be an `rexec` still mid-run or mid-linger — deleting it
early closes a terminal that's actively in use. Give it the 60s grace window
first; only then is it safe to treat as a stray.

```bash
wsh blocks list                 # find strays (note which look idle ≥60s)
wsh deleteblock -b <block-id>   # remove each confirmed orphan
```

Only delete blocks **you** created. Leave the user's own panes — their long-lived
terminal, their `tmux attach`, your own block — alone. When unsure, leave it.

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

## Gotchas

- **A reused session can turn out to be your OWN Claude Code terminal —
  `spawn` now guards against this automatically, but know the failure mode.**
  `find_reusable_session` looks up the last-remembered session **for the
  agent/prefix key**, not for the exact positional name you passed — if that
  key was ever recorded against a tmux session that got repurposed later (e.g.
  a human attached to it and started an interactive program, including another
  `claude` CLI), a bare `spawn` would previously hand it back with zero
  content check. `send`ing into that pane doesn't run a command — it types the
  text into whatever's running there; against a live Claude Code REPL, that
  means your "situate" probe (`hostname; pwd; whoami`) is submitted as a **new
  chat message** instead of executing, and you only notice from a confused
  reply. `session_safe_to_reuse()` (`lib/session.sh`) now guards on two checks
  before any reuse: (1) an unconditional block on the exact tmux session the
  caller is itself running inside (`$TMUX` + `tmux display-message -p '#S'`,
  via `own_tmux_session`) — this is the check that actually catches the
  incident above, since `pane_current_command` alone would report "bash" from
  inside the check itself; and (2) a `pane_current_command` heuristic that
  rejects any OTHER session whose foreground process isn't a bare shell
  (`bash`/`zsh`/`sh`/`fish`). Either guard failing makes `spawn` fall back to
  a fresh session instead of reusing them silently.
  This is a code-level fix, not just a doc reminder — but it's still a
  heuristic (a shell running inside `screen`/another mux layer can still slip
  through), so keep doing the "situate" `read`-then-`send` dance below as
  defense in depth, and treat any pane content that doesn't look like a bare
  prompt as a hard stop.
- **Never `start cockpit` blindly.** Another agent may already own that tmux
  session. Use `spawn` to open/continue your cockpit; it reuses an alive session
  automatically. Only `spawn --force` creates a duplicate window.
- **Never call `spawn` again mid-workflow to "reconnect".** If the cockpit tab is
  still open, run `send`/`read` (or `current` / `status`) against the existing
  `SESSION=`. Calling `spawn` without `--force` will reuse it; calling it with
  `--force` opens a second tab the user did not ask for.
- **Never skip airy step banners on multi-step cockpit work.** If you're running
  more than ~2 related commands, use `banner` before each logical step and
  `banner done` at each phase end. Plain `echo`, markdown headings, or chat-only
  narration do not replace in-pane banners — the user is watching the terminal.
- **The linger does NOT block the call.** `rexec` returns as soon as the command
  finishes; the visible-then-delete window runs in a detached background job, so
  the block can still be lingering in the user's Wave tab after your call has
  returned. Set `WSH_REXEC_LINGER=0` only when you want the block gone instantly.
- **First statement mangled (remote):** Wave types the command into the remote
  shell, and the first statement loses its argument in that handoff. The
  `true __warmup__;` prefix + `START` marker absorb it — don't remove them, and
  don't make the first real statement something that errors without its argument.
- **Don't forget `cmd:runonce=true` on remote** if you ever drive the steps by
  hand — without it the command runs twice (the connection switch restarts the
  controller, which re-runs).
- **Exit code:** Wave's own per-block "exit code" is unreliable (`-1` is normal).
  Trust the `---- exit code ----` line, which comes from `echo END$?` on target.
- **No input injection into an arbitrary block.** wsh has no `sendinput`/`type`.
  `live` mode works precisely *because* tmux (on the Mac) gives you `send-keys`;
  `rexec` bakes the whole command in up front. A `rexec` command that prompts for
  input won't work — make it non-interactive (`-y`, here-strings) or use `live`.
- **Remote needs an existing Wave connection.** Check `wsh conn status`; if the
  host isn't listed, the user opens it once with `wsh ssh -n <host>`.
- **Reading a remote *file*** is better done directly: `wsh file cat
  "wsh://<conn>/path"`. Use this skill when you need to *run* something visibly.
- **Never push files via base64 in cockpit `send`.** Use `scripts/wsh-push.sh`
  (tailscale ssh pipe / `wsh file cp`) from the agent shell, then verify with a
  short `send` in the cockpit. Base64 in tmux breaks quotes and length limits.
- **After `openclaw gateway restart`, wait for the gateway before the next command.**
  A bare restart returns while LaunchAgent is still starting — immediate `infer`,
  `agent`, or `channels status` calls race a dead socket and fail. **Do not** fire
  the next `send` until the restart command's footer shows exit 0 *and* probe is ok.
  Prefer **one chained cockpit command** (wait loop inside the pane) instead of
  relying on agent-side `sleep`:
  ```bash
  # Option A — helper on remote (deploy via wsh-push.sh):
  $COCKPIT send 'bash ~/wsh-gw-restart.sh 60' cockpit-theo-plan-225108
  # Option B — inline wait loop in a single send:
  $COCKPIT send 'openclaw gateway restart; EL=0; while [ $EL -lt 60 ]; do sleep 3; EL=$((EL+3)); openclaw gateway status 2>&1 | grep -q "Connectivity probe: ok" && echo READY:$EL && break; echo waiting:$EL; done; openclaw gateway status | head -12'
  ```
  Only after `Connectivity probe: ok` → send the next step (`infer`, `agent`, etc.).
  OpenClaw also supports `openclaw gateway restart --wait 45s` when run as one command.
- **Toujours terminer la commande `send`/`rexec` par `2>&1` — non négociable.**
  L'utilisateur **EXIGE de voir le footer `└─[#N] exit <code>` de chaque process**.
  Si une commande écrit sur **stderr** (erreur, warning, log de progression) et que
  tu n'as pas redirigé stderr, cette sortie peut arriver **après** le footer (ou
  hors de la fenêtre de `read`), ce qui donne l'impression que « les commentaires de
  fin d'exécution » manquent. En collant `2>&1` à la fin de la commande, stdout et
  stderr fusionnent dans le pane **avant** que le footer ne s'imprime — le footer
  reste donc bien la **dernière ligne**, fidèle et complète.
  ```bash
  # BIEN — stderr fusionné, footer fiable :
  $COCKPIT send 'openclaw doctor 2>&1' "$SESS"
  $COCKPIT send 'tailscale ssh macbook-openclaw "ls -l ~/.openclaw 2>&1"' "$SESS"

  # MAL — stderr s'échappe, footer paraît manquant / incohérent :
  $COCKPIT send 'openclaw doctor' "$SESS"
  ```
  - **Commande chaînée :** mettre `2>&1` sur l'**ensemble** : `'{ cmd1; cmd2; } 2>&1'`
    ou regrouper en sous-shell `'( cmd1 && cmd2 ) 2>&1'`. Ne pas se contenter d'un
    `2>&1` sur la dernière sous-commande.
  - **Jamais de commande interactive sans footer.** `tailscale ssh host` (sans
    commande) ouvre un **shell interactif** : il ne rend jamais la main, donc le
    footer `exit` n'apparaît qu'à la déconnexion. Pour un diagnostic, préférer un
    **one-shot** `tailscale ssh host '<cmd> 2>&1'` qui retourne et imprime le footer.
- **Never `send` the next command until the previous one shows `exit` in the pane.**
  Each framed `send` ends with `└─[#N] exit <code>`. Use `wait-done` before the next
  `send` — do not guess with agent-side `sleep` or grep arbitrary output text:
  ```bash
  $COCKPIT send 'bash ~/wsh-gw-restart.sh 60 2>&1' cockpit-theo-plan-225108
  $COCKPIT wait-done cockpit-theo-plan-225108 120    # blocks until #[N] exit seen
  # only if exit 0:
  $COCKPIT send 'openclaw infer model run ... 2>&1' cockpit-theo-plan-225108
  $COCKPIT wait-done cockpit-theo-plan-225108 180
  ```
  `wait-done` reads the `@[wsh_seq]` counter set by the last `send` and polls the
  tmux pane for the matching footer. Timeout defaults to 300s (`WSH_WAIT_TIMEOUT`).

### Auto-open (`live open`)

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

### doctor — diagnostiquer le cockpit

`scripts/wsh-live.sh doctor` déroule 11 checks read-only (tmux, serveur, sessions
`cockpit-*` vivantes, `wsh`/`sqlite3`, DB Wave/tab actif, state dir, helpers,
logs d'audit, extras `ttyd`/`zellij`) et n'écrit jamais rien — sûr à lancer
n'importe quand, même sans session. Utilise-le quand `open` échoue, qu'une
session semble invisible côté utilisateur, ou que l'état parait périmé. Sortie
une ligne par check (`ok|warn|fail — libellé — détail`), rc 0 si tout est `ok`/
`warn`, rc 1 si au moins un `fail`.

### Cockpit dans le navigateur (web)

`scripts/wsh-live.sh web {start|stop|status} [session]` expose le pane d'une
session cockpit dans un navigateur via [`ttyd`](https://github.com/tsl0922/ttyd)
(`brew install ttyd`), pour un utilisateur qui préfère un onglet web à un
`tmux attach`.

```bash
scripts/wsh-live.sh web start cockpit-theo-plan-225108
# web view started: http://127.0.0.1:7681 (pid 84403, session '...')
# mode: read-only (default) — set WSH_WEB_WRITE=1 for a writable view
# loopback only ; from the tailnet: tailscale serve --bg 7681 (never 'funnel' — see SKILL.md)

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
