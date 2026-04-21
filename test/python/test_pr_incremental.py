"""Tests for repo-mode incremental PR generation helpers."""
from __future__ import annotations

import subprocess
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

import pytest

from git_ai._generate import generate_mr_description
from git_ai._git import get_git_dir
from git_ai._pr_incremental import (
    load_cached_pr,
    load_cached_pr_sha,
    prepare_repo_pr_context,
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
    subprocess.run(["git", "config", "user.email", "test@test.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True)
    subprocess.run(["git", "checkout", "-b", "feature/test"], cwd=repo, check=True)
    return repo


def _client_returning(text: str) -> MagicMock:
    response = SimpleNamespace(text=text, candidates=[], prompt_feedback=None)
    client = MagicMock()
    client.models.generate_content.return_value = response
    return client


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
    first_client = _client_returning("feat: title\n\n### Features\n- first")

    first = generate_mr_description(repo, base_branch="main", client=first_client)
    assert "feat: title" in first
    assert first_client.models.generate_content.call_count == 1

    second_client = _client_returning("unused")
    second = generate_mr_description(repo, base_branch="main", client=second_client)
    assert second == first
    second_client.models.generate_content.assert_not_called()

    git_dir = get_git_dir(repo)
    assert load_cached_pr(git_dir, "feature/test", "main") == first
    assert load_cached_pr_sha(git_dir, "feature/test", "main") == _git(repo, "rev-parse", "HEAD")


def test_generate_mr_description_previous_head_sha_overrides_cache(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")
    first_sha = _git(repo, "rev-parse", "HEAD")
    _commit(repo, "two.txt", "two\n", "fix: add second")
    client = _client_returning("fix: title\n\n### Bug Fixes\n- second")

    generate_mr_description(
        repo,
        base_branch="main",
        previous_head_sha=first_sha,
        existing_pr="feat: title\n\n### Features\n- first",
        client=client,
    )

    contents = client.models.generate_content.call_args.kwargs["contents"]
    assert "<existing_pr>" in contents
    assert "fix: add second" in contents
    assert "feat: add first" not in contents
