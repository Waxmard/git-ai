"""Core generation functions for commit messages and MR descriptions."""
from __future__ import annotations

import re
from pathlib import Path

from google import genai
from google.genai import errors as genai_errors
from google.genai import types

from ._gemini import COMMIT_MODEL, MR_MODEL, create_gemini_client
from ._git import (
    DEFAULT_RELEASE_CONTEXT,
    check_git_repo,
    derive_diff_stat,
    get_git_dir,
    get_release_context,
    get_staged_diff,
)
from ._pr_incremental import prepare_repo_pr_context, save_cached_pr
from ._pr_prompt_build import build_mr_prompt_input

_PROMPTS_DIR = Path(__file__).parent / "prompts"


def _load_prompt(name: str) -> str:
    return (_PROMPTS_DIR / name).read_text(encoding="utf-8").rstrip()


def _strip_fences(text: str) -> str:
    """Remove markdown code fences and trim whitespace."""
    text = re.sub(r"^[ \t]*```.*\n", "", text, flags=re.MULTILINE)
    text = re.sub(r"^[ \t]*`+[ \t]*$\n?", "", text, flags=re.MULTILINE)
    return text.strip()


def _format_api_error(exc: genai_errors.APIError) -> str:
    code = getattr(exc, "code", None)
    message = getattr(exc, "message", None) or str(exc)
    if code in (401, 403):
        return (
            "Gemini auth rejected. Check GEMINI_API_KEY or application-default "
            f"credentials. ({message})"
        )
    if code == 429:
        return f"Gemini rate-limited. Try again shortly. ({message})"
    if isinstance(code, int) and 500 <= code < 600:
        return f"Gemini server error ({code}). Try again. ({message})"
    return f"Gemini API error ({code}): {message}"


def _safety_reason(response: types.GenerateContentResponse) -> str | None:
    prompt_feedback = getattr(response, "prompt_feedback", None)
    if prompt_feedback is not None:
        block_reason = getattr(prompt_feedback, "block_reason", None)
        if block_reason:
            name = getattr(block_reason, "name", None) or str(block_reason)
            return f"prompt blocked: {name}"

    for candidate in getattr(response, "candidates", None) or []:
        finish_reason = getattr(candidate, "finish_reason", None)
        if finish_reason and finish_reason != types.FinishReason.STOP:
            name = getattr(finish_reason, "name", None) or str(finish_reason)
            return name
    return None


def _call_gemini(
    client: genai.Client, model: str, system_prompt: str, user_input: str
) -> str:
    """Call Gemini and return stripped text output."""
    try:
        response = client.models.generate_content(
            model=model,
            contents=user_input,
            config=types.GenerateContentConfig(
                system_instruction=system_prompt,
            ),
        )
    except genai_errors.APIError as e:
        raise RuntimeError(_format_api_error(e)) from e
    except Exception as e:
        raise RuntimeError(f"Gemini call failed: {e}") from e

    text = (response.text or "").strip()
    if not text:
        reason = _safety_reason(response)
        if reason:
            raise RuntimeError(f"Gemini blocked the response ({reason})")
        raise RuntimeError("Gemini returned an empty response")
    return _strip_fences(text)


def generate_commit_message_from_diff(
    diff: str,
    *,
    release_context: str | None = None,
    client: genai.Client | None = None,
    model: str | None = None,
) -> str:
    """Generate a Conventional Commits message from a raw unified diff.

    Args:
        diff: Unified diff string (as produced by ``git diff`` or a comparable
            source such as GitLab's MR diff API).
        release_context: Optional release-context blurb (e.g. ``"Release
            context: current version v1.2.3, 5 commits since"``). Defaults to
            a generic "no release tags found" string.
        client: Gemini client. If ``None``, ``create_gemini_client()`` is used.
        model: Gemini model ID. Defaults to :data:`COMMIT_MODEL`.

    Returns:
        Generated commit message string.

    Raises:
        ValueError: if ``diff`` is empty or auth is not configured.
        RuntimeError: if the Gemini call fails or returns empty.
    """
    if not diff.strip():
        raise ValueError("diff is empty")

    if client is None:
        client = create_gemini_client()
    if model is None:
        model = COMMIT_MODEL
    if release_context is None:
        release_context = DEFAULT_RELEASE_CONTEXT

    user_input = (
        f"<release_context>{release_context}</release_context>\n\n"
        f"<diff>\n{diff}\n</diff>"
    )
    prompt = _load_prompt("commit.txt")
    return _call_gemini(client, model, prompt, user_input)


