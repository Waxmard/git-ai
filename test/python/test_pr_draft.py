from git_ai._pr_draft import analyze


def _log(*commits: str) -> str:
    return "\x1e".join(commits) + "\x1e"


def test_empty_log_is_fallback() -> None:
    result = analyze("")
    assert result.two_pass is False
    assert result.draft_body == ""


def test_all_conventional_triggers_two_pass() -> None:
    log = _log("feat: add thing", "fix: patch thing")
    result = analyze(log)
    assert result.two_pass is True
    assert "### Features" in result.draft_body
    assert "- add thing" in result.draft_body
    assert "### Bug Fixes" in result.draft_body
    assert "- patch thing" in result.draft_body


def test_scope_and_bang_are_stripped() -> None:
    log = _log("feat(api)!: breaking", "fix(ui): tweak")
    result = analyze(log)
    assert result.two_pass is True
    assert "- breaking" in result.draft_body
    assert "- tweak" in result.draft_body


def test_body_lines_indented_under_bullet() -> None:
    log = _log("feat: x\nmore detail\n", "fix: y")
    result = analyze(log)
    assert result.two_pass is True
    assert "- x\n  more detail" in result.draft_body


def test_half_conventional_triggers_two_pass_boundary() -> None:
    # 2 of 4 conventional → conv*2 >= total → two_pass
    log = _log("feat: a", "random subject", "fix: b", "another random")
    result = analyze(log)
    assert result.two_pass is True


def test_mostly_unconventional_falls_back() -> None:
    # 1 of 3 conventional → fallback
    log = _log("feat: a", "random", "more random")
    result = analyze(log)
    assert result.two_pass is False
    assert result.draft_body == ""


def test_unknown_type_not_counted() -> None:
    # 'wip:' is not in the conventional set
    log = _log("wip: draft", "wip: more")
    result = analyze(log)
    assert result.two_pass is False


def test_section_order_follows_catalog() -> None:
    log = _log("fix: b", "feat: a")
    result = analyze(log)
    idx_feat = result.draft_body.find("### Features")
    idx_fix = result.draft_body.find("### Bug Fixes")
    assert idx_feat != -1 and idx_fix != -1
    assert idx_feat < idx_fix
