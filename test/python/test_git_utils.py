"""Tests for pure git utility functions in _git.py."""

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