def generate_commit_message(
    repo_path: str | Path = ".",
    client: genai.Client | None = None,
    model: str | None = None,
) -> str:
    """Generate a Conventional Commits commit message for staged changes.

    Args:
        repo_path: Path to the git repository.
        client: Gemini client. If None, create_gemini_client() is called.
        model: Gemini model ID. Defaults to COMMIT_MODEL (flash-lite).

    Returns:
        Generated commit message string.

    Raises:
        RuntimeError: if not in a git repo or nothing is staged.
        ValueError: if auth is not configured and client is None.
    """
    repo_path = Path(repo_path)
    check_git_repo(repo_path)

    staged_diff = get_staged_diff(repo_path)
    release_context = get_release_context(repo_path)

    return generate_commit_message_from_diff(
        staged_diff,
        release_context=release_context,
        client=client,
        model=model,
    )


def generate_mr_description_from_data(
    *,
    diff: str,
    commit_log: str | None = None,
    diff_stat: str | None = None,
    release_context: str | None = None,
    existing_pr: str | None = None,
    client: genai.Client | None = None,
    model: str | None = None,
) -> str:
    """Generate a PR/MR title and description from pre-fetched git data.

    Args:
        diff: Unified diff between base and HEAD.
        commit_log: Commit log in ``GITAI_COMMIT <subject>\\n<body>\\n`` format
            (see :func:`format_commit_log`). If ``None`` or empty, the
            two-pass path is skipped and the fallback prompt is used.
        diff_stat: Pre-computed diff stat. If ``None``, it is derived from
            ``diff`` via :func:`derive_diff_stat`.
        release_context: Optional release-context blurb. Defaults to a generic
            "no release tags found" string.
        existing_pr: Existing PR text for incremental updates (preserves
            wording).
        client: Gemini client. If ``None``, ``create_gemini_client()`` is used.
        model: Gemini model ID. Defaults to :data:`MR_MODEL`.

    Returns:
        Generated PR text — first line is the title, remainder is the body.

    Raises:
        ValueError: if ``diff`` is empty or auth is not configured.
        RuntimeError: if the Gemini call fails or returns empty.
    """
    if not diff.strip():
        raise ValueError("diff is empty")

    if client is None:
        client = create_gemini_client()
    if model is None:
        model = MR_MODEL
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
    prompt = _load_prompt(prompt_name)
    return _call_gemini(client, model, prompt, user_input)


def generate_mr_description(
    repo_path: str | Path = ".",
    base_branch: str = "main",
    client: genai.Client | None = None,
    existing_pr: str | None = None,
    fresh: bool = False,
    previous_head_sha: str | None = None,
    model: str | None = None,
) -> str:
    """Generate a PR/MR title and description.

    Args:
        repo_path: Path to the git repository.
        base_branch: Branch to compare against.
        client: Gemini client. If None, create_gemini_client() is called.
        existing_pr: Existing PR text for incremental updates (preserves wording).
        fresh: Ignore cached repo-mode state and regenerate from base_branch.
        previous_head_sha: Explicit prior generated HEAD SHA to update from.
        model: Gemini model ID. Defaults to MR_MODEL (pro).

    Returns:
        Generated PR text — first line is the title, remainder is the body.

    Raises:
        RuntimeError: if not in a git repo or no commits ahead of base_branch.
        ValueError: if auth is not configured and client is None.
    """
    repo_path = Path(repo_path)
    context = prepare_repo_pr_context(
        repo_path,
        base_branch=base_branch,
        existing_pr=existing_pr,
        previous_head_sha=previous_head_sha,
        fresh=fresh,
    )
    if context.no_changes:
        return context.existing_pr or ""

    output = generate_mr_description_from_data(
        diff=context.diff,
        commit_log=context.commit_log,
        diff_stat=context.diff_stat,
        release_context=context.release_context,
        existing_pr=context.existing_pr,
        client=client,
        model=model,
    )
    if context.current_branch:
        save_cached_pr(
            get_git_dir(repo_path),
            context.current_branch,
            base_branch,
            output,
            context.head_sha,
        )
    return output
