"""Tests for pure git utility functions in _git.py."""

import subprocess
import sys
from pathlib import Path

import pytest
from git_ai import (
    get_branch_commit_subjects,
    get_default_branch,
    get_diff,
    get_diff_stat,
    get_git_dir,
    get_staged_diff,
    resolve_commit_base,
)
from git_ai._commit_cli import _emit_branch_context
from git_ai._git import build_draft_body, count_conventional_commits, largest_diff_files
from git_ai._pr_incremental import branch_cache_dir

# ---------------------------------------------------------------------------
# count_conventional_commits
# ---------------------------------------------------------------------------

_ALL_CONVENTIONAL = """\
GITAI_COMMIT feat: add new feature
GITAI_COMMIT fix: correct a bug
GITAI_COMMIT chore: update deps
GITAI_COMMIT refactor: simplify logic
GITAI_COMMIT docs: update readme
"""

_MIXED = """\
GITAI_COMMIT feat: add new feature
GITAI_COMMIT WIP: half-done thing
GITAI_COMMIT fix: correct a bug
GITAI_COMMIT random commit message
"""

_NONE_CONVENTIONAL = """\
GITAI_COMMIT WIP: half-done
GITAI_COMMIT random commit message
GITAI_COMMIT another bad one
"""

_EMPTY = ""


def test_count_all_conventional() -> None:
    conventional, total = count_conventional_commits(_ALL_CONVENTIONAL)
    assert conventional == 5
    assert total == 5


def test_count_mixed() -> None:
    conventional, total = count_conventional_commits(_MIXED)
    assert conventional == 2
    assert total == 4


def test_count_none_conventional() -> None:
    conventional, total = count_conventional_commits(_NONE_CONVENTIONAL)
    assert conventional == 0
    assert total == 3


def test_count_empty_log() -> None:
    conventional, total = count_conventional_commits(_EMPTY)
    assert conventional == 0
    assert total == 0


def test_git_module_supports_standalone_import() -> None:
    package_dir = Path(__file__).parents[2] / "python" / "git_ai"
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            (
                "import sys; "
                f"sys.path.insert(0, {str(package_dir)!r}); "
                "import _git; "
                "print(_git.to_pathspec_args(['x.lock'])[-1])"
            ),
        ],
        capture_output=True,
        check=True,
        text=True,
    )
    assert result.stdout.strip() == ":(top,exclude,glob)**/x.lock"


def test_count_ignores_body_lines() -> None:
    log = "GITAI_COMMIT feat: add thing\nThis is a body line\nGITAI_COMMIT fix: bug\n"
    conventional, total = count_conventional_commits(log)
    assert conventional == 2
    assert total == 2


def test_count_all_types_recognized() -> None:
    types = [
        "feat",
        "fix",
        "refactor",
        "docs",
        "chore",
        "ci",
        "test",
        "style",
        "perf",
        "build",
    ]
    log = "\n".join(f"GITAI_COMMIT {t}: something" for t in types)
    conventional, total = count_conventional_commits(log)
    assert conventional == len(types)
    assert total == len(types)


# ---------------------------------------------------------------------------
# build_draft_body
# ---------------------------------------------------------------------------

_DRAFT_LOG = """\
GITAI_COMMIT feat: add login page
GITAI_COMMIT fix: correct null pointer
GITAI_COMMIT docs: update api reference
GITAI_COMMIT chore: bump version
"""


def test_draft_body_contains_sections() -> None:
    draft = build_draft_body(_DRAFT_LOG)
    assert "### Features" in draft
    assert "### Bug Fixes" in draft
    assert "### Docs" in draft
    assert "### Chores" in draft


def test_draft_body_strips_type_prefix() -> None:
    draft = build_draft_body(_DRAFT_LOG)
    assert "add login page" in draft
    assert "correct null pointer" in draft


def test_draft_body_omits_empty_sections() -> None:
    draft = build_draft_body(_DRAFT_LOG)
    assert "### Refactors" not in draft
    assert "### Tests" not in draft


def test_draft_body_empty_log() -> None:
    assert build_draft_body("") == ""


def test_draft_body_only_unknown_types() -> None:
    log = "GITAI_COMMIT WIP: something\nGITAI_COMMIT random: thing\n"
    assert build_draft_body(log) == ""


def test_draft_body_includes_commit_body_lines() -> None:
    log = "GITAI_COMMIT feat: new thing\nsome body detail\nGITAI_COMMIT fix: other\n"
    draft = build_draft_body(log)
    assert "some body detail" in draft


# ---------------------------------------------------------------------------
# largest_diff_files
# ---------------------------------------------------------------------------


