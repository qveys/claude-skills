# Lot 1 — Réintroduction de la garde `own_tmux_session` (wsh-cockpit)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** Réintroduire sur `main` la garde « ne jamais réutiliser la session tmux qui héberge le CLI appelant » (`own_tmux_session` / `session_safe_to_reuse`), perdue par la régression silencieuse `9863c07`, avec un selftest dédié.

**Architecture :** Réimplémentation ciblée du hunk `session.sh` de `a920197` (vérifié ré-applicable — `git apply --check` OK) + le hunk `start --reuse` de `wsh-live.sh`, précédés d'un selftest `selftest-guard` écrit en premier (TDD). `mux_pane_command` (mux.sh:93) a survécu à la régression : rien à faire côté mux. La doc du gotcha (perdue avec le hunk SKILL.md de `a920197`) renaît dans `docs/gotchas.md`, son emplacement actuel.

**Tech stack :** Bash 3.2 (macOS), tmux, harnais de selftests maison (`scripts/lib/selftests.sh`, rc 0/1).

**Contexte spec :** `docs/superpowers/specs/2026-07-27-claude-cockpit-wrapper-design.md` §2 (garde-fou) et §7 lot 1. Ce lot est un prérequis autonome du lot 2 (adoption) — **rien d'autre ne bouge**.

## Global Constraints

- Repo : `/Users/qveys/.claude/skills` (branche `main`). Tous les chemins ci-dessous sont relatifs à cette racine.
- Bash 3.2 : **aucune expansion bash-4** (`${x,,}` interdit — le codebase utilise `tr`), le script tourne sous `set -euo pipefail` (wsh-live.sh:156) → toute capture de rc passe par `set +e` / `set -e`.
- Commits **signés** : `git commit -S`. **JAMAIS** de `Co-Authored-By`/attribution IA. **JAMAIS** de `git push`.
- Le message du commit principal DOIT nommer la régression `9863c07` et le nettoyage résiduel `e7d09a6` (exigence de la spec §7).
- Commentaires de code en anglais (style du codebase) ; sorties utilisateur des selftests dans le style existant (`ok N label` / `FAIL N label`).
- Ne toucher à AUCUN autre fichier que : `wsh-cockpit/scripts/lib/selftests.sh`, `wsh-cockpit/scripts/wsh-live.sh`, `wsh-cockpit/scripts/lib/session.sh`, `wsh-cockpit/docs/gotchas.md`.
- Vérification syntaxique systématique avant chaque commit : `bash -n <fichier modifié>` (+ `shellcheck` si disponible, non bloquant).

---

### Task 1 : Garde dans `session.sh` + selftest `selftest-guard`

**Files:**
- Modify: `wsh-cockpit/scripts/lib/selftests.sh` (append en fin de fichier, après `cmd_selftest_output`, ligne 839)
- Modify: `wsh-cockpit/scripts/wsh-live.sh:115-118` (bloc usage, après la description de `selftest-transfer`) et `wsh-cockpit/scripts/wsh-live.sh:860-862` (dispatcher, après le case `selftest-transfer`)
- Modify: `wsh-cockpit/scripts/lib/session.sh:72-89` (insertion des deux fonctions avant `find_reusable_session`, + 2 lignes modifiées dedans)

**Interfaces:**
- Consumes : `mux_pane_command <sess>` (mux.sh:93, existant — rend le nom du process au premier plan, vide si zellij/indisponible) ; `MUX`, `STATE_DIR` (wsh-live.sh:159), `SCRIPT_DIR` (wsh-live.sh:176) ; `last_session`/`newest_session_for_prefix`/`normalize_prefix` (session.sh, existants).
- Produces : `own_tmux_session()` — imprime le nom de la session tmux hébergeant le processus appelant, rc 1 hors tmux ; `session_safe_to_reuse <sess>` — rc 0 si réutilisable en silence, rc 1 + warning stderr sinon. **Le lot 2 étendra `session_safe_to_reuse` (états `ssh`/`tailscale`/`mosh` adoptables) — ces signatures sont un contrat.**

- [ ] **Step 1 : Écrire le selftest (échec attendu)**

Ajouter à la FIN de `wsh-cockpit/scripts/lib/selftests.sh` :

