"""Shared incremental PR-generation helpers for repo-mode callers."""

from __future__ import annotations

import importlib
import json
import shutil
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

# TYPE_CHECKING is for mypy only; the elif (standalone) and else (package)
# branches below are what actually import at runtime.
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
        git_merge_base,
        git_ref_exists,
    )
    from ._git_branch import (
        _best_base_ref,
        base_warnings,
        branch_content_id,
        get_branch_churn_subjects,
    )
    from ._ignore import load_ignore_patterns
elif __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    _git = importlib.import_module("_git")
    _git_branch = importlib.import_module("_git_branch")
    check_git_repo = _git.check_git_repo
    _best_base_ref = _git_branch._best_base_ref
    base_warnings = _git_branch.base_warnings
    branch_content_id = _git_branch.branch_content_id
    get_branch_churn_subjects = _git_branch.get_branch_churn_subjects
    get_commit_log = _git.get_commit_log
    get_current_branch = _git.get_current_branch
    get_diff = _git.get_diff
    get_diff_stat = _git.get_diff_stat
    get_git_dir = _git.get_git_dir
    get_head_sha = _git.get_head_sha
    get_mr_release_context = _git.get_mr_release_context
    get_repo_root = _git.get_repo_root
    git_is_ancestor = _git.git_is_ancestor
    git_merge_base = _git.git_merge_base
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
        git_merge_base,
        git_ref_exists,
    )
    from ._git_branch import (
        _best_base_ref,
        base_warnings,
        branch_content_id,
        get_branch_churn_subjects,
    )
    from ._ignore import load_ignore_patterns

# Cache dirs written before `branch-name` existed can't be tied to a branch, so
# they age out instead.
_LEGACY_CACHE_MAX_AGE_DAYS = 90


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
    content_id: str | None = None
    no_changes: bool = False
    churn_subjects: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

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


def load_cached_content_id(
    git_dir: str | Path, branch_name: str, base_branch: str
) -> str | None:
    path = branch_cache_dir(git_dir, branch_name, base_branch) / "last-content-id"
    if not path.is_file():
        return None
    return path.read_text(encoding="utf-8").strip() or None


def save_cached_pr(
    git_dir: str | Path,
    branch_name: str,
    base_branch: str,
    output: str,
    head_sha: str | None = None,
    content_id: str | None = None,
) -> None:
    """Write ``output`` and its provenance to the branch's cache entry.

    A ``content_id`` of None means the fingerprint was unavailable for this
    output (branch over the commit cap, git failure) — the previous one is
    deleted rather than kept, since a stale id paired with newer text is what
    would let a later rewrite back onto that content reuse the wrong PR.
    """
    cache_dir = branch_cache_dir(git_dir, branch_name, base_branch)
    cache_dir.mkdir(parents=True, exist_ok=True)
    branch_cache_path(git_dir, branch_name, base_branch).write_text(
        f"{output}\n", encoding="utf-8"
    )
    # The cache key is a hash, so the branch is unrecoverable without this.
    (cache_dir / "branch-name").write_text(f"{branch_name}\n", encoding="utf-8")
    if head_sha:
        (cache_dir / "last-head-sha").write_text(f"{head_sha}\n", encoding="utf-8")
    content_id_path = cache_dir / "last-content-id"
    if content_id:
        content_id_path.write_text(f"{content_id}\n", encoding="utf-8")
    else:
        content_id_path.unlink(missing_ok=True)


