---
name: pr-comments-resolver
description: >
  Use when the user asks to resolve or address GitHub pull-request review
  comments/threads, provides a PR URL or number and wants review feedback
  handled, or says "resolve PR comments", "address review feedback",
  "traiter les commentaires de review", "résoudre les threads de la PR", or
  similar in any language.
---

# PR Comments Resolver

Automates the full GitHub PR review response cycle:
**fetch → classify → patch → commit → reply → resolve**.

---

## Prerequisites

| Requirement | Details |
|---|---|
| `GITHUB_TOKEN` | Optional as an env var — if unset, the script falls back automatically to `gh auth token`. Classic PAT: `repo` scope. Fine-grained token: `Contents: write` and `Pull requests: write` permissions. |
| Python 3.9+ | Standard library only — no `pip install` needed (`urllib`, `subprocess`, `json`, `tempfile`). |
| `git` | Available in `PATH`, configured to push over HTTPS |

---

## Tool invocation

All operations use a single script. Invoke it with an **absolute path** — the
working directory is typically the PR's repo checkout, not this skill's folder:

```bash
python3 ~/.claude/skills/pr-comments-resolver/scripts/pr_tool.py '<json_input>'
```

The script prints a JSON result to stdout. Always parse stdout as JSON.
On any error the script prints `{"error": "..."}` **and** exits with status
code 1 — check both, do not rely on stdout parsing alone.

---

### Operation: `list_pr_comments`

**Input:**
```json
{
  "kind": "list_pr_comments",
  "owner": "qveys",
  "repo": "my-supervision",
  "prNumber": 4
}
```

**Output:** `{ "comments": [ ...comment objects... ] }`

Each comment object:

| Field | Type | Notes |
|---|---|---|
| `id` | int | REST ID — use for `in_reply_to` when posting replies |
| `threadId` | string | GraphQL node ID — use for resolving threads |
| `isResolved` | bool | Skip if `true` |
| `path` | string | File path relative to repo root |
| `line` | int | Line number in the file |
| `position` | int\|null | Diff position; `null` when the comment falls outside the current diff (outdated) |
| `body` | string | Comment text |
| `inReplyToId` | int\|null | `null` = root comment of a thread |
| `user` | string | Reviewer login |
| `createdAt` | string | ISO 8601 timestamp |
| `diffHunk` | string | Surrounding diff context for locating the code |

Thread pagination is exhaustive: the script follows `hasNextPage` across the
GraphQL `reviewThreads` connection until all pages are fetched, so PRs with
more than 100 threads are still fully covered.

---

### Operation: `apply_patch`

**Input – legacy single-patch (still supported):**
```json
{
  "kind": "apply_patch",
  "owner": "qveys",
  "repo": "my-supervision",
  "prNumber": 4,
  "patch": "diff --git a/src/foo.py b/src/foo.py\n--- a/src/foo.py\n+++ b/src/foo.py\n@@ -10,7 +10,7 @@\n ...",
  "commitMessage": "fix: address review comment #<id> – <short description>",
  "authorName": "Quentin Veys",
  "authorEmail": "contact@quentinveys.be"
}
```
**Output:** `{ "commitSha": "abc123..." }`

**Input – batch mode (multiple fixes, one push):**
```json
{
  "kind": "apply_patch",
  "owner": "qveys",
  "repo": "my-supervision",
  "prNumber": 4,
  "commits": [
    { "patch": "diff --git a/src/foo.py ...", "commitMessage": "fix: address review comment #1" },
    { "patch": "diff --git a/src/bar.py ...", "commitMessage": "fix: address review comment #2" }
  ]
}
```
One clone (or one local checkout, see below), N signed commits applied in order, one push at
the end — so N review-comment fixes cost one clone + one push instead of N.
**Output:** `{ "commitShas": ["abc123...", "def456..."] }`

`authorName` / `authorEmail` are **optional** (top-level, apply to every commit in the
batch); when omitted the commit inherits the ambient git identity (global
`~/.gitconfig`). They exist so the SSH signature is attributed to the right author.

