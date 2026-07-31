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
from ._git_branch import (
    branch_content_id,
    format_branch_context,
    get_branch_churn_subjects,
    get_branch_commit_subjects,
    get_default_branch,
    resolve_commit_base,
)
from ._instructions import format_repo_guidance, load_repo_instructions
from ._pr_incremental import (
    RepoPrContext,
    load_cached_content_id,
    load_cached_pr,
    load_cached_pr_sha,
    prepare_repo_pr_context,
    prune_pr_cache,
    save_cached_pr,
)
from ._pr_render import render_pr_diff, summarize_pr_changes

__all__ = [
    "RepoPrContext",
    "branch_content_id",
    "build_commit_prompt",
    "build_mr_prompt",
    "check_git_repo",
    "derive_diff_stat",
    "format_branch_context",
    "format_commit_log",
    "format_repo_guidance",
    "get_branch_churn_subjects",
    "get_branch_commit_subjects",
    "get_commit_log",
    "get_current_branch",
    "get_default_branch",
    "get_diff",
    "get_diff_stat",
    "get_git_dir",
    "get_head_sha",
    "get_mr_release_context",
    "get_release_context",
    "get_staged_diff",
    "load_cached_content_id",
    "load_cached_pr",
    "load_cached_pr_sha",
    "load_repo_instructions",
    "parse_commit_response",
    "parse_mr_response",
    "prepare_repo_pr_context",
    "prune_pr_cache",
    "render_pr_diff",
    "resolve_commit_base",
    "save_cached_pr",
    "strip_fences",
    "summarize_pr_changes",
]