```bash

cmd_selftest_guard() {
  have_mux
  if [ "$MUX" != tmux ]; then
    echo "selftest-guard: skip (tmux-only — the guard rests on tmux display-message)"
    return 0
  fi
  # NOT local: cleanup runs from the EXIT trap after this function returned
  # (same rationale as cmd_selftest_gc's SESS).
  GUARD_BUSY="cockpit-selftest-guard-busy-$$"
  GUARD_IDLE="cockpit-selftest-guard-idle-$$"
  GUARD_KEY="selftest-guard-$$"
  local rc failures=0 own cmd tries found

  report_guard_case() {  # $1 label  $2 rc (0=ok)  $3 detail (shown on failure)
    if [ "$2" -eq 0 ]; then
      echo "ok $1"
    else
      echo "FAIL $1${3:+: $3}" >&2
      failures=$((failures + 1))
    fi
  }

  selftest_guard_cleanup() {
    tmux kill-session -t "$GUARD_BUSY" 2>/dev/null || true
    tmux kill-session -t "$GUARD_IDLE" 2>/dev/null || true
    rm -f "$STATE_DIR/last-session-$GUARD_KEY" 2>/dev/null || true
  }
  trap selftest_guard_cleanup EXIT

  # 1. outside tmux, own_tmux_session must fail cleanly (rc != 0).
  set +e
  ( unset TMUX; own_tmux_session >/dev/null 2>&1 )
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then report_guard_case "1 own_tmux_session outside tmux -> rc!=0" 0
  else report_guard_case "1 own_tmux_session outside tmux -> rc!=0" 1 "rc=0 without TMUX"; fi

  # 2+3. only meaningful when THIS test itself runs inside tmux.
  if [ -n "${TMUX:-}" ]; then
    set +e; own=$(own_tmux_session); rc=$?; set -e
    if [ "$rc" -eq 0 ] && [ -n "$own" ]; then report_guard_case "2 own_tmux_session names current session" 0
    else report_guard_case "2 own_tmux_session names current session" 1 "rc=$rc own='$own'"; fi
    set +e; session_safe_to_reuse "$own" 2>/dev/null; rc=$?; set -e
    if [ "$rc" -ne 0 ]; then report_guard_case "3 own session refused" 0
    else report_guard_case "3 own session refused" 1 "rc=0 on '$own'"; fi
  else
    echo "note: cases 2-3 skipped (not inside tmux)"
  fi

  # 4. a session whose foreground is NOT a bare shell is refused.
  tmux new-session -d -s "$GUARD_BUSY" 'exec top'
  tries=0; cmd=""
  while [ "$tries" -lt 20 ]; do
    cmd=$(mux_pane_command "$GUARD_BUSY")
    [ "$cmd" = top ] && break
    tries=$((tries + 1)); sleep 0.2
  done
  set +e; session_safe_to_reuse "$GUARD_BUSY" 2>/dev/null; rc=$?; set -e
  if [ "$rc" -ne 0 ]; then report_guard_case "4 non-shell foreground refused" 0
  else report_guard_case "4 non-shell foreground refused" 1 "rc=0 (cmd='$cmd')"; fi

  # 5. a bare-shell session is accepted.
  tmux new-session -d -s "$GUARD_IDLE"
  set +e; session_safe_to_reuse "$GUARD_IDLE" 2>/dev/null; rc=$?; set -e
  if [ "$rc" -eq 0 ]; then report_guard_case "5 bare shell accepted" 0
  else report_guard_case "5 bare shell accepted" 1 "rc=$rc"; fi

  # 6. empty pane_current_command (zellij / transient) = unverifiable-but-SAFE.
  set +e
  ( mux_pane_command() { printf ''; }; session_safe_to_reuse "$GUARD_IDLE" 2>/dev/null )
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then report_guard_case "6 empty pane command treated safe" 0
  else report_guard_case "6 empty pane command treated safe" 1 "rc=$rc"; fi

  # 7. find_reusable_session must NOT hand back a remembered-but-unsafe session.
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$GUARD_BUSY" > "$STATE_DIR/last-session-$GUARD_KEY"
  set +e
  found=$( WSH_COCKPIT_AGENT="$GUARD_KEY"; export WSH_COCKPIT_AGENT
           find_reusable_session "selftest-guard-none" 2>/dev/null )
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && [ -z "$found" ]; then report_guard_case "7 unsafe remembered session not reused" 0
  else report_guard_case "7 unsafe remembered session not reused" 1 "rc=$rc found='$found'"; fi

  selftest_guard_cleanup
  trap - EXIT
  if [ "$failures" -eq 0 ]; then echo "selftest-guard: all cases passed"; return 0
  else echo "selftest-guard: $failures failure(s)" >&2; return 1; fi
}
```

