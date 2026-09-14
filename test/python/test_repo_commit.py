from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
from git_ai import _commit_cli, build_repo_commit_prompt
from git_ai._git import FILE_DIFF_LIMIT_BYTES


def _git(repo: Path, *args: str) -> None:
    subprocess.run(["git", *args], cwd=repo, check=True)


def _init_repo(repo: Path) -> None:
    repo.mkdir()
    subprocess.run(["git", "init", "-b", "main", repo], check=True)
    _git(repo, "config", "user.email", "t@t.com")
    _git(repo, "config", "user.name", "T")


def _write(repo: Path, name: str, content: str) -> None:
    path = repo / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _commit(repo: Path, name: str, content: str, message: str) -> None:
    _write(repo, name, content)
    _git(repo, "add", name)
    _git(repo, "commit", "-m", message)


def _branch_repo(repo: Path) -> None:
    _init_repo(repo)
    _write(repo, ".git-ai-instructions", "Use api scope.\n")
    _git(repo, "add", ".git-ai-instructions")
    _git(repo, "commit", "-m", "chore: initialize")
    _git(repo, "tag", "v1.0.0")
    _git(repo, "checkout", "-b", "feature")
    _commit(repo, "branch.py", "one\n", "feat: add branch work")


def test_build_repo_commit_prompt_collects_repo_context(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _branch_repo(repo)
    _write(repo, "staged.py", "ready\n")
    _git(repo, "add", "staged.py")

    system, user = build_repo_commit_prompt(repo)

    assert system.strip()
    assert "<repo_guidance>\nUse api scope.\n</repo_guidance>" in user
    assert "last tag v1.0.0, 1 commits since" in user
    assert "<branch>feature</branch>" in user
    assert "feat: add branch work" in user
    assert "branch.py" in user.split("<branch_diffstat>", 1)[1]
    assert "staged.py" in user.split("<changed_files>", 1)[1]
    assert "+ready" in user.split("<diff>", 1)[1]


def test_build_repo_commit_prompt_base_precedence(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = tmp_path / "repo"
    _branch_repo(repo)
    _commit(repo, "second.py", "two\n", "fix: add second change")
    _write(repo, "staged.py", "ready\n")
    _git(repo, "add", "staged.py")

    monkeypatch.setenv("GIT_AI_COMMIT_BASE", "HEAD~1")
    _, explicit = build_repo_commit_prompt(repo, base="main")
    _, environment = build_repo_commit_prompt(repo)
    monkeypatch.delenv("GIT_AI_COMMIT_BASE")
    _, automatic = build_repo_commit_prompt(repo)

    assert "feat: add branch work" in explicit
    assert "feat: add branch work" not in environment
    assert "fix: add second change" in environment
    assert "feat: add branch work" in automatic


def test_build_repo_commit_prompt_keeps_large_file_stat_only(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_repo(repo)
    _write(repo, "large.txt", "x" * (FILE_DIFF_LIMIT_BYTES + 1))
    _write(repo, "small.txt", "small\n")
    _git(repo, "add", "large.txt", "small.txt")

    _, user = build_repo_commit_prompt(repo)
    changed_files, diff = user.split("<diff>", 1)

    assert "large.txt" in changed_files
    assert "large.txt" not in diff
    assert "small.txt" in diff


def test_build_repo_commit_prompt_rejects_no_staged_changes(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_repo(repo)

    with pytest.raises(RuntimeError, match="No staged changes"):
        build_repo_commit_prompt(repo)


def test_build_repo_commit_prompt_omits_failed_branch_context(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    repo = tmp_path / "repo"
    _branch_repo(repo)
    _write(repo, "staged.py", "ready\n")
    _git(repo, "add", "staged.py")

    def fail_base_resolution(*args: object, **kwargs: object) -> None:
        raise RuntimeError("broken")

    monkeypatch.setattr("git_ai._generate.resolve_commit_base", fail_base_resolution)

    _, user = build_repo_commit_prompt(repo)

    assert "<branch>" not in user
    assert "<branch_commits>" not in user
    assert "staged.py" in user


def test_build_prompt_bridge_matches_public_builder(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    repo = tmp_path / "repo"
    _init_repo(repo)
    _write(repo, "staged.py", "ready\n")
    _git(repo, "add", "staged.py")
    prompt_file = tmp_path / "prompt"

    expected_prompt, expected_input = build_repo_commit_prompt(repo)
    result = _commit_cli.main(
        [
            "build-prompt",
            "--repo",
            str(repo),
            "--prompt-file",
            str(prompt_file),
        ]
    )

    assert result == 0
    assert prompt_file.read_text(encoding="utf-8") == expected_prompt
    assert capsys.readouterr().out == expected_input
