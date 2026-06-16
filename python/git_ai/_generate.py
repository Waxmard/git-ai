"""Prompt builders and response parsers for commit + MR generation.

git_ai is **provider-agnostic**: it owns prompt assembly, diff-stat derivation,
and output cleanup but never calls an LLM. Consumers wire their own model
call between :func:`build_commit_prompt` / :func:`build_mr_prompt` and
:func:`parse_commit_response` / :func:`parse_mr_response`.
"""

from __future__ import annotations

import os
import re
from pathlib import Path

from ._git import (
    DEFAULT_RELEASE_CONTEXT,
    derive_diff_stat,
    largest_diff_files,
)
from ._git_branch import format_branch_context
from ._instructions import format_repo_guidance
from ._pr_prompt_build import build_mr_prompt_input

_PROMPTS_DIR = Path(__file__).parent / "prompts"
_DEFAULT_MAX_DIFF_BYTES = 900_000


def _max_diff_bytes() -> int:
    raw = os.environ.get("GIT_AI_MAX_DIFF_BYTES")
    if raw is None:
        return _DEFAULT_MAX_DIFF_BYTES
    try:
        return int(raw)
    except ValueError:
        return _DEFAULT_MAX_DIFF_BYTES


def _check_diff_size(diff: str) -> None:
    limit = _max_diff_bytes()
    if limit <= 0:
        return
    size = len(diff.encode("utf-8"))
    if size <= limit:
        return
    top = largest_diff_files(diff, 5)
    lines = [
        f"git-ai: diff is {size} bytes, exceeds limit ({limit}).",
        "Largest changed files:",
    ]
    for path, ins, dels in top:
        lines.append(f"   {ins + dels:>6} lines  {path}")
    lines.append(
        "Add patterns to .git-ai-ignore (repo root) to skip them, "
        "unstage them, or raise GIT_AI_MAX_DIFF_BYTES."
    )
    raise RuntimeError("\n".join(lines))


def _load_prompt(name: str) -> str:
    return (_PROMPTS_DIR / name).read_text(encoding="utf-8").rstrip()


def strip_fences(text: str) -> str:
    """Remove markdown code fences and trim whitespace."""
    text = re.sub(r"^[ \t]*```.*\n", "", text, flags=re.MULTILINE)
    text = re.sub(r"^[ \t]*`+[ \t]*$\n?", "", text, flags=re.MULTILINE)
    text = text.strip()
    # Unwrap a subject line the model wrapped in an inline code span, e.g.
    # "`feat: add x`" -> "feat: add x". Only when the whole first line is a
    # single span (no internal backticks), so code spans in a body survive.
    lines = text.split("\n")
    if lines:
        m = re.fullmatch(r"[ \t]*(`+)([^`]+)\1[ \t]*", lines[0])
        if m:
            lines[0] = m.group(2).strip()
    return "\n".join(lines).strip()


def build_commit_prompt(
    diff: str,
    *,
    release_context: str | None = None,
    branch_name: str | None = None,
    branch_commits: str | None = None,
    branch_diffstat: str | None = None,
    repo_guidance: str | None = None,
) -> tuple[str, str]:
    """Build the (system_prompt, user_input) pair for commit-message generation.

    Args:
        diff: Unified diff string (e.g. ``git diff --staged`` output).
        release_context: Optional release-context blurb. Defaults to a generic
            "no release tags found" string.
        branch_name: Current branch name. Surfaced so the model can pick the
            commit prefix from the perspective of the whole branch.
        branch_commits: Newline-separated subjects of the commits already on
            this branch since its base (most recent first).
        branch_diffstat: ``git diff --stat`` of the whole branch vs its base.
        repo_guidance: Free-form repo-local conventions (commit scopes,
            type-classification overrides) from ``.git-ai-instructions``.
            Surfaced as an authoritative ``<repo_guidance>`` block.

    The branch_* values describe the branch's overall purpose; the prompt uses
    them only to disambiguate the prefix when the staged diff alone is
    ambiguous. Any branch tag whose value is empty is omitted.

    Returns:
        ``(system_prompt, user_input)`` — feed both to your LLM, then run the
        raw response through :func:`parse_commit_response`.

    Raises:
        ValueError: if ``diff`` is empty.
        RuntimeError: if the diff exceeds ``GIT_AI_MAX_DIFF_BYTES``.
    """
    if not diff.strip():
        raise ValueError("diff is empty")

    _check_diff_size(diff)

    if release_context is None:
        release_context = DEFAULT_RELEASE_CONTEXT

    parts = []
    guidance_block = format_repo_guidance(repo_guidance)
    if guidance_block:
        parts.append(guidance_block)
    parts.append(f"<release_context>{release_context}</release_context>")
    branch_block = format_branch_context(
        branch_name=branch_name,
        branch_commits=branch_commits,
        branch_diffstat=branch_diffstat,
    )
    if branch_block:
        parts.append(branch_block)
    parts.append(f"<diff>\n{diff}\n</diff>")

    return _load_prompt("commit.txt"), "\n\n".join(parts)


