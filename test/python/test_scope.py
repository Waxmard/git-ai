"""Tests for branch scope collection, prompting, and partition parsing."""

import json
import subprocess
from pathlib import Path

from git_ai import (
    SCOPE_MARKER,
    ScopeCommit,
    ScopeContext,
    build_scope_prompt,
    degraded_scope,
    parse_scope_response,
    prepare_branch_scope,
    suggested_split,
)


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


def _crept_repo(repo: Path) -> None:
    """A branch carrying a feature plus two unrelated riders."""
    _init_repo(repo)
    _commit_files(
        repo, {"core.py": "a\n", "pyproject.toml": "ruff==1\n"}, "chore: base"
    )
    subprocess.run(["git", "checkout", "-qb", "feature"], cwd=repo, check=True)
    _commit_files(repo, {"persona.py": "x\n"}, "feat: add persona")
    _commit_files(repo, {"persona.py": "y\n"}, "fix: tidy persona")
    _commit_files(repo, {"pyproject.toml": "ruff==2\n"}, "chore: bump ruff")


def _response(concerns: list[dict[str, object]]) -> str:
    return f"{SCOPE_MARKER}\n{json.dumps({'concerns': concerns})}"


def _ctx(n: int) -> ScopeContext:
    return ScopeContext(
        base="main",
        commits=tuple(
            ScopeCommit(
                sha=f"{i:040x}",
                subject=f"feat: c{i}",
                commit_type="feat",
                files=(f"f{i}.py",),
            )
            for i in range(1, n + 1)
        ),
        base_files=frozenset({"f1.py"}),
    )


def test_prepare_collects_subjects_and_files_oldest_first(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)

    ctx = prepare_branch_scope(repo, "main", branch="feature")

    assert not ctx.degraded
    assert [c.subject for c in ctx.commits] == [
        "feat: add persona",
        "fix: tidy persona",
        "chore: bump ruff",
    ]
    assert ctx.commits[0].files == ("persona.py",)
    assert ctx.commits[0].commit_type == "feat"
    assert ctx.branch == "feature"


def test_prepare_records_the_base_tree_for_provenance(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)

    ctx = prepare_branch_scope(repo, "main")

    assert "pyproject.toml" in ctx.base_files
    assert "persona.py" not in ctx.base_files


