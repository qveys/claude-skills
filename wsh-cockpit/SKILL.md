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

Detailed docs (read the relevant one before diving into that area):
- `docs/session-lifecycle.md` — `spawn`/`start`/`open`/`stop`, situating the
  shell, reusing sessions, cleanup timing, `gc` sweep.
- `docs/banners.md` — full banner rendering rules, palette, `step-run`.
- `docs/framing-and-transfer.md` — `send` command framing internals, pushing
  files to a remote, `remote-init`/`local-init`.
- `docs/advanced.md` — audit trail, Zellij backend, `open` internals, `doctor`,
  browser view (`web`).
- `docs/gotchas.md` — the full pitfalls list with the "why" behind each.

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

The 60s linger runs detached (script returns immediately); mechanics of the
transport (`START`/`END` markers, `runonce` resync) live in `wsh-rexec.sh`'s
header — see `docs/gotchas.md` for the user-facing consequences.

## Mode 2 — live (shared cockpit)

A tmux session **on the Mac** that you and the user share. Your own shell runs on
the Mac, so you talk to the local tmux server directly — no remote dispatcher, no
`wsh file` queue, no SSH resync to freeze anything. tmux only needs to exist on
the Mac (`brew install tmux`).

```bash
scripts/wsh-live.sh spawn [prefix] [--force] [--situate]  # open cockpit: reuse alive session by default
scripts/wsh-live.sh start [session] [--reuse]  # create session (auto-unique if no name)
scripts/wsh-live.sh open  [session]            # AUTO-OPEN a Wave block attached to it
scripts/wsh-live.sh send  '<command>' [session]  # type a command + Enter
scripts/wsh-live.sh keys  '<tmux-keys>' [session] # raw keys: C-c, Up, q, Enter...
scripts/wsh-live.sh read  [session] [lines]    # snapshot the pane (default 30 lines)
scripts/wsh-live.sh stop  [session]            # kill the session
scripts/wsh-live.sh current                    # print last spawned session for this agent
scripts/wsh-live.sh doctor                     # read-only diagnostic, 11 checks, rc 0/1
scripts/wsh-live.sh gc [--dry-run] [--idle=SECONDS] [--only-session=NAME]  # sweep orphaned idle sessions
scripts/wsh-live.sh web {start|stop|status} [session]  # browser view via ttyd, read-only by default
scripts/wsh-live.sh status [prefix]            # is last session alive? matching sessions?
scripts/wsh-live.sh banner {header|phase|step|done} ... [session]  # airy step banners (required)
scripts/wsh-live.sh step-run <id> '<label>' '<command>' [session] [timeout_sec]  # banner step + send + wait-done in ONE call
scripts/wsh-live.sh remote-init [session] [host]  # after an ssh hop: push helpers to [host] (or sticky inline-only without it)
scripts/wsh-live.sh local-init  [session]         # revert remote-init — back to local helper-file framing
scripts/wsh-live.sh wait-done [session] [timeout_sec]              # wait for send exit footer
scripts/wsh-step.sh {header|phase|step|done|cmd|defs}  # renderer / one-liner / pane-side fn defs
```

### Annonces d'étapes aérées — **obligatoire** pour tout plan multi-étapes

Quand tu exécutes un plan dans le cockpit (setup, déploiement, migration, audit…),
**tu dois annoncer chaque phase et chaque étape avec des bannières visuelles aérées**
via `banner` (jamais `echo`/markdown/commandes nues). Détails complets, palette,
et le raccourci `step-run` : voir `docs/banners.md`.

```bash
COCKPIT=/Users/qveys/.claude/skills/wsh-cockpit/scripts/wsh-live.sh
$COCKPIT banner header "Théo Marceau — OpenClaw" "cockpit-theo-plan-225108"
$COCKPIT banner phase  1 6 "Fondations & isolation"
$COCKPIT banner step   1.1 "openclaw doctor"
$COCKPIT send 'openclaw doctor 2>&1'
$COCKPIT banner done   "Phase 1 terminée"
```

### Opening a cockpit — never hijack another agent's session

**Use `spawn` to open or continue a cockpit** — never bare `start cockpit` (name
commonly reused by other agents). `spawn` reuses an alive session by default;
`spawn --force` only when you intentionally need a second window. `spawn
--situate` also runs the mandatory hostname/pwd/whoami probe in one call — see
"Situer le shell" below. Full lifecycle (`start --reuse`, `open` self-healing,
`stop` auto-closing the Wave block, cleanup timing, `gc` sweep) : voir `docs/session-lifecycle.md`.

**Situer le shell juste après `spawn` — obligatoire.** Une session réutilisée
peut être restée sur un serveur distant (ssh persistant, `cd` projet). Avant
toute autre commande, sache sur quelle machine/répertoire/identité tu parles :

```bash
COCKPIT=/Users/qveys/.claude/skills/wsh-cockpit/scripts/wsh-live.sh
$COCKPIT spawn theo-plan --situate
# → SESSION=cockpit-... puis directement la sortie du pane :
#   srv1453980 / /docker/paperclip / root  (ou le Mac)
```

Si le résultat montre un hôte différent de l'attendu, appelle `$COCKPIT
remote-init "$SESS" [host]` avant tout autre `send`/`banner` — voir
`docs/framing-and-transfer.md` ("Remote shell / lost helpers").

Set `WSH_COCKPIT_PREFIX` or `WSH_COCKPIT_AGENT` so parallel agents keep separate
last-session state under `~/.cache/wsh-cockpit/`.

`send` types a command + Enter, framed by default with header/footer banners
(see `docs/framing-and-transfer.md`). `keys` sends raw control sequences
(`C-c`, `Up`, `q`) for interactive programs — never framed. `read` is
`capture-pane`; default to short reads (`read [session] 20`), only widen when
output is truncated.

### Pousser des fichiers vers un remote — **jamais base64 dans `send`**

Séparer transfert et exécution : `scripts/wsh-push.sh` (ou `wsh file cp`) pour
pousser le fichier depuis le shell agent (invisible), puis un `send` court dans
le cockpit pour vérifier/utiliser. Détails, fallback chain, méthodes : voir
`docs/framing-and-transfer.md`.

## Cleaning up — but not too fast

Every visible block/pane is clutter if left behind. **Wait at least 60s** before
treating an apparently-idle block/session as an orphan — it may still be mid-run.
Only delete blocks/sessions **you** created. `live` mode: `stop` (and `gc`) close
the Wave block automatically along with the tmux session — nothing manual
needed. Automated sweep for forgotten `live` sessions: `scripts/wsh-live.sh gc`.
Full detail: see `docs/session-lifecycle.md`.

## Gotchas — top of mind

The full list with rationale lives in `docs/gotchas.md`; the two that bite most:

- **Always end `send`/`rexec` commands with `2>&1`** — non négociable, sinon le
  footer `exit <code>` peut sembler manquant ou incomplet.
- **Never `send` the next command until the previous one's footer shows `exit`.**
  Use `wait-done`, never agent-side `sleep` or output-grepping.

See `docs/gotchas.md` for the rest (remote-first-statement mangling, `rexec`
non-interactivity, Wave exit-code unreliability, base64-in-`send`, gateway
restart race, etc).
