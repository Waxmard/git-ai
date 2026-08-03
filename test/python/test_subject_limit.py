"""Tests for enforce_subject_limit — mirrors test/lib/enforce_subject_limit.bats."""

from git_ai import SUBJECT_LIMIT, enforce_subject_limit


def test_short_subject_passes_through() -> None:
    result = enforce_subject_limit("feat: add thing\n\nBody line.")
    assert result.message == "feat: add thing\n\nBody line."
    assert result.dropped == ""
    assert not result.over_limit


def test_trims_at_and_boundary() -> None:
    result = enforce_subject_limit(
        "feat: restructure PR body prompts around purpose sections "
        "and fix nested fence stripping"
    )
    assert result.message == "feat: restructure PR body prompts around purpose sections"
    assert result.dropped == "and fix nested fence stripping"
    assert result.subject_length == 88
    assert not result.over_limit


def test_trims_at_comma_boundary() -> None:
    result = enforce_subject_limit(
        "fix: preserve the cached PR body across rebases, "
        "force-pushes, and amended commits"
    )
    assert result.message == (
        "fix: preserve the cached PR body across rebases, force-pushes"
    )
    assert result.dropped == "and amended commits"


def test_prefers_the_longest_head_within_the_limit() -> None:
    result = enforce_subject_limit(
        "feat: add the picker, wire the cache and document the whole flow"
        " and then some more text",
        limit=SUBJECT_LIMIT,
    )
    assert result.message == (
        "feat: add the picker, wire the cache and document the whole flow"
    )


def test_body_survives_the_trim() -> None:
    result = enforce_subject_limit(
        "feat: restructure PR body prompts around purpose sections "
        "and fix nested fence stripping\n\nBody line one.\nBody line two."
    )
    assert result.message == (
        "feat: restructure PR body prompts around purpose sections"
        "\n\nBody line one.\nBody line two."
    )


def test_no_clause_break_is_left_untouched_and_flagged() -> None:
    subject = "feat: introduce a deterministic branch fingerprint mechanism for caching"
    result = enforce_subject_limit(subject)
    assert result.message == subject
    assert result.dropped == ""
    assert result.over_limit


def test_break_yielding_a_stub_is_rejected() -> None:
    subject = (
        "refactor: split, then rewrite the entire wizard flow end to end for clarity"
    )
    result = enforce_subject_limit(subject)
    assert result.message == subject
    assert result.over_limit


def test_separator_inside_the_scope_is_skipped() -> None:
    result = enforce_subject_limit(
        "refactor(setup, vertex): move project discovery into its own module "
        "and simplify the picker"
    )
    assert result.message == (
        "refactor(setup, vertex): move project discovery into its own module"
    )


def test_trim_is_idempotent() -> None:
    once = enforce_subject_limit(
        "feat: restructure PR body prompts around purpose sections "
        "and fix nested fence stripping"
    )
    twice = enforce_subject_limit(once.message)
    assert twice.message == once.message
    assert twice.dropped == ""


def test_custom_limit() -> None:
    result = enforce_subject_limit(
        "feat: add the model picker and wire the cache", limit=40
    )
    assert result.message == "feat: add the model picker"


def test_separator_inside_a_code_reference_is_skipped() -> None:
    subject = (
        "fix: keep configuration for parse(foo, bar) intact while validating subjects"
    )
    result = enforce_subject_limit(subject)
    assert result.message == subject
    assert result.over_limit


def test_separator_inside_backticks_is_skipped() -> None:
    subject = (
        "fix: keep `parse(foo, bar)` output intact while validating generated subjects"
    )
    result = enforce_subject_limit(subject)
    assert result.message == subject
    assert result.over_limit


def test_break_outside_a_code_reference_still_wins() -> None:
    result = enforce_subject_limit(
        "feat: add parse(a, b) support and wire the cache into the discovery layer"
    )
    assert result.message == "feat: add parse(a, b) support"
    assert result.dropped == "and wire the cache into the discovery layer"


def test_unclosed_bracket_suppresses_later_breaks() -> None:
    subject = (
        "fix: handle the unclosed paren case (foo, bar while validating "
        "the subject line"
    )
    result = enforce_subject_limit(subject)
    assert result.message == subject
    assert result.over_limit
