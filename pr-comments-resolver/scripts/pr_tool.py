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
    pip install requests
    export GITHUB_TOKEN=<your_token>
    git must be available in PATH
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from typing import Any

import requests

# ---------------------------------------------------------------------------
# Auth & constants
# ---------------------------------------------------------------------------

GITHUB_TOKEN: str = os.environ.get("GITHUB_TOKEN", "")
BASE: str = "https://api.github.com"
GQL_URL: str = f"{BASE}/graphql"

REST_HEADERS: dict[str, str] = {
    "Authorization": f"token {GITHUB_TOKEN}",
    "Accept": "application/vnd.github.v3+json",
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
        _exit_error("GITHUB_TOKEN environment variable is not set.")


def _exit_error(message: str) -> None:
    print(json.dumps({"error": message}, ensure_ascii=False))
    sys.exit(1)


def _paginate(url: str, params: dict | None = None) -> list[dict]:
    """Fetch all pages of a GitHub REST endpoint."""
    results: list[dict] = []
    page = 1
    while True:
        p = {**(params or {}), "per_page": 100, "page": page}
        r = requests.get(url, headers=REST_HEADERS, params=p, timeout=30)
        r.raise_for_status()
        data = r.json()
        if not data:
            break
        results.extend(data)
        if len(data) < 100:
            break
        page += 1
    return results


def _gql(query: str, variables: dict) -> dict:
    """Execute a GitHub GraphQL query."""
    r = requests.post(
        GQL_URL,
        headers=GQL_HEADERS,
        json={"query": query, "variables": variables},
        timeout=30,
    )
    r.raise_for_status()
    data = r.json()
    if "errors" in data:
        raise RuntimeError(f"GraphQL errors: {data['errors']}")
    return data["data"]


def _git(*args: str, cwd: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=check,
    )


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
    # We fetch up to 250 threads (2 pages of 100 + 1 page of 50 is typical for
    # large PRs). Increase the `first` value if needed.
    gql_data = _gql(
        """
        query($owner: String!, $repo: String!, $pr: Int!) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $pr) {
              reviewThreads(first: 100) {
                nodes {
                  id
                  isResolved
                  comments(first: 1) {
                    nodes { databaseId }
                  }
                }
              }
            }
          }
        }
        """,
        {"owner": owner, "repo": repo, "pr": pr_number},
    )

    threads = (
        gql_data["repository"]["pullRequest"]["reviewThreads"]["nodes"]
    )

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
    Clone PR head branch, apply a unified diff, commit, and push.
    Returns: { "commitSha": "..." } or { "error": "..." }
    """
    owner = inp["owner"]
    repo = inp["repo"]
    pr_number = int(inp["prNumber"])
    patch: str = inp["patch"]
    commit_message: str = inp["commitMessage"]

    # --- Resolve PR head branch ---
    r = requests.get(
        f"{BASE}/repos/{owner}/{repo}/pulls/{pr_number}",
        headers=REST_HEADERS,
        timeout=30,
    )
    r.raise_for_status()
    pr_data = r.json()
    head_branch: str = pr_data["head"]["ref"]
    clone_url: str = pr_data["head"]["repo"]["clone_url"]

    # Inject token for HTTPS push
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
            return {"error": f"git clone failed:\n{clone_r.stderr}"}

        # --- Identity & signing ---
        # Attribute the commit to the real author so the SSH signature is valid
        # and correctly attributed. Optional overrides via input; otherwise the
        # ambient git identity (global ~/.gitconfig) is inherited.
        author_name = inp.get("authorName")
        author_email = inp.get("authorEmail")
        if author_name:
            _git("config", "user.name", author_name, cwd=tmpdir)
        if author_email:
            _git("config", "user.email", author_email, cwd=tmpdir)

        # Enforce commit signing. gpg.format / user.signingkey / gpg.ssh.program
        # are inherited from the ambient config (nothing hardcoded → portable).
        # Forcing commit.gpgsign locally prevents a repo-local `false` from
        # slipping an unsigned commit through.
        _git("config", "commit.gpgsign", "true", cwd=tmpdir)

        # Write patch file
        patch_path = os.path.join(tmpdir, "_pr_resolver.patch")
        with open(patch_path, "w", encoding="utf-8") as f:
            f.write(patch)

        # Apply patch
        apply_r = _git("apply", "--whitespace=fix", patch_path, cwd=tmpdir, check=False)
        if apply_r.returncode != 0:
            return {
                "error": (
                    f"git apply failed:\n{apply_r.stderr.strip()}\n\n"
                    f"stdout:\n{apply_r.stdout.strip()}"
                )
            }

        # Stage all changes
        _git("add", "-A", cwd=tmpdir)

        # Commit (signed). `-S` forces signing so a failing/locked signer aborts
        # the commit instead of silently producing an unsigned one.
        commit_r = _git("commit", "-S", "-m", commit_message, cwd=tmpdir, check=False)
        if commit_r.returncode != 0:
            # Handle "nothing to commit"
            if "nothing to commit" in commit_r.stdout:
                return {"error": "Nothing to commit – patch produced no changes."}
            err = commit_r.stderr.strip()
            low = err.lower()
            if "gpg" in low or "sign" in low or "op-ssh-sign" in low:
                return {
                    "error": (
                        "Commit signing failed – refusing to push an unsigned commit. "
                        "Unlock your signing key (e.g. 1Password) and retry.\n\n"
                        f"{err}"
                    )
                }
            return {"error": f"git commit failed:\n{err}"}

        # Guard: refuse to push unless a signature is actually present on HEAD.
        # `%G?` == "N" means no signature; other codes mean a signature exists
        # (this check needs no allowed-signers file, so it won't false-fail).
        sig_r = _git("log", "-1", "--format=%G?", cwd=tmpdir, check=False)
        sig_status = sig_r.stdout.strip()
        if sig_status in ("N", ""):
            return {
                "error": (
                    f"Refusing to push: HEAD carries no signature (status={sig_status!r}). "
                    "Ensure your signing key is available (unlock 1Password) and retry."
                )
            }

        # Push
        push_r = _git("push", "origin", head_branch, cwd=tmpdir, check=False)
        if push_r.returncode != 0:
            return {"error": f"git push failed:\n{push_r.stderr.strip()}"}

        # Get SHA
        sha_r = _git("rev-parse", "HEAD", cwd=tmpdir)
        commit_sha: str = sha_r.stdout.strip()

    return {"commitSha": commit_sha}


def update_threads(inp: dict) -> dict:
    """
    For each update:
      1. Post a reply comment in the thread (if `message` is provided).
      2. Resolve the thread via GraphQL (if `resolved=true` and `threadId` present).
    Returns: { "ok": true }
    """
    owner = inp["owner"]
    repo = inp["repo"]
    pr_number = int(inp["prNumber"])
    updates: list[dict] = inp["updates"]

    post_headers = {**REST_HEADERS, "Content-Type": "application/json"}
    reply_url = f"{BASE}/repos/{owner}/{repo}/pulls/{pr_number}/comments"

    for u in updates:
        comment_id: int = u["commentId"]
        message: str = u.get("message", "")
        resolved: bool = u.get("resolved", False)
        thread_id: str | None = u.get("threadId")

        # Post reply
        if message:
            r = requests.post(
                reply_url,
                headers=post_headers,
                json={"body": message, "in_reply_to": comment_id},
                timeout=30,
            )
            r.raise_for_status()

        # Resolve thread via GraphQL
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

    return {"ok": True}


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
    except requests.HTTPError as e:
        result = {
            "error": f"GitHub API error {e.response.status_code}: {e.response.text}"
        }
    except Exception as e:  # noqa: BLE001
        result = {"error": str(e)}

    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
