# Cycle de vie d'une session cockpit

## Opening a cockpit — never hijack another agent's session

**Use `spawn` to open or continue a cockpit.** Do **not** run bare
`start cockpit` — that name is commonly reused by other agents (Claude, Grok, etc.)
and you will land in their tmux pane.

**`spawn` reuses an alive cockpit by default** — it does **not** open a duplicate
Wave block if your previous session is still running. This is the fix for
accidentally jumping from `cockpit-theo-plan-224847` to `cockpit-theo-plan-225108`
while the first tab was still open. Since the wrapper/adoption lot (fiches
1.2-1.9), "reuse" is no longer a single alive-or-not check — `spawn` (without
`--force`) walks three resolution steps in order, each gated by an atomic
**claim** (`lib/claim.sh`, invariant I3: any session claimed by anyone, in any
state past ABSENT, is skipped by the steps below it — never a silent double
claim):

1. **Registry** (`find_registry_session`) — among *my own* sessions (claimed
   under my `WSH_COCKPIT_AGENT`/`WSH_COCKPIT_PREFIX` key), filtered by prefix
   if one was passed, else last-used-if-registered, else the sole candidate →
   **reuse it**. More than one match with none last-used → refuses (exit 2,
   ambiguous) rather than silently pick one.
2. **Adoption** (`WSH_COCKPIT_ADOPT` only — see "Cockpit pré-ouvert par
   l'utilisateur" ci-dessous) — if step 1 missed, try each session listed in
   `WSH_COCKPIT_ADOPT` (comma-separated, in order): claim it, run the
   **mandatory** `hostname; pwd; whoami` probe, and only finalize the adoption
   if the probe succeeds — a failed probe rolls the claim back instead of
   handing you a session nobody verified.
3. **Legacy scan** (`try_legacy_claim`, pre-registry sessions) — an unclaimed
   `cockpit-<prefix>-*` tmux session found free (not in `WSH_COCKPIT_ADOPT`,
   nobody's registry, nobody else's claim) → claimed on the spot (same probe
   gate as step 2) and reused.
4. **Nothing found** → create a fresh tmux session
   (`cockpit-<prefix>-<HHMMSS>`, e.g. `cockpit-grok-222830`), claim it under my
   key, and auto-open Wave.

Skip auto-open when clients are already attached (the user is still watching
that tab) whichever step 1-4 produced the session.

5. Prints `SESSION=<name>` — use that name (or rely on `send`/`read` defaults)
   for every subsequent command in this workflow.
6. **`spawn --force`** — only when you intentionally need a *second* cockpit
   window (rare); skips steps 1-3 entirely, never touches an existing claim of
   mine. Never call bare `spawn` again mid-workflow just to "reconnect".
7. **`spawn --situate`** — also runs the hostname/pwd/whoami probe (see below)
   internally before returning, in one call instead of four. If the probed
   hostname differs from this Mac's, it now auto-calls `remote-init` for you
   (best-effort push, falls back to inline framing with a warning — see below).
8. **`spawn --pre <host>`** — pre-stages the sep/step helpers on `<host>`
   *before* the pane ever ssh-hops there (shorthand for `remote-init --pre
   <host>` right after spawn — see "Voie recommandée" below).
9. **`spawn --tab <name>`** — relayed to the underlying `open`: anchors the
   Wave block on the named tab instead of the live/current one (see
   `docs/advanced.md` → "Auto-open").

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

**Voie recommandée quand l'hôte est déjà connu — pré-push avant le hop :**
`remote-init --pre <host>` pousse les helpers sur `<host>` **avant** que le pane
ne fasse son `ssh`, en résolvant `$HOME` distant directement (hors pane, via
`tailscale ssh`) — pas besoin d'attendre le hop pour situer le shell. Le premier
`send`/`banner` après le hop utilise donc immédiatement la forme courte (~100
caractères), jamais le blob inline. `spawn --pre <host>` fait la même chose en
un seul appel, juste après avoir créé/réutilisé la session :

```bash
COCKPIT=/Users/qveys/.claude/skills/wsh-cockpit/scripts/wsh-live.sh
$COCKPIT spawn theo-plan --pre macbook-openclaw
# → SESSION=cockpit-... puis "pre-push: helpers staged on 'macbook-openclaw':... — remote mode ON"
$COCKPIT send 'tailscale ssh macbook-openclaw' "$SESS"   # le hop lui-même
$COCKPIT send 'hostname' "$SESS"   # sonde non-interactive : le hop lui-même n'émet pas de footer avant déconnexion, ne pas wait-done dessus
$COCKPIT wait-done "$SESS" 60
$COCKPIT send 'docker ps' "$SESS"   # déjà en forme courte, pas de remote-init à part
```

Équivalent en deux appels sur une session déjà spawnée :
`$COCKPIT remote-init --pre <host> "$SESS"`, puis le `send` du hop.

**Sinon (hôte inconnu à l'avance) — `spawn --situate` :** le probe
hostname/pwd/whoami (send + wait-done + read) tourne en interne, en un seul
appel, et si le hostname retourné diffère de celui du Mac, `situate` appelle
lui-même `remote-init` en best-effort (push si `<host>` est joignable, sinon
repli inline avec warning stderr — jamais de hard-fail) :

```bash
$COCKPIT spawn theo-plan --situate
# → SESSION=cockpit-... puis directement la sortie du pane :
#   srv1453980 / /docker/paperclip / root  (ou le Mac)
# → si différent du Mac : "situate: pane is on '...' — auto-calling remote-init '...'"
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
`ssh`-hopper) et que rien n'a encore poussé les helpers, appelle `$COCKPIT
remote-init "$SESS"` (ou `remote-init "$SESS" <host>` si tu connais le nom/l'IP
à passer à `tailscale ssh`/`scp`) **avant tout autre** `send`/`banner` — voir
`docs/framing-and-transfer.md` ("Remote shell / lost helpers").

Set `WSH_COCKPIT_PREFIX` or `WSH_COCKPIT_AGENT` so parallel agents keep separate
last-session state under `~/.cache/wsh-cockpit/`.

## Cockpit pré-ouvert par l'utilisateur — adoption, `--keep`, hygiène

Le wrapper `claude-cockpit` (`scripts/claude-cockpit.sh`, symlinké en
`claude-cockpit` sur le `$PATH`) permet à l'utilisateur de pré-ouvrir un ou
plusieurs cockpits avant même de lancer l'agent : `claude-cockpit theo-plan
--keep --and deploy -- <args claude>` crée un cockpit par groupe `--and`
(toujours `spawn --force --preopen`, jamais une réutilisation silencieuse),
pose `WSH_COCKPIT_ADOPT=<sessions>` (liste ordonnée, jointe par des virgules)
dans l'environnement du process `claude` lancé en avant-plan, avec
`WSH_COCKPIT_AGENT=claude-<epoch>-<pid>` — jamais `WSH_COCKPIT_PREFIX`,
explicitement retirée même si héritée, car elle prendrait le pas sur
`WSH_COCKPIT_AGENT` dans `normalize_prefix`.

- **Claim atomique.** Chaque étape de la résolution `spawn` (registre →
  adoption → scan legacy, ci-dessus) passe par la machine d'états de
  `lib/claim.sh` (ABSENT → PRÉ-CLAIM → EN-COURS → POSSÉDÉ) : jamais deux
  agents ne peuvent finaliser la même session, et une adoption qui échoue
  (sonde en échec, pane occupé) restaure le claim précédent au lieu de le
  perdre.
- **`--keep` est une propriété de la SESSION, pas du claim.** Posé par le
  wrapper à la création (`touch keep-<slug>`), le marqueur survit à toute
  adoption/relâche ultérieure — un agent qui adopte une session `keep` en
  hérite telle quelle. Conséquence directe : `release` (jamais `stop`) sur
  une session `keep` — `stop` le sait déjà et se rabat automatiquement sur
  `release` quand le marqueur est présent, gardant le claim rétrogradé en
  pré-claim `released` (ré-adoptable via l'étape 2, jamais redétruit au
  passage). Une session adoptée **sans** `keep` (créée directement par le
  wrapper sans `--keep`, ou reprise via le scan legacy) suit le chemin normal
  : `release_session` supprime le fichier de claim entièrement (retour
  ABSENT, re-scannable étape 3).
- **Balayage de sortie du wrapper.** Après le retour de `claude` (succès ou
  échec — seul un crash du wrapper lui-même saute le balayage), toute session
  encore vivante de ce run — adoptée (`claude-<runid>`) ou jamais adoptée
  (toujours `user-preopen-<n>`) — est relâchée si elle porte le marqueur
  `keep`, détruite sinon. Un agent qui a lui-même `release`/`stop` proprement
  en fin de tâche n'a rien de plus à faire ; le wrapper est le filet, pas le
  chemin nominal.
- **Hygiène `gc`.** Le plancher d'idle d'une session `keep` est porté à 24h
  minimum (`GC_KEEP_FLOOR_IDLE`, `lib/gc.sh`) quel que soit un `--idle` plus
  court passé à `gc` — mais reste soumis au balayage normal passé ce plancher
  : une `keep` détachée et oubliée finit par disparaître, elle n'est pas
  immortelle. `gc` nettoie aussi, en passe séparée, les familles de
  marqueurs orphelins (`keep-`, `prefix-`, `adopt-claim-`, `.won-<pid>`, …)
  dont la session sous-jacente est morte — jamais une session vivante.

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
5. To see a `send` result, prefer `wait-done --print` (or `output` after a plain
   `wait-done`) over `read N` — the `┌─[#N]`/`└─[#N] exit <code>` markers already
   bound the segment exactly, so there is no line count to guess (see
   `docs/framing-and-transfer.md` → "Lire un résultat sans deviner"). `read` is
   `capture-pane` of the raw scrollback — reserve it for free-form inspection
   where there are no markers to bound on (a TUI/REPL, `WSH_LIVE_SEP=0`, or
   recovering lost context), and keep it short (`read [session] 20`) even then.
6. To co-drive a **remote** host, just open it *inside* the session
   (`send 'wsh ssh -n qveys@1.2.3.4'` or `send 'ssh host'`) and keep going — tmux
   stays on the Mac, the remote shell lives inside it.

The session persists across calls and across detach (Ctrl-b d), which is exactly
what makes it a shared workspace. Kill it with `stop` when you're done.

**`stop` (and `gc`) auto-close the Wave block.** `open`/`spawn` print
`opened Wave block <block-id> ...` and remember that id under
`~/.cache/wsh-cockpit/block-<session>`; `teardown_session` — shared by `stop`
and `gc` — reads it back and runs `wsh deleteblock -b <block-id>` best-effort
(the block sometimes auto-closes once the pane's process exits, in which case
`deleteblock` just returns `not found`; no `wsh` on PATH is also fine). Nothing
manual to do here anymore — this is only a fallback if the state file is
missing (e.g. a block opened by hand, or state cleared out from under it).

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

Only delete blocks/sessions **you created or adopted without `--keep`**. Leave
the user's own panes — their long-lived terminal, their `tmux attach`, your own
block — alone. When unsure, leave it. A `live` session adopted **with**
`--keep` is never deleted, only `release`d (see "Cockpit pré-ouvert par
l'utilisateur" above).

**`live` mode:** `stop` (and `gc`) close the Wave block automatically along with
the tmux session — see "Opening a cockpit" above. This heuristic-scan cleanup
section is for `rexec` strays only, which have no state file to key off.

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
- Une session marquée **`keep`** (sticky, voir "Cockpit pré-ouvert par
  l'utilisateur" ci-dessus) a un plancher d'idle porté à 24h minimum même avec
  un `--idle` plus court — passé ce plancher, elle retombe dans le balayage
  normal comme n'importe quelle autre session.
- Couvert par `selftest-gc` (décision pure testée sans tmux réel) — lancer après
  toute retouche de `lib/gc.sh`.