_LARGEST_DIFF = """\
diff --git a/small.txt b/small.txt
--- a/small.txt
+++ b/small.txt
@@ -1 +1,2 @@
-old
+new
+extra
diff --git a/big.json b/big.json
--- a/big.json
+++ b/big.json
@@ -1 +1,5 @@
-x
+a
+b
+c
+d
+e
diff --git a/medium.py b/medium.py
--- a/medium.py
+++ b/medium.py
@@ -1,2 +1,3 @@
-old1
-old2
+new1
+new2
+new3
"""


def test_largest_diff_files_orders_by_total_changes() -> None:
    top = largest_diff_files(_LARGEST_DIFF, n=5)
    assert [p for p, _, _ in top] == ["big.json", "medium.py", "small.txt"]
    assert top[0] == ("big.json", 5, 1)


def test_largest_diff_files_respects_limit() -> None:
    top = largest_diff_files(_LARGEST_DIFF, n=2)
    assert len(top) == 2
    assert top[0][0] == "big.json"


def test_largest_diff_files_empty_input() -> None:
    assert largest_diff_files("") == []


def _init_repo(repo: Path) -> None:
    subprocess.run(["git", "init", "-b", "main", repo], check=True)
    subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "T"], cwd=repo, check=True)


def _stage_files(repo: Path, files: dict[str, str]) -> None:
    _init_repo(repo)
    for name, content in files.items():
        (repo / name).write_text(content, encoding="utf-8")
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True)