def prune_pr_cache(git_dir: str | Path) -> None:
    """Drop cache entries for branches that no longer exist. Best-effort.

    Skips entirely when the branch list can't be read — deleting on an unknown
    ref set would wipe live entries. Cached PR text is regenerable, so a wrong
    keep costs nothing and a wrong delete costs one LLM call. Writers don't call
    this: ``save_cached_pr`` is free to cache a branch that has no local ref.
    """
    root = Path(git_dir) / "pr-cache"
    if not root.is_dir():
        return
    result = subprocess.run(
        [
            "git",
            "--git-dir",
            str(git_dir),
            "for-each-ref",
            "--format=%(refname:short)",
            "refs/heads",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return
    live = {line.strip() for line in result.stdout.splitlines() if line.strip()}
    cutoff = time.time() - _LEGACY_CACHE_MAX_AGE_DAYS * 86400
    try:
        entries = list(root.iterdir())
    except OSError:
        return
    for entry in entries:
        if not entry.is_dir():
            continue
        name_file = entry / "branch-name"
        try:
            if name_file.is_file():
                stale = name_file.read_text(encoding="utf-8").strip() not in live
            else:
                stale = entry.stat().st_mtime < cutoff
        except OSError:
            continue
        if stale:
            shutil.rmtree(entry, ignore_errors=True)


def _rewritten_cache_check(
    repo_path: Path,
    git_dir: str,
    *,
    base_ref: str | None,
    base_branch: str,
    current_branch: str | None,
    effective_existing: str | None,
) -> tuple[str | None, str, bool]:
    """Return (content_id, warning, whether the rewrite preserved the content)."""
    content_id = branch_content_id(repo_path, base_ref) if base_ref else None
    unchanged = bool(
        content_id
        and effective_existing
        and current_branch
        and content_id == load_cached_content_id(git_dir, current_branch, base_branch)
    )
    warning = (
        "branch was rewritten (rebase/amend) but its content is unchanged — "
        "reusing cached output."
        if unchanged
        else "branch history was rewritten (rebase/amend) since the last run; "
        "regenerating from the full branch diff."
    )
    return content_id, warning, unchanged


def _resolve_cache_state(
    repo_path: Path,
    git_dir: str,
    *,
    base_branch: str,
    current_branch: str | None,
    existing_pr: str | None,
    previous_head_sha: str | None,
    fresh: bool,
) -> tuple[str | None, str, bool]:
    """Return the PR text to refine, the diff base, and whether HEAD was rewritten.

    A cached SHA that is no longer an ancestor of HEAD means a rebase, amend or
    reset replaced the branch: the incremental base is gone, so the caller
    falls back to the base branch.
    """
    cached_pr: str | None = None
    cached_sha: str | None = None
    if not fresh and current_branch:
        cached_pr = load_cached_pr(git_dir, current_branch, base_branch)
        cached_sha = load_cached_pr_sha(git_dir, current_branch, base_branch)
    effective_existing = existing_pr if existing_pr is not None else cached_pr

    if previous_head_sha:
        if not git_ref_exists(repo_path, previous_head_sha):
            raise ValueError(
                f"previous_head_sha {previous_head_sha!r} not found in repo"
            )
        if not git_is_ancestor(repo_path, previous_head_sha, "HEAD"):
            raise ValueError(
                f"previous_head_sha {previous_head_sha!r} is not an ancestor of HEAD "
                f"— a rebase or amend since then rewrote it. Re-run without "
                f"previous_head_sha to describe the whole branch, or with fresh=True "
                f"to also drop the cached wording."
            )
        return effective_existing, previous_head_sha, False
    if cached_sha:
        if git_ref_exists(repo_path, cached_sha) and git_is_ancestor(
            repo_path, cached_sha, "HEAD"
        ):
            return effective_existing, cached_sha, False
        return effective_existing, base_branch, True
    return effective_existing, base_branch, False


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
    prune_pr_cache(git_dir)

    effective_existing, input_base, history_rewritten = _resolve_cache_state(
        repo_path,
        git_dir,
        base_branch=base_branch,
        current_branch=current_branch,
        existing_pr=existing_pr,
        previous_head_sha=previous_head_sha,
        fresh=fresh,
    )

    # Prefer origin/<base> over a local branch that may lag: a stale local base
    # leaks already-merged commits into the diff and log, so the PR describes
    # work that isn't on this branch.
    base_ref = _best_base_ref(repo_path, base_branch)
    if input_base == base_branch:
        if base_ref is None:
            raise RuntimeError(
                f"base branch {base_branch!r} not found in this repository "
                f"(looked for {base_branch!r} and 'origin/{base_branch}')."
            )
        diff_ref = base_ref
        # A three-dot diff needs a common ancestor; git's own error is cryptic.
        if git_merge_base(repo_path, diff_ref, "HEAD") is None:
            raise RuntimeError(
                f"{base_branch!r} and HEAD share no common ancestor, so they "
                f"cannot be compared. Is the base branch correct? It may have "
                f"been force-pushed or replaced with unrelated history."
            )
    else:
        diff_ref = input_base

    # Fingerprinting diffs the whole branch, so it stays off the paths that
    # return without regenerating: it's needed only to compare against a
    # rewritten cache, and to stamp a context the caller will save.
    content_id: str | None = None
    warnings: list[str] = []
    if history_rewritten:
        content_id, warning, rewritten_unchanged = _rewritten_cache_check(
            repo_path,
            git_dir,
            base_ref=base_ref,
            base_branch=base_branch,
            current_branch=current_branch,
            effective_existing=effective_existing,
        )
        warnings.append(warning)
        if rewritten_unchanged:
            # Re-stamp the cache onto the rewritten HEAD. The caller returns
            # here without saving anything, so leaving the pre-rebase SHA
            # behind would make every later run re-fingerprint the whole
            # branch and re-warn instead of taking the cheap ancestor path.
            if current_branch and effective_existing:
                save_cached_pr(
                    git_dir,
                    current_branch,
                    base_branch,
                    effective_existing,
                    head_sha,
                    content_id,
                )
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
                content_id=content_id,
                no_changes=True,
                warnings=warnings,
            )

    commit_log = get_commit_log(repo_path, diff_ref)
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
            content_id=content_id,
            no_changes=True,
        )

    if input_base == base_branch and not commit_log.strip():
        raise RuntimeError(f"No commits ahead of {base_branch}")

    if input_base != base_branch and not commit_log.strip():
        raise RuntimeError(
            f"No commits since {input_base[:12]} and no existing_pr to refine"
        )

    three_dot = input_base == base_branch
    repo_root = get_repo_root(repo_path)
    patterns = load_ignore_patterns(repo_root)
    # The stat keeps lockfiles so a lockfile-only bump (common when draining bot
    # branches) still shows as one describable line; the full diff strips them
    # as noise. User `.git-ai-ignore` entries apply to both.
    stat_patterns = load_ignore_patterns(repo_root, include_defaults=False)
    # Churn membership spans the whole branch (base ref); classification covers
    # only the commits the draft will list (diff_ref).
    churn_base = base_ref if base_ref is not None else diff_ref
    churn_subjects = get_branch_churn_subjects(
        repo_path, churn_base, classify_base=diff_ref
    )
    if content_id is None and base_ref:
        content_id = branch_content_id(repo_path, base_ref)
    if current_branch is None:
        warnings.append("detached HEAD: PR caching is disabled for this run.")
    # An incremental update (input_base = a HEAD SHA) has no base relationship.
    if three_dot:
        warnings.extend(base_warnings(repo_path, base_branch, current_branch))
    return RepoPrContext(
        base_branch=base_branch,
        current_branch=current_branch,
        head_sha=head_sha,
        input_base=input_base,
        existing_pr=effective_existing,
        commit_log=commit_log,
        diff=get_diff(
            repo_path, diff_ref, three_dot=three_dot, exclude_patterns=patterns
        ),
        diff_stat=get_diff_stat(
            repo_path, diff_ref, three_dot=three_dot, exclude_patterns=stat_patterns
        ),
        release_context=get_mr_release_context(repo_path),
        content_id=content_id,
        churn_subjects=churn_subjects,
        warnings=warnings,
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