**`localRepoPath` (optional, opt-in):**
```json
{ "localRepoPath": "/abs/path/to/existing/checkout" }
```
Reuses an already-checked-out working copy instead of cloning. Preconditions are
checked up front, each with its own clear error: the path must be a git repo, its
**current branch must equal the PR's head branch**, and its **working tree must be
clean**. The user's git config is never touched — an `authorName`/`authorEmail`
override, if given, is passed per commit via `git -c user.name=... -c user.email=...
commit ...` instead of `git config`. Pushes go through the existing `origin` remote
(no token URL).

**`dryRun` (optional):**
```json
{ "dryRun": true }
```
Runs the full flow (clone or local checks, patch application, signed commits) but
never pushes. **Output:** `{ "dryRun": true, "wouldPush": [ { "commitMessage": "...",
"diffStat": "...", "signed": <bool> }, ... ] }`. In local-repo mode, the branch is hard-reset
back to its pre-dry-run HEAD before returning, so the checkout never ends up carrying
unpushed commits. In a dry run a signing failure does not abort the operation — it
retries the commit unsigned and reports `signed: false`, since the point of a dry run
is to diagnose before the real pass.

**Signing (enforced on real runs):** commits are **always signed** (`git commit -S`).
The signing key, format, and signer program are inherited from your ambient git
config — nothing is hardcoded. If signing fails, the operation **aborts and never
pushes an unsigned commit**; it returns an `error` asking you to unlock the key and
retry. A push is also refused if `HEAD` ends up without a signature. Two common
causes: (1) the signing key is locked (e.g. 1Password) — unlock it and retry; (2) the
shell is sandboxed and blocks the signer (`op-ssh-sign`) — rerun outside the sandbox
(e.g. Claude Code Bash with `dangerouslyDisableSandbox`).

**Output (failure):** `{ "error": "git apply failed: ..." }` — or a signing error as
described above. In batch mode, a failure on commit *k* names the offending commit
(e.g. `commit 2/3 ("fix: ...") failed: ...`) and nothing is pushed.

---

### Operation: `update_threads`

**Input:**
```json
{
  "kind": "update_threads",
  "owner": "qveys",
  "repo": "my-supervision",
  "prNumber": 4,
  "updates": [
    {
      "commentId": 123456,
      "threadId": "PRRT_kwDOABC123",
      "resolved": true,
      "resolvingCommitSha": "abc123",
      "message": "Fixed in abc123 – renamed variable to `userCount`."
    }
  ]
}
```

**Output:**
```json
{
  "ok": true,
  "results": [
    { "commentId": 123456, "ok": true },
    { "commentId": 789012, "ok": false, "step": "reply", "error": "..." }
  ]
}
```
`ok` at the top level is `true` only if every update succeeded. Each update is
processed independently — a failure on one (posting the reply, or resolving the
thread; see `step`) does not interrupt the loop, so the remaining updates still get
applied and reported.

**`dryRun` (optional):**
```json
{ "dryRun": true }
```
Makes **no network call at all** — no reply posted, no thread resolved. **Output:**
`{ "dryRun": true, "wouldPost": [ { "commentId": 123456, "message": "...",
"wouldResolve": <bool> }, ... ] }`.

---

## Workflow

### Step 1 – Receive context

Minimum required: `owner`, `repo`, `prNumber`.

### Step 2 – Fetch all comments

```bash
python3 ~/.claude/skills/pr-comments-resolver/scripts/pr_tool.py '{"kind":"list_pr_comments","owner":"...","repo":"...","prNumber":N}'
```

- Filter out comments where `isResolved = true`.
- Focus analysis on **root comments** (`inReplyToId = null`). Reply comments provide context but do not require individual action.

### Step 3 – Classify each root comment

**→ Relevant** (generate a patch):
- Explicit request: rename, refactor, extract, delete, add something
- Bug, security vulnerability, performance issue, correctness problem
- Missing test, missing documentation, missing configuration
- Inconsistency with the rest of the codebase

**→ Not relevant** (no code change needed):
- Praise or acknowledgement ("LGTM", "nice")
- Stylistic preference without an agreed-upon standard in the project
- Question already answered by the existing code
- Obsolete comment (the file or line no longer exists in the PR diff)

### Step 4 – Generate patches

For each relevant comment:

