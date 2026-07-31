"""Tests for repo-mode incremental PR generation helpers."""

from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

import pytest
from git_ai import (
    build_mr_prompt,
    get_git_dir,
    get_head_sha,
    load_cached_content_id,
    load_cached_pr,
    load_cached_pr_sha,
    parse_mr_response,
    prepare_repo_pr_context,
    prune_pr_cache,
    save_cached_pr,
)
from git_ai._pr_incremental import branch_cache_dir


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()


def _commit(repo: Path, name: str, content: str, message: str) -> str:
    path = repo / name
    path.write_text(content, encoding="utf-8")
    subprocess.run(["git", "add", name], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-m", message], cwd=repo, check=True)
    return _git(repo, "rev-parse", "HEAD")


def _make_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    subprocess.run(["git", "init", "-b", "main", repo], check=True)
    subprocess.run(
        ["git", "config", "user.email", "test@test.com"], cwd=repo, check=True
    )
    subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "init"], cwd=repo, check=True
    )
    subprocess.run(["git", "checkout", "-b", "feature/test"], cwd=repo, check=True)
    return repo


def test_prepare_repo_pr_context_uses_incremental_range_from_explicit_sha(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")
    first_sha = _git(repo, "rev-parse", "HEAD")
    _commit(repo, "two.txt", "two\n", "fix: add second")

    context = prepare_repo_pr_context(
        repo,
        base_branch="main",
        existing_pr="feat: existing title\n\n### Features\n- old",
        previous_head_sha=first_sha,
    )

    assert context.input_base == first_sha
    assert context.existing_pr == "feat: existing title\n\n### Features\n- old"
    assert "fix: add second" in context.commit_log
    assert "feat: add first" not in context.commit_log
    assert "two.txt" in context.diff_stat
    # GITAI_COMMIT prefixes are what let the builder pick two-pass vs fallback.
    assert "GITAI_COMMIT" in context.commit_log


def test_prepare_repo_pr_context_raises_on_unresolvable_previous_head_sha(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")

    with pytest.raises(ValueError, match="not found in repo"):
        prepare_repo_pr_context(
            repo,
            base_branch="main",
            previous_head_sha="deadbeef00000000",
        )


def test_prepare_repo_pr_context_incremental_enables_two_pass(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")
    first_sha = _git(repo, "rev-parse", "HEAD")
    _commit(repo, "two.txt", "two\n", "feat: add second")

    context = prepare_repo_pr_context(
        repo,
        base_branch="main",
        existing_pr="feat: old title\n\n### Features\n- old",
        previous_head_sha=first_sha,
    )

    _, user_input = build_mr_prompt(
        diff=context.diff,
        commit_log=context.commit_log,
        diff_stat=context.diff_stat,
        existing_pr=context.existing_pr,
    )
    # conventional commits on incremental path must reach the two-pass prompt
    assert "<draft>" in user_input
    assert "<commit_log>" not in user_input


def test_prepare_repo_pr_context_short_circuits_when_no_new_commits(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    head_sha = _commit(repo, "one.txt", "one\n", "feat: add first")
    git_dir = get_git_dir(repo)

    save_cached_pr(
        git_dir,
        "feature/test",
        "main",
        "feat: cached title\n\n### Features\n- cached",
        head_sha,
    )

    context = prepare_repo_pr_context(repo, base_branch="main")

    assert context.no_changes is True
    assert context.existing_pr == "feat: cached title\n\n### Features\n- cached"
    assert context.diff == ""
    assert context.commit_log == ""


def test_prepare_repo_pr_context_rejects_fresh_and_previous_sha(tmp_path: Path) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")

    with pytest.raises(ValueError, match="fresh=True cannot be combined"):
        prepare_repo_pr_context(
            repo,
            base_branch="main",
            previous_head_sha="abc123",
            fresh=True,
        )


def test_caller_flow_caches_and_short_circuits_on_unchanged_head(
    tmp_path: Path,
) -> None:
    """End-to-end repo-mode caller flow: generate → save → reuse without LLM."""
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")

    # First call: cache empty → caller runs LLM and saves output.
    first_ctx = prepare_repo_pr_context(repo, base_branch="main")
    assert first_ctx.no_changes is False
    system, user = build_mr_prompt(
        diff=first_ctx.diff,
        commit_log=first_ctx.commit_log,
        diff_stat=first_ctx.diff_stat,
        release_context=first_ctx.release_context,
        existing_pr=first_ctx.existing_pr,
    )
    assert system and user
    first_text = parse_mr_response("feat: title\n\n### Features\n- first")
    assert first_ctx.current_branch == "feature/test"
    save_cached_pr(
        get_git_dir(repo),
        first_ctx.current_branch,
        "main",
        first_text,
        first_ctx.head_sha,
    )

    # Second call: same HEAD → context.no_changes signals caller to skip LLM.
    second_ctx = prepare_repo_pr_context(repo, base_branch="main")
    assert second_ctx.no_changes is True
    assert second_ctx.existing_pr == first_text

    git_dir = get_git_dir(repo)
    assert load_cached_pr(git_dir, "feature/test", "main") == first_text
    assert load_cached_pr_sha(git_dir, "feature/test", "main") == get_head_sha(repo)


def test_caller_flow_previous_head_sha_overrides_cache(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")
    first_sha = _git(repo, "rev-parse", "HEAD")
    _commit(repo, "two.txt", "two\n", "fix: add second")

    ctx = prepare_repo_pr_context(
        repo,
        base_branch="main",
        previous_head_sha=first_sha,
        existing_pr="feat: title\n\n### Features\n- first",
    )
    _, user = build_mr_prompt(
        diff=ctx.diff,
        commit_log=ctx.commit_log,
        diff_stat=ctx.diff_stat,
        release_context=ctx.release_context,
        existing_pr=ctx.existing_pr,
    )

    assert "<existing_pr>" in user
    # two-pass prompt strips type prefix into <draft>; check description word
    assert "add second" in user
    assert "add first" not in user


def test_prepare_repo_pr_context_raises_on_non_ancestor_previous_head_sha(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")
    # orphan branch commit exists in repo but shares no history with feature/test
    subprocess.run(["git", "checkout", "--orphan", "orphan-tmp"], cwd=repo, check=True)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "orphan"], cwd=repo, check=True
    )
    orphan_sha = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    subprocess.run(["git", "checkout", "feature/test"], cwd=repo, check=True)

    with pytest.raises(ValueError, match="not an ancestor"):
        prepare_repo_pr_context(repo, base_branch="main", previous_head_sha=orphan_sha)


def test_prepare_repo_pr_context_excludes_lockfiles_from_diff_only(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    # Default excludes drop lockfile content from the full diff, but the stat
    # keeps it so a lockfile-only bump still leaves a trace for the model.
    _commit(repo, "package-lock.json", "lock_contents\n", "chore: lockfile")
    _commit(repo, "app.py", "print('hi')\n", "feat: add app")

    ctx = prepare_repo_pr_context(repo, base_branch="main")

    assert "app.py" in ctx.diff
    assert "package-lock.json" not in ctx.diff
    assert "package-lock.json" in ctx.diff_stat


def test_prepare_repo_pr_context_diff_stat_honors_user_ignore(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    # User `.git-ai-ignore` entries stay excluded from the stat, unlike the
    # built-in lockfile defaults.
    (repo / ".git-ai-ignore").write_text("generated.txt\n", encoding="utf-8")
    _commit(repo, "package-lock.json", "lock_contents\n", "chore: lockfile")
    _commit(repo, "generated.txt", "noise\n", "chore: generated")
    _commit(repo, "app.py", "print('hi')\n", "feat: add app")

    ctx = prepare_repo_pr_context(repo, base_branch="main")

    assert "package-lock.json" in ctx.diff_stat
    assert "generated.txt" not in ctx.diff_stat


def test_prepare_repo_pr_context_from_subdirectory_uses_repo_root_diff(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add root file")
    subdir = repo / "nested"
    subdir.mkdir()

    ctx = prepare_repo_pr_context(subdir, base_branch="main")

    assert "one.txt" in ctx.diff
    assert "feat: add root file" in ctx.commit_log


def test_prepare_repo_pr_context_from_subdirectory_uses_root_ignore_file(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    (repo / ".git-ai-ignore").write_text("root-only.txt\n", encoding="utf-8")
    _commit(repo, "root-only.txt", "ignored\n", "chore: add ignored file")
    _commit(repo, "app.py", "print('hi')\n", "feat: add app")
    subdir = repo / "nested"
    subdir.mkdir()

    ctx = prepare_repo_pr_context(subdir, base_branch="main")

    assert "app.py" in ctx.diff
    assert "root-only.txt" not in ctx.diff


def test_prepare_repo_pr_context_negation_reincludes_lockfile(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "package-lock.json", "lock_contents\n", "chore: lockfile")
    _commit(repo, "app.py", "print('hi')\n", "feat: add app")
    (repo / ".git-ai-ignore").write_text("!package-lock.json\n", encoding="utf-8")

    ctx = prepare_repo_pr_context(repo, base_branch="main")

    assert "package-lock.json" in ctx.diff


def test_prepare_repo_pr_context_non_ancestor_cached_sha_falls_back(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")
    # create an orphan SHA to plant in the cache
    subprocess.run(["git", "checkout", "--orphan", "orphan-tmp2"], cwd=repo, check=True)
    subprocess.run(
        ["git", "commit", "--allow-empty", "-m", "orphan"], cwd=repo, check=True
    )
    orphan_sha = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=repo,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()
    subprocess.run(["git", "checkout", "feature/test"], cwd=repo, check=True)

    git_dir = Path(repo) / ".git"
    save_cached_pr(git_dir, "feature/test", "main", "old pr text", orphan_sha)

    ctx = prepare_repo_pr_context(repo, base_branch="main")
    assert ctx.input_base == "main"
    assert ctx.no_changes is False
    assert "feat: add first" in ctx.commit_log


def test_prepare_repo_pr_context_raises_on_missing_base_branch(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")

    with pytest.raises(RuntimeError, match="base branch 'dev' not found"):
        prepare_repo_pr_context(repo, base_branch="dev")


def test_prepare_repo_pr_context_uses_origin_base_when_local_missing(
    tmp_path: Path,
) -> None:
    repo = _make_repo(tmp_path)
    base_sha = _git(repo, "rev-parse", "HEAD")
    # Only origin/dev exists (fetched, never checked out) — use it, don't error.
    _git(repo, "update-ref", "refs/remotes/origin/dev", base_sha)
    _commit(repo, "one.txt", "one\n", "feat: add first")

    ctx = prepare_repo_pr_context(repo, base_branch="dev")
    assert ctx.no_changes is False
    assert "feat: add first" in ctx.commit_log


def test_prepare_repo_pr_context_prefers_origin_over_stale_local_base(
    tmp_path: Path,
) -> None:
    # Local `main` lags origin/main; the stale base would leak the already-merged
    # upstream commit into the diff/log.
    repo = tmp_path / "repo"
    subprocess.run(["git", "init", "-b", "main", repo], check=True)
    subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "T"], cwd=repo, check=True)
    sha_a = _commit(repo, "a.txt", "a\n", "chore: init")
    sha_b = _commit(repo, "b.txt", "b\n", "feat: upstream work already merged")
    subprocess.run(["git", "checkout", "-b", "feature/x"], cwd=repo, check=True)
    _commit(repo, "c.txt", "c\n", "refactor: branch-only work")
    # origin/main is at B (the real base); local main lags at A.
    _git(repo, "update-ref", "refs/remotes/origin/main", sha_b)
    _git(repo, "branch", "-f", "main", sha_a)

    ctx = prepare_repo_pr_context(repo, base_branch="main")
    assert "refactor: branch-only work" in ctx.commit_log
    assert "upstream work already merged" not in ctx.commit_log
    assert "c.txt" in ctx.diff
    assert "b.txt" not in ctx.diff
    assert any("behind 'origin/main'" in w for w in ctx.warnings)


def test_prepare_warns_when_no_origin_base(tmp_path: Path) -> None:
    # Local base only, no origin/<base>: the base may be stale and we can't know.
    repo = _make_repo(tmp_path)
    _commit(repo, "one.txt", "one\n", "feat: add first")

    ctx = prepare_repo_pr_context(repo, base_branch="main")
    assert any("no remote-tracking 'origin/main'" in w for w in ctx.warnings)


def test_prepare_warns_when_forked_from_other_branch(tmp_path: Path) -> None:
    # HEAD forks from feat-x, which forks from main — a PR against main folds in
    # feat-x's commit, so warn and suggest --base feat-x.
    repo = tmp_path / "repo"
    subprocess.run(["git", "init", "-b", "main", repo], check=True)
    subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "T"], cwd=repo, check=True)
    _commit(repo, "a.txt", "a\n", "chore: init")
    subprocess.run(["git", "checkout", "-b", "feat-x"], cwd=repo, check=True)
    _commit(repo, "x.txt", "x\n", "feat: x work")
    subprocess.run(["git", "checkout", "-b", "feature/test"], cwd=repo, check=True)
    _commit(repo, "y.txt", "y\n", "feat: build on x")

    ctx = prepare_repo_pr_context(repo, base_branch="main")
    assert any(
        "forked from 'feat-x'" in w and "--base feat-x" in w for w in ctx.warnings
    )


def test_prepare_raises_on_no_common_ancestor(tmp_path: Path) -> None:
    # Unrelated histories: the three-dot diff would error cryptically.
    repo = tmp_path / "repo"
    subprocess.run(["git", "init", "-b", "main", repo], check=True)
    subprocess.run(["git", "config", "user.email", "t@t.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "T"], cwd=repo, check=True)
    _commit(repo, "a.txt", "a\n", "chore: init main")
    subprocess.run(["git", "checkout", "--orphan", "unrelated"], cwd=repo, check=True)
    _commit(repo, "u.txt", "u\n", "feat: unrelated root")

    with pytest.raises(RuntimeError, match="no common ancestor"):
        prepare_repo_pr_context(repo, base_branch="main")


def test_prepare_warns_on_detached_head(tmp_path: Path) -> None:
    repo = _make_repo(tmp_path)
    feature_sha = _commit(repo, "one.txt", "one\n", "feat: add first")
    subprocess.run(["git", "checkout", feature_sha], cwd=repo, check=True)

    ctx = prepare_repo_pr_context(repo, base_branch="main")
    assert ctx.current_branch is None
    assert any("detached HEAD" in w for w in ctx.warnings)


def test_prepare_no_warnings_on_clean_tree(tmp_path: Path) -> None:
    # HEAD forks directly from main, local main matches origin/main → no warnings.
    repo = _make_repo(tmp_path)
    base_sha = _git(repo, "rev-parse", "HEAD")
    _git(repo, "update-ref", "refs/remotes/origin/main", base_sha)
    _commit(repo, "one.txt", "one\n", "feat: add first")

    ctx = prepare_repo_pr_context(repo, base_branch="main")
    assert ctx.warnings == []


def _rebase_repo(tmp_path: Path) -> Path:
    repo = _make_repo(tmp_path)
    _commit(repo, "f.txt", "a\nb\n", "feat: add f")
    _commit(repo, "f.txt", "a\nb\nc\n", "fix: extend f")
    return repo


def _seed_cache(repo: Path, text: str = "feat: cached title\n\ncached body") -> None:
    ctx = prepare_repo_pr_context(repo, base_branch="main")
    save_cached_pr(
        get_git_dir(repo), "feature/test", "main", text, ctx.head_sha, ctx.content_id
    )


def _move_main_and_rebase(repo: Path) -> None:
    subprocess.run(["git", "checkout", "main"], cwd=repo, check=True)
    _commit(repo, "other.txt", "x\n", "chore: main moves")
    subprocess.run(["git", "checkout", "feature/test"], cwd=repo, check=True)
    subprocess.run(["git", "rebase", "main"], cwd=repo, check=True)


def test_prepare_reuses_cache_after_content_preserving_rebase(tmp_path: Path) -> None:
    repo = _rebase_repo(tmp_path)
    _seed_cache(repo)
    _move_main_and_rebase(repo)

    ctx = prepare_repo_pr_context(repo, base_branch="main")

    assert ctx.no_changes is True
    assert ctx.existing_pr == "feat: cached title\n\ncached body"
    assert any("content is unchanged" in w for w in ctx.warnings)


def test_prepare_regenerates_when_rebase_carries_new_work(tmp_path: Path) -> None:
    repo = _rebase_repo(tmp_path)
    _seed_cache(repo)
    _move_main_and_rebase(repo)
    _commit(repo, "f.txt", "a\nb\nc\nd\n", "feat: more work")

    ctx = prepare_repo_pr_context(repo, base_branch="main")

    assert ctx.no_changes is False
    assert ctx.existing_pr == "feat: cached title\n\ncached body"
    # Falls back to the full branch diff: the pre-rebase commits are gone.
    assert ctx.input_base == "main"
    assert "feat: add f" in ctx.commit_log
    assert any("history was rewritten" in w for w in ctx.warnings)


def test_prepare_regenerates_after_reword_only_rewrite(tmp_path: Path) -> None:
    repo = _rebase_repo(tmp_path)
    _seed_cache(repo)
    subprocess.run(
        ["git", "commit", "--amend", "-m", "fix: extend f, reworded"],
        cwd=repo,
        check=True,
    )

    ctx = prepare_repo_pr_context(repo, base_branch="main")

    assert ctx.no_changes is False
    assert any("history was rewritten" in w for w in ctx.warnings)


def test_prepare_previous_head_sha_error_names_rebase(tmp_path: Path) -> None:
    repo = _rebase_repo(tmp_path)
    stale_sha = _git(repo, "rev-parse", "HEAD")
    subprocess.run(
        ["git", "commit", "--amend", "-m", "fix: extend f, reworded"],
        cwd=repo,
        check=True,
    )

    with pytest.raises(ValueError, match="rebase or amend"):
        prepare_repo_pr_context(repo, base_branch="main", previous_head_sha=stale_sha)


def test_save_cached_pr_round_trips_content_id(tmp_path: Path) -> None:
    repo = _make_repo(tmp_path)
    git_dir = get_git_dir(repo)

    save_cached_pr(git_dir, "feature/test", "main", "text", "abc123", "fingerprint")

    assert load_cached_content_id(git_dir, "feature/test", "main") == "fingerprint"


def test_prune_pr_cache_drops_entries_for_deleted_branches(tmp_path: Path) -> None:
    repo = _rebase_repo(tmp_path)
    git_dir = get_git_dir(repo)
    save_cached_pr(git_dir, "feature/test", "main", "live text", "sha1")
    save_cached_pr(git_dir, "feature/gone", "main", "dead text", "sha2")

    prune_pr_cache(git_dir)

    assert load_cached_pr(git_dir, "feature/test", "main") == "live text"
    assert load_cached_pr(git_dir, "feature/gone", "main") is None


def test_prune_pr_cache_ages_out_entries_without_a_branch_name(
    tmp_path: Path,
) -> None:
    repo = _rebase_repo(tmp_path)
    git_dir = get_git_dir(repo)
    save_cached_pr(git_dir, "feature/test", "main", "legacy text", "sha1")
    legacy_dir = branch_cache_dir(git_dir, "feature/test", "main")
    (legacy_dir / "branch-name").unlink()

    prune_pr_cache(git_dir)
    assert load_cached_pr(git_dir, "feature/test", "main") == "legacy text"

    aged = time.time() - 91 * 86400
    os.utime(legacy_dir, (aged, aged))
    prune_pr_cache(git_dir)

    assert load_cached_pr(git_dir, "feature/test", "main") is None