def test_prepare_excludes_ignored_paths_from_the_prompt(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_repo(repo)
    _commit_files(repo, {"core.py": "a\n", "uv.lock": "v1\n"}, "chore: base")
    subprocess.run(["git", "checkout", "-qb", "feature"], cwd=repo, check=True)
    _commit_files(repo, {"core.py": "b\n", "uv.lock": "v2\n"}, "feat: work")

    ctx = prepare_branch_scope(repo, "main")

    assert ctx.commits[0].files == ("core.py",)


def test_prepare_degrades_on_an_unreadable_range(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)

    ctx = prepare_branch_scope(repo, "no-such-branch")

    assert ctx.degraded
    assert ctx.commits == ()


def test_prepare_degrades_on_an_empty_range(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_repo(repo)
    _commit_files(repo, {"core.py": "a\n"}, "chore: base")

    ctx = prepare_branch_scope(repo, "main")

    assert ctx.degraded
    assert "no commits" in ctx.degraded_reason


def test_prepare_degrades_over_the_commit_cap(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)

    ctx = prepare_branch_scope(repo, "main", limit=2)

    assert ctx.degraded
    assert "exceeds the 2-commit cap" in ctx.degraded_reason


def test_prompt_numbers_commits_and_lists_files(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)

    system, user = build_scope_prompt(
        prepare_branch_scope(repo, "main", branch="feature")
    )

    assert "===SCOPE===" in system
    assert "<branch>feature</branch>" in user
    assert "1. feat: add persona" in user
    assert "   files: persona.py" in user
    assert "3. chore: bump ruff" in user


def test_parse_builds_concerns_and_marks_provenance(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)
    ctx = prepare_branch_scope(repo, "main", branch="feature")

    scope = parse_scope_response(
        _response(
            [
                {"label": "Persona support", "primary": True, "commits": [1, 2]},
                {"label": "Ruff bump", "primary": False, "commits": [3]},
            ]
        ),
        ctx,
    )

    assert scope.is_split
    assert scope.primary is not None
    assert scope.primary.label == "Persona support"
    assert [c.subject for c in scope.primary.commits] == [
        "feat: add persona",
        "fix: tidy persona",
    ]
    assert scope.primary.adds_new_files
    rider = scope.riders[0]
    assert rider.label == "Ruff bump"
    assert rider.touches_pre_existing_files
    assert not rider.adds_new_files


def test_parse_discards_reasoning_before_the_marker() -> None:
    ctx = _ctx(2)
    noisy = "Let me think about this.\nThe branch does two things.\n" + _response(
        [{"label": "A", "primary": True, "commits": [1, 2]}]
    )

    scope = parse_scope_response(noisy, ctx)

    assert not scope.degraded
    assert scope.concerns[0].label == "A"


def test_parse_accepts_a_fenced_response_without_a_marker() -> None:
    ctx = _ctx(2)
    fenced = '```json\n{"concerns":[{"label":"A","primary":true,"commits":[1,2]}]}\n```'

    scope = parse_scope_response(fenced, ctx)

    assert not scope.degraded
    assert scope.concerns[0].label == "A"


def test_parse_rejects_a_partition_that_drops_a_commit() -> None:
    scope = parse_scope_response(
        _response([{"label": "A", "primary": True, "commits": [1, 2]}]), _ctx(3)
    )

    # Commit 3 vanished. A dropped commit is the exact failure this tool exists
    # to catch, so the partition is refused rather than reported incomplete.
    assert scope.degraded
    assert scope.concerns == ()


def test_parse_rejects_a_partition_that_claims_a_commit_twice() -> None:
    scope = parse_scope_response(
        _response(
            [
                {"label": "A", "primary": True, "commits": [1, 2]},
                {"label": "B", "primary": False, "commits": [2]},
            ]
        ),
        _ctx(2),
    )

    assert scope.degraded


def test_parse_rejects_an_out_of_range_index() -> None:
    scope = parse_scope_response(
        _response([{"label": "A", "primary": True, "commits": [1, 9]}]), _ctx(2)
    )

    assert scope.degraded


def test_parse_rejects_unparseable_output() -> None:
    scope = parse_scope_response("I could not determine the concerns.", _ctx(2))

    assert scope.degraded
    assert "complete partition" in scope.degraded_reason


def test_parse_promotes_the_largest_concern_when_none_is_primary() -> None:
    scope = parse_scope_response(
        _response(
            [
                {"label": "A", "primary": False, "commits": [1]},
                {"label": "B", "primary": False, "commits": [2, 3]},
            ]
        ),
        _ctx(3),
    )

    assert scope.primary is not None
    assert scope.primary.label == "B"


def test_parse_keeps_only_the_first_of_several_primaries() -> None:
    scope = parse_scope_response(
        _response(
            [
                {"label": "A", "primary": True, "commits": [1]},
                {"label": "B", "primary": True, "commits": [2]},
            ]
        ),
        _ctx(2),
    )

    assert [c.primary for c in scope.concerns] == [True, False]


def test_parse_passes_a_degraded_context_straight_through(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)
    ctx = prepare_branch_scope(repo, "main", limit=1)

    scope = parse_scope_response(
        _response([{"label": "A", "primary": True, "commits": [1]}]), ctx
    )

    # An over-cap context must not be partitioned even if a response exists —
    # degraded means the question went unanswered, never "the branch is focused".
    assert scope.degraded
    assert not scope.is_split
    assert scope.concerns == ()


def test_degraded_scope_carries_the_context_reason(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)

    scope = degraded_scope(prepare_branch_scope(repo, "main", limit=1))

    assert scope.degraded
    assert "exceeds the 1-commit cap" in scope.degraded_reason


def test_suggested_split_slugs_the_label_and_orders_picks(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _crept_repo(repo)
    ctx = prepare_branch_scope(repo, "main")
    scope = parse_scope_response(
        _response(
            [
                {"label": "Persona support", "primary": True, "commits": [1, 2]},
                {"label": "Ruff bump", "primary": False, "commits": [3]},
            ]
        ),
        ctx,
    )

    commands = suggested_split(scope.riders[0], "origin/main")
    assert commands[0] == "git switch -c ruff-bump main"
    assert commands[1] == f"git cherry-pick {ctx.commits[2].sha[:7]}"

    primary = scope.primary
    assert primary is not None
    picks = suggested_split(primary, "main")[1].removeprefix("git cherry-pick ")
    assert picks.split() == [c.sha[:7] for c in primary.commits]


def test_prepare_keeps_a_commit_whose_every_file_is_ignored(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    _init_repo(repo)
    _commit_files(repo, {"core.py": "a\n", "uv.lock": "v1\n"}, "chore: base")
    subprocess.run(["git", "checkout", "-qb", "feature"], cwd=repo, check=True)
    _commit_files(repo, {"core.py": "b\n"}, "feat: work")
    _commit_files(repo, {"uv.lock": "v2\n"}, "fix(security): upgrade joserfc")

    ctx = prepare_branch_scope(repo, "main")

    # A lockfile-only bump is exactly the rider this tool exists to surface, so
    # it must keep its subject even though every path it touches is filtered.
    assert [c.subject for c in ctx.commits] == [
        "feat: work",
        "fix(security): upgrade joserfc",
    ]
    assert ctx.commits[1].files == ()