def build_mr_prompt(
    *,
    diff: str,
    commit_log: str | None = None,
    diff_stat: str | None = None,
    release_context: str | None = None,
    existing_pr: str | None = None,
    churn_subjects: set[str] | None = None,
    repo_guidance: str | None = None,
) -> tuple[str, str]:
    """Build the (system_prompt, user_input) pair for MR/PR generation.

    Selects the two-pass or fallback prompt template based on whether the
    supplied ``commit_log`` is mostly Conventional Commits, and an
    update-flavoured variant when ``existing_pr`` is supplied.

    Args:
        diff: Unified diff string (e.g. ``git diff base...HEAD`` output).
        commit_log: Commits log in ``GITAI_COMMIT``-prefixed form
            (see :func:`format_commit_log`). Optional.
        diff_stat: Pre-computed diff stat. Derived from ``diff`` when omitted.
        release_context: Optional release-context blurb.
        existing_pr: Prior PR text to refine against. When supplied, the
            update-flavoured prompt variant is selected.
        churn_subjects: Subjects of commits that only refine code introduced
            earlier in this same branch. Folded in the two-pass draft instead
            of emitted as standalone sections. Optional.
        repo_guidance: Free-form repo-local conventions from
            ``.git-ai-instructions``, surfaced as a ``<repo_guidance>`` block.

    Returns:
        ``(system_prompt, user_input)`` — feed both to your LLM, then run the
        raw response through :func:`parse_mr_response`.

    Raises:
        ValueError: if ``diff`` is empty.
        RuntimeError: if the diff exceeds ``GIT_AI_MAX_DIFF_BYTES``.
    """
    if not diff.strip():
        raise ValueError("diff is empty")
    _check_diff_size(diff)
    if release_context is None:
        release_context = DEFAULT_RELEASE_CONTEXT
    if diff_stat is None:
        diff_stat = derive_diff_stat(diff)

    prompt_name, user_input = build_mr_prompt_input(
        diff=diff,
        commit_log=commit_log,
        diff_stat=diff_stat,
        release_context=release_context,
        existing_pr=existing_pr,
        churn_subjects=churn_subjects,
        repo_guidance=repo_guidance,
    )
    return _load_prompt(prompt_name), user_input


def _parse_response(raw: str) -> str:
    text = strip_fences((raw or "").strip())
    if not text:
        raise RuntimeError("LLM returned an empty response")
    return text


_PR_TITLE_MARKER = "===TITLE==="
_PR_BODY_MARKER = "===BODY==="


def _marker_index(lines: list[str], marker: str) -> int:
    for i, line in enumerate(lines):
        if line.strip() == marker:
            return i
    return -1


def _extract_pr_sections(text: str) -> str:
    """Slice title/body out of sentinel-delimited PR output.

    The PR prompts wrap output in ``===TITLE===`` / ``===BODY===`` line
    markers so any preamble, reasoning, or char-count chatter the model
    emits outside the markers is discarded. Returns ``title\\n\\nbody``.
    Falls back to ``text`` unchanged when the markers are absent or
    malformed (older or non-compliant models).
    """
    lines = text.split("\n")
    t_idx = _marker_index(lines, _PR_TITLE_MARKER)
    b_idx = _marker_index(lines, _PR_BODY_MARKER)
    if t_idx < 0 or b_idx < 0 or t_idx >= b_idx:
        return text
    title = "\n".join(lines[t_idx + 1 : b_idx]).strip()
    if not title:
        return text
    body = "\n".join(lines[b_idx + 1 :]).strip()
    return f"{title}\n\n{body}" if body else title


def parse_commit_response(raw: str) -> str:
    """Strip markdown fences from a commit-message response and validate non-empty.

    Raises:
        RuntimeError: if the cleaned response is empty.
    """
    return _parse_response(raw)


def parse_mr_response(raw: str) -> str:
    """Parse an MR/PR response: strip fences, slice sentinel sections, validate.

    Unwraps the ``===TITLE===`` / ``===BODY===`` markers the PR prompts
    emit (discarding any out-of-band preamble); falls back to the
    fence-stripped text when the markers are absent.

    Raises:
        RuntimeError: if the cleaned response is empty.
    """
    return _extract_pr_sections(_parse_response(raw))
