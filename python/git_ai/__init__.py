"""Provider-agnostic prompt/styling toolkit for LLM-powered git workflows."""

from ._generate import (
    build_commit_prompt,
    build_mr_prompt,
    parse_commit_response,
    parse_mr_response,
    strip_fences,
)
from ._git import (
    check_git_repo,
    derive_diff_stat,
    format_commit_log,
    get_commit_log,
    get_current_branch,
    get_diff,
    get_diff_stat,
    get_git_dir,
    get_head_sha,
    get_mr_release_context,
    get_release_context,
    get_staged_diff,
)
from ._pr_incremental import (
    RepoPrContext,
    load_cached_pr,
    load_cached_pr_sha,
    prepare_repo_pr_context,
    save_cached_pr,
)
from ._pr_render import render_pr_diff

__all__ = [
    "RepoPrContext",
    "build_commit_prompt",
    "build_mr_prompt",
    "check_git_repo",
    "derive_diff_stat",
    "format_commit_log",
    "get_commit_log",
    "get_current_branch",
    "get_diff",
    "get_diff_stat",
    "get_git_dir",
    "get_head_sha",
    "get_mr_release_context",
    "get_release_context",
    "get_staged_diff",
    "load_cached_pr",
    "load_cached_pr_sha",
    "parse_commit_response",
    "parse_mr_response",
    "prepare_repo_pr_context",
    "render_pr_diff",
    "save_cached_pr",
    "strip_fences",
]
