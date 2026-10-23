"""CLI helpers for repo-mode PR prompt building/cache persistence."""

from __future__ import annotations

import argparse
import shlex
import sys
from collections.abc import Callable
from dataclasses import asdict
from pathlib import Path
from typing import cast

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    __package__ = "git_ai"

from ._generate import build_mr_prompt, parse_mr_response
from ._instructions import load_repo_instructions
from ._pr_incremental import prepare_repo_pr_context, save_cached_pr
from ._pr_prompt_build import DIFF_SCOPES, DiffScope


def _cmd_prepare(args: argparse.Namespace) -> int:
    context = prepare_repo_pr_context(
        args.repo_path,
        base_branch=args.base_branch,
        previous_head_sha=args.previous_head_sha,
        fresh=args.fresh,
    )
    for key, value in asdict(context).items():
        if value is None:
            rendered = ""
        elif isinstance(value, bool):
            rendered = "true" if value else "false"
        elif isinstance(value, list):
            # Commit subjects and warning strings are single-line, so
            # newline-join is a safe delimiter _read_subjects can split apart.
            rendered = "\n".join(str(item) for item in value)
        else:
            rendered = str(value)
        sys.stdout.write(f"{key.upper()}={shlex.quote(rendered)}\n")
    return 0


def _cmd_save(args: argparse.Namespace) -> int:
    output = Path(args.output_file).read_text(encoding="utf-8")
    save_cached_pr(
        args.git_dir,
        args.branch_name,
        args.base_branch,
        output,
        args.head_sha,
        args.content_id,
    )
    return 0


def _read_optional(path: str | None) -> str | None:
    if not path:
        return None
    return Path(path).read_text(encoding="utf-8")


def _read_subjects(path: str | None) -> set[str] | None:
    text = _read_optional(path)
    if text is None:
        return None
    subjects = {line.strip() for line in text.splitlines() if line.strip()}
    return subjects or None


def _cmd_build_prompt(args: argparse.Namespace) -> int:
    prompt, user_input = build_mr_prompt(
        diff=Path(args.diff_file).read_text(encoding="utf-8"),
        commit_log=_read_optional(args.commit_log_file),
        diff_stat=_read_optional(args.diff_stat_file),
        release_context=_read_optional(args.release_context_file),
        existing_pr=_read_optional(args.existing_pr_file),
        churn_subjects=_read_subjects(args.churn_subjects_file),
        repo_guidance=load_repo_instructions(args.repo_path),
        diff_scope=cast("DiffScope", args.diff_scope),
    )
    Path(args.prompt_file).write_text(prompt, encoding="utf-8")
    sys.stdout.write(user_input)
    return 0


def _cmd_format(args: argparse.Namespace) -> int:
    sys.stdout.write(parse_mr_response(sys.stdin.read()))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="git_ai._pr_repo_cli")
    sub = parser.add_subparsers(dest="command", required=True)

    prepare = sub.add_parser("prepare")
    prepare.add_argument("--repo-path", default=".")
    prepare.add_argument("--base-branch", required=True)
    prepare.add_argument("--previous-head-sha")
    prepare.add_argument("--fresh", action="store_true")
    prepare.set_defaults(func=_cmd_prepare)

    save = sub.add_parser("save-cache")
    save.add_argument("--git-dir", required=True)
    save.add_argument("--branch-name", required=True)
    save.add_argument("--base-branch", required=True)
    save.add_argument("--output-file", required=True)
    save.add_argument("--head-sha")
    save.add_argument("--content-id")
    save.set_defaults(func=_cmd_save)

    build = sub.add_parser("build-prompt")
    build.add_argument("--repo-path", default=".")
    build.add_argument("--prompt-file", required=True)
    build.add_argument("--diff-file", required=True)
    build.add_argument("--commit-log-file")
    build.add_argument("--diff-stat-file")
    build.add_argument("--release-context-file")
    build.add_argument("--existing-pr-file")
    build.add_argument("--churn-subjects-file")
    build.add_argument("--diff-scope", choices=DIFF_SCOPES, default="since_existing")
    build.set_defaults(func=_cmd_build_prompt)

    fmt = sub.add_parser("format")
    fmt.set_defaults(func=_cmd_format)

    args = parser.parse_args(argv)
    func = cast(Callable[[argparse.Namespace], int], args.func)
    try:
        return func(args)
    except (RuntimeError, ValueError, OSError) as exc:
        sys.stderr.write(f"git-ai: {exc}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
