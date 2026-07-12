# Cycle de vie d'une session cockpit

## Opening a cockpit — never hijack another agent's session

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
5. **`spawn --situate`** — also runs the hostname/pwd/whoami probe (see below)
   internally before returning, in one call instead of four.

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
avertissement. Avant **toute** autre commande, il faut savoir sur quelle machine,
dans quel répertoire et sous quelle identité tu parles — sinon tu pilotes à
l'aveugle (commandes Docker lancées sur le Mac au lieu du serveur, `tailscale ssh`
redondant vers une machine où tu es déjà, etc.).

**Voie recommandée — `spawn --situate` :** le probe hostname/pwd/whoami (send +
wait-done + read) tourne en interne, en un seul appel :

```bash
COCKPIT=/Users/qveys/.claude/skills/wsh-cockpit/scripts/wsh-live.sh
$COCKPIT spawn theo-plan --situate
# → SESSION=cockpit-... puis directement la sortie du pane :
#   srv1453980 / /docker/paperclip / root  (ou le Mac)
```

**Repli — séquence manuelle** (équivalente, utile si tu dois re-situer le shell
plus tard dans le workflow, pas juste après un `spawn`) :

```bash
SESS=cockpit-...        # la valeur retournée par spawn
$COCKPIT send 'hostname; pwd; whoami 2>&1' "$SESS"
$COCKPIT wait-done "$SESS" 60
$COCKPIT read "$SESS" 20   # → srv1453980 / /docker/paperclip / root  (ou le Mac)
```

Adapte la suite selon le résultat : shell **local** (Mac) → `tailscale ssh` pour
atteindre un serveur ; shell **déjà sur le serveur** → Docker/psql/commands en
direct, sans re-SHS. Ne présume jamais « je suis sur le Mac » par défaut.

Si le résultat montre un hôte différent de celui attendu (le pane vient de
`ssh`-hopper), appelle `$COCKPIT remote-init "$SESS"` (ou `remote-init "$SESS" <host>`
si tu connais le nom/l'IP à passer à `tailscale ssh`/`scp`) **avant tout autre**
`send`/`banner` — voir `docs/framing-and-transfer.md` ("Remote shell / lost helpers").

Set `WSH_COCKPIT_PREFIX` or `WSH_COCKPIT_AGENT` so parallel agents keep separate
last-session state under `~/.cache/wsh-cockpit/`.

## Reusing a named session

Requires an explicit flag — otherwise `start` errors:

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
   a live tab (see `docs/advanced.md` → "Auto-open").
4. `send` types a command into the pane and presses Enter; the user sees it
   appear live. By default each `send` is **framed with header/footer banners**
   so the watcher can tell where one call ends and the next begins (see
   `docs/framing-and-transfer.md`). `keys` sends raw control sequences for interactive
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

**`stop` kills the tmux session but does not reliably close the Wave block —
close both.** `open`/`spawn` print `opened Wave block <block-id> ...`: keep that
id. After `stop`, also run `wsh deleteblock -b <block-id>` (best-effort: the
block sometimes auto-closes once the pane's process exits, in which case
`deleteblock` just returns `not found` — that's fine, it means it's already
gone). Skipping this leaves a dead, empty pane in the user's Wave tab.

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

**`live` mode:** `stop` only kills the tmux session — it does not close the Wave
block. Delete that too (see "Opening a cockpit" above for the `deleteblock`
step); otherwise a dead pane lingers in the user's tab.

## `gc` — sweep automatique des sessions orphelines

`live` sessions ne sont normalement supprimées que par un `stop` explicite — si
cet appel n'a jamais lieu (crash, cockpit oublié, agent qui sort sans nettoyer),
la session tmux fuit indéfiniment. `gc` est un sweep périodique ou à la demande :
toute session `cockpit-*` restée **idle** (aucune activité de pane) depuis au
moins le seuil configuré **et** sans client attaché est détruite via le même
`teardown_session()` qu'utilise `stop`.

```bash
scripts/wsh-live.sh gc                          # sweep réel, seuil par défaut 24h
scripts/wsh-live.sh gc --dry-run                # liste ce qui SERAIT tué, ne touche rien
scripts/wsh-live.sh gc --idle=3600               # seuil personnalisé (secondes)
scripts/wsh-live.sh gc --only-session=cockpit-x  # restreint le sweep à une session précise
```

- `--idle=SECONDS` — surcharge `WSH_LIVE_GC_IDLE` (défaut `86400` = 24h).
- `--dry-run` — liste ce qui serait tué sans rien toucher.
- `--only-session=NAME` — restreint le sweep à exactement cette session `cockpit-*`.
- Une session **attachée** (un client tmux dessus) n'est jamais tuée, même au-delà
  du seuil d'idle.
- Couvert par `selftest-gc` (décision pure testée sans tmux réel) — lancer après
  toute retouche de `lib/gc.sh`.
