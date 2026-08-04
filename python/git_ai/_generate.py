"""Prompt builders and response parsers for commit + MR generation.

Provider-agnostic: never calls an LLM. Consumers wire their own model call
between the ``build_*_prompt`` and ``parse_*_response`` halves.
"""

from __future__ import annotations

import os
import re
import textwrap
from collections.abc import Iterator
from pathlib import Path
from typing import TYPE_CHECKING, NamedTuple

if TYPE_CHECKING:
    from ._git import (
        DEFAULT_RELEASE_CONTEXT,
        derive_diff_stat,
        largest_diff_files,
    )
    from ._git_branch import format_branch_context
    from ._instructions import format_repo_guidance
    from ._pr_prompt_build import build_mr_prompt_input
elif __package__ in (None, ""):
    import importlib

    _git_mod = importlib.import_module("_git")
    _git_branch_mod = importlib.import_module("_git_branch")
    DEFAULT_RELEASE_CONTEXT = _git_mod.DEFAULT_RELEASE_CONTEXT
    build_mr_prompt_input = importlib.import_module(
        "_pr_prompt_build"
    ).build_mr_prompt_input
    derive_diff_stat = _git_mod.derive_diff_stat
    format_branch_context = _git_branch_mod.format_branch_context
    format_repo_guidance = importlib.import_module("_instructions").format_repo_guidance
    largest_diff_files = _git_mod.largest_diff_files
else:
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


_FENCE_OPEN_RE = re.compile(r"[ \t]*`{3,}[^`]*")
_FENCE_CLOSE_RE = re.compile(r"[ \t]*`{3,}[ \t]*")


def strip_fences(text: str) -> str:
    """Unwrap a fence only when it wraps the entire response.

    Fenced blocks *inside* a PR body are content — verification commands,
    deployment steps — so only a fence that opens the first line and closes the
    last is treated as the model wrapping its whole answer.
    """
    lines = text.strip().split("\n")
    if (
        len(lines) >= 2
        and _FENCE_OPEN_RE.fullmatch(lines[0])
        and _FENCE_CLOSE_RE.fullmatch(lines[-1])
    ):
        lines = lines[1:-1]
    # Unwrap a subject wrapped in an inline code span ("`feat: add x`"). Only a
    # whole-line single span, so code spans inside a body survive.
    text = "\n".join(lines).strip()
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

    The branch_* values describe the branch's overall purpose; the prompt uses
    them only to disambiguate the prefix when the staged diff alone is
    ambiguous. Empty branch tags are omitted. ``repo_guidance``
    (``.git-ai-instructions``) becomes an authoritative ``<repo_guidance>``
    block. Feed both returned strings to your LLM, then run the response
    through :func:`parse_commit_response`.

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

    Selects the two-pass or fallback prompt template based on whether
    ``commit_log`` (``GITAI_COMMIT``-prefixed, see :func:`format_commit_log`)
    is mostly Conventional Commits, and an update-flavoured variant when
    ``existing_pr`` is supplied. ``churn_subjects`` are commits that only
    refine code introduced earlier in the same branch — folded into the draft
    instead of emitted as standalone sections. Feed both returned strings to
    your LLM, then run the response through :func:`parse_mr_response`.

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


_ATTRIBUTION_TRAILER_RE = re.compile(
    r"^(?:co-authored-by:|\W*generated with \[)", re.IGNORECASE
)
_CLOSING_MARKER_RE = re.compile(r"^={2,} *[A-Za-z][A-Za-z0-9 _-]* *={2,}$")


def _drop_trailing_noise(text: str) -> str:
    """Drop trailing closing markers and agent self-attribution lines.

    Agent CLIs (``claude -p``, ``codex exec``) carry a system prompt of their
    own instructing them to sign commits with ``Co-Authored-By:`` and PR bodies
    with a ``Generated with [...]`` line; that outranks anything the git-ai
    prompt says, so the trailer is stripped after the fact instead. Markers are
    any ``===WORD===`` line, not just the ones the prompt asks for: models
    routinely close a section with an invented ``===END===``.

    Both kinds go in one pass because they interleave — an agent that signs its
    work below its own ``===END===`` strands the marker if the two run as
    separate passes.
    """
    lines = text.split("\n")
    while lines and (
        not lines[-1].strip()
        or _ATTRIBUTION_TRAILER_RE.match(lines[-1].strip())
        or _CLOSING_MARKER_RE.match(lines[-1].strip())
    ):
        lines.pop()
    return "\n".join(lines)


def _drop_trailing_noise_safe(text: str) -> str:
    """``_drop_trailing_noise``, keeping ``text`` when noise is all there is."""
    stripped = _drop_trailing_noise(text)
    return stripped if stripped.strip() else text


