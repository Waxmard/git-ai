"""CLI helpers for repo-mode PR preparation/cache persistence."""

from __future__ import annotations

import argparse
import importlib
import json
import shlex
import sys
from pathlib import Path
from typing import TYPE_CHECKING, Callable, cast

if TYPE_CHECKING:
    from ._pr_incremental import prepare_repo_pr_context, save_cached_pr
    from ._pr_prompt_build import build_mr_prompt_input
elif __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    _pr_incremental = importlib.import_module("_pr_incremental")
    _pr_prompt_build = importlib.import_module("_pr_prompt_build")
    prepare_repo_pr_context = _pr_incremental.prepare_repo_pr_context
    save_cached_pr = _pr_incremental.save_cached_pr
    build_mr_prompt_input = _pr_prompt_build.build_mr_prompt_input
else:
    from ._pr_incremental import prepare_repo_pr_context, save_cached_pr
    from ._pr_prompt_build import build_mr_prompt_input


def _cmd_prepare(args: argparse.Namespace) -> int:
    existing_pr = None
    if args.existing_pr_file:
        existing_pr = Path(args.existing_pr_file).read_text(encoding="utf-8")
    context = prepare_repo_pr_context(
        args.repo_path,
        base_branch=args.base_branch,
        existing_pr=existing_pr,
        previous_head_sha=args.previous_head_sha,
        fresh=args.fresh,
    )
    if args.format == "shell":
        for key, value in json.loads(context.to_json()).items():
            if value is None:
                rendered = ""
            elif isinstance(value, bool):
                rendered = "true" if value else "false"
            else:
                rendered = str(value)
            sys.stdout.write(f"{key.upper()}={shlex.quote(rendered)}\n")
        return 0
    sys.stdout.write(context.to_json())
    return 0


def _cmd_save(args: argparse.Namespace) -> int:
    output = Path(args.output_file).read_text(encoding="utf-8")
    save_cached_pr(
        args.git_dir,
        args.branch_name,
        args.base_branch,
        output,
        args.head_sha,
    )
    return 0


def _read_optional(path: str | None) -> str | None:
    if not path:
        return None
    return Path(path).read_text(encoding="utf-8")


def _cmd_build_input(args: argparse.Namespace) -> int:
    prompt_name, user_input = build_mr_prompt_input(
        diff=Path(args.diff_file).read_text(encoding="utf-8"),
        commit_log=_read_optional(args.commit_log_file),
        diff_stat=_read_optional(args.diff_stat_file),
        release_context=_read_optional(args.release_context_file),
        existing_pr=_read_optional(args.existing_pr_file),
    )
    sys.stdout.write(json.dumps({"prompt_name": prompt_name, "user_input": user_input}))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="git_ai._pr_repo_cli")
    sub = parser.add_subparsers(dest="command", required=True)

    prepare = sub.add_parser("prepare")
    prepare.add_argument("--repo-path", default=".")
    prepare.add_argument("--base-branch", required=True)
    prepare.add_argument("--existing-pr-file")
    prepare.add_argument("--previous-head-sha")
    prepare.add_argument("--fresh", action="store_true")
    prepare.add_argument("--format", choices=["json", "shell"], default="json")
    prepare.set_defaults(func=_cmd_prepare)

    save = sub.add_parser("save-cache")
    save.add_argument("--git-dir", required=True)
    save.add_argument("--branch-name", required=True)
    save.add_argument("--base-branch", required=True)
    save.add_argument("--output-file", required=True)
    save.add_argument("--head-sha")
    save.set_defaults(func=_cmd_save)

    build = sub.add_parser("build-input")
    build.add_argument("--diff-file", required=True)
    build.add_argument("--commit-log-file")
    build.add_argument("--diff-stat-file")
    build.add_argument("--release-context-file")
    build.add_argument("--existing-pr-file")
    build.set_defaults(func=_cmd_build_input)

    args = parser.parse_args(argv)
    func = cast(Callable[[argparse.Namespace], int], args.func)
    return func(args)


if __name__ == "__main__":
    raise SystemExit(main())