def test_get_staged_diff_from_subdirectory_uses_repo_root_diff(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    (repo / "root.txt").write_text("hello\n", encoding="utf-8")
    subprocess.run(["git", "add", "root.txt"], cwd=repo, check=True)

    subdir = repo / "nested"
    subdir.mkdir()

    diff = get_staged_diff(subdir)

    assert "root.txt" in diff
    assert "+hello" in diff


def test_get_staged_diff_excludes_default_lockfiles(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _stage_files(repo, {"package-lock.json": "lock\n", "app.py": "print('hi')\n"})

    diff = get_staged_diff(repo)

    assert "app.py" in diff
    assert "package-lock.json" not in diff


def test_get_staged_diff_auto_loads_git_ai_ignore(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _stage_files(
        repo,
        {
            ".git-ai-ignore": "secret.txt\n",
            "secret.txt": "shh\n",
            "app.py": "print('hi')\n",
        },
    )

    diff = get_staged_diff(repo)

    assert "b/app.py" in diff
    assert "b/secret.txt" not in diff


def test_get_staged_diff_explicit_empty_list_disables_filtering(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _stage_files(repo, {"package-lock.json": "lock\n", "app.py": "print('hi')\n"})

    diff = get_staged_diff(repo, exclude_patterns=[])

    assert "package-lock.json" in diff
    assert "app.py" in diff


def test_get_staged_diff_negation_reincludes_lockfile(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _stage_files(
        repo,
        {".git-ai-ignore": "!package-lock.json\n", "package-lock.json": "lock\n"},
    )

    diff = get_staged_diff(repo)

    assert "package-lock.json" in diff


def test_get_staged_diff_from_subdirectory_uses_root_ignore_file(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _stage_files(
        repo,
        {
            ".git-ai-ignore": "secret.txt\n",
            "secret.txt": "shh\n",
            "app.py": "print('hi')\n",
        },
    )
    subdir = repo / "nested"
    subdir.mkdir()

    diff = get_staged_diff(subdir)

    assert "b/app.py" in diff
    assert "b/secret.txt" not in diff


def _commit_files(repo: Path, files: dict[str, str], message: str) -> None:
    for name, content in files.items():
        (repo / name).write_text(content, encoding="utf-8")
    subprocess.run(["git", "add", "-A"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", message], cwd=repo, check=True)


def test_get_diff_excludes_default_lockfiles(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True
    )
    _commit_files(
        repo, {"package-lock.json": "lock\n", "app.py": "print('hi')\n"}, "feat"
    )

    diff = get_diff(repo, "HEAD~1", three_dot=False)

    assert "b/app.py" in diff
    assert "package-lock.json" not in diff


def test_get_diff_stat_excludes_default_lockfiles(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True
    )
    _commit_files(
        repo, {"package-lock.json": "lock\n", "app.py": "print('hi')\n"}, "feat"
    )

    stat = get_diff_stat(repo, "HEAD~1", three_dot=False)

    assert "app.py" in stat
    assert "package-lock.json" not in stat


# ---------------------------------------------------------------------------
# branch-aware commit base resolution
# ---------------------------------------------------------------------------


def _checkout(repo: Path, *args: str) -> None:
    subprocess.run(["git", "checkout", *args], cwd=repo, check=True)


def test_get_default_branch_none_without_origin(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    subprocess.run(["git", "commit", "--allow-empty", "-m", "i"], cwd=repo, check=True)

    assert get_default_branch(repo) is None


def test_resolve_commit_base_returns_main_on_feature_branch(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True
    )
    _checkout(repo, "-b", "feature")
    _commit_files(repo, {"a.py": "1\n"}, "feat: a")
    _commit_files(repo, {"b.py": "2\n"}, "test: b")

    assert resolve_commit_base(repo) == "main"

    subjects = get_branch_commit_subjects(repo, "main")
    assert subjects.splitlines() == ["test: b", "feat: a"]


def test_resolve_commit_base_none_on_base_branch(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    _commit_files(repo, {"a.py": "1\n"}, "feat: a")

    # HEAD is main itself — no commits ahead of any candidate base.
    assert resolve_commit_base(repo) is None


def test_resolve_commit_base_picks_closest_base(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True
    )
    _checkout(repo, "-b", "dev")
    _commit_files(repo, {"d.py": "d\n"}, "feat: dev work")
    _checkout(repo, "-b", "feature")
    _commit_files(repo, {"f.py": "f\n"}, "feat: feature work")

    # main..HEAD = 2 commits, dev..HEAD = 1 — dev is the closer (real) base.
    assert resolve_commit_base(repo) == "dev"


def test_resolve_commit_base_detects_non_standard_base(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True
    )
    _checkout(repo, "-b", "release/2.0")
    _commit_files(repo, {"r.py": "r\n"}, "feat: release prep")
    _checkout(repo, "-b", "feature")
    _commit_files(repo, {"f.py": "f\n"}, "feat: feature work")

    # main..HEAD = 2, release/2.0..HEAD = 1 — the release branch is the real base.
    assert resolve_commit_base(repo) == "release/2.0"


def test_resolve_commit_base_detects_stacked_parent(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True
    )
    _checkout(repo, "-b", "feature-a")
    _commit_files(repo, {"a.py": "a\n"}, "feat: a")
    _checkout(repo, "-b", "feature-b")
    _commit_files(repo, {"b.py": "b\n"}, "feat: b")

    # A stacked branch should target its immediate parent, not main.
    assert resolve_commit_base(repo) == "feature-a"


def test_resolve_commit_base_stacked_parent_after_parent_advances(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True
    )
    _checkout(repo, "-b", "feature-a")
    _commit_files(repo, {"a.py": "a\n"}, "feat: a")
    _checkout(repo, "-b", "feature-b")
    _commit_files(repo, {"b.py": "b\n"}, "feat: b")
    # The parent advances *after* feature-b forked off it, so feature-a is no
    # longer an ancestor of HEAD (a bare `--merged HEAD` fast-path would miss it
    # and wrongly fall back to main). feature-a..HEAD = 1 ahead / 1 behind still
    # beats main..HEAD = 2 ahead / 0 behind on the ahead count.
    _checkout(repo, "feature-a")
    _commit_files(repo, {"a2.py": "a2\n"}, "feat: a more")
    _checkout(repo, "feature-b")

    assert resolve_commit_base(repo) == "feature-a"


def test_resolve_commit_base_honors_override(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True
    )
    _checkout(repo, "-b", "feature")
    _commit_files(repo, {"a.py": "1\n"}, "feat: a")

    assert resolve_commit_base(repo, override="HEAD~1") == "HEAD~1"


def test_resolve_commit_base_prefers_pr_cache_base(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True
    )
    # dev and main point at the same commit, so closest-base ties and main wins.
    subprocess.run(["git", "branch", "dev"], cwd=repo, check=True)
    _checkout(repo, "-b", "feature")
    _commit_files(repo, {"a.py": "1\n"}, "feat: a")

    git_dir = get_git_dir(repo)
    # Simulate a prior `git-ai pr --base dev` on this branch.
    branch_cache_dir(git_dir, "feature", "dev").mkdir(parents=True)

    assert resolve_commit_base(repo, git_dir=git_dir, branch="feature") == "dev"


def test_emit_branch_context_honors_env_base(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _init_repo(repo)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True
    )
    _checkout(repo, "-b", "feature")
    _commit_files(repo, {"a.py": "1\n"}, "feat: a")
    _commit_files(repo, {"b.py": "2\n"}, "feat: b")

    # Auto-resolution would pick main (both commits ahead). GIT_AI_COMMIT_BASE
    # is honored even without --base, narrowing the base to HEAD~1 so only the
    # most recent commit is in scope.
    monkeypatch.setenv("GIT_AI_COMMIT_BASE", "HEAD~1")
    _emit_branch_context(str(repo), None)

    block = capsys.readouterr().out
    assert "<branch>feature</branch>" in block
    assert "feat: b" in block
    assert "feat: a" not in block
