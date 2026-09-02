#!/usr/bin/env python3
"""CLI bridge for the shell `git-ai commit` path.

``branch-context`` emits the branch-context block so the shell can splice it
into the commit prompt without reimplementing the base-resolution cascade in
bash; it is best-effort, printing nothing and exiting 0 on any failure so it
never blocks a commit. ``format`` runs the raw provider response through the
parse + wrap + subject-limit chain, ``staged-context`` emits the bounded diff
and stat, and ``ignore-pathspec`` / ``instructions`` serve the repo-local
readers, so those rules have one implementation rather than a bash mirror.

Unlike ``branch-context``, the other commands fail loudly: a swallowed error
there would silently change which files reach the model.
"""

from __future__ import annotations

import argparse
import importlib
import os
import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ._generate import (
        SUBJECT_LIMIT,
        SubjectTrim,
        enforce_subject_limit,
        parse_commit_response,
        wrap_commit_body,
    )
    from ._git import (
        get_current_branch,
        get_diff_stat,
        get_git_dir,
        get_staged_diff_context,
    )
    from ._git_branch import (
        format_branch_context,
        get_branch_commit_subjects,
        resolve_commit_base,
    )
    from ._ignore import load_ignore_patterns, to_pathspec_args
    from ._instructions import load_repo_instructions
elif __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    _generate = importlib.import_module("_generate")
    _git = importlib.import_module("_git")
    _git_branch = importlib.import_module("_git_branch")
    _ignore = importlib.import_module("_ignore")
    SUBJECT_LIMIT = _generate.SUBJECT_LIMIT
    enforce_subject_limit = _generate.enforce_subject_limit
    format_branch_context = _git_branch.format_branch_context
    get_branch_commit_subjects = _git_branch.get_branch_commit_subjects
    get_current_branch = _git.get_current_branch
    get_diff_stat = _git.get_diff_stat
    get_git_dir = _git.get_git_dir
    get_staged_diff_context = _git.get_staged_diff_context
    load_ignore_patterns = _ignore.load_ignore_patterns
    load_repo_instructions = importlib.import_module(
        "_instructions"
    ).load_repo_instructions
    parse_commit_response = _generate.parse_commit_response
    resolve_commit_base = _git_branch.resolve_commit_base
    to_pathspec_args = _ignore.to_pathspec_args
    wrap_commit_body = _generate.wrap_commit_body
else:
    from ._generate import (
        SUBJECT_LIMIT,
        enforce_subject_limit,
        parse_commit_response,
        wrap_commit_body,
    )
    from ._git import (
        get_current_branch,
        get_diff_stat,
        get_git_dir,
        get_staged_diff_context,
    )
    from ._git_branch import (
        format_branch_context,
        get_branch_commit_subjects,
        resolve_commit_base,
    )
    from ._ignore import load_ignore_patterns, to_pathspec_args
    from ._instructions import load_repo_instructions


def _emit_branch_context(repo: str, override: str | None) -> None:
    branch = get_current_branch(repo)
    git_dir = get_git_dir(repo)
    base = resolve_commit_base(
        repo,
        override=override or os.environ.get("GIT_AI_COMMIT_BASE") or None,
        git_dir=git_dir,
        branch=branch,
    )
    if not base:
        return
    block = format_branch_context(
        branch_name=branch,
        branch_commits=get_branch_commit_subjects(repo, base),
        branch_diffstat=get_diff_stat(repo, base),
    )
    if block:
        sys.stdout.write(block)


def _subject_note(trim: SubjectTrim) -> str:
    if trim.over_limit:
        return (
            f"subject is {trim.subject_length} chars (limit {SUBJECT_LIMIT})"
            " - no clean clause break; shorten this line"
        )
    if trim.dropped:
        return (
            f'trimmed: dropped "{trim.dropped}"'
            f" (was {trim.subject_length} chars, limit {SUBJECT_LIMIT})"
        )
    return ""


def _emit_formatted_commit(raw: str, note_file: str | None) -> None:
    try:
        message = parse_commit_response(raw)
    except RuntimeError:
        # An empty response is reported by the shell, which can name the
        # provider that produced it; printing nothing lands on that path.
        return
    trim = enforce_subject_limit(wrap_commit_body(message))
    sys.stdout.write(trim.message)
    if note_file:
        Path(note_file).write_text(_subject_note(trim), encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    branch_ctx = sub.add_parser(
        "branch-context", help="print the branch-context block for a commit prompt"
    )
    branch_ctx.add_argument("--repo", default=".")
    branch_ctx.add_argument("--base", default=None)
    fmt = sub.add_parser(
        "format", help="parse, wrap, and subject-limit a raw provider response"
    )
    fmt.add_argument("--note-file", default=None)
    pathspec = sub.add_parser(
        "ignore-pathspec", help="print git pathspec excludes, one per line"
    )
    pathspec.add_argument("--repo", default=".")
    instructions = sub.add_parser(
        "instructions", help="print the repo's .git-ai-instructions contents"
    )
    instructions.add_argument("--repo", default=".")
    staged = sub.add_parser(
        "staged-context", help="print adaptive staged diff and write its stat"
    )
    staged.add_argument("--repo", default=".")
    staged.add_argument("--stat-file", required=True)
    args = parser.parse_args(argv)

    if args.command == "branch-context":
        try:
            _emit_branch_context(args.repo, args.base)
        except Exception:
            # Branch context is best-effort — never block a commit on it.
            return 0
        return 0

    try:
        if args.command == "format":
            _emit_formatted_commit(sys.stdin.read(), args.note_file)
        elif args.command == "ignore-pathspec":
            for arg in to_pathspec_args(load_ignore_patterns(args.repo)):
                sys.stdout.write(f"{arg}\n")
        elif args.command == "instructions":
            text = load_repo_instructions(args.repo)
            if text:
                sys.stdout.write(f"{text}\n")
        elif args.command == "staged-context":
            diff, stat = get_staged_diff_context(args.repo)
            Path(args.stat_file).write_text(stat, encoding="utf-8")
            sys.stdout.write(diff)
    except (RuntimeError, ValueError, OSError) as exc:
        sys.stderr.write(f"git-ai: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
