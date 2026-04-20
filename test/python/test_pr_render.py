"""Tests for git_ai._pr_render.render_pr_diff."""
from __future__ import annotations

from git_ai._pr_render import render_pr_diff


def test_identical_input_returns_empty() -> None:
    text = "feat: title\n\n- item"
    assert render_pr_diff(text, text, color=False) == ""


def test_pure_addition_uses_plus_prefix() -> None:
    existing = "feat: a\n- one"
    updated = "feat: a\n- one\n- two"
    result = render_pr_diff(existing, updated, color=False)

    assert "+ - two" in result
    assert "  feat: a" in result
    assert "  - one" in result


def test_pure_removal_uses_minus_prefix() -> None:
    existing = "feat: a\n- one\n- two"
    updated = "feat: a\n- one"
    result = render_pr_diff(existing, updated, color=False)

    assert "- - two" in result


def test_changed_line_uses_tilde_prefix() -> None:
    existing = "feat: title\n- old bullet"
    updated = "feat: title\n- new bullet"
    result = render_pr_diff(existing, updated, color=False)

    assert "~ - new bullet" in result
    assert "- old bullet" not in result
    assert "+- (changed)" not in result


def test_mixed_group_pairs_then_remainder() -> None:
    existing = "h\n- a\n- b"
    updated = "h\n- A\n- B\n- C"
    result = render_pr_diff(existing, updated, color=False)

    assert "~ - A" in result
    assert "~ - B" in result
    assert "+ - C" in result


def test_color_wraps_change_lines() -> None:
    existing = "h\n- old"
    updated = "h\n- new"
    result = render_pr_diff(existing, updated, color=True)

    assert "\033[32m~ - new\033[m" in result


def test_color_off_omits_ansi_codes() -> None:
    existing = "h\n- old"
    updated = "h\n- new"
    result = render_pr_diff(existing, updated, color=False)

    assert "\033[" not in result
    assert "~ - new" in result


def test_removal_red_when_color_enabled() -> None:
    existing = "h\n- one\n- two"
    updated = "h\n- one"
    result = render_pr_diff(existing, updated, color=True)

    assert "\033[31m- - two\033[m" in result


def test_hunk_header_passes_through() -> None:
    existing = "a\nb\nc"
    updated = "a\nb\nc\nd"
    result = render_pr_diff(existing, updated, color=False)

    assert "@@ " in result


def test_context_line_two_space_prefix() -> None:
    existing = "title\nbody"
    updated = "title\nbody\nmore"
    result = render_pr_diff(existing, updated, color=False)

    assert "  title" in result
    assert "  body" in result


def test_file_headers_stripped() -> None:
    existing = "x"
    updated = "y"
    result = render_pr_diff(existing, updated, color=False)

    assert "--- " not in result
    assert "+++ " not in result
