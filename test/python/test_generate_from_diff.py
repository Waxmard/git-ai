"""Tests for diff-string generate entry points and supporting helpers."""
from __future__ import annotations

from types import SimpleNamespace
from typing import Any
from unittest.mock import MagicMock

import pytest

from git_ai import (
    COMMIT_MODEL,
    MR_MODEL,
    MrDescription,
    derive_diff_stat,
    format_commit_log,
    generate_commit_message_from_diff,
    generate_mr_description,
)

_SAMPLE_DIFF = """\
diff --git a/foo.py b/foo.py
index aaa..bbb 100644
--- a/foo.py
+++ b/foo.py
@@ -1,3 +1,4 @@
 def f():
-    return 1
+    return 2
+    # trailing
diff --git a/bar.md b/bar.md
index ccc..ddd 100644
--- a/bar.md
+++ b/bar.md
@@ -1 +1,2 @@
-old
+new
+extra
"""


def _client_returning(text: str) -> MagicMock:
    response = SimpleNamespace(text=text, candidates=[], prompt_feedback=None)
    client = MagicMock()
    client.models.generate_content.return_value = response
    return client


def _capture_call(client: MagicMock) -> dict[str, Any]:
    """Return kwargs from the single generate_content call."""
    assert client.models.generate_content.call_count == 1
    _, kwargs = client.models.generate_content.call_args
    return dict(kwargs)


# ---------------------------------------------------------------------------
# format_commit_log
# ---------------------------------------------------------------------------


def test_format_commit_log_empty() -> None:
    assert format_commit_log([]) == ""


def test_format_commit_log_subjects_only() -> None:
    log = format_commit_log([("feat: a", ""), ("fix: b", "")])
    assert log == "GITAI_COMMIT feat: a\nGITAI_COMMIT fix: b\n"


def test_format_commit_log_with_bodies() -> None:
    log = format_commit_log([("feat: a", "body line 1\nbody line 2"), ("fix: b", "")])
    assert log == (
        "GITAI_COMMIT feat: a\n"
        "body line 1\n"
        "body line 2\n"
        "GITAI_COMMIT fix: b\n"
    )


# ---------------------------------------------------------------------------
# derive_diff_stat
# ---------------------------------------------------------------------------


def test_derive_diff_stat_empty_input() -> None:
    assert derive_diff_stat("") == ""


def test_derive_diff_stat_counts_per_file() -> None:
    stat = derive_diff_stat(_SAMPLE_DIFF)
    lines = stat.splitlines()
    assert any("foo.py" in line and " 3 " in line for line in lines[:-1])
    assert any("bar.md" in line and " 3 " in line for line in lines[:-1])
    assert (
        lines[-1] == " 2 files changed, 4 insertions(+), 2 deletions(-)"
    )


def test_derive_diff_stat_binary_file() -> None:
    diff = (
        "diff --git a/img.png b/img.png\n"
        "index aaa..bbb 100644\n"
        "Binary files a/img.png and b/img.png differ\n"
    )
    stat = derive_diff_stat(diff)
    assert "img.png" in stat
    assert "Bin" in stat
    assert "1 file changed" in stat


def test_derive_diff_stat_skips_header_lines() -> None:
    """+++/--- header lines are not counted as insertions/deletions."""
    diff = (
        "diff --git a/x.txt b/x.txt\n"
        "--- a/x.txt\n"
        "+++ b/x.txt\n"
        "@@ -1 +1 @@\n"
        "-old\n"
        "+new\n"
    )
    stat = derive_diff_stat(diff)
    assert "1 insertion(+)" in stat
    assert "1 deletion(-)" in stat


# ---------------------------------------------------------------------------
# generate_commit_message_from_diff
# ---------------------------------------------------------------------------


def test_commit_from_diff_uses_commit_model_by_default() -> None:
    client = _client_returning("feat: do thing")
    result = generate_commit_message_from_diff(_SAMPLE_DIFF, client=client)
    assert result == "feat: do thing"
    assert _capture_call(client)["model"] == COMMIT_MODEL


def test_commit_from_diff_rejects_empty_diff() -> None:
    client = _client_returning("unused")
    with pytest.raises(ValueError, match="diff is empty"):
        generate_commit_message_from_diff("   \n", client=client)
    client.models.generate_content.assert_not_called()


def test_commit_from_diff_includes_release_context_and_diff() -> None:
    client = _client_returning("feat: x")
    generate_commit_message_from_diff(
        _SAMPLE_DIFF, release_context="Release context: v1.0.0", client=client
    )
    kwargs = _capture_call(client)
    assert "<release_context>Release context: v1.0.0</release_context>" in kwargs["contents"]
    assert "<diff>" in kwargs["contents"]
    assert "foo.py" in kwargs["contents"]


def test_commit_from_diff_defaults_release_context() -> None:
    client = _client_returning("feat: x")
    generate_commit_message_from_diff(_SAMPLE_DIFF, client=client)
    kwargs = _capture_call(client)
    assert "no release tags found" in kwargs["contents"]


def test_commit_from_diff_respects_model_override() -> None:
    client = _client_returning("feat: x")
    generate_commit_message_from_diff(_SAMPLE_DIFF, client=client, model="custom-model")
    assert _capture_call(client)["model"] == "custom-model"


