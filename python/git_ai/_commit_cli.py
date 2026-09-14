#!/usr/bin/env python3
"""CLI bridge for the shell `git-ai commit` path."""

from __future__ import annotations

import argparse
import importlib
import sys
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ._generate import (
        SUBJECT_LIMIT,
        SubjectTrim,
        build_repo_commit_prompt,
        enforce_subject_limit,
        parse_commit_response,
        wrap_commit_body,
    )
    from ._ignore import load_ignore_patterns, to_pathspec_args
    from ._instructions import load_repo_instructions
elif __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    _generate = importlib.import_module("_generate")
    _ignore = importlib.import_module("_ignore")
    SUBJECT_LIMIT = _generate.SUBJECT_LIMIT
    build_repo_commit_prompt = _generate.build_repo_commit_prompt
    enforce_subject_limit = _generate.enforce_subject_limit
    load_ignore_patterns = _ignore.load_ignore_patterns
    load_repo_instructions = importlib.import_module(
        "_instructions"
    ).load_repo_instructions
    parse_commit_response = _generate.parse_commit_response
    to_pathspec_args = _ignore.to_pathspec_args
    wrap_commit_body = _generate.wrap_commit_body
else:
    from ._generate import (
        SUBJECT_LIMIT,
        build_repo_commit_prompt,
        enforce_subject_limit,
        parse_commit_response,
        wrap_commit_body,
    )
    from ._ignore import load_ignore_patterns, to_pathspec_args
    from ._instructions import load_repo_instructions


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
    build = sub.add_parser("build-prompt", help="build a prompt from staged changes")
    build.add_argument("--repo", default=".")
    build.add_argument("--base", default=None)
    build.add_argument("--prompt-file", required=True)
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
    args = parser.parse_args(argv)

    try:
        if args.command == "build-prompt":
            prompt, user_input = build_repo_commit_prompt(args.repo, base=args.base)
            Path(args.prompt_file).write_text(prompt, encoding="utf-8")
            sys.stdout.write(user_input)
        elif args.command == "format":
            _emit_formatted_commit(sys.stdin.read(), args.note_file)
        elif args.command == "ignore-pathspec":
            for arg in to_pathspec_args(load_ignore_patterns(args.repo)):
                sys.stdout.write(f"{arg}\n")
        elif args.command == "instructions":
            text = load_repo_instructions(args.repo)
            if text:
                sys.stdout.write(f"{text}\n")
    except (RuntimeError, ValueError, OSError) as exc:
        sys.stderr.write(f"git-ai: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
