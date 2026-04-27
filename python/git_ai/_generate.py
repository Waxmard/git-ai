"""Core generation functions for commit messages and MR descriptions.

git_ai handles prompt assembly, diff-stat derivation, cache management, and
output styling. It is **provider-agnostic**: callers supply a ``generate``
callable that does the actual LLM call, so git_ai carries no LLM SDK deps.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from ._git import (
    DEFAULT_RELEASE_CONTEXT,
    check_git_repo,
    derive_diff_stat,
    get_git_dir,
    get_release_context,
    get_staged_diff,
    largest_diff_files,
)
from ._ignore import load_ignore_patterns
from ._pr_incremental import prepare_repo_pr_context, save_cached_pr
from ._pr_prompt_build import build_mr_prompt_input
from ._pr_render import render_pr_diff

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


Completion = Callable[[str, str], str]
"""Consumer-supplied LLM call: ``(system_prompt, user_input) -> raw text``."""


@dataclass(frozen=True)
class MrDescription:
    """Result of :func:`generate_mr_description`.

    ``text`` is the full generated PR (first line is the title, remainder is
    the body). ``diff`` is a plain-text rendering (via
    :func:`git_ai.render_pr_diff`) of the delta between ``existing_pr`` and
    ``text``, using ``~ ``/``+ ``/``- `` markers. It is ``None`` when no
    ``existing_pr`` was supplied or when the regenerated PR is unchanged.
    """

    text: str
    diff: str | None


def _load_prompt(name: str) -> str:
    return (_PROMPTS_DIR / name).read_text(encoding="utf-8").rstrip()


def _strip_fences(text: str) -> str:
    """Remove markdown code fences and trim whitespace."""
    text = re.sub(r"^[ \t]*```.*\n", "", text, flags=re.MULTILINE)
    text = re.sub(r"^[ \t]*`+[ \t]*$\n?", "", text, flags=re.MULTILINE)
    return text.strip()


def _invoke(generate: Completion, system_prompt: str, user_input: str) -> str:
    """Call the consumer's ``generate`` fn, strip fences, reject empty."""
    raw = generate(system_prompt, user_input)
    text = _strip_fences((raw or "").strip())
    if not text:
        raise RuntimeError("generate() returned an empty response")
    return text


def generate_commit_message_from_diff(
    diff: str,
    *,
    generate: Completion,
    release_context: str | None = None,
) -> str:
    """Generate a Conventional Commits message from a raw unified diff.

    Args:
        diff: Unified diff string (as produced by ``git diff`` or a comparable
            source such as GitLab's MR diff API).
        generate: Consumer-supplied ``(system_prompt, user_input) -> str``
            function. git_ai builds the prompts and lets the caller own the
            LLM call.
        release_context: Optional release-context blurb. Defaults to a generic
            "no release tags found" string.

    Returns:
        Generated commit message string.

    Raises:
        ValueError: if ``diff`` is empty.
        RuntimeError: if ``generate`` returns an empty string.
    """
    if not diff.strip():
        raise ValueError("diff is empty")

    _check_diff_size(diff)

    if release_context is None:
        release_context = DEFAULT_RELEASE_CONTEXT

    user_input = (
        f"<release_context>{release_context}</release_context>\n\n"
        f"<diff>\n{diff}\n</diff>"
    )
    return _invoke(generate, _load_prompt("commit.txt"), user_input)


def generate_commit_message(
    repo_path: str | Path = ".",
    *,
    generate: Completion,
) -> str:
    """Generate a Conventional Commits commit message for staged changes.

    Args:
        repo_path: Path to the git repository.
        generate: Consumer-supplied ``(system_prompt, user_input) -> str``.

    Returns:
        Generated commit message string.

    Raises:
        RuntimeError: if not in a git repo or nothing is staged, or the
            consumer's ``generate`` returns empty.
    """
    repo_path = Path(repo_path)
    check_git_repo(repo_path)
    patterns = load_ignore_patterns(repo_path)

    return generate_commit_message_from_diff(
        get_staged_diff(repo_path, exclude_patterns=patterns),
        generate=generate,
        release_context=get_release_context(repo_path),
    )


def _generate_mr_text(
    *,
    generate: Completion,
    diff: str,
    commit_log: str | None,
    diff_stat: str | None,
    release_context: str | None,
    existing_pr: str | None,
) -> str:
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
    )
    return _invoke(generate, _load_prompt(prompt_name), user_input)


def _build_mr_result(text: str, existing_pr: str | None) -> MrDescription:
    if not existing_pr:
        return MrDescription(text=text, diff=None)
    rendered = render_pr_diff(existing_pr, text, color=False)
    return MrDescription(text=text, diff=rendered or None)


def generate_mr_description(
    repo_path: str | Path | None = None,
    base_branch: str = "main",
    *,
    generate: Completion,
    diff: str | None = None,
    commit_log: str | None = None,
    diff_stat: str | None = None,
    release_context: str | None = None,
    existing_pr: str | None = None,
    fresh: bool = False,
    previous_head_sha: str | None = None,
) -> MrDescription:
    """Generate a PR/MR title and description.

    Two invocation styles share this entry point:

    * **Repo-mode** — pass ``repo_path`` pointing at a local git checkout.
      ``diff``/``commit_log``/``diff_stat``/``release_context`` are derived
      from git, and output is cached under ``.git/pr-cache/``. ``fresh`` and
      ``previous_head_sha`` control the incremental cache behaviour.
    * **Data-mode** — pass ``diff`` directly (plus optional ``commit_log``,
      ``diff_stat``, ``release_context``, ``existing_pr``) when you already
      have the MR payload in hand and have no local checkout. No caching is
      performed; persistence is the caller's responsibility.

    ``generate`` is the consumer-supplied ``(system_prompt, user_input) ->
    str`` callable. git_ai is provider-agnostic — bring your own LLM.

    Returns an :class:`MrDescription` with the full PR text plus, when an
    ``existing_pr`` is available (directly or via cache), a plain-text
    marker-style rendering of what changed between old and new PRs.

    Raises:
        ValueError: if neither or both of ``repo_path`` and ``diff`` are
            supplied, or if ``diff`` is empty in data-mode.
        RuntimeError: if ``generate`` returns an empty string or — in
            repo-mode — the repo has no commits ahead of ``base_branch``.
    """
    if repo_path is not None and diff is not None:
        raise ValueError(
            "Pass either repo_path (repo-mode) or diff (data-mode), not both"
        )
    if repo_path is None and diff is None:
        raise ValueError("Provide repo_path (repo-mode) or diff (data-mode)")

    if repo_path is not None:
        repo_path = Path(repo_path)
        context = prepare_repo_pr_context(
            repo_path,
            base_branch=base_branch,
            existing_pr=existing_pr,
            previous_head_sha=previous_head_sha,
            fresh=fresh,
        )
        if context.no_changes:
            return MrDescription(text=context.existing_pr or "", diff=None)

        text = _generate_mr_text(
            generate=generate,
            diff=context.diff,
            commit_log=context.commit_log,
            diff_stat=context.diff_stat,
            release_context=context.release_context,
            existing_pr=context.existing_pr,
        )
        if context.current_branch:
            save_cached_pr(
                get_git_dir(repo_path),
                context.current_branch,
                base_branch,
                text,
                context.head_sha,
            )
        return _build_mr_result(text, context.existing_pr)

    assert diff is not None
    text = _generate_mr_text(
        generate=generate,
        diff=diff,
        commit_log=commit_log,
        diff_stat=diff_stat,
        release_context=release_context,
        existing_pr=existing_pr,
    )
    return _build_mr_result(text, existing_pr)
