"""Lightweight PR prompt selection and input assembly helpers."""

from __future__ import annotations

import importlib
import sys
from pathlib import Path
from typing import TYPE_CHECKING, Literal

if TYPE_CHECKING:
    from ._git import (
        DEFAULT_RELEASE_CONTEXT,
        count_conventional_commits,
        derive_diff_stat,
    )
    from ._instructions import format_repo_guidance
    from ._pr_draft import analyze
elif __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    _git = importlib.import_module("_git")
    _instructions = importlib.import_module("_instructions")
    _pr_draft = importlib.import_module("_pr_draft")
    DEFAULT_RELEASE_CONTEXT = _git.DEFAULT_RELEASE_CONTEXT
    count_conventional_commits = _git.count_conventional_commits
    derive_diff_stat = _git.derive_diff_stat
    format_repo_guidance = _instructions.format_repo_guidance
    analyze = _pr_draft.analyze
else:
    from ._git import (
        DEFAULT_RELEASE_CONTEXT,
        count_conventional_commits,
        derive_diff_stat,
    )
    from ._instructions import format_repo_guidance
    from ._pr_draft import analyze


DiffScope = Literal["branch", "since_existing"]
DIFF_SCOPES: tuple[DiffScope, ...] = ("branch", "since_existing")


def build_mr_prompt_input(
    *,
    diff: str,
    commit_log: str | None = None,
    diff_stat: str | None = None,
    release_context: str | None = None,
    existing_pr: str | None = None,
    churn_subjects: set[str] | None = None,
    repo_guidance: str | None = None,
    diff_scope: DiffScope = "since_existing",
) -> tuple[str, str]:
    """Return (prompt_filename, user_input) for MR generation.

    ``churn_subjects`` reach the two-pass draft so those commits fold into the
    feature they refine instead of becoming standalone sections.
    ``repo_guidance`` leads the input as an authoritative block.
    ``diff_scope`` picks the update prompt that matches what ``diff`` spans; see
    :func:`git_ai.build_mr_prompt`.
    """
    if not diff.strip():
        raise ValueError("diff is empty")
    if diff_scope not in DIFF_SCOPES:
        raise ValueError(f"diff_scope must be one of {DIFF_SCOPES}, got {diff_scope!r}")
    if release_context is None:
        release_context = DEFAULT_RELEASE_CONTEXT
    if diff_stat is None:
        diff_stat = derive_diff_stat(diff)

    log = commit_log or ""
    conventional_count, total_count = count_conventional_commits(log)
    two_pass = total_count > 0 and conventional_count * 2 >= total_count
    scope_suffix = "" if diff_scope == "branch" else "-incremental"

    if two_pass:
        draft = analyze(_to_rs_delimited_log(log), churn_subjects).draft_body
        if existing_pr:
            prompt_name = f"pr-two-pass-update{scope_suffix}.txt"
            user_input = (
                f"<existing_pr>\n{existing_pr}\n</existing_pr>\n\n"
                f"<draft>\n{draft}\n</draft>\n"
                f"<changed_files>\n{diff_stat}\n</changed_files>"
            )
        else:
            prompt_name = "pr-two-pass.txt"
            user_input = (
                f"<draft>\n{draft}\n</draft>\n"
                f"<changed_files>\n{diff_stat}\n</changed_files>"
            )
    else:
        clean_log = "\n".join(
            line[len("GITAI_COMMIT ") :] if line.startswith("GITAI_COMMIT ") else line
            for line in log.splitlines()
        )
        # An empty <commit_log> is omitted, not emitted blank: the prompt names
        # the tag as authoritative context, so a present-but-empty one asserts
        # "this branch has no commits" to a caller that merely passed no log.
        log_block = (
            f"<commit_log>\n{clean_log}\n</commit_log>\n" if clean_log.strip() else ""
        )
        body = (
            f"{log_block}"
            f"<changed_files>\n{diff_stat}\n</changed_files>\n"
            f"<diff>\n{diff}\n</diff>"
        )
        if existing_pr:
            prompt_name = f"pr-fallback-update{scope_suffix}.txt"
            user_input = f"<existing_pr>\n{existing_pr}\n</existing_pr>\n\n{body}"
        else:
            prompt_name = "pr-fallback.txt"
            user_input = body

    user_input = f"<release_context>{release_context}</release_context>\n\n{user_input}"
    guidance_block = format_repo_guidance(repo_guidance)
    if guidance_block:
        user_input = f"{guidance_block}\n\n{user_input}"
    return prompt_name, user_input


def _to_rs_delimited_log(log: str) -> str:
    if not log.strip():
        return ""
    blocks: list[str] = []
    current: list[str] = []
    for line in log.splitlines():
        if line.startswith("GITAI_COMMIT "):
            if current:
                blocks.append("\n".join(current))
            current = [line[len("GITAI_COMMIT ") :]]
        else:
            current.append(line)
    if current:
        blocks.append("\n".join(current))
    return "\x1e".join(blocks) + "\x1e"
