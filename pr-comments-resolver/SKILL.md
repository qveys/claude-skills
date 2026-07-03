---
name: pr-comments-resolver
description: >
  Automatically resolves GitHub pull-request review comments end-to-end:
  fetches all threads, classifies each comment as actionable or not, generates
  targeted code patches, commits them to the PR branch, and updates each thread
  with a resolution reply. Use this skill whenever a user asks to "resolve PR
  comments", "address review feedback", "process review threads", "fix PR
  comments automatically", or provides a GitHub PR URL/number and wants the
  review loop handled programmatically. Also trigger when the user says things
  like "traiter les commentaires de review", "résoudre les threads de la PR",
  or any similar phrase in any language.
---

# PR Comments Resolver

Automates the full GitHub PR review response cycle:
**fetch → classify → patch → commit → reply → resolve**.

---

## Prerequisites

| Requirement | Details |
|---|---|
| `GITHUB_TOKEN` | Classic PAT or fine-grained token. Required scopes: `repo`, `pull_requests:write`, `contents:write` |
| Python 3.9+ | `pip install requests` |
| `git` | Available in `PATH`, configured to push over HTTPS |

---

## Tool invocation

All operations use a single script:

```bash
python scripts/pr_tool.py '<json_input>'
```

The script prints a JSON result to stdout. Always parse stdout as JSON.

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
| `body` | string | Comment text |
| `inReplyToId` | int\|null | `null` = root comment of a thread |
| `user` | string | Reviewer login |
| `diffHunk` | string | Surrounding diff context for locating the code |

---

### Operation: `apply_patch`

**Input:**
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

`authorName` / `authorEmail` are **optional**; when omitted the commit inherits the
ambient git identity (global `~/.gitconfig`). They exist so the SSH signature is
attributed to the right author.

**Signing (enforced):** commits are **always signed** (`git commit -S`). The signing
key, format, and signer program are inherited from your ambient git config — nothing
is hardcoded. If signing fails (e.g. 1Password locked), the operation **aborts and
never pushes an unsigned commit**; it returns an `error` asking you to unlock the key
and retry. A push is also refused if `HEAD` ends up without a signature.

**Output (success):** `{ "commitSha": "abc123..." }`  
**Output (failure):** `{ "error": "git apply failed: ..." }` — or a signing error as described above.

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

**Output:** `{ "ok": true }`

---

## Workflow

### Step 1 – Receive context

Minimum required: `owner`, `repo`, `prNumber`.

### Step 2 – Fetch all comments

```bash
python scripts/pr_tool.py '{"kind":"list_pr_comments","owner":"...","repo":"...","prNumber":N}'
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

```bash
python scripts/pr_tool.py '{"kind":"apply_patch", ...}'
```

Store the returned `commitSha`, associated with the relevant `commentId`(s).

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

```bash
python scripts/pr_tool.py '{"kind":"update_threads", ...}'
```

Pass all updates in a single call. The script posts a reply in each thread and resolves threads via GitHub GraphQL when `resolved = true` and `threadId` is present.

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