Note : le `$( VAR=…; export VAR; fonction )` du cas 7 est un sous-shell — l'export ne fuit pas dans le selftest.

- [ ] **Step 2 : Brancher usage + dispatcher**

Dans `wsh-cockpit/scripts/wsh-live.sh`, après le bloc usage de `selftest-transfer` (il se termine vers la ligne 118 par la parenthèse du « skipped with a note ») , ajouter :

```
#   selftest-guard             own_tmux_session/session_safe_to_reuse cases: own session
#                              refused, non-shell foreground refused, bare shell ok, empty
#                              pane_current_command safe, find_reusable_session never hands
#                              back an unsafe remembered session, start --reuse exit 8;
#                              tmux-only; rc 0/1
```

Dans le dispatcher, après le case `selftest-transfer)` (lignes 860-862) :

```bash
selftest-guard)
  cmd_selftest_guard
  ;;
```

- [ ] **Step 3 : Vérifier l'échec**

Run : `bash -n wsh-cockpit/scripts/lib/selftests.sh && bash -n wsh-cockpit/scripts/wsh-live.sh && wsh-cockpit/scripts/wsh-live.sh selftest-guard; echo "rc=$?"`

Attendu : **rc=1**, avec `FAIL` au moins sur les cas 5, 6 (`session_safe_to_reuse: command not found` → rc 127) et 7 (`find_reusable_session` rend `$GUARD_BUSY` sans vérification). Les cas 1 et 4 peuvent « passer » par accident (127 ≠ 0) — c'est attendu en phase rouge.

- [ ] **Step 4 : Implémenter la garde dans `session.sh`**

Dans `wsh-cockpit/scripts/lib/session.sh`, insérer ENTRE `newest_session_for_prefix()` (qui se termine ligne ~74) et le commentaire de `find_reusable_session` (ligne ~75) — réimplémentation fidèle du hunk de `a920197` (consultable via `git show a920197 -- wsh-cockpit/scripts/lib/session.sh`) :

```bash
# The tmux session CURRENTLY running the calling process itself, if any.
# `$TMUX` is set by tmux in every process spawned inside a pane — including
# the Bash tool call whose shell lives inside the Claude Code CLI's own
# wrapping tmux session (Wave wraps every terminal in tmux, one block = one
# session). `tmux display-message` asks the tmux server, not the pane
# content, so it's authoritative regardless of what's drawn on screen.
own_tmux_session() {
  [ "$MUX" = tmux ] || return 1
  [ -n "${TMUX:-}" ] || return 1
  tmux display-message -p '#S' 2>/dev/null
}

# A session is safe to silently reuse only if BOTH hold:
#   1. it is not the tmux session the caller is itself running inside
#      (absolute, unconditional block — see own_tmux_session);
#   2. its foreground process is a bare shell, not some other interactive
#      program left running in an otherwise-orphaned cockpit (most
#      dangerously another CLI: `send` would TYPE into its input).
# Empty pane_current_command (zellij: unsupported, or transient read
# failure) is treated unverifiable-but-safe, not unsafe.
# NOTE (spec claude-cockpit §2): lot 2 extends check 2 for ADOPTION with
# ssh/tailscale/mosh as adoptable states — reuse stays bare-shell strict.
session_safe_to_reuse() {
  local sess="$1" cmd own
  if own=$(own_tmux_session) && [ "$sess" = "$own" ]; then
    echo "⚠️  session '$sess' IS the tmux session this call is running inside (your own controlling terminal) — refusing to reuse it under any circumstance" >&2
    return 1
  fi
  cmd=$(mux_pane_command "$sess")
  case "$cmd" in
    ""|bash|zsh|sh|fish|-bash|-zsh|-sh|-fish) return 0 ;;
    *)
      echo "⚠️  session '$sess' has foreground process '$cmd', not a bare shell — refusing silent reuse (pass --force for a fresh cockpit, or 'read' it manually first)" >&2
      return 1 ;;
  esac
}
```

