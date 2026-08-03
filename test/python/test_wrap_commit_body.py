"""Tests for wrap_commit_body — mirrors test/lib/wrap_commit_body.bats."""

from git_ai import BODY_WRAP_WIDTH, wrap_commit_body

LONG = (
    "Replaces the flat group-bullets-by-conventional-commit-type PR body format "
    "with purpose sections scaled to the size of the change, so a one-concern "
    "branch gets prose and a large one gets the full set of headings."
)


def _body_lines(message: str) -> list[str]:
    return [ln for ln in message.split("\n")[1:] if ln]


def test_subject_only_untouched() -> None:
    assert wrap_commit_body("feat: add thing") == "feat: add thing"


def test_wraps_long_paragraph() -> None:
    result = wrap_commit_body(f"feat: add thing\n\n{LONG}")
    assert result.startswith("feat: add thing\n\n")
    assert all(len(ln) <= BODY_WRAP_WIDTH for ln in _body_lines(result))
    assert " ".join(_body_lines(result)) == LONG


def test_never_wraps_the_subject() -> None:
    subject = "feat: " + "x" * 100
    assert wrap_commit_body(f"{subject}\n\nbody").split("\n")[0] == subject


def test_idempotent() -> None:
    once = wrap_commit_body(f"feat: add thing\n\n{LONG}")
    assert wrap_commit_body(once) == once


def test_trailing_newline_does_not_block_reflow() -> None:
    result = wrap_commit_body(f"feat: add thing\n\n{LONG}\n")
    assert result.endswith("\n")
    assert all(len(ln) <= BODY_WRAP_WIDTH for ln in _body_lines(result))


def test_paragraph_breaks_preserved() -> None:
    result = wrap_commit_body("feat: x\n\nfirst para\n\nsecond para")
    assert result == "feat: x\n\nfirst para\n\nsecond para"


def test_reflows_ragged_paragraph() -> None:
    ragged = "feat: x\n\nshort\nlines that\nthe model\nwrapped badly"
    assert wrap_commit_body(ragged) == (
        "feat: x\n\nshort lines that the model wrapped badly"
    )


def test_list_items_untouched() -> None:
    body = "- " + "word " * 30
    result = wrap_commit_body(f"feat: x\n\n{body.strip()}")
    assert result == f"feat: x\n\n{body.strip()}"


def test_indented_block_untouched() -> None:
    block = "    " + "word " * 30
    result = wrap_commit_body(f"feat: x\n\n{block.rstrip()}")
    assert result == f"feat: x\n\n{block.rstrip()}"


def test_fenced_block_untouched() -> None:
    block = (
        "```bash\n"
        "gcloud workstations create verify-name --cluster=demo --region=example-west1\n"
        "```"
    )
    result = wrap_commit_body(f"feat: x\n\n{block}")
    assert result == f"feat: x\n\n{block}"


def test_multi_stanza_fenced_block_untouched() -> None:
    block = (
        "```bash\n"
        "echo one\n"
        "\n"
        "echo an interior stanza that carries no fence marker of its very own\n"
        "echo three\n"
        "\n"
        "echo done\n"
        "```"
    )
    result = wrap_commit_body(f"feat: x\n\n{block}")
    assert result == f"feat: x\n\n{block}"


def test_nested_fenced_block_untouched() -> None:
    block = (
        "````markdown\n"
        "```text\n"
        "first\n"
        "\n"
        "line one of the interior stanza\n"
        "line two of the interior stanza\n"
        "\n"
        "third\n"
        "```\n"
        "````"
    )
    result = wrap_commit_body(f"feat: x\n\n{block}")
    assert result == f"feat: x\n\n{block}"


def test_tilde_fenced_block_untouched() -> None:
    block = (
        "~~~text\n"
        "first line of the tilde block\n"
        "\n"
        "line one of the interior stanza\n"
        "line two of the interior stanza\n"
        "\n"
        "third\n"
        "~~~"
    )
    result = wrap_commit_body(f"feat: x\n\n{block}")
    assert result == f"feat: x\n\n{block}"


def test_backtick_fence_nested_in_tilde_fence_untouched() -> None:
    block = (
        "~~~markdown\n"
        "```text\n"
        "first\n"
        "\n"
        "line one of the interior stanza\n"
        "line two of the interior stanza\n"
        "\n"
        "third\n"
        "```\n"
        "~~~"
    )
    result = wrap_commit_body(f"feat: x\n\n{block}")
    assert result == f"feat: x\n\n{block}"


def test_prose_after_fenced_block_still_wraps() -> None:
    message = f"feat: x\n\n```\ncode a\n\ncode b\n```\n\n{LONG}"
    result = wrap_commit_body(message)
    assert "```\ncode a\n\ncode b\n```" in result
    assert max(len(ln) for ln in _body_lines(result)) <= BODY_WRAP_WIDTH


def test_trailing_trailer_block_untouched() -> None:
    trailer = (
        "Reviewed-by: A Person <averylongaddress@example.com>, B Person <b@example.com>"
    )
    assert len(trailer) > BODY_WRAP_WIDTH
    result = wrap_commit_body(f"feat: x\n\n{LONG}\n\n{trailer}")
    assert result.endswith(f"\n\n{trailer}")


def test_mid_body_colon_prose_still_wraps() -> None:
    prose = f"Verified: {LONG}"
    result = wrap_commit_body(f"feat: x\n\n{prose}\n\nRefs ABC-123")
    assert all(len(ln) <= BODY_WRAP_WIDTH for ln in _body_lines(result))
    assert result.endswith("\n\nRefs ABC-123")


def test_long_url_not_broken() -> None:
    url = "https://example.com/" + "a" * 90
    result = wrap_commit_body(f"feat: x\n\nSee {url} for details.")
    assert url in result


def test_custom_width() -> None:
    result = wrap_commit_body("feat: x\n\n" + "word " * 40, width=40)
    assert all(len(ln) <= 40 for ln in _body_lines(result))


def test_single_word_longer_than_width_overflows() -> None:
    # break_long_words=False — an unbreakable token overflows rather than being
    # split, which is what keeps URLs and paths intact.
    word = "a" * 100
    assert wrap_commit_body(f"feat: x\n\n{word}") == f"feat: x\n\n{word}"