1. Use `diffHunk` + `path` + `line` to locate the exact section.
2. Determine the **minimal change** that fully satisfies the request.
3. Build a **unified diff**:

```diff
diff --git a/path/to/file.ext b/path/to/file.ext
--- a/path/to/file.ext
+++ b/path/to/file.ext
@@ -10,7 +10,7 @@
 context line
 context line
-old line to remove
+new line to add
 context line
 context line
```

**Patch rules:**
- 3 lines of context around each hunk.
- Paths must be relative to repo root, no leading `/`.
- If multiple comments touch the same file, merge into one patch with multiple `@@` hunks.
- Never change behaviour beyond what the comment explicitly requests.
- Preserve existing naming, formatting, and patterns.
- When in doubt about intent: **do not patch**. Mark unresolved and ask.

### Step 5 – Apply patches

Group logically related comments into a single commit where appropriate (e.g., two nits in the same function). Keep unrelated changes in separate commits.

If the PR is sensitive (production branch, many reviewers) or the patch set is large,
run with `"dryRun": true` first and inspect `wouldPush` before committing to a real
run.

```bash
python3 ~/.claude/skills/pr-comments-resolver/scripts/pr_tool.py '{"kind":"apply_patch", ...}'
```

Store the returned `commitSha` (or `commitShas` for a batch), associated with the relevant `commentId`(s).

On error: do **not** mark the comment resolved; report the error in the thread.

### Step 6 – Determine resolution status

| Situation | `resolved` |
|---|---|
| Patch applied, request fully addressed | `true` |
| Partial fix or ambiguous request | `false` |
| Not relevant (praise, obsolete, etc.) | `true` (or skip) |
| Patch application failed | `false` |

### Step 7 – Build the `updates` list

One entry per root comment. Always include `threadId` (required for GitHub to mark the thread as resolved).

**resolved = true:**
```
Fixed in `<short-sha>` – <one-line explanation of the change>.
```

**resolved = false – ambiguous:**
```
Not resolved: the request is unclear. Could you clarify whether you want X or Y?
```

**resolved = false – patch error:**
```
Not resolved: failed to apply the patch (`<error summary>`). Please review manually.
```

**Not relevant:**
```
No code change needed here. Thanks for the feedback!
```

### Step 8 – Update threads

For a sensitive PR, consider a `"dryRun": true` pass first and review `wouldPost`
before posting for real.

```bash
python3 ~/.claude/skills/pr-comments-resolver/scripts/pr_tool.py '{"kind":"update_threads", ...}'
```

Pass all updates in a single call. The script posts a reply in each thread and resolves threads via GitHub GraphQL when `resolved = true` and `threadId` is present. Check `results` for per-update failures — a single failure does not block the others.

---

## Language detection

1. Count comment bodies that are clearly English vs. clearly French (or other language).
2. **Default to English** when uncertain or when counts are equal.
3. Write all thread replies in the detected language.

---

## Message templates

### English

| Status | Template |
|---|---|
| Resolved | `Fixed in \`<sha>\` – <brief explanation>.` |
| Unresolved – ambiguous | `Not resolved: unclear request. Could you clarify whether you mean X or Y?` |
| Unresolved – patch error | `Not resolved: \`git apply\` failed (\`<error>\`). Please review the diff manually.` |
| Not relevant | `No code change needed here. Thanks for the feedback!` |

### French

| Statut | Modèle |
|---|---|
| Résolu | `Corrigé dans \`<sha>\` – <explication courte>.` |
| Non résolu – ambigu | `Non résolu : la demande est ambiguë. Pourriez-vous préciser si vous voulez X ou Y ?` |
| Non résolu – patch échoué | `Non résolu : \`git apply\` a échoué (\`<erreur>\`). Merci de vérifier le diff manuellement.` |
| Non pertinent | `Aucun changement de code nécessaire ici. Merci pour le retour !` |

---

## Safety rules

- Never modify files outside the PR's existing diff scope unless a comment explicitly requests it.
- Never alter public API signatures without an explicit reviewer request.
- Never push force-push or rebase — only `git push origin <branch>`.
- Prefer several small, focused commits over one large patch.
- If genuinely unsure: `resolved = false`, post a clarification request.
