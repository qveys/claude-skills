# Gotchas

Pièges classiques et erreurs fréquentes en mode `live` et `rexec`. Voir
`SKILL.md` pour les règles impératives (celles-là ne se discutent pas) ; ce qui
suit est le détail et le "pourquoi" derrière chacune.

- **A reused session can turn out to be your OWN Claude Code terminal —
  `spawn` guards automatically, but know the failure mode.**
  `find_reusable_session` looks up the last-remembered session **for the
  agent/prefix key**, not for the exact positional name you passed — if that
  key was ever recorded against a tmux session that got repurposed later
  (e.g. a human attached it and started an interactive program, including
  another `claude` CLI), a bare `spawn` would hand it back with zero content
  check. `send`ing into that pane doesn't run a command — it types text into
  whatever's running there; against a live Claude Code REPL, your "situate"
  probe (`hostname; pwd; whoami`) gets submitted as a **new chat message**
  instead of executing, and you only notice from the confused reply.
  `session_safe_to_reuse()` (`lib/session.sh`) guards on two checks before
  any reuse: (1) an unconditional block on any tmux session that resolves to,
  or shares a pane with, the one the caller is itself running inside — exact
  name, prefix, fnmatch, anchored `=name`, or a grouped session under another
  name are all caught primarily via `$TMUX_PANE` membership in
  `mux_session_panes` (`tmux list-panes -s`); when `$TMUX_PANE` is unset, the
  guard can no longer establish identity at all and refuses outright
  (`own_tmux_session` returns rc=2, Task 8) instead of falling back to a name
  comparison — this catches the incident above, since
  `pane_current_command` alone would report "bash" from inside the check
  itself; (2) a `pane_current_command` heuristic that rejects any OTHER
  session whose foreground isn't a bare shell. `start <name> --reuse` refuses
  the caller's own session with exit 8 but deliberately applies only check 1:
  `--reuse` is an explicit "continue THIS session", so a non-shell foreground
  is presumed known to the caller — only `spawn`'s silent reuse runs the
  bare-shell heuristic too. History: guard introduced by
  `a920197` (#7), silently lost in the `9863c07` regression, reintroduced
  with `selftest-guard`. Since Task 2 (lot 2), the same own-session check
  guards the WRITE paths too: `send`/`keys`/`step-run`/`banner` all refuse
  outright (exit 8, `deny_own_session`, `lib/session.sh`) when the resolved
  session is the caller's own — against a bare shell this used to TYPE the
  command into the caller's own pane, queued silently behind the still-
  running caller until it eventually finished (measured: `step-run` timing
  out at rc=124 rather than ever seeing the real result, since `wait-done`
  gave up long before the queued text got a chance to run). `read`/`output`/
  `wait-done` stay unguarded — read-only, no self-interference hazard (plan
  §3).
- **A session name is now taken literally — abbreviations by prefix are no
  longer accepted.** `mux_has`/`mux_kill`/`mux_clients` (`lib/mux.sh`) anchor
  their tmux target with `=` (`-t "=$1"`), forcing an exact match. Before
  this, an unanchored `-t "$1"` let tmux fall back from exact match to
  session-name prefix, then to fnmatch — so `mux_has "cockpit-foo"` could
  silently resolve to `cockpit-foo-bar-123456` and a remembered dead session
  could "come back to life" via a same-prefixed homonym. This was never a
  designed shortcut: `resolve_session` (`lib/session.sh`) is a pure
  passthrough with no resolution logic of its own, so the old fallback was
  tmux's default behavior leaking through, not a feature. The one place this
  changes visible behavior is argument disambiguation in `wsh-live.sh`
  (`output`/`step-run` parsing "is this token a session name or something
  else?"): a prefix typed by a caller now falls through to the other
  category instead of matching. Covered by `selftest-guard` cases 13-17 (18
  adds a positive control — see `lib/selftests.sh`).
  Whether a tmux command honors `=` is **not** predictable from "target-session
  vs target-pane" alone — measure per command:
  - Honor `=` (target-session): `has-session`, `kill-session`, and
    `list-clients` (measured: `list-clients -t "=beta"` → rc=0, `-t "=bet"` →
    `can't find session: bet`, rc=1). `mux_clients` is anchored the same way
    as `mux_has`/`mux_kill` — free to add, since its 4 callers
    (`wsh-live.sh:441,477,727,730`) only ever receive names already
    validated by `need_session`/`last_session`.
  - Reject `=` outright and resolve by PREFIX instead (measured, tmux 3.7b):
    `set-option`/`show-option`, along with `send-keys`, `capture-pane`,
    `split-window`, `pipe-pane`. Previously misclassified in this file as
    honoring `=` — measured wrong, by deduction, not by running it (see the
    I2 gotcha below for what that cost). Measured on an isolated server with
    only a session named `soptlong`: `set-option -t "=sopt" @m 1` → rc=1
    `no such session: =sopt` (the anchor is rejected), but `set-option -t
    "sopt" @m 7` → rc=0, and `show-option -v -t soptlong @m` → `7` — the
    unanchored write landed on `soptlong` via prefix resolution, the exact
    opposite of what an anchored command would do. Piège associé :
    `show-option -qv -t "=X" @opt` still returns rc=0 with an EMPTY value
    when `X` doesn't exactly exist (`-q` swallows the "no such session"
    error) — a quiet empty result is not proof the target was rejected, nor
    that it doesn't exist. Fixing prefix ambiguity for these commands means
    canonicalizing the name once via `mux_session_name` and propagating
    only that — a separate piece of work (`send-keys`/`capture-pane`/
    `split-window`/`pipe-pane` still need it; `set-option`/`show-option` in
    `teardown_session` got a narrower fix — see the next gotcha).
  Fixed for the discrimination itself (not the canonicalization above) by the
  `2026-08-02-desambiguisation-argument-session.md` lot: a token still gets
  dropped from ITS category when it doesn't look like a session at all, but a
  token whose FORM matches (`cockpit-*`, the bare `cockpit` default, or an
  anchored `=…`) no longer falls through silently just because it happens not
  to exist right now — `looks_like_session` (`lib/session.sh`) makes that
  call by shape, before `mux_has` ever asks about existence, and a token that
  passes it but is dead reaches `need_session` and fails loud (`no tmux
  session 'X'`, exit 4) at `banner`/`wait-done`/`output`/`step-run`, the same
  four sites this gotcha names. `--session NAME` / `-s NAME`
  (`parse_session_flag`) sidesteps the whole discrimination for a caller that
  already knows the name it wants — including one that doesn't match
  `cockpit-*` at all (`start` accepts free-form names) — short-circuiting
  straight to `resolve_session`/`need_session`; a flag with no value (end of
  arguments, or a value starting with `-`) is a usage error, exit 2, not a
  silent no-op. Covered by `selftest-guard` cases 30-36.
- **`stop <prefix>` used to silently corrupt a LIVE neighbour session
  instead of doing nothing.** `stop` (`wsh-live.sh`) passes its raw argument
  straight to `teardown_session` (`lib/session.sh`) with no `mux_has` check
  of its own. `teardown_session`'s six `tmux set-option -u -t "$sess"` calls
  are unanchored, and `set-option` resolves by PREFIX (see the gotcha
  above) — so `stop cockpit-nb`, with no session exactly named
  `cockpit-nb` but a live `cockpit-nb-222222` next to it, used to wipe that
  neighbour's `@wsh_remote_mode`/`@wsh_remote_host`/helper-path options
  while the anchored `mux_kill` right after correctly (and silently)
  refused to kill anything — measured end to end: `stop cockpit-nb` prints
  `no session 'cockpit-nb' to kill` (rc=1) and the neighbour's three
  options come back empty immediately after, with the neighbour itself
  still alive and never mentioned. Concretely dangerous for a neighbour
  mid-SSH-hop with `remote-init` done: its next `send` loses remote mode
  and tries to source a helper path local to the Mac on the remote host;
  `push`/`pull` lose the recorded host. Not a new hole — before the "="
  anchoring (Task 6), the same call used to actually KILL the neighbour
  (loud, at least visible); anchoring `mux_kill` alone turned that into a
  silent partial corruption instead. Fixed by gating the six set-option
  calls on an anchored `mux_has "$sess"` check at the top of
  `teardown_session` (`lib/session.sh`): only once that confirms an
  EXACT session exists does the function resolve its canonical name
  (`mux_session_name`) and touch its options; a bare prefix with no exact
  match now leaves the block untouched entirely. Closing `stop`/`gc`
  themselves against acting on a prefix at all (rather than just this one
  function's internal consistency) is deferred to
  `docs/plans/2026-08-02-desambiguisation-argument-session.md`.
- **`gc` now refuses to destroy its own session; `stop` refuses outright
  (exit 8).** (Task 1, lot 2.) `gc_should_kill` (`lib/gc.sh`) itself stays
  a pure idle/attached check — the own-session guard lives in `cmd_gc`
  instead: a probe before the loop (`session_is_own` on a name that can
  never exist) refuses the WHOLE sweep, printing a note and destroying
  nothing, when identity is indeterminable (`$TMUX` set, `$TMUX_PANE`
  unset); inside the loop, any candidate that IS the caller's own session
  is skipped — counted `kept`, the sweep continues on the others (unlike
  `stop`, this is a skip, not an error). `--dry-run` still lists normally
  regardless (it never destroys anything, so the indeterminate-identity
  probe is skipped for it). Measured before this guard existed: running
  `gc --idle=0` from inside a detached `cockpit-*` session killed that
  session out from under itself — conditions to self-kill were the calling
  session named `cockpit-*`, detached (no attached tmux client), and idle
  for at least the threshold (default 86400s, override with `--idle=`);
  `gc` runs automatically, best-effort, in the background on every `spawn`
  and every `start`, so this could fire without the caller ever running
  `gc` by hand. `stop <session>` (`wsh-live.sh`) got its own, stricter
  guard on the same `session_is_own`/`session_own_refusal`/
  `session_indeterminate_refusal` helpers (`lib/session.sh`) already used
  by `start --reuse`: unlike `gc`'s skip-and-continue, a `stop` on the
  caller's own session refuses outright (exit 8, same family as `start
  --reuse`'s own-session refusal) — there is no "continue on the rest",
  `stop` only ever targets the one session it was given. The remaining
  ergonomic gap (how a caller should DISAMBIGUATE which session they meant
  in the first place, rather than just being refused) is tracked in
  `docs/plans/2026-08-02-desambiguisation-argument-session.md` §3 bis.
- **`selftest-guard` creates sessions on the DEFAULT tmux server, some of
  them GROUPED onto the caller's own live session.** Case 10 (grouped
  session sharing the caller's pane) runs `tmux new-session -t "=$own"`
  against whatever real tmux session is currently running the selftest
  itself — not an isolated `-L` socket. It cleans up after itself
  (`tmux kill-session` on its own throwaway names, plus the EXIT trap), but
  it is operating directly on the tmux server that also holds the user's
  real Wave-wrapped sessions for the duration of the run. Never invoke it
  from inside a session you cannot afford to see momentarily grouped, and
  never edit it without re-reading the cleanup trap.
  A session literally named `=foo` is not addressable through this code: the
  `${1#=}` strip in `mux_has`/`mux_kill`/`mux_clients` treats a leading `=`
  as the anchor marker, not as part of the name. Unreachable via generated
  names (`cockpit-<prefix>-<ts>`, `[a-z0-9-]`), but reachable via a
  free-form name passed to `start`.
- **Anchoring turned an implicit "current session" target into a safe
  no-op.** Measured: `tmux has-session -t ""` → rc=0, resolving to whatever
  session is CURRENT on the server; `tmux has-session -t "="` → rc=1 ("no
  mouse target" — sic). So before this lot's `=` anchoring, `mux_has ""` was
  true and `mux_kill ""` targeted a real, implicit session — the server's
  current one. After anchoring, the same empty argument is a safe no-op.
  Unreachable today (`teardown_session` only ever receives canonical names,
  `resolve_session` falls back to `SESS_DEFAULT` rather than passing an
  empty string through) — but it is exactly the failure mode this lot exists
  to close.
- **A cockpit left mid-`ssh`/`tailscale ssh` still doesn't look reusable to
  ORDINARY `spawn`.** Once hopped, the pane's foreground isn't a bare shell
  anymore, so `session_safe_to_reuse` refuses it (registry step 1 and the
  legacy scan step 3 both rely on it) and `spawn` opens a fresh session — new
  FIDO2 auth and a second Wave block. Still not a bug: `pane_current_command`
  says nothing about what's running at the far end of the tunnel (a remote
  shell is reusable, a remote `claude` isn't), and that information isn't
  available locally without a probe. The wrapper/adoption lot (fiches 1.2-1.9)
  DID add a relaxed check — `adopt_state_allowed` accepts a bare shell OR an
  `ssh`/`tailscale`/`mosh` foreground, gated by the mandatory situate probe
  (`adopt_run_probe`) — but **only** for step 2 of `spawn`'s resolution, i.e.
  a session explicitly listed in `WSH_COCKPIT_ADOPT` (see
  `docs/session-lifecycle.md` → "Opening a cockpit"). It is deliberately NOT
  applied to my own last-remembered session or to the legacy scan — silently
  reusing a session *I myself* left mid-hop carries the same "your probe
  becomes a chat message" risk as the incident described above, and the
  explicit `WSH_COCKPIT_ADOPT` list is the only place that risk is judged
  worth taking (the sessions there were pre-opened *for* this purpose).
  Workaround unchanged for anything outside `WSH_COCKPIT_ADOPT`: reuse the
  existing session explicitly (`SESSION=…`) instead of calling `spawn` again.
- **The adoption probe never trusts a session's remembered remote-mode
  state — it re-frames itself inline every time.** A `keep` session can be
  released, picked up by a completely different agent, ssh-hopped again to a
  different host, released again… any number of times before the next
  adoption — its sticky `@wsh_remote_mode`/helper-path tmux options reflect
  whatever the PREVIOUS occupant last set, not necessarily reality for the
  agent adopting it now. `adopt_run_probe` (`lib/session.sh`) forces
  `WSH_LIVE_SEP_REINIT=1` on its own `send`/`wait-done`/`read` calls
  regardless of what the session's options claim — self-contained inline
  framing, never the pushed-helper form — so the probe itself can never be
  the thing that silently breaks because a stale remote-mode flag pointed it
  at a helper file that no longer exists on that host. This is deliberately
  probe-only: once the probe succeeds and you know where you actually are,
  a normal `remote-init "$SESS" <host>` (or `local-init`) still applies if
  you want the short-form framing for the rest of the workflow.
- **A command typed but not yet submitted is invisible to the adoption
  guard's process check — the last captured pane line is the only signal
  that catches it, and it only recognizes the machine's actual prompt
  shapes.** `mux_pane_command` (`lib/mux.sh`) reports the pane's FOREGROUND
  process; while a human or a prior agent is mid-keystroke on a command
  (no Enter pressed yet), that process is still the bare shell, so
  `adopt_state_allowed` alone would call the pane adoptable and the
  probe's own `send` would land its text on top of the unsubmitted
  input, merging into a garbled command. Measured on this machine's real
  prompt (disposable tmux session, zsh + powerlevel10k-style theme with a
  right-side RPROMPT segment): the rendered last line pads out to the pane
  width and appends `─`+a corner glyph (`╮`/`╯`) flush right REGARDLESS of
  whether text was typed — a naive "anything after the prompt glyph"
  check would refuse every adoption. `adopt_last_line_busy`
  (`lib/session.sh`) strips that decoration if present, then recognizes
  exactly two shapes: bare `❯` (idle, adoptable) vs `❯ <text>` (busy,
  refused). Anything else — a different prompt theme (classic `$`/`%`/`#`,
  non-p10k themes), an empty capture, unrelated scrollback — is
  UNCLASSIFIED and is treated as adoptable: a false positive here would
  make a healthy cockpit unadoptable, which is worse than the accepted
  best-effort gap. `mux_pane_last_line` captures with `-J` (joins
  tmux-wrapped physical rows back into one logical line) specifically
  because the padded RPROMPT row can exceed `#{pane_width}` without tmux
  ever setting the wrap flag — `-J` re-joins it either way, so the
  predicate always sees the true tail of the logical line. Net effect:
  this mitigation only protects sessions using a prompt shape it
  recognizes; a custom or unrecognized prompt with text typed but not
  submitted can still slip through unrefused.
- **The live Wave state DB and its on-disk fallback path can disagree by
  days.** Two different resolvers exist in `lib/wave.sh`: `wave_db_ro()`
  (used by tab-cache resolution, `open`'s auto-open path) falls back to the
  hardcoded `~/Library/Application Support/waveterm` when `wsh wavepath data`
  fails or is empty; `wave_db_ro_strict()` (used only by `open --tab`'s
  `resolve_tab_by_name`) refuses outright (rc=1) instead of ever touching
  that hardcoded path. This isn't cosmetic: measured in step-1.1, the
  hardcoded fallback pointed at a DB snapshot **9 days stale** relative to
  the live one `wsh wavepath data` resolves dynamically — a `--tab` lookup
  silently falling back to it could match (or miss) a tab that was
  renamed/closed/created days ago. If you're adding a NEW caller that needs
  the live DB and correctness matters more than best-effort availability,
  reach for `wave_db_ro_strict()`, not `wave_db_ro()`.
- **Never `start cockpit` blindly.** Another agent may already own that tmux
  session. Use `spawn` to open/continue your cockpit; it reuses an alive session
  automatically. Only `spawn --force` creates a duplicate window.
- **Never call `spawn` again mid-workflow to "reconnect".** If the cockpit tab is
  still open, run `send`/`read` (or `current` / `status`) against the existing
  `SESSION=`. Calling `spawn` without `--force` **usually** reuses it — but this
  is no longer an unconditional guarantee since the registry/adoption lot
  (fiches 1.2-1.9, `docs/session-lifecycle.md` → "Opening a cockpit", steps
  1-4): a `spawn` with an explicit **prefix that doesn't match** anything in
  my registry, `WSH_COCKPIT_ADOPT`, or the legacy scan **creates a fresh
  cockpit instead** — a mismatched prefix mid-workflow is a second tab the
  user did not ask for, exactly like `--force`, just spelled differently.
  Calling it with `--force` always opens a second tab regardless of prefix.
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
  - **Ce one-shot est pour un diagnostic ponctuel, pas pour travailler.** Pour du
    travail réel sur un hôte, ouvre une session SSH persistante (une seule fois)
    au lieu d'enchaîner des one-shots — voir SKILL.md "Travailler sur un hôte
    distant". `send` avertit sur stderr (jamais bloquant) à partir du 2e one-shot
    SSH consécutif.
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
  Add `--print` to also emit the result — bounded by the `┌─[#N]`/`└─[#N]` markers,
  no line count to guess — in that same call instead of a separate `read`/`output`;
  see `docs/framing-and-transfer.md` → "Lire un résultat sans deviner".
