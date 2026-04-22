"""Provider-agnostic prompt/styling toolkit for LLM-powered git workflows."""

from ._generate import (
    Completion,
    MrDescription,
    generate_commit_message,
    generate_commit_message_from_diff,
    generate_mr_description,
)
from ._git import derive_diff_stat, format_commit_log
from ._pr_render import render_pr_diff

__all__ = [
    "Completion",
    "MrDescription",
    "derive_diff_stat",
    "format_commit_log",
    "generate_commit_message",
    "generate_commit_message_from_diff",
    "generate_mr_description",
    "render_pr_diff",
]
