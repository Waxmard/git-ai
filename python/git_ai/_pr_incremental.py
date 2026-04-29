"""Shared incremental PR-generation helpers for repo-mode callers."""

from __future__ import annotations

import importlib
import json
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ._git import (
        check_git_repo,
        get_commit_log,
        get_current_branch,
        get_diff,
        get_diff_stat,
        get_git_dir,
        get_head_sha,
        get_mr_release_context,
        get_repo_root,
        git_is_ancestor,
        git_ref_exists,
    )
    from ._ignore import load_ignore_patterns
elif __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    _git = importlib.import_module("_git")
    check_git_repo = _git.check_git_repo
    get_commit_log = _git.get_commit_log
    get_current_branch = _git.get_current_branch
    get_diff = _git.get_diff
    get_diff_stat = _git.get_diff_stat
    get_git_dir = _git.get_git_dir
    get_head_sha = _git.get_head_sha
    get_mr_release_context = _git.get_mr_release_context
    get_repo_root = _git.get_repo_root
    git_is_ancestor = _git.git_is_ancestor
    git_ref_exists = _git.git_ref_exists
    _ignore = importlib.import_module("_ignore")
    load_ignore_patterns = _ignore.load_ignore_patterns
else:
    from ._git import (
        check_git_repo,
        get_commit_log,
        get_current_branch,
        get_diff,
        get_diff_stat,
        get_git_dir,
        get_head_sha,
        get_mr_release_context,
        get_repo_root,
        git_is_ancestor,
        git_ref_exists,
    )
    from ._ignore import load_ignore_patterns


@dataclass
class RepoPrContext:
    base_branch: str
    current_branch: str | None
    head_sha: str
    input_base: str
    existing_pr: str | None
    commit_log: str
    diff: str
    diff_stat: str
    release_context: str
    no_changes: bool = False

    def to_json(self) -> str:
        return json.dumps(asdict(self), ensure_ascii=True)


def branch_cache_dir(git_dir: str | Path, branch_name: str, base_branch: str) -> Path:
    key = _git_hash_object(f"{branch_name}\n{base_branch}\n")
    return Path(git_dir) / "pr-cache" / key


def branch_cache_path(git_dir: str | Path, branch_name: str, base_branch: str) -> Path:
    return branch_cache_dir(git_dir, branch_name, base_branch) / "last-output"


def load_cached_pr(
    git_dir: str | Path, branch_name: str, base_branch: str
) -> str | None:
    path = branch_cache_path(git_dir, branch_name, base_branch)
    if not path.is_file():
        return None
    return path.read_text(encoding="utf-8").rstrip("\n")


def load_cached_pr_sha(
    git_dir: str | Path, branch_name: str, base_branch: str
) -> str | None:
    path = branch_cache_dir(git_dir, branch_name, base_branch) / "last-head-sha"
    if not path.is_file():
        return None
    return path.read_text(encoding="utf-8").strip() or None


def save_cached_pr(
    git_dir: str | Path,
    branch_name: str,
    base_branch: str,
    output: str,
    head_sha: str | None = None,
) -> None:
    cache_dir = branch_cache_dir(git_dir, branch_name, base_branch)
    cache_dir.mkdir(parents=True, exist_ok=True)
    branch_cache_path(git_dir, branch_name, base_branch).write_text(
        f"{output}\n", encoding="utf-8"
    )
    if head_sha:
        (cache_dir / "last-head-sha").write_text(f"{head_sha}\n", encoding="utf-8")


def prepare_repo_pr_context(
    repo_path: str | Path = ".",
    *,
    base_branch: str,
    existing_pr: str | None = None,
    previous_head_sha: str | None = None,
    fresh: bool = False,
) -> RepoPrContext:
    if fresh and previous_head_sha:
        raise ValueError("fresh=True cannot be combined with previous_head_sha")

    repo_path = Path(repo_path)
    check_git_repo(repo_path)

    current_branch = get_current_branch(repo_path)
    git_dir = get_git_dir(repo_path)
    head_sha = get_head_sha(repo_path)

    cached_pr: str | None = None
    cached_sha: str | None = None
    if not fresh and current_branch:
        cached_pr = load_cached_pr(git_dir, current_branch, base_branch)
        cached_sha = load_cached_pr_sha(git_dir, current_branch, base_branch)

    effective_existing = existing_pr if existing_pr is not None else cached_pr

    input_base = base_branch
    if previous_head_sha:
        if not git_ref_exists(repo_path, previous_head_sha):
            raise ValueError(
                f"previous_head_sha {previous_head_sha!r} not found in repo"
            )
        if not git_is_ancestor(repo_path, previous_head_sha, "HEAD"):
            raise ValueError(
                f"previous_head_sha {previous_head_sha!r} is not an ancestor of HEAD"
            )
        input_base = previous_head_sha
    elif (
        cached_sha
        and git_ref_exists(repo_path, cached_sha)
        and git_is_ancestor(repo_path, cached_sha, "HEAD")
    ):
        input_base = cached_sha

    commit_log = get_commit_log(repo_path, input_base)
    if input_base != base_branch and effective_existing and not commit_log.strip():
        return RepoPrContext(
            base_branch=base_branch,
            current_branch=current_branch,
            head_sha=head_sha,
            input_base=input_base,
            existing_pr=effective_existing,
            commit_log="",
            diff="",
            diff_stat="",
            release_context=get_mr_release_context(repo_path),
            no_changes=True,
        )

    if input_base == base_branch and not commit_log.strip():
        raise RuntimeError(f"No commits ahead of {base_branch}")

    three_dot = input_base == base_branch
    repo_root = get_repo_root(repo_path)
    patterns = load_ignore_patterns(repo_root)
    return RepoPrContext(
        base_branch=base_branch,
        current_branch=current_branch,
        head_sha=head_sha,
        input_base=input_base,
        existing_pr=effective_existing,
        commit_log=commit_log,
        diff=get_diff(
            repo_path, input_base, three_dot=three_dot, exclude_patterns=patterns
        ),
        diff_stat=get_diff_stat(
            repo_path, input_base, three_dot=three_dot, exclude_patterns=patterns
        ),
        release_context=get_mr_release_context(repo_path),
    )


def _git_hash_object(text: str) -> str:
    result = subprocess.run(
        ["git", "hash-object", "--stdin"],
        input=text,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git hash-object --stdin failed: {result.stderr.strip()}")
    return result.stdout.strip()