# ---------------------------------------------------------------------------
# generate_mr_description — data-mode
# ---------------------------------------------------------------------------


_CONVENTIONAL_LOG = (
    "GITAI_COMMIT feat: add login\n"
    "GITAI_COMMIT fix: correct null pointer\n"
    "GITAI_COMMIT chore: bump deps\n"
)

_NON_CONVENTIONAL_LOG = (
    "GITAI_COMMIT WIP: half done\n"
    "GITAI_COMMIT random update\n"
)


def test_mr_data_mode_uses_mr_model_by_default() -> None:
    client = _client_returning("feat: x\n\n### Features\n- x")
    result = generate_mr_description(diff=_SAMPLE_DIFF, client=client)
    assert isinstance(result, MrDescription)
    assert "feat: x" in result.text
    assert result.diff is None
    assert _capture_call(client)["model"] == MR_MODEL


def test_mr_data_mode_rejects_empty_diff() -> None:
    client = _client_returning("unused")
    with pytest.raises(ValueError, match="diff is empty"):
        generate_mr_description(diff="", client=client)
    client.models.generate_content.assert_not_called()


def test_mr_rejects_both_repo_path_and_diff() -> None:
    client = _client_returning("unused")
    with pytest.raises(ValueError, match="not both"):
        generate_mr_description(".", diff=_SAMPLE_DIFF, client=client)
    client.models.generate_content.assert_not_called()


def test_mr_rejects_neither_repo_path_nor_diff() -> None:
    client = _client_returning("unused")
    with pytest.raises(ValueError, match="repo_path.*or diff"):
        generate_mr_description(client=client)
    client.models.generate_content.assert_not_called()


def test_mr_data_mode_two_pass_when_mostly_conventional() -> None:
    client = _client_returning("feat: x")
    generate_mr_description(
        diff=_SAMPLE_DIFF, commit_log=_CONVENTIONAL_LOG, client=client
    )
    contents = _capture_call(client)["contents"]
    # two-pass prompt uses <draft>; fallback uses <commit_log>.
    assert "<draft>" in contents
    assert "<commit_log>" not in contents
    assert "### Features" in contents
    assert "add login" in contents


def test_mr_data_mode_fallback_when_not_conventional() -> None:
    client = _client_returning("chore: x")
    generate_mr_description(
        diff=_SAMPLE_DIFF, commit_log=_NON_CONVENTIONAL_LOG, client=client
    )
    contents = _capture_call(client)["contents"]
    assert "<commit_log>" in contents
    assert "<draft>" not in contents
    # GITAI_COMMIT prefix stripped
    assert "GITAI_COMMIT" not in contents
    assert "WIP: half done" in contents


def test_mr_data_mode_no_log_uses_fallback() -> None:
    client = _client_returning("chore: x")
    generate_mr_description(diff=_SAMPLE_DIFF, client=client)
    contents = _capture_call(client)["contents"]
    assert "<draft>" not in contents
    assert "<commit_log>" in contents


def test_mr_data_mode_existing_pr_picks_update_prompt_and_renders_diff() -> None:
    client = _client_returning("feat: new title\n\n### Features\n- new bullet")
    result = generate_mr_description(
        diff=_SAMPLE_DIFF,
        commit_log=_CONVENTIONAL_LOG,
        existing_pr="feat: old title\n\n### Features\n- old bullet",
        client=client,
    )
    contents = _capture_call(client)["contents"]
    assert "<existing_pr>" in contents
    assert "feat: old title" in contents
    assert result.diff is not None
    # render_pr_diff emits `~ ` / `+ ` / `- ` markers and `@@` hunk headers.
    assert any(marker in result.diff for marker in ("~ ", "+ ", "- ", "@@"))


def test_mr_data_mode_diff_none_when_existing_pr_matches_output() -> None:
    generated = "feat: same\n\n### Features\n- same"
    client = _client_returning(generated)
    result = generate_mr_description(
        diff=_SAMPLE_DIFF, existing_pr=generated, client=client
    )
    assert result.text == generated
    assert result.diff is None


def test_mr_data_mode_derives_diff_stat_when_omitted() -> None:
    client = _client_returning("feat: x")
    generate_mr_description(diff=_SAMPLE_DIFF, client=client)
    contents = _capture_call(client)["contents"]
    assert "<changed_files>" in contents
    # Derived stat should mention at least one changed file from the sample diff.
    assert "foo.py" in contents


def test_mr_data_mode_uses_supplied_diff_stat() -> None:
    client = _client_returning("feat: x")
    generate_mr_description(
        diff=_SAMPLE_DIFF, diff_stat="CUSTOM-STAT", client=client
    )
    contents = _capture_call(client)["contents"]
    assert "CUSTOM-STAT" in contents


def test_mr_data_mode_defaults_release_context() -> None:
    client = _client_returning("feat: x")
    generate_mr_description(diff=_SAMPLE_DIFF, client=client)
    contents = _capture_call(client)["contents"]
    assert "no release tags found" in contents


def test_mr_data_mode_respects_release_context_override() -> None:
    client = _client_returning("feat: x")
    generate_mr_description(
        diff=_SAMPLE_DIFF, release_context="Release context: v2.0.0", client=client
    )
    contents = _capture_call(client)["contents"]
    assert "Release context: v2.0.0" in contents
