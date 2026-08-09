#!/usr/bin/env python3
"""
pr_tool.py – GitHub PR automation tool for pr-comments-resolver skill.

Usage:
    python scripts/pr_tool.py '<json_input>'

JSON input must include a "kind" field:
    - "list_pr_comments"  → fetch review comments + thread metadata
    - "apply_patch"       → apply a unified diff, commit, and push
    - "update_threads"    → post replies and resolve threads

See SKILL.md for full input/output schemas.

Requirements:
    export GITHUB_TOKEN=<your_token>  (or be logged in via `gh auth login`)
    git must be available in PATH
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


class GitHubAPIError(Exception):
    """Raised when a GitHub API request returns an HTTP error status."""

    def __init__(self, status: int, body: str) -> None:
        self.status = status
        self.body = body
        super().__init__(f"GitHub API error {status}: {body}")


def _resolve_github_token() -> str:
    """Resolve the GitHub token from the environment, falling back to `gh auth token`."""
    token = os.environ.get("GITHUB_TOKEN", "")
    if token:
        return token
    try:
        gh_r = subprocess.run(
            ["gh", "auth", "token"], capture_output=True, text=True
        )
    except (FileNotFoundError, OSError):
        return ""
    if gh_r.returncode == 0:
        return gh_r.stdout.strip()
    return ""


# ---------------------------------------------------------------------------
# Auth & constants
# ---------------------------------------------------------------------------

GITHUB_TOKEN: str = _resolve_github_token()
BASE: str = "https://api.github.com"
GQL_URL: str = f"{BASE}/graphql"

REST_HEADERS: dict[str, str] = {
    "Authorization": f"token {GITHUB_TOKEN}",
    "Accept": "application/vnd.github.v3+json",
    "X-GitHub-Api-Version": "2022-11-28",
}
GQL_HEADERS: dict[str, str] = {
    "Authorization": f"bearer {GITHUB_TOKEN}",
    "Content-Type": "application/json",
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _check_token() -> None:
    if not GITHUB_TOKEN:
        _exit_error(
            "No GitHub token available: set the GITHUB_TOKEN environment variable, "
            "or install and authenticate the gh CLI (`gh auth login`)."
        )


def _redact(text: str) -> str:
    """Replace any occurrence of GITHUB_TOKEN in `text` with `***` to avoid leaking it."""
    if GITHUB_TOKEN and GITHUB_TOKEN in text:
        return text.replace(GITHUB_TOKEN, "***")
    return text


def _exit_error(message: str) -> None:
    print(json.dumps({"error": message}, ensure_ascii=False))
    sys.exit(1)


def _http_get(url: str, params: dict | None = None) -> Any:
    """Perform a GET request against the GitHub REST API and return parsed JSON."""
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers=REST_HEADERS, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise GitHubAPIError(e.code, e.read().decode("utf-8")) from e


def _http_post(url: str, payload: dict, headers: dict) -> Any:
    """Perform a POST request with a JSON body and return parsed JSON."""
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise GitHubAPIError(e.code, e.read().decode("utf-8")) from e


def _paginate(url: str, params: dict | None = None) -> list[dict]:
    """Fetch all pages of a GitHub REST endpoint."""
    results: list[dict] = []
    page = 1
    while True:
        p = {**(params or {}), "per_page": 100, "page": page}
        data = _http_get(url, params=p)
        if not data:
            break
        results.extend(data)
        if len(data) < 100:
            break
        page += 1
    return results


def _gql(query: str, variables: dict) -> dict:
    """Execute a GitHub GraphQL query."""
    data = _http_post(
        GQL_URL,
        {"query": query, "variables": variables},
        GQL_HEADERS,
    )
    if "errors" in data:
        raise RuntimeError(f"GraphQL errors: {data['errors']}")
    return data["data"]


def _git(*args: str, cwd: str, check: bool = True) -> subprocess.CompletedProcess:
    result = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )
    if check and result.returncode != 0:
        message = f"git {' '.join(args)} failed (exit {result.returncode}):\n{result.stderr.strip()}"
        if result.stdout.strip():
            message += f"\n{result.stdout.strip()}"
        raise RuntimeError(_redact(message))
    return result


# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------

def list_pr_comments(inp: dict) -> dict:
    """
    Fetch all inline review comments for a PR, enriched with GraphQL thread metadata.
    Returns: { "comments": [...] }
    """
    owner = inp["owner"]
    repo = inp["repo"]
    pr_number = int(inp["prNumber"])

    # --- REST: inline review comments ---
    rest_comments = _paginate(
        f"{BASE}/repos/{owner}/{repo}/pulls/{pr_number}/comments"
    )

    # --- GraphQL: review threads (for threadId + isResolved) ---
    #
    # Threads are paginated 100 at a time; we follow `pageInfo.hasNextPage`
    # until exhausted, so PRs with any number of threads are covered.
    threads: list[dict] = []
    cursor: str | None = None
    while True:
        gql_data = _gql(
            """
            query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
              repository(owner: $owner, name: $repo) {
                pullRequest(number: $pr) {
                  reviewThreads(first: 100, after: $cursor) {
                    nodes {
                      id
                      isResolved
                      comments(first: 1) {
                        nodes { databaseId }
                      }
                    }
                    pageInfo {
                      hasNextPage
                      endCursor
                    }
                  }
                }
              }
            }
            """,
            {"owner": owner, "repo": repo, "pr": pr_number, "cursor": cursor},
        )

        review_threads = gql_data["repository"]["pullRequest"]["reviewThreads"]
        threads.extend(review_threads["nodes"])

        page_info = review_threads["pageInfo"]
        if not page_info["hasNextPage"]:
            break
        cursor = page_info["endCursor"]

    # Map: root comment REST id → { threadId, isResolved }
    thread_map: dict[int, dict] = {}
    for t in threads:
        nodes = t["comments"]["nodes"]
        if nodes:
            db_id: int = nodes[0]["databaseId"]
            thread_map[db_id] = {
                "threadId": t["id"],
                "isResolved": t["isResolved"],
            }

    # Build output
    comments_out: list[dict] = []
    for c in rest_comments:
        cid: int = c["id"]
        in_reply_to: int | None = c.get("in_reply_to_id")
        root_id: int = cid if in_reply_to is None else in_reply_to
        meta = thread_map.get(root_id, {})

        comments_out.append(
            {
                "id": cid,
                "threadId": meta.get("threadId"),
                "isResolved": meta.get("isResolved", False),
                "path": c.get("path", ""),
                "line": c.get("line") or c.get("original_line"),
                "position": c.get("position"),
                "body": c["body"],
                "inReplyToId": in_reply_to,
                "user": c["user"]["login"],
                "createdAt": c["created_at"],
                "diffHunk": c.get("diff_hunk", ""),
            }
        )

    return {"comments": comments_out}


def apply_patch(inp: dict) -> dict:
    """
    Apply one or more unified diffs as signed commits on the PR head branch,
    then push once.

    Input – two formats select the commit payload:
      - Legacy single-patch: {"patch": "...", "commitMessage": "..."}.
        Normalized internally into a one-element `commits` list.
      - Batch: {"commits": [{"patch": "...", "commitMessage": "..."}, ...]}.
        Each entry is applied as its own commit, in order.
    Either way there is exactly one push at the end (never one per commit),
    so N review-comment fixes cost one clone + one push instead of N.

    Input – repo acquisition mode (independent of the above):
      - Clone mode (default, used whenever "localRepoPath" is absent): shallow
        clones the PR head branch into a temp dir with the token embedded in
        the URL, sets identity/commit.gpgsign in that clone's local config,
        and pushes back through the token URL. This is the original behaviour.
      - Local mode (opt-in via {"localRepoPath": "/abs/path"}): reuses an
        already-checked-out working copy instead of cloning. Preconditions
        (path is a git repo, its current branch is the PR head branch, its
        tree is clean) are verified up front, each with its own clear error.
        The user's repo config is never touched (no `git config` calls); an
        `authorName`/`authorEmail` override, if given, is passed per commit
        via `git -c user.name=... -c user.email=... commit ...` instead.
        Pushes go through the existing `origin` remote (no token URL). On
        failure (git apply, signing, push, or an unexpected exception), the
        branch is hard-reset back to its pre-run HEAD before the error is
        returned/raised.

    Input – preview mode:
      - {"dryRun": true} runs the full flow (clone or local checks, patch
        application, signed commits) but never pushes. Each commit is still
        created locally so its diffstat can be inspected; a signing failure
        no longer aborts the run – it retries the commit unsigned and just
        flags it, since the point of a dry run is to diagnose before the
        real pass. In local-repo mode, the branch is hard-reset back to its
        pre-dry-run HEAD before returning, so the user's checkout never ends
        up carrying unpushed commits. In clone mode there is nothing to
        clean up (the clone lives in a discarded temp dir).

    Output:
      - Legacy single-patch input → {"commitSha": "..."}.
      - Batch input               → {"commitShas": ["...", ...]}.
      - Dry run                  → {"dryRun": true, "wouldPush": [
        {"commitMessage": "...", "diffStat": "...", "signed": <bool>}, ...]}.
      - Failure                   → {"error": "..."}. If commit k in a batch
        fails, nothing has been pushed (the single push only runs once every
        commit has succeeded), and the error names the offending commit:
        {"error": "commit 2/3 (\\"fix: ...\\") failed: <detail>"} – existing
        failure messages (git apply, signing, nothing to commit, unsigned
        HEAD) are reused, prefixed with that context when the batch has more
        than one element. (In dry-run mode, signing failures don't produce
        an error – see above.)
    """
    owner = inp["owner"]
    repo = inp["repo"]
    pr_number = int(inp["prNumber"])

    # --- Normalize input: legacy single-patch vs batch ---
    if "commits" in inp:
        commits_in: list[dict] = inp["commits"]
        is_batch = True
    else:
        commits_in = [{"patch": inp["patch"], "commitMessage": inp["commitMessage"]}]
        is_batch = False
    n = len(commits_in)
    if n == 0:
        return {"error": "commits list is empty – nothing to apply."}

    author_name = inp.get("authorName")
    author_email = inp.get("authorEmail")
    local_repo_path: str | None = inp.get("localRepoPath")
    dry_run: bool = bool(inp.get("dryRun", False))

    # --- Resolve PR head branch ---
    pr_data = _http_get(f"{BASE}/repos/{owner}/{repo}/pulls/{pr_number}")
    head_branch: str = pr_data["head"]["ref"]
    head_repo = pr_data["head"]["repo"]
    if head_repo is None:
        return {"error": "PR head repository is gone (fork deleted?) – cannot clone/push."}
    clone_url: str = head_repo["clone_url"]

    # Fork detection: if the head repo differs from the base repo, a push is
    # very likely to fail for lack of token rights on the fork. We don't block
    # here – just remember it to enrich the push error message below.
    is_fork = head_repo["full_name"] != pr_data["base"]["repo"]["full_name"]
    fork_full_name: str = head_repo["full_name"]

    def _run(work_dir: str, dry_run: bool = False) -> dict:
        """Apply every commit in `commits_in` against `work_dir`, then push once
        (skipped entirely when `dry_run` is true)."""
        commit_shas: list[str] = []
        would_push: list[dict] = []
        for idx, c in enumerate(commits_in, start=1):
            patch: str = c["patch"]
            commit_message: str = c["commitMessage"]
            prefix = f'commit {idx}/{n} ("{commit_message}") failed: ' if n > 1 else ""

            # Write the patch to a temp file OUTSIDE the working tree, so the
            # later `git add -A` can never stage the patch file itself into
            # the commit. Unlink is guaranteed even if applying raises.
            patch_fd, patch_path = tempfile.mkstemp(suffix=".patch", prefix="pr_resolver_")
            with os.fdopen(patch_fd, "w", encoding="utf-8") as f:
                f.write(patch)
            try:
                # Apply patch. LLM-generated diffs often have slightly stale
                # context, so on failure we retry with `--3way`, which can
                # reconstruct a fake ancestor from the blobs referenced by the
                # patch's index lines and merge around the drift. This still
                # needs those index lines to be present and resolvable in our
                # shallow clone; when they're missing (common in LLM-generated
                # diffs), --3way fails with something like "could not build
                # fake ancestor" and we fall through to the error.
                apply_r = _git("apply", "--whitespace=fix", patch_path, cwd=work_dir, check=False)
                if apply_r.returncode != 0:
                    apply_3way_r = _git(
                        "apply", "--3way", "--whitespace=fix", patch_path, cwd=work_dir, check=False
                    )
                    if apply_3way_r.returncode != 0:
                        return {
                            "error": _redact(
                                f"{prefix}git apply failed (direct):\n{apply_r.stderr.strip()}\n\n"
                                f"stdout:\n{apply_r.stdout.strip()}\n\n"
                                f"git apply --3way also failed:\n{apply_3way_r.stderr.strip()}\n\n"
                                f"stdout:\n{apply_3way_r.stdout.strip()}"
                            )
                        }
            finally:
                os.unlink(patch_path)

            # Stage all changes
            _git("add", "-A", cwd=work_dir)

            # Commit (signed). `-S` forces signing so a failing/locked signer
            # aborts the commit instead of silently producing an unsigned one.
            # In local-repo mode we never touch the user's git config, so a
            # per-commit author override (if provided) goes through `-c`
            # instead of `git config`.
            commit_args: list[str] = []
            if local_repo_path and (author_name or author_email):
                if author_name:
                    commit_args += ["-c", f"user.name={author_name}"]
                if author_email:
                    commit_args += ["-c", f"user.email={author_email}"]

            signed = True
            if dry_run:
                # A dry run still commits (so we have something to diff/stat),
                # but a signing failure is diagnostic information rather than
                # a hard stop: retry unsigned and flag it in the report.
                commit_r = _git(*commit_args, "commit", "-S", "-m", commit_message, cwd=work_dir, check=False)
                if commit_r.returncode != 0:
                    if "nothing to commit" in commit_r.stdout:
                        return {"error": f"{prefix}Nothing to commit – patch produced no changes."}
                    signed = False
                    commit_r = _git(*commit_args, "commit", "-m", commit_message, cwd=work_dir, check=False)
                    if commit_r.returncode != 0:
                        return {"error": _redact(f"{prefix}git commit failed:\n{commit_r.stderr.strip()}")}
            else:
                # Commit (signed). `-S` forces signing so a failing/locked
                # signer aborts the commit instead of silently producing an
                # unsigned one.
                commit_r = _git(*commit_args, "commit", "-S", "-m", commit_message, cwd=work_dir, check=False)
                if commit_r.returncode != 0:
                    # Handle "nothing to commit"
                    if "nothing to commit" in commit_r.stdout:
                        return {"error": f"{prefix}Nothing to commit – patch produced no changes."}
                    err = commit_r.stderr.strip()
                    low = err.lower()
                    if "gpg" in low or "sign" in low or "op-ssh-sign" in low:
                        return {
                            "error": _redact(
                                f"{prefix}Commit signing failed – refusing to push an unsigned "
                                "commit. Two common causes: (1) the signing key is locked – "
                                "unlock 1Password; (2) this script is running inside a "
                                "sandboxed shell that blocks the signer (op-ssh-sign) – rerun "
                                "outside the sandbox (e.g. Claude Code Bash with "
                                "dangerouslyDisableSandbox).\n\n"
                                f"{err}"
                            )
                        }
                    return {"error": _redact(f"{prefix}git commit failed:\n{err}")}

            # Guard: refuse to push unless a signature is actually present on
            # HEAD. `%G?` == "N" means no signature; other codes mean a
            # signature exists (this check needs no allowed-signers file, so
            # it won't false-fail).
            sig_r = _git("log", "-1", "--format=%G?", cwd=work_dir, check=False)
            sig_status = sig_r.stdout.strip()
            if sig_status in ("N", ""):
                if dry_run:
                    signed = False
                else:
                    return {
                        "error": (
                            f"{prefix}Refusing to push: HEAD carries no signature "
                            f"(status={sig_status!r}). Two common causes: (1) the signing "
                            "key is locked – unlock 1Password; (2) this script is running "
                            "inside a sandboxed shell that blocks the signer (op-ssh-sign) – "
                            "rerun outside the sandbox (e.g. Claude Code Bash with "
                            "dangerouslyDisableSandbox)."
                        )
                    }

            if dry_run:
                stat_r = _git("show", "--stat", "--format=", "HEAD", cwd=work_dir, check=False)
                would_push.append(
                    {
                        "commitMessage": commit_message,
                        "diffStat": stat_r.stdout.strip(),
                        "signed": signed,
                    }
                )
                continue

            sha_r = _git("rev-parse", "HEAD", cwd=work_dir)
            commit_shas.append(sha_r.stdout.strip())

        if dry_run:
            return {"dryRun": True, "wouldPush": would_push}

        # Single push, covering every commit made above.
        push_r = _git("push", "origin", head_branch, cwd=work_dir, check=False)
        if push_r.returncode != 0:
            err = f"git push failed:\n{push_r.stderr.strip()}"
            if is_fork:
                err += (
                    f"\n\nNote: the PR head lives on fork {fork_full_name}; "
                    "your token may lack push rights there."
                )
            return {"error": _redact(err)}

        return {"commitShas": commit_shas} if is_batch else {"commitSha": commit_shas[0]}

    if local_repo_path:
        # --- Local repo mode: reuse an existing working copy, no clone. ---
        if not os.path.isdir(local_repo_path):
            return {"error": f"localRepoPath {local_repo_path!r} does not exist or is not a directory."}

        is_repo_r = _git("rev-parse", "--is-inside-work-tree", cwd=local_repo_path, check=False)
        if is_repo_r.returncode != 0 or is_repo_r.stdout.strip() != "true":
            return {"error": f"localRepoPath {local_repo_path!r} is not a git repository."}

        branch_r = _git("rev-parse", "--abbrev-ref", "HEAD", cwd=local_repo_path, check=False)
        current_branch = branch_r.stdout.strip()
        if branch_r.returncode != 0 or current_branch != head_branch:
            return {
                "error": (
                    f"localRepoPath is on branch {current_branch!r}, expected PR head "
                    f"branch {head_branch!r}. Checkout the correct branch and retry."
                )
            }

        status_r = _git("status", "--porcelain", cwd=local_repo_path, check=False)
        if status_r.returncode != 0 or status_r.stdout.strip():
            return {
                "error": _redact(
                    "localRepoPath working tree is not clean; commit, stash, or discard "
                    f"local changes and retry.\n\n{status_r.stdout.strip()}"
                )
            }

        # Remember the pre-run HEAD so we can hard-reset back to it on
        # failure: _run() creates real commits on this working copy, and
        # leaving them behind on a failed attempt would silently move the
        # user's branch and/or leave the tree dirty.
        initial_sha = _git("rev-parse", "HEAD", cwd=local_repo_path).stdout.strip()

        if dry_run:
            try:
                return _run(local_repo_path, dry_run=True)
            finally:
                # Restore even if _run raises (e.g. an unexpected git failure):
                # the user's branch must never keep the dry-run commits.
                _git("reset", "--hard", initial_sha, cwd=local_repo_path, check=False)

        try:
            result = _run(local_repo_path)
        except Exception:
            # Unexpected failure mid-run: restore the branch before letting
            # the exception propagate (main()'s generic handler formats it).
            _git("reset", "--hard", initial_sha, cwd=local_repo_path, check=False)
            raise
        if "error" in result:
            # Known failure (git apply, signing, push, ...): the commits
            # made so far were never pushed, so reset them away rather than
            # leaving the user's checkout dirty/ahead of origin.
            _git("reset", "--hard", initial_sha, cwd=local_repo_path, check=False)
        return result

    # --- Clone mode (default): shallow clone into a temp dir, push via token URL. ---
    auth_url = clone_url.replace(
        "https://", f"https://x-access-token:{GITHUB_TOKEN}@"
    )

    with tempfile.TemporaryDirectory() as tmpdir:
        # Clone (shallow, head branch only)
        clone_r = subprocess.run(
            ["git", "clone", "--depth=1", "--branch", head_branch, auth_url, tmpdir],
            capture_output=True,
            text=True,
        )
        if clone_r.returncode != 0:
            return {"error": _redact(f"git clone failed:\n{clone_r.stderr}")}

        # --- Identity & signing ---
        # Attribute the commit to the real author so the SSH signature is valid
        # and correctly attributed. Optional overrides via input; otherwise the
        # ambient git identity (global ~/.gitconfig) is inherited.
        if author_name:
            _git("config", "user.name", author_name, cwd=tmpdir)
        if author_email:
            _git("config", "user.email", author_email, cwd=tmpdir)

        # Enforce commit signing. gpg.format / user.signingkey / gpg.ssh.program
        # are inherited from the ambient config (nothing hardcoded → portable).
        # Forcing commit.gpgsign locally prevents a repo-local `false` from
        # slipping an unsigned commit through.
        _git("config", "commit.gpgsign", "true", cwd=tmpdir)

        # Nothing to clean up here for dry runs: the clone lives in a
        # TemporaryDirectory that's discarded on exit regardless of outcome.
        return _run(tmpdir, dry_run=dry_run)


def update_threads(inp: dict) -> dict:
    """
    For each update:
      1. Post a reply comment in the thread (if `message` is provided).
      2. Resolve the thread via GraphQL (if `resolved=true` and `threadId` present).

    Each update is processed independently: a failure on one update (either
    the reply post or the thread resolution) is caught and does not interrupt
    the loop, so the remaining updates still get applied and reported.

    Input – preview mode:
      - {"dryRun": true} makes NO network call at all (no reply posted, no
        thread resolved) and instead reports what each update would do.

    Returns:
      - Normal run:
        {
          "ok": <bool>,       # true only if every update succeeded
          "results": [
            {"commentId": <id>, "ok": true},
            {"commentId": <id>, "ok": false, "step": "reply" | "resolve", "error": "<message>"},
            ...
          ],
        }
      - Dry run:
        {
          "dryRun": true,
          "wouldPost": [
            {"commentId": <id>, "message": "<message>", "wouldResolve": <bool>},
            ...
          ],
        }
    """
    owner = inp["owner"]
    repo = inp["repo"]
    pr_number = int(inp["prNumber"])
    updates: list[dict] = inp["updates"]

    if bool(inp.get("dryRun", False)):
        would_post = [
            {
                "commentId": u["commentId"],
                "message": u.get("message", ""),
                "wouldResolve": bool(u.get("resolved", False) and u.get("threadId")),
            }
            for u in updates
        ]
        return {"dryRun": True, "wouldPost": would_post}

    post_headers = {**REST_HEADERS, "Content-Type": "application/json"}
    reply_url = f"{BASE}/repos/{owner}/{repo}/pulls/{pr_number}/comments"

    results: list[dict] = []

    for u in updates:
        comment_id: int = u["commentId"]
        message: str = u.get("message", "")
        resolved: bool = u.get("resolved", False)
        thread_id: str | None = u.get("threadId")

        step = "reply"
        try:
            # Post reply
            if message:
                _http_post(
                    reply_url,
                    {"body": message, "in_reply_to": comment_id},
                    post_headers,
                )

            # Resolve thread via GraphQL
            step = "resolve"
            if resolved and thread_id:
                _gql(
                    """
                    mutation($threadId: ID!) {
                      resolveReviewThread(input: {threadId: $threadId}) {
                        thread { id isResolved }
                      }
                    }
                    """,
                    {"threadId": thread_id},
                )

            results.append({"commentId": comment_id, "ok": True})
        except Exception as exc:
            results.append(
                {"commentId": comment_id, "ok": False, "step": step, "error": _redact(str(exc))}
            )

    return {"ok": all(r["ok"] for r in results), "results": results}


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

OPERATIONS: dict[str, Any] = {
    "list_pr_comments": list_pr_comments,
    "apply_patch": apply_patch,
    "update_threads": update_threads,
}


def main() -> None:
    _check_token()

    if len(sys.argv) < 2:
        _exit_error(
            "Usage: python scripts/pr_tool.py '<json_input>'\n"
            "Supported kinds: list_pr_comments, apply_patch, update_threads"
        )

    try:
        inp = json.loads(sys.argv[1])
    except json.JSONDecodeError as e:
        _exit_error(f"Invalid JSON input: {e}")

    kind: str = inp.get("kind", "")
    handler = OPERATIONS.get(kind)

    if handler is None:
        _exit_error(
            f"Unknown kind: {kind!r}. "
            f"Valid options: {', '.join(OPERATIONS)}"
        )

    try:
        result = handler(inp)
    except GitHubAPIError as e:
        result = {"error": str(e)}
    except Exception as e:  # noqa: BLE001
        result = {"error": str(e)}

    if isinstance(result, dict) and isinstance(result.get("error"), str):
        result["error"] = _redact(result["error"])

    print(json.dumps(result, ensure_ascii=False, indent=2))

    if isinstance(result, dict) and ("error" in result or result.get("ok") is False):
        sys.exit(1)


if __name__ == "__main__":
    main()
