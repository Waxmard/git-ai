"""Lightweight PR prompt selection and input assembly helpers."""

from __future__ import annotations

import importlib
import sys
from pathlib import Path
from typing import TYPE_CHECKING

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


def build_mr_prompt_input(
    *,
    diff: str,
    commit_log: str | None = None,
    diff_stat: str | None = None,
    release_context: str | None = None,
    existing_pr: str | None = None,
    churn_subjects: set[str] | None = None,
    repo_guidance: str | None = None,
) -> tuple[str, str]:
    """Return (prompt_filename, user_input) for MR generation.

    ``churn_subjects`` (commit subjects that only refine code introduced earlier
    in the same branch) is forwarded to the two-pass draft so those entries are
    folded rather than emitted as standalone sections. ``repo_guidance``
    (free-form ``.git-ai-instructions`` contents) is surfaced as an
    authoritative ``<repo_guidance>`` block at the top of the input.
    """
    if not diff.strip():
        raise ValueError("diff is empty")
    if release_context is None:
        release_context = DEFAULT_RELEASE_CONTEXT
    if diff_stat is None:
        diff_stat = derive_diff_stat(diff)

    log = commit_log or ""
    conventional_count, total_count = count_conventional_commits(log)
    two_pass = total_count > 0 and conventional_count * 2 >= total_count

    if two_pass:
        draft = analyze(_to_rs_delimited_log(log), churn_subjects).draft_body
        if existing_pr:
            prompt_name = "pr-two-pass-update.txt"
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
        if existing_pr:
            prompt_name = "pr-fallback-update.txt"
            user_input = (
                f"<existing_pr>\n{existing_pr}\n</existing_pr>\n\n"
                f"<commit_log>\n{clean_log}\n</commit_log>\n"
                f"<changed_files>\n{diff_stat}\n</changed_files>\n"
                f"<diff>\n{diff}\n</diff>"
            )
        else:
            prompt_name = "pr-fallback.txt"
            user_input = (
                f"<commit_log>\n{clean_log}\n</commit_log>\n"
                f"<changed_files>\n{diff_stat}\n</changed_files>\n"
                f"<diff>\n{diff}\n</diff>"
            )

    user_input = f"<release_context>{release_context}</release_context>\n\n{user_input}"
    guidance_block = format_repo_guidance(repo_guidance)
    if guidance_block:
        user_input = f"{guidance_block}\n\n{user_input}"
    return prompt_name, user_input


def verbatim_pr_text(
    commit_log: str | None, existing_pr: str | None = None
) -> str | None:
    """Return a ready-made PR body when the branch is one conventional commit.

    A branch with exactly one commit that already follows Conventional Commits
    IS its own best PR summary, so the CLI can emit the commit subject/body
    verbatim and skip the LLM. Returns ``None`` (caller falls back to the normal
    prompt flow) when there are zero/multiple commits, the lone commit is not
    conventional, or an ``existing_pr`` is being refined.
    """
    if existing_pr:
        return None
    log = commit_log or ""
    conventional_count, total_count = count_conventional_commits(log)
    if total_count != 1 or conventional_count != 1:
        return None
    subject = ""
    body_lines: list[str] = []
    for line in log.splitlines():
        if line.startswith("GITAI_COMMIT "):
            subject = line[len("GITAI_COMMIT ") :]
        else:
            body_lines.append(line)
    body = "\n".join(body_lines).strip()
    return f"{subject}\n\n{body}" if body else subject


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