_PR_TITLE_MARKER = "===TITLE==="
_PR_BODY_MARKER = "===BODY==="


def _marker_index(lines: list[str], marker: str) -> int:
    for i, line in enumerate(lines):
        if line.strip() == marker:
            return i
    return -1


def _extract_pr_sections(text: str) -> str:
    """Slice ``title\\n\\nbody`` out of ``===TITLE===`` / ``===BODY===`` markers.

    Preamble, reasoning, or char-count chatter outside the markers is
    discarded. Falls back to ``text`` unchanged when the markers are absent or
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
    body = _drop_trailing_noise("\n".join(lines[b_idx + 1 :])).strip()
    return f"{title}\n\n{body}" if body else title


_COMMIT_MARKER = "===COMMIT==="
_COMMIT_TYPES = "feat|fix|refactor|build|chore|docs|style|test|perf|ci|revert"
_COMMIT_PREFIX_RE = re.compile(rf"^(?:{_COMMIT_TYPES})(?:\([^)]*\))?!?: ")
_COMMIT_SUBJECT_RE = re.compile(rf"^(?:{_COMMIT_TYPES})(?:\([^)]*\))?!?: \S")


def _extract_commit_message(text: str) -> str:
    """Slice the message out of a commit response, discarding any preamble.

    Reasoning models emit their type-choice rationale ahead of the message,
    which otherwise lands as the subject line. Prefers everything after the
    ``===COMMIT===`` marker; falls back to the first Conventional Commits
    subject line onward for models that drop the marker, and to ``text``
    unchanged when neither is present.
    """
    lines = text.split("\n")
    idx = _marker_index(lines, _COMMIT_MARKER)
    if idx >= 0:
        after = _drop_trailing_noise("\n".join(lines[idx + 1 :])).strip()
        if after:
            return after
    for i, line in enumerate(lines):
        if _COMMIT_SUBJECT_RE.match(line.strip()):
            return _drop_trailing_noise("\n".join(lines[i:])).strip()
    return text


SUBJECT_LIMIT = 70
_MIN_TRIMMED_SUBJECT = 24
_CLAUSE_SEPARATORS = (" and ", " plus ", ", ", "; ")


class SubjectTrim(NamedTuple):
    """Result of ``enforce_subject_limit``.

    ``dropped`` is the clause removed from the subject, empty when nothing was
    trimmed; ``over_limit`` says whether the subject still exceeds the limit,
    which is how a caller knows to warn.
    """

    message: str
    dropped: str
    subject_length: int
    over_limit: bool


def _clause_break_positions(subject: str, start: int) -> Iterator[int]:
    """Yield indices in ``subject`` at or after ``start`` that may hold a break.

    Skips anything nested in brackets or a code span: a separator inside a code
    reference (``parse(foo, bar)``) is punctuation, not a clause boundary, and
    cutting there leaves a mangled half-identifier. Code spans follow CommonMark
    — a run of backticks closes only on a run of the same length — so a span
    opened with two backticks can hold a literal backtick without ending early.
    An unclosed bracket or span suppresses every later position, which degrades
    to the untouched ``over_limit`` path rather than a bad trim.
    """
    depth = 0
    code_run = 0
    i = 0
    while i < len(subject):
        ch = subject[i]
        if ch == "`":
            run = len(subject[i:]) - len(subject[i:].lstrip("`"))
            if code_run == 0:
                code_run = run
            elif run == code_run:
                code_run = 0
            i += run
            continue
        if code_run == 0:
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth = max(0, depth - 1)
            if i >= start and depth == 0:
                yield i
        i += 1


def enforce_subject_limit(message: str, limit: int = SUBJECT_LIMIT) -> SubjectTrim:
    """Shorten an over-long commit subject at a clause boundary.

    Long subjects are near-always two clauses joined by ``and`` / ``,`` / ``;``,
    so cutting at the last such break under ``limit`` leaves a whole,
    grammatical subject and the dropped detail is already covered by the body.
    A subject with no usable break is returned untouched with ``over_limit``
    set — a mid-word truncation reads worse than an over-long subject, so the
    caller warns instead. Separators inside the Conventional Commits prefix are
    skipped so a multi-word scope can't be cut in half.
    """
    subject, newline, rest = message.partition("\n")
    length = len(subject)
    if length <= limit:
        return SubjectTrim(message, "", length, False)

    prefix = _COMMIT_PREFIX_RE.match(subject)
    best = ""
    for i in _clause_break_positions(subject, prefix.end() if prefix else 0):
        if not any(subject.startswith(sep, i) for sep in _CLAUSE_SEPARATORS):
            continue
        head = subject[:i].rstrip(" ,;")
        if _MIN_TRIMMED_SUBJECT <= len(head) <= limit and len(head) > len(best):
            best = head
    if not best:
        return SubjectTrim(message, "", length, True)
    dropped = subject[len(best) :].strip(" ,;")
    return SubjectTrim(best + newline + rest, dropped, length, False)


BODY_WRAP_WIDTH = 72
_PARAGRAPH_BREAK_RE = re.compile(r"(\n[ \t]*\n)")
_LIST_ITEM_RE = re.compile(r"(?:[-*+]|\d+[.)]) ")
_TRAILER_LINE_RE = re.compile(r"[A-Za-z][A-Za-z0-9-]*:(?: \S.*)?")
_FENCE_DELIM_RE = re.compile(r"[ \t]*((`|~)\2{2,})(.*)")
_FENCE_ANY_RE = re.compile(r"`{3,}|~{3,}")


def _fence_state(
    lines: list[str], fence: tuple[str, int] | None
) -> tuple[str, int] | None:
    """Track fence nesting across ``lines``, returning the open delimiter.

    ``None`` means "not inside a fence"; otherwise (character, run length).
    Follows CommonMark: a fence closes only on a run of the *same* character at
    least as long as the one that opened it, so a four-backtick block can hold a
    three-backtick example without either the inner opener or its closer ending
    the outer block. Only a backtick opener's info string is restricted (it may
    not contain a backtick); a tilde opener's is free-form.
    """
    for ln in lines:
        m = _FENCE_DELIM_RE.fullmatch(ln)
        if not m:
            continue
        run, char, rest = m.group(1), m.group(2), m.group(3)
        if fence:
            if char == fence[0] and len(run) >= fence[1] and not rest.strip():
                fence = None
        elif char == "~" or "`" not in rest:
            fence = (char, len(run))
    return fence


def _reflowable(lines: list[str], is_last: bool) -> bool:
    # Only the final paragraph gets the trailer exemption: git reads trailers
    # from the last block, and mid-body prose routinely opens "Verified: ...",
    # which is ordinary text that should still wrap.
    if is_last and all(_TRAILER_LINE_RE.fullmatch(ln) for ln in lines):
        return False
    return all(
        ln[:1].strip() and not _LIST_ITEM_RE.match(ln) and not _FENCE_ANY_RE.search(ln)
        for ln in lines
    )


def wrap_commit_body(message: str, width: int = BODY_WRAP_WIDTH) -> str:
    """Hard-wrap the prose paragraphs of a commit body at ``width`` columns.

    git renders commit bodies verbatim, so an unwrapped paragraph is a single
    long line in ``git log``; models wrap inconsistently, so it is done here.
    Reflow is confined to plain prose — indented lines, list items, fenced
    blocks, and a trailing trailer block keep their line structure, which is
    load-bearing. The subject is never touched (see ``enforce_subject_limit``).
    """
    subject, newline, body = message.partition("\n")
    if not newline:
        return message
    core = body.lstrip("\n")
    lead = len(body) - len(core)
    tail = len(core) - len(core.rstrip("\n"))
    blocks = _PARAGRAPH_BREAK_RE.split(core[: len(core) - tail])
    content = [i for i, b in enumerate(blocks) if i % 2 == 0 and b.strip()]
    last = content[-1] if content else -1
    out = []
    fence: tuple[str, int] | None = None
    for i, block in enumerate(blocks):
        if i % 2 or not block.strip():
            out.append(block)
            continue
        lines = block.split("\n")
        # A fenced block can span blank lines, which puts an interior stanza in
        # its own paragraph with no fence marker of its own to spot it by.
        reflow = not fence and _reflowable(lines, i == last)
        fence = _fence_state(lines, fence)
        if not reflow:
            out.append(block)
            continue
        out.append(
            textwrap.fill(
                " ".join(lines),
                width=width,
                break_long_words=False,
                break_on_hyphens=False,
            )
        )
    return subject + newline + "\n" * lead + "".join(out) + "\n" * tail


def parse_commit_response(raw: str) -> str:
    """Strip fences, unwrap the ``===COMMIT===`` marker, drop agent trailers.

    Falls back to the fence-stripped text when the marker is absent. Raises if
    the response cleans to empty.
    """
    return _drop_trailing_noise_safe(_extract_commit_message(_parse_response(raw)))


def parse_mr_response(raw: str) -> str:
    """Strip fences, unwrap ``===TITLE===`` / ``===BODY===``, drop agent trailers.

    Falls back to the fence-stripped text when the markers are absent. Raises
    if the response cleans to empty.
    """
    return _drop_trailing_noise_safe(_extract_pr_sections(_parse_response(raw)))