Puis modifier `find_reusable_session()` (les deux conditions, session.sh:80 et :84) :

```bash
# AVANT (ligne 80) :
  if remembered=$(last_session 2>/dev/null); then
# APRÈS :
  if remembered=$(last_session 2>/dev/null) && session_safe_to_reuse "$remembered"; then

# AVANT (ligne 84) :
  if newest=$(newest_session_for_prefix "$norm" 2>/dev/null); then
# APRÈS :
  if newest=$(newest_session_for_prefix "$norm" 2>/dev/null) && session_safe_to_reuse "$newest"; then
```

- [ ] **Step 5 : Vérifier le vert**

Run : `bash -n wsh-cockpit/scripts/lib/session.sh && wsh-cockpit/scripts/wsh-live.sh selftest-guard; echo "rc=$?"`

Attendu : **rc=0**, `ok` sur les cas 1, 4, 5, 6, 7 (+ 2, 3 si le shell de test tourne dans tmux — c'est le cas dans Wave ; sinon `note: cases 2-3 skipped`).

- [ ] **Step 6 : Non-régression des selftests voisins**

Run : `wsh-cockpit/scripts/wsh-live.sh selftest-gc && wsh-cockpit/scripts/wsh-live.sh selftest-oneshot-ssh; echo "rc=$?"`

Attendu : rc=0 (la garde ne change ni `gc_should_kill` ni le tracking one-shot ; `selftest-gc` exerce indirectement le voisinage de `find_reusable_session`).

- [ ] **Step 7 : Commit**

```bash
cd /Users/qveys/.claude/skills
git add wsh-cockpit/scripts/lib/session.sh wsh-cockpit/scripts/lib/selftests.sh wsh-cockpit/scripts/wsh-live.sh
git commit -S -m "fix(wsh-cockpit): reintroduce own-session reuse guard lost in 9863c07

own_tmux_session()/session_safe_to_reuse() were merged in a920197 (#7),
then silently removed from session.sh by 9863c07 (auto-close Wave block)
whose message never mentions the deletion; e7d09a6 later cleaned the
dangling call-site it had left in wsh-live.sh. gc.sh:25 kept referencing
the guard as if it existed. Reimplemented on the current base
(mux_pane_command survived in mux.sh) and wired back into
find_reusable_session, with a dedicated selftest-guard."
```

---

### Task 2 : Garde dans `start --reuse`

**Files:**
- Modify: `wsh-cockpit/scripts/lib/selftests.sh` (dans `cmd_selftest_guard`, insérer le cas 8 AVANT la ligne `selftest_guard_cleanup` finale)
- Modify: `wsh-cockpit/scripts/wsh-live.sh:513` (branche `--reuse` de `start`, juste avant `echo "session '$SESS' already exists — reusing it (--reuse)"`)

**Interfaces:**
- Consumes : `own_tmux_session()` (Task 1).
- Produces : `start <own-session> --reuse` → **exit 8** (code réservé par `a920197`, repris tel quel).

- [ ] **Step 1 : Étendre le selftest (cas 8)**

Dans `cmd_selftest_guard`, juste avant les lignes finales `selftest_guard_cleanup` / `trap - EXIT`, insérer :

```bash
  # 8. start --reuse on the caller's own session must refuse with exit 8.
  #    Confined under GUARD_KEY so the red phase can never pollute the real
  #    agent state (remember_session on the caller's own session is exactly
  #    the original incident).
  if [ -n "${TMUX:-}" ]; then
    own=$(tmux display-message -p '#S')
    set +e
    WSH_COCKPIT_AGENT="$GUARD_KEY" "$SCRIPT_DIR/wsh-live.sh" start "$own" --reuse >/dev/null 2>&1
    rc=$?
    set -e
    if [ "$rc" -eq 8 ]; then report_guard_case "8 start --reuse refuses own session (exit 8)" 0
    else report_guard_case "8 start --reuse refuses own session (exit 8)" 1 "rc=$rc (expected 8)"; fi
  else
    echo "note: case 8 skipped (not inside tmux)"
  fi
```

- [ ] **Step 2 : Vérifier l'échec**

Run : `wsh-cockpit/scripts/wsh-live.sh selftest-guard; echo "rc=$?"`

Attendu : **rc=1**, `FAIL 8 ... rc=0 (expected 8)` (le `start --reuse` actuel réutilise sans broncher). Hors tmux : cas 8 sauté → relancer depuis un pane tmux (Wave) pour la phase rouge/verte de cette tâche.

- [ ] **Step 3 : Implémenter le refus dans `start`**

Dans `wsh-cockpit/scripts/wsh-live.sh`, la branche `--reuse` de `start` (le `echo "session '$SESS' already exists — reusing it (--reuse)"` est ligne 513). Insérer juste AVANT ce `echo` (réimplémentation du hunk `a920197`, `own` est locale au bloc) :

```bash
        own=$(own_tmux_session 2>/dev/null) || own=""
        if [ -n "$own" ] && [ "$SESS" = "$own" ]; then
          echo "refusing: '$SESS' is the tmux session this call is running inside (your own controlling terminal) — pick a different name" >&2
          exit 8
        fi
```

(Respecter l'indentation du bloc environnant — le `echo` existant est indenté de 8 espaces.)

- [ ] **Step 4 : Vérifier le vert**

Run : `bash -n wsh-cockpit/scripts/wsh-live.sh && wsh-cockpit/scripts/wsh-live.sh selftest-guard; echo "rc=$?"`

Attendu : **rc=0**, `ok 8 start --reuse refuses own session (exit 8)`.

- [ ] **Step 5 : Commit**

```bash
cd /Users/qveys/.claude/skills
git add wsh-cockpit/scripts/lib/selftests.sh wsh-cockpit/scripts/wsh-live.sh
git commit -S -m "fix(wsh-cockpit): start --reuse refuses the caller's own tmux session (exit 8)

Second half of the a920197 guard lost in the 9863c07 regression: the
explicit-name path (start --reuse) bypassed find_reusable_session and
could still hand the caller its own controlling terminal."
```

---

### Task 3 : Documentation du gotcha

**Files:**
- Modify: `wsh-cockpit/docs/gotchas.md:7` (insérer AVANT le bullet `- **Never \`start cockpit\` blindly.**`)

**Interfaces:**
- Consumes : rien. Produces : rien (doc pure). Le commentaire `gc.sh:25` qui référence `own_tmux_session` redevient exact grâce aux Tasks 1-2 — aucune modification de `gc.sh`.

- [ ] **Step 1 : Insérer le gotcha**

Dans `wsh-cockpit/docs/gotchas.md`, insérer juste avant la ligne 7 (`- **Never \`start cockpit\` blindly.**`) — texte du hunk SKILL.md de `a920197`, adapté à son nouvel emplacement :

```markdown
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
  any reuse: (1) an unconditional block on the exact tmux session the caller
  is itself running inside (`$TMUX` + `tmux display-message -p '#S'`, via
  `own_tmux_session`) — this catches the incident above, since
  `pane_current_command` alone would report "bash" from inside the check
  itself; (2) a `pane_current_command` heuristic that rejects any OTHER
  session whose foreground isn't a bare shell. `start <name> --reuse` refuses
  the caller's own session with exit 8. History: guard introduced by
  `a920197` (#7), silently lost in the `9863c07` regression, reintroduced
  with `selftest-guard`.
```

- [ ] **Step 2 : Vérification et commit**

Run : `grep -n "own_tmux_session" wsh-cockpit/docs/gotchas.md wsh-cockpit/scripts/lib/gc.sh wsh-cockpit/scripts/lib/session.sh | head` — attendu : les trois fichiers matchent (le commentaire gc.sh:25 pointe de nouveau vers du code réel).

```bash
cd /Users/qveys/.claude/skills
git add wsh-cockpit/docs/gotchas.md
git commit -S -m "docs(wsh-cockpit): document the own-session reuse guard in gotchas.md

Restores the guard documentation from a920197 (originally in SKILL.md,
whose gotchas have since moved to docs/gotchas.md) and records the
9863c07 regression history."
```

---

## Post-plan

- Revue du code par un relecteur fable vierge (tradition du chantier) AVANT de considérer le lot 1 terminé.
- Le plan du **lot 2** (registre/claims, wrapper `claude-cockpit`, `release`, `open --tab`, hygiène gc, docs, `selftest-adopt`/`selftest-wrapper`) sera rédigé séparément après validation du lot 1 — il étend `session_safe_to_reuse` (états adoptables) et le case dispatcher créés ici.
