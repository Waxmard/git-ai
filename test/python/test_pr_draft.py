from git_ai._pr_draft import draft_body


def _log(*commits: str) -> str:
    return "".join(f"GITAI_COMMIT {c}\n" for c in commits)


def test_empty_log_drafts_nothing() -> None:
    assert draft_body("") == ""


def test_all_conventional_triggers_two_pass() -> None:
    log = _log("feat: add thing", "fix: patch thing")
    draft = draft_body(log)
    assert "### Features" in draft
    assert "- add thing" in draft
    assert "### Bug Fixes" in draft
    assert "- patch thing" in draft


def test_scope_and_bang_are_stripped() -> None:
    log = _log("feat(api)!: breaking", "fix(ui): tweak")
    draft = draft_body(log)
    assert "- breaking" in draft
    assert "- tweak" in draft


def test_body_lines_indented_under_bullet() -> None:
    log = _log("feat: x\nmore detail\n", "fix: y")
    draft = draft_body(log)
    assert "- x\n  more detail" in draft


def test_section_order_follows_catalog() -> None:
    log = _log("fix: b", "feat: a")
    draft = draft_body(log)
    idx_feat = draft.find("### Features")
    idx_fix = draft.find("### Bug Fixes")
    assert idx_feat != -1 and idx_fix != -1
    assert idx_feat < idx_fix


def test_churn_commits_folded_into_refinements_block() -> None:
    log = _log("feat: add thing", "perf: speed it up", "docs: document it")
    draft = draft_body(log, churn_subjects={"perf: speed it up", "docs: document it"})

    # The feature stays in its own section...
    assert "### Features" in draft
    assert "- add thing" in draft
    # ...while churn entries leave their type sections for the refinements block.
    assert "### Performance" not in draft
    assert "### Docs" not in draft
    assert "### Intra-branch refinements" in draft
    assert "- speed it up" in draft
    assert "- document it" in draft
    # The refinements block trails the real sections.
    assert draft.find("### Features") < draft.find("### Intra-branch refinements")


def test_churn_only_section_drops_the_section_header() -> None:
    # The only perf commit is churn → no ### Performance section at all.
    log = _log("feat: a", "perf: tune internal helper")
    draft = draft_body(log, churn_subjects={"perf: tune internal helper"})
    assert "### Performance" not in draft
    assert "### Intra-branch refinements" in draft


def test_no_churn_block_when_subjects_empty() -> None:
    log = _log("feat: a", "perf: real win")
    draft = draft_body(log, churn_subjects=set())
    assert "### Performance" in draft
    assert "### Intra-branch refinements" not in draft


def test_churn_subject_must_match_full_subject() -> None:
    # Matching is on the full subject, so a bare description does not fold.
    log = _log("feat: a", "perf: real win")
    draft = draft_body(log, churn_subjects={"real win"})
    assert "### Performance" in draft
    assert "### Intra-branch refinements" not in draft
