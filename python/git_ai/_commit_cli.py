#!/usr/bin/env python3
"""CLI bridge for the shell `git-ai commit` path.

Emits the branch-context block so the shell can splice it into the commit
prompt without reimplementing the base-resolution cascade in bash. Best-effort:
any failure prints nothing and exits 0, never blocking a commit.
"""

from __future__ import annotations

import argparse
import importlib
import os
import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ._git import get_current_branch, get_diff_stat, get_git_dir
    from ._git_branch import (
        format_branch_context,
        get_branch_commit_subjects,
        resolve_commit_base,
    )
elif __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    _git = importlib.import_module("_git")
    _git_branch = importlib.import_module("_git_branch")
    format_branch_context = _git_branch.format_branch_context
    get_branch_commit_subjects = _git_branch.get_branch_commit_subjects
    get_current_branch = _git.get_current_branch
    get_diff_stat = _git.get_diff_stat
    get_git_dir = _git.get_git_dir
    resolve_commit_base = _git_branch.resolve_commit_base
else:
    from ._git import get_current_branch, get_diff_stat, get_git_dir
    from ._git_branch import (
        format_branch_context,
        get_branch_commit_subjects,
        resolve_commit_base,
    )


def _emit_branch_context(repo: str, override: str | None) -> None:
    branch = get_current_branch(repo)
    git_dir = get_git_dir(repo)
    base = resolve_commit_base(
        repo,
        override=override or os.environ.get("GIT_AI_COMMIT_BASE") or None,
        git_dir=git_dir,
        branch=branch,
    )
    if not base:
        return
    block = format_branch_context(
        branch_name=branch,
        branch_commits=get_branch_commit_subjects(repo, base),
        branch_diffstat=get_diff_stat(repo, base),
    )
    if block:
        sys.stdout.write(block)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    branch_ctx = sub.add_parser(
        "branch-context", help="print the branch-context block for a commit prompt"
    )
    branch_ctx.add_argument("--repo", default=".")
    branch_ctx.add_argument("--base", default=None)
    args = parser.parse_args(argv)

    if args.command == "branch-context":
        try:
            _emit_branch_context(args.repo, args.base)
        except Exception:
            # Branch context is best-effort — never block a commit on it.
            return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
