"""Core generation functions for commit messages and MR descriptions."""
from __future__ import annotations

import re
from pathlib import Path

from google import genai
from google.genai import errors as genai_errors
from google.genai import types

from ._gemini import COMMIT_MODEL, MR_MODEL
from ._git import (
    build_draft_body,
    check_git_repo,
    count_conventional_commits,
    get_commit_log,
    get_diff,
    get_diff_stat,
    get_mr_release_context,
    get_release_context,
    get_staged_diff,
)

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
    from ._gemini import create_gemini_client

    if client is None:
        client = create_gemini_client()
    if model is None:
        model = COMMIT_MODEL

    repo_path = Path(repo_path)
    check_git_repo(repo_path)

    staged_diff = get_staged_diff(repo_path)
    release_context = get_release_context(repo_path)

    user_input = (
        f"<release_context>{release_context}</release_context>\n\n"
        f"<diff>\n{staged_diff}\n</diff>"
    )

    prompt = _load_prompt("commit.txt")
    return _call_gemini(client, model, prompt, user_input)


def generate_mr_description(
    repo_path: str | Path = ".",
    base_branch: str = "main",
    client: genai.Client | None = None,
    existing_pr: str | None = None,
    model: str | None = None,
) -> str:
    """Generate a PR/MR title and description.

    Args:
        repo_path: Path to the git repository.
        base_branch: Branch to compare against.
        client: Gemini client. If None, create_gemini_client() is called.
        existing_pr: Existing PR text for incremental updates (preserves wording).
        model: Gemini model ID. Defaults to MR_MODEL (pro).

    Returns:
        Generated PR text — first line is the title, remainder is the body.

    Raises:
        RuntimeError: if not in a git repo or no commits ahead of base_branch.
        ValueError: if auth is not configured and client is None.
    """
    from ._gemini import create_gemini_client

    if client is None:
        client = create_gemini_client()
    if model is None:
        model = MR_MODEL

    repo_path = Path(repo_path)
    check_git_repo(repo_path)

    log = get_commit_log(repo_path, base_branch)
    if not log.strip():
        raise RuntimeError(f"No commits ahead of {base_branch}")

    conventional_count, total_count = count_conventional_commits(log)
    two_pass = total_count > 0 and conventional_count * 2 >= total_count

    diff_stat = get_diff_stat(repo_path, base_branch)

    if two_pass:
        draft = build_draft_body(log)
        if existing_pr:
            prompt = _load_prompt("pr-two-pass-update.txt")
            user_input = (
                f"<existing_pr>\n{existing_pr}\n</existing_pr>\n\n"
                f"<draft>\n{draft}\n</draft>\n"
                f"<changed_files>\n{diff_stat}\n</changed_files>"
            )
        else:
            prompt = _load_prompt("pr-two-pass.txt")
            user_input = (
                f"<draft>\n{draft}\n</draft>\n"
                f"<changed_files>\n{diff_stat}\n</changed_files>"
            )
    else:
        clean_log = "\n".join(
            line[len("GITAI_COMMIT "):] if line.startswith("GITAI_COMMIT ") else line
            for line in log.splitlines()
        )
        diff = get_diff(repo_path, base_branch)
        if existing_pr:
            prompt = _load_prompt("pr-fallback-update.txt")
            user_input = (
                f"<existing_pr>\n{existing_pr}\n</existing_pr>\n\n"
                f"<commit_log>\n{clean_log}\n</commit_log>\n"
                f"<changed_files>\n{diff_stat}\n</changed_files>\n"
                f"<diff>\n{diff}\n</diff>"
            )
        else:
            prompt = _load_prompt("pr-fallback.txt")
            user_input = (
                f"<commit_log>\n{clean_log}\n</commit_log>\n"
                f"<changed_files>\n{diff_stat}\n</changed_files>\n"
                f"<diff>\n{diff}\n</diff>"
            )

    release_context = get_mr_release_context(repo_path)
    user_input = f"<release_context>{release_context}</release_context>\n\n{user_input}"

    return _call_gemini(client, model, prompt, user_input)
