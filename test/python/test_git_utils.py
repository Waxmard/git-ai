"""Tests for pure git utility functions in _git.py."""

import subprocess
import sys
from pathlib import Path

from git_ai import get_diff, get_diff_stat, get_staged_diff
from git_ai._git import build_draft_body, count_conventional_commits, largest_diff_files

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
