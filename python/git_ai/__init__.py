"""git-ai Python package — LLM-powered git workflow tools."""
from ._gemini import COMMIT_MODEL, MR_MODEL, create_gemini_client
from ._generate import (
    generate_commit_message,
    generate_commit_message_from_diff,
    generate_mr_description,
    generate_mr_description_from_data,
)
from ._git import derive_diff_stat, format_commit_log

__all__ = [
    "COMMIT_MODEL",
    "MR_MODEL",
    "create_gemini_client",
    "derive_diff_stat",
    "format_commit_log",
    "generate_commit_message",
    "generate_commit_message_from_diff",
    "generate_mr_description",
    "generate_mr_description_from_data",
]
