"""Tests for branch scope partitioning in _scope.py."""

import subprocess
from pathlib import Path

from git_ai import analyze_branch_scope, suggested_split


def _init_repo(repo: Path) -> None:
    repo.mkdir()
    subprocess.run(["git", "init", "-b", "main", repo], check=True)
    subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "T"], cwd=repo, check=True)


def _commit_files(repo: Path, files: dict[str, str], message: str) -> None:
    for name, content in files.items():
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", message], cwd=repo, check=True)


def _checkout(repo: Path, *args: str) -> None:
    subprocess.run(["git", "checkout", *args], cwd=repo, check=True)


def _crept_repo(repo: Path) -> None:
    """A branch carrying a feature plus two unrelated riders."""
    _init_repo(repo)
    _commit_files(
        repo,
        {"core.py": "a\nb\nc\n", "lock.py": "ttl = 1\n", "pyproject.toml": "ruff==1\n"},
        "chore: base",
    )
    _checkout(repo, "-b", "feature")
    _commit_files(repo, {"persona.py": "x\ny\nz\n"}, "feat: add persona")
    _commit_files(repo, {"persona.py": "x\nY2\nz\n"}, "refactor: tidy persona")
    _commit_files(repo, {"lock.py": "ttl = 2\n"}, "fix: lock TTL off-by-one")
    _commit_files(repo, {"pyproject.toml": "ruff==2\n"}, "chore: bump ruff")


def _labels(repo: Path) -> list[str]:
    return [c.label for c in analyze_branch_scope(repo, "main").concerns]


def test_unrelated_riders_split_into_their_own_concerns(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)

    scope = analyze_branch_scope(repo, "main")
    assert scope.is_split
    assert len(scope.concerns) == 3
    assert scope.commit_count == 4

    primary = next(c for c in scope.concerns if c.primary)
    # The refactor blames back to the feat's own lines → same concern.
    assert [c.subject for c in primary.commits] == [
        "feat: add persona",
        "refactor: tidy persona",
    ]
    assert primary.label == "feat: add persona"
    assert primary.adds_new_files

    assert sorted(c.label for c in scope.secondary) == [
        "chore: bump ruff",
        "fix: lock TTL off-by-one",
    ]


def test_rider_editing_base_code_is_flagged_pre_existing(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)

    scope = analyze_branch_scope(repo, "main")
    rider = next(c for c in scope.concerns if c.label == "fix: lock TTL off-by-one")
    assert rider.touches_pre_existing
    assert not rider.adds_new_files
    assert rider.files == ("lock.py",)


def test_shared_file_links_commits_without_a_blame_edge(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_repo(repo)
    _commit_files(repo, {"core.py": "a\n"}, "chore: base")
    _checkout(repo, "-b", "feature")
    _commit_files(repo, {"new.py": "1\n"}, "feat: add new")
    # Appending is a pure addition — no pre-image lines, so no blame edge. Only
    # the shared path keeps the two together.
    _commit_files(repo, {"new.py": "1\n2\n"}, "feat: extend new")

    scope = analyze_branch_scope(repo, "main")
    assert len(scope.concerns) == 1
    assert scope.concerns[0].commits[1].refines == frozenset()


def test_lockfile_churn_does_not_glue_concerns_together(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_repo(repo)
    _commit_files(repo, {"core.py": "a\n", "uv.lock": "v1\n"}, "chore: base")
    _checkout(repo, "-b", "feature")
    _commit_files(repo, {"new.py": "1\n", "uv.lock": "v2\n"}, "feat: add new")
    _commit_files(repo, {"core.py": "b\n", "uv.lock": "v3\n"}, "fix: unrelated bug")

    scope = analyze_branch_scope(repo, "main")
    assert len(scope.concerns) == 2
    assert all("uv.lock" not in c.files for c in scope.concerns)


def test_focused_branch_is_one_concern(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_repo(repo)
    _commit_files(repo, {"core.py": "a\nb\n"}, "chore: base")
    _checkout(repo, "-b", "feature")
    _commit_files(repo, {"new.py": "x\ny\n"}, "feat: add new")
    _commit_files(repo, {"new.py": "x\nY\n"}, "fix: correct new")

    scope = analyze_branch_scope(repo, "main")
    assert not scope.is_split
    assert not scope.degraded
    assert len(scope.concerns) == 1


def test_empty_range_yields_no_concerns(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_repo(repo)
    _commit_files(repo, {"core.py": "a\n"}, "chore: base")

    scope = analyze_branch_scope(repo, "main")
    assert scope.concerns == ()
    assert not scope.degraded
    assert not scope.is_split


def test_over_limit_degrades_to_a_single_concern(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)

    scope = analyze_branch_scope(repo, "main", limit=1)
    assert scope.degraded
    assert "exceeds the 1-commit cap" in scope.degraded_reason
    # Degraded must not read as "focused" — is_split is suppressed, and the
    # single concern holds every commit rather than claiming a partition.
    assert not scope.is_split
    assert len(scope.concerns) == 1
    assert len(scope.concerns[0].commits) == 4


def test_bad_base_degrades_instead_of_raising(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)

    scope = analyze_branch_scope(repo, "no-such-branch")
    assert scope.degraded
    assert scope.concerns == ()


def test_branch_name_is_carried_through(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)

    scope = analyze_branch_scope(repo, "main", branch="feature")
    assert scope.branch == "feature"
    assert scope.base == "main"


def test_suggested_split_emits_branch_and_cherry_pick(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)

    scope = analyze_branch_scope(repo, "main")
    rider = next(c for c in scope.concerns if c.label == "fix: lock TTL off-by-one")
    commands = suggested_split(rider, "origin/main")

    assert commands[0] == "git switch -c fix/lock-ttl-off-by-one main"
    assert commands[1] == f"git cherry-pick {rider.commits[0].sha[:7]}"


def test_suggested_split_orders_cherry_picks_oldest_first(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)

    scope = analyze_branch_scope(repo, "main")
    primary = next(c for c in scope.concerns if c.primary)
    picks = suggested_split(primary, "main")[1].removeprefix("git cherry-pick ").split()

    assert picks == [c.sha[:7] for c in primary.commits]


def test_scope_labels_are_stable_across_runs(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)

    assert _labels(repo) == _labels(repo)
