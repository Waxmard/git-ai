"""Tests for repo-mode incremental PR generation helpers."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from git_ai._generate import generate_mr_description
from git_ai._git import get_git_dir
from git_ai._pr_incremental import (
    load_cached_pr,
    load_cached_pr_sha,
    prepare_repo_pr_context,
    save_cached_pr,
)


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()


def _commit(repo: Path, name: str, content: str, message: str) -> str:
    path = repo / name
    path.write_text(content, encoding="utf-8")
    subprocess.run(["git", "add", name], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", message], cwd=repo, check=True)
    return _git(repo, "rev-parse", "HEAD")


def _make_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    subprocess.run(["git", "init", "-b", "main", repo], check=True)
    subprocess.run(
        ["git", "config", "user.email", "test@test.com"], cwd=repo, check=True
    )
    subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True
    )
    subprocess.run(["git", "checkout", "-b", "feature/test"], cwd=repo, check=True)
    return repo


class _Spy:
    def __init__(self, text: str) -> None:
        self._text = text
        self.calls: list[tuple[str, str]] = []

    def __call__(self, system_prompt: str, user_input: str) -> str:
        self.calls.append((system_prompt, user_input))
        return self._text


def test_prepare_repo_pr_context_uses_incremental_range_from_explicit_sha(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")
    first_sha = _git(repo, "rev-parse", "HEAD")
    _commit(repo, "two.txt", "two\n", "fix: add second")

    context = prepare_repo_pr_context(
        repo,
        base_branch="main",
        existing_pr="feat: existing title\n\n### Features\n- old",
        previous_head_sha=first_sha,
    )

    assert context.input_base == first_sha
    assert context.existing_pr == "feat: existing title\n\n### Features\n- old"
    assert "fix: add second" in context.commit_log
    assert "feat: add first" not in context.commit_log
    assert "two.txt" in context.diff_stat
    # log must be GITAI_COMMIT-prefixed so build_mr_prompt_input can detect
    # conventional commits and choose two-pass vs fallback correctly
    assert "GITAI_COMMIT" in context.commit_log


def test_prepare_repo_pr_context_raises_on_unresolvable_previous_head_sha(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")

    with pytest.raises(ValueError, match="not found in repo"):
        prepare_repo_pr_context(
            repo,
            base_branch="main",
            previous_head_sha="deadbeef00000000",
        )


def test_prepare_repo_pr_context_incremental_enables_two_pass(
    tmp_path: Path,
) -> None:
    from git_ai._pr_prompt_build import build_mr_prompt_input

    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")
    first_sha = _git(repo, "rev-parse", "HEAD")
    _commit(repo, "two.txt", "two\n", "feat: add second")

    context = prepare_repo_pr_context(
        repo,
        base_branch="main",
        existing_pr="feat: old title\n\n### Features\n- old",
        previous_head_sha=first_sha,
    )

    _, user_input = build_mr_prompt_input(
        diff=context.diff,
        commit_log=context.commit_log,
        diff_stat=context.diff_stat,
        existing_pr=context.existing_pr,
    )
    # conventional commits on incremental path must reach the two-pass prompt
    assert "<draft>" in user_input
    assert "<commit_log>" not in user_input


def test_prepare_repo_pr_context_short_circuits_when_no_new_commits(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    head_sha = _commit(repo, "one.txt", "one\n", "feat: add first")
    git_dir = get_git_dir(repo)

    from git_ai._pr_incremental import save_cached_pr

    save_cached_pr(
        git_dir,
        "feature/test",
        "main",
        "feat: cached title\n\n### Features\n- cached",
        head_sha,
    )

    context = prepare_repo_pr_context(repo, base_branch="main")

    assert context.no_changes is True
    assert context.existing_pr == "feat: cached title\n\n### Features\n- cached"
    assert context.diff == ""
    assert context.commit_log == ""


def test_prepare_repo_pr_context_rejects_fresh_and_previous_sha(tmp_path: Path) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")

    with pytest.raises(ValueError, match="fresh=True cannot be combined"):
        prepare_repo_pr_context(
            repo,
            base_branch="main",
            previous_head_sha="abc123",
            fresh=True,
        )


def test_generate_mr_description_caches_and_reuses_without_model_call(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")
    first_gen = _Spy("feat: title\n\n### Features\n- first")

    first = generate_mr_description(repo, base_branch="main", generate=first_gen)
    assert "feat: title" in first.text
    assert first.diff is None
    assert len(first_gen.calls) == 1

    second_gen = _Spy("unused")
    second = generate_mr_description(repo, base_branch="main", generate=second_gen)
    assert second.text == first.text
    assert second.diff is None
    assert second_gen.calls == []

    git_dir = get_git_dir(repo)
    assert load_cached_pr(git_dir, "feature/test", "main") == first.text
    assert load_cached_pr_sha(git_dir, "feature/test", "main") == _git(
        repo, "rev-parse", "HEAD"
    )


def test_generate_mr_description_previous_head_sha_overrides_cache(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")
    first_sha = _git(repo, "rev-parse", "HEAD")
    _commit(repo, "two.txt", "two\n", "fix: add second")
    gen = _Spy("fix: title\n\n### Bug Fixes\n- second")

    generate_mr_description(
        repo,
        base_branch="main",
        previous_head_sha=first_sha,
        existing_pr="feat: title\n\n### Features\n- first",
        generate=gen,
    )

    assert len(gen.calls) == 1
    _, user_input = gen.calls[0]
    assert "<existing_pr>" in user_input
    # two-pass prompt strips type prefix into <draft>; check description word
    assert "add second" in user_input
    assert "add first" not in user_input


def test_prepare_repo_pr_context_raises_on_non_ancestor_previous_head_sha(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")
    # orphan branch commit exists in repo but shares no history with feature/test
    subprocess.run(["git", "checkout", "--orphan", "orphan-tmp"], cwd=repo, check=True)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "orphan"], cwd=repo, check=True
    )
    orphan_sha = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    subprocess.run(["git", "checkout", "feature/test"], cwd=repo, check=True)

    with pytest.raises(ValueError, match="not an ancestor"):
        prepare_repo_pr_context(repo, base_branch="main", previous_head_sha=orphan_sha)


def test_prepare_repo_pr_context_excludes_lockfiles_by_default(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    # Lockfile commit + a real-code commit. Default excludes should drop the
    # lockfile from diff/diff_stat output.
    _commit(repo, "package-lock.json", "lock_contents\n", "chore: lockfile")
    _commit(repo, "app.py", "print('hi')\n", "feat: add app")

    ctx = prepare_repo_pr_context(repo, base_branch="main")

    assert "app.py" in ctx.diff
    assert "package-lock.json" not in ctx.diff
    assert "package-lock.json" not in ctx.diff_stat


def test_prepare_repo_pr_context_negation_reincludes_lockfile(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "package-lock.json", "lock_contents\n", "chore: lockfile")
    _commit(repo, "app.py", "print('hi')\n", "feat: add app")
    (repo / ".git-ai-ignore").write_text("!package-lock.json\n", encoding="utf-8")

    ctx = prepare_repo_pr_context(repo, base_branch="main")

    assert "package-lock.json" in ctx.diff


def test_prepare_repo_pr_context_non_ancestor_cached_sha_falls_back(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")
    # create an orphan SHA to plant in the cache
    subprocess.run(["git", "checkout", "--orphan", "orphan-tmp2"], cwd=repo, check=True)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "orphan"], cwd=repo, check=True
    )
    orphan_sha = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    subprocess.run(["git", "checkout", "feature/test"], cwd=repo, check=True)

    git_dir = Path(repo) / ".git"
    save_cached_pr(git_dir, "feature/test", "main", "old pr text", orphan_sha)

    ctx = prepare_repo_pr_context(repo, base_branch="main")
    assert ctx.input_base == "main"
    assert ctx.no_changes is False
    assert "feat: add first" in ctx.commit_log
