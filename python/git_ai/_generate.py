"""Core generation functions for commit messages and MR descriptions."""
from __future__ import annotations

import re
from dataclasses import dataclass
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
from ._pr_render import render_pr_diff

_PROMPTS_DIR = Path(__file__).parent / "prompts"


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


def _generate_mr_text(
    *,
    diff: str,
    commit_log: str | None,
    diff_stat: str | None,
    release_context: str | None,
    existing_pr: str | None,
    client: genai.Client | None,
    model: str | None,
) -> str:
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


def _build_mr_result(text: str, existing_pr: str | None) -> MrDescription:
    if not existing_pr:
        return MrDescription(text=text, diff=None)
    rendered = render_pr_diff(existing_pr, text, color=False)
    return MrDescription(text=text, diff=rendered or None)


def generate_mr_description(
    repo_path: str | Path | None = None,
    base_branch: str = "main",
    *,
    diff: str | None = None,
    commit_log: str | None = None,
    diff_stat: str | None = None,
    release_context: str | None = None,
    existing_pr: str | None = None,
    fresh: bool = False,
    previous_head_sha: str | None = None,
    client: genai.Client | None = None,
    model: str | None = None,
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

    Returns an :class:`MrDescription` with the full PR text plus, when an
    ``existing_pr`` is available (directly or via cache), a plain-text
    marker-style rendering of what changed between old and new PRs.

    Raises:
        ValueError: if neither or both of ``repo_path`` and ``diff`` are
            supplied, or if ``diff`` is empty in data-mode.
        RuntimeError: if the Gemini call fails, returns empty, or — in
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
                text,
                context.head_sha,
            )
        return _build_mr_result(text, context.existing_pr)

    assert diff is not None
    text = _generate_mr_text(
        diff=diff,
        commit_log=commit_log,
        diff_stat=diff_stat,
        release_context=release_context,
        existing_pr=existing_pr,
        client=client,
        model=model,
    )
    return _build_mr_result(text, existing_pr)
