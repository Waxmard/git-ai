"""Branch-context helpers: base resolution, churn detection, context assembly."""

from __future__ import annotations

import hashlib
import re
import subprocess
from collections.abc import Callable
from pathlib import Path
from typing import TYPE_CHECKING, cast

if TYPE_CHECKING:
    from ._git import (
        _DIFF_FILE_HEADER,
        _git,
        git_is_ancestor,
        git_ref_exists,
    )
elif __package__ in (None, ""):
    import importlib as _importlib

    _git_mod = _importlib.import_module("_git")
    _git = _git_mod._git
    _DIFF_FILE_HEADER = _git_mod._DIFF_FILE_HEADER
    git_is_ancestor = _git_mod.git_is_ancestor
    git_ref_exists = _git_mod.git_ref_exists
else:
    from ._git import (
        _DIFF_FILE_HEADER,
        _git,
        git_is_ancestor,
        git_ref_exists,
    )

_BASE_CANDIDATE_NAMES = ("main", "master", "dev")

# Caps the fork-parent heuristic so thousands of stale remote branches can't
# stall a commit. Branches are taken most-recently-committed first.
_MAX_ENUMERATED_BRANCHES = 50

# Each churn-classified commit costs a `git show` plus a `git blame` per
# modified file; over the cap, churn detection is skipped entirely.
_MAX_CHURN_COMMITS = 50

# The content fingerprint diffs the whole branch; over the cap the rebase
# fast path is skipped rather than paying for a huge `git log -p`.
_MAX_CONTENT_ID_COMMITS = 200

_HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+")
_PORCELAIN_SHA_RE = re.compile(r"^([0-9a-f]{40}) ")


def _load_branch_cache_dir() -> Callable[..., Path]:
    """Lazily import branch_cache_dir, avoiding a circular import at module load."""
    if __package__ in (None, ""):
        import importlib  # noqa: PLC0415

        return cast(
            "Callable[..., Path]",
            importlib.import_module("_pr_incremental").branch_cache_dir,
        )
    from ._pr_incremental import branch_cache_dir  # noqa: PLC0415

    return branch_cache_dir


def get_default_branch(repo_path: str | Path) -> str | None:
    """Return the remote's default branch as a bare name (origin/HEAD), or None."""
    result = subprocess.run(
        ["git", "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        name = result.stdout.strip()
        if name:
            return name.removeprefix("origin/")
    return None


def _best_base_ref(repo_path: str | Path, name: str) -> str | None:
    """Resolve a base name to a usable ref, preferring the remote-tracking copy."""
    for ref in (f"origin/{name}", name):
        if git_ref_exists(repo_path, ref):
            return ref
    return None


def _candidate_base_names(repo_path: str | Path) -> list[str]:
    """Ordered, de-duped base candidates: default branch first, then conventions."""
    names: list[str] = []
    default = get_default_branch(repo_path)
    if default:
        names.append(default)
    for name in _BASE_CANDIDATE_NAMES:
        if name not in names:
            names.append(name)
    return names


def _count_range(
    repo_path: str | Path, rng: str, *, no_merges: bool = False
) -> int | None:
    """Count commits in a ``A..B`` range. None on git failure."""
    result = subprocess.run(
        ["git", "rev-list", "--count", *(["--no-merges"] if no_merges else []), rng],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    try:
        return int(result.stdout.strip())
    except ValueError:
        return None


def _commits_ahead(repo_path: str | Path, base_ref: str) -> int | None:
    """Count commits on HEAD not reachable from base_ref. None on git failure."""
    return _count_range(repo_path, f"{base_ref}..HEAD")


def base_warnings(
    repo_path: str | Path,
    base_branch: str,
    current_branch: str | None = None,
) -> list[str]:
    """Advisory warnings about a weird base/HEAD relationship for ``git-ai pr``.

    All are best-effort and non-fatal — each is suppressed on any git failure.
    Detects the cases that make a PR summary describe work not on this branch:

    1. A local base that lags its ``origin/`` copy (the compared ref), so the
       reader knows the remote — not the stale local branch — is the baseline.
    2. No ``origin/<base>`` at all, so the local base may be stale.
    3. HEAD forked from another branch that sits between the base and HEAD, so
       the PR diff folds in that branch's commits unless ``--base`` is narrowed.

    ``current_branch`` is used as-is when given, avoiding a second
    ``git rev-parse`` that could race and disagree with the caller.
    """
    warnings: list[str] = []
    origin_ref = f"origin/{base_branch}"
    has_origin = git_ref_exists(repo_path, origin_ref)
    has_local = git_ref_exists(repo_path, base_branch)

    if has_origin and has_local:
        behind = _count_range(repo_path, f"{base_branch}..{origin_ref}")
        if behind:
            warnings.append(
                f"local '{base_branch}' is {behind} commit(s) behind "
                f"'{origin_ref}'; comparing against '{origin_ref}'."
            )
    elif has_local and not has_origin:
        warnings.append(
            f"no remote-tracking '{origin_ref}'; comparing against local "
            f"'{base_branch}', which may be stale. run 'git fetch' if the PR "
            f"shows already-merged work."
        )

    # Fork detection needs a named branch — on detached HEAD "branch looks
    # forked from 'X'" is nonsense and contradicts the caller's own warning.
    base_ref = origin_ref if has_origin else (base_branch if has_local else None)
    if base_ref and current_branch is not None:
        fork = _nearest_fork_parent(repo_path, current_branch)
        if (
            fork
            and fork.removeprefix("origin/") != base_branch
            and git_is_ancestor(repo_path, base_ref, fork)
            and not git_is_ancestor(repo_path, fork, base_ref)
        ):
            warnings.append(
                f"branch looks forked from '{fork}', not '{base_branch}'; the "
                f"PR may include commits from '{fork}'. re-run with "
                f"--base {fork.removeprefix('origin/')} to scope it."
            )
    return warnings


def _base_name_from_pr_cache(
    git_dir: str | Path | None, branch: str | None, names: list[str]
) -> str | None:
    """Return the most-recent candidate base the user drafted a PR against.

    The PR cache key is ``hash(branch+base)`` and doesn't store the base, so
    each candidate's cache dir is probed and the newest match wins.
    """
    if not git_dir or not branch:
        return None
    branch_cache_dir = _load_branch_cache_dir()
    best: tuple[float, str] | None = None
    for name in names:
        cache_dir = branch_cache_dir(git_dir, branch, name)
        try:
            mtime = cache_dir.stat().st_mtime
        except OSError:
            continue
        if cache_dir.is_dir() and (best is None or mtime > best[0]):
            best = (mtime, name)
    return best[1] if best else None


def _list_branch_refs(repo_path: str | Path, current_branch: str | None) -> list[str]:
    """Local + origin branch short-refs, newest first, minus the current branch."""
    result = subprocess.run(
        [
            "git",
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname:short)",
            "refs/heads",
            "refs/remotes/origin",
        ],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return []
    exclude = {"origin"}
    if current_branch:
        exclude.add(current_branch)
        exclude.add(f"origin/{current_branch}")
    refs: list[str] = []
    for line in result.stdout.splitlines():
        ref = line.strip()
        if not ref or ref in exclude or ref.endswith("/HEAD"):
            continue
        refs.append(ref)
        if len(refs) >= _MAX_ENUMERATED_BRANCHES:
            break
    return refs


def _ahead_behind(repo_path: str | Path, ref: str) -> tuple[int, int] | None:
    """Return (ahead, behind): HEAD-only and ref-only commit counts. None on error."""
    result = subprocess.run(
        ["git", "rev-list", "--left-right", "--count", f"{ref}...HEAD"],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    parts = result.stdout.split()
    if len(parts) != 2:
        return None
    try:
        behind, ahead = int(parts[0]), int(parts[1])
    except ValueError:
        return None
    return ahead, behind


def _base_name_rank(ref: str, default_name: str | None) -> int:
    """Tie-break preference for equally-near bases: lower is preferred.

    Favours the remote's default branch, then conventional names, and the
    remote-tracking copy over an identical local branch.
    """
    name = ref.removeprefix("origin/")
    is_remote = ref.startswith("origin/")
    if default_name and name == default_name:
        base = 0
    elif name == "main":
        base = 1
    elif name == "master":
        base = 2
    elif name == "dev":
        base = 3
    else:
        base = 4
    return base * 2 + (0 if is_remote else 1)


def _branch_ahead_behind(
    repo_path: str | Path, current_branch: str | None
) -> list[tuple[str, int, int]] | None:
    """One-shot ``(ref, ahead, behind)`` for every candidate branch, or None.

    Uses ``for-each-ref``'s ``ahead-behind:HEAD`` token (git >= 2.41) to get
    every branch's divergence in one subprocess instead of a ``rev-list`` probe
    each. None when the token is unsupported, so the caller can fall back to
    per-ref probing. ``ahead``/``behind`` match :func:`_ahead_behind`.
    """
    result = subprocess.run(
        [
            "git",
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname:short)\t%(ahead-behind:HEAD)",
            "refs/heads",
            "refs/remotes/origin",
        ],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    exclude = {"origin"}
    if current_branch:
        exclude.add(current_branch)
        exclude.add(f"origin/{current_branch}")
    rows: list[tuple[str, int, int]] = []
    for line in result.stdout.splitlines():
        ref, _, counts = line.partition("\t")
        ref = ref.strip()
        if not ref or ref in exclude or ref.endswith("/HEAD"):
            continue
        parts = counts.split()
        if len(parts) != 2:
            continue
        try:
            ref_only, head_only = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        # `ahead-behind:HEAD` prints "<ref-ahead-of-HEAD> <HEAD-ahead-of-ref>",
        # i.e. ref-only then HEAD-only — our (ahead=HEAD-only, behind=ref-only).
        rows.append((ref, head_only, ref_only))
        if len(rows) >= _MAX_ENUMERATED_BRANCHES:
            break
    return rows


def _nearest_fork_parent(
    repo_path: str | Path, current_branch: str | None
) -> str | None:
    """Return the branch HEAD most likely forked from, or None.

    Scores every other branch by ``(commits-ahead, commits-behind, name-rank)``
    and takes the smallest — the nearest ancestor with the least divergence.
    Name-agnostic, so it finds ``release/*``, ``staging``, or a stacked parent
    branch, not just ``main``/``master``/``dev``. Branches that already contain
    all of HEAD are skipped.
    """
    default_name = get_default_branch(repo_path)
    rows = _branch_ahead_behind(repo_path, current_branch)
    if rows is None:
        rows = [
            (ref, ahead_behind[0], ahead_behind[1])
            for ref in _list_branch_refs(repo_path, current_branch)
            if (ahead_behind := _ahead_behind(repo_path, ref)) is not None
        ]
    best_key: tuple[int, int, int] | None = None
    best_ref: str | None = None
    for ref, ahead, behind in rows:
        if ahead == 0:
            continue
        key = (ahead, behind, _base_name_rank(ref, default_name))
        if best_key is None or key < best_key:
            best_key = key
            best_ref = ref
    return best_ref


def resolve_commit_base(
    repo_path: str | Path,
    *,
    override: str | None = None,
    git_dir: str | Path | None = None,
    branch: str | None = None,
) -> str | None:
    """Resolve the ref to compare the current branch against for commit context.

    Local-only cascade, first hit wins:

    1. ``override`` (e.g. ``--base`` / ``GIT_AI_COMMIT_BASE``)
    2. the base the user last drafted a PR against (git-ai PR cache), probed
       across the conventional base names
    3. the nearest fork-parent among all local/origin branches — handles
       ``main``/``master``/``dev`` plus ``release/*``, ``staging``, and stacked
       parent branches
    4. ``None`` when HEAD has no commits ahead of any branch — i.e. the commit
       is on the base branch itself, detached at base, or the base is
       unresolvable; callers should then omit branch context entirely.
    """
    if override:
        ref = _best_base_ref(repo_path, override)
        if ref is None and git_ref_exists(repo_path, override):
            ref = override
        return ref

    cached = _base_name_from_pr_cache(git_dir, branch, _candidate_base_names(repo_path))
    if cached:
        ref = _best_base_ref(repo_path, cached)
        if ref and (_commits_ahead(repo_path, ref) or 0) > 0:
            return ref

    return _nearest_fork_parent(repo_path, branch)


_INDEX_LINE_RE = re.compile(r"^index [0-9a-f]+\.\.[0-9a-f]+")
_HUNK_HEADER_RE = re.compile(r"^@@ .* @@")


def _normalize_diff_position(diff: str) -> str:
    """Erase a diff's line numbers and blob ids, keeping its text verbatim.

    Both move when a branch is rebased onto a newer base even though the change
    itself is identical. Everything else is kept byte-for-byte — including the
    whitespace inside ``+``/``-`` lines, which ``git patch-id`` discards and an
    indentation-only edit depends on. Erasing the hunk header also erases where
    a change sits, which is why the diff is taken with context lines: they pin
    the position without pinning the line numbers.
    """
    out = []
    for line in diff.split("\n"):
        if _INDEX_LINE_RE.match(line):
            continue
        out.append("@@" if _HUNK_HEADER_RE.match(line) else line)
    return "\n".join(out)


def branch_content_id(
    repo_path: str | Path, base_ref: str, *, max_commits: int = _MAX_CONTENT_ID_COMMITS
) -> str | None:
    """Fingerprint the branch's content against ``base_ref``, or None if unavailable.

    Hashes the position-normalized three-dot diff together with the branch's
    full commit messages, so a rebase or amend that preserves what the branch
    does and says yields the same id even though every SHA changed. Hashing the
    net diff rather than a per-commit ``git patch-id`` set is what catches
    whitespace-only edits and merge conflict resolutions; hashing whole
    messages rather than subjects catches a body-only amend, which the PR
    prompt reads.

    None (no git failure surfaced) on an empty range, a range over
    ``max_commits``, or any git error — callers treat it as "no match".
    """
    # Counted --no-merges so a merge-heavy branch doesn't trip the cap on
    # commits that carry no message of their own.
    count = _count_range(repo_path, f"{base_ref}..HEAD", no_merges=True)
    if not count or count > max_commits:
        return None
    diff = subprocess.run(
        ["git", "diff", "--no-color", "--no-ext-diff", "-U3", f"{base_ref}...HEAD"],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
        check=False,
    )
    if diff.returncode != 0:
        return None
    messages = subprocess.run(
        [
            "git",
            "log",
            "--no-merges",
            "--no-color",
            "--format=%B%x00",
            f"{base_ref}..HEAD",
        ],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
        check=False,
    )
    if messages.returncode != 0:
        return None
    payload = _normalize_diff_position(diff.stdout) + "\0" + messages.stdout
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def get_branch_commit_subjects(
    repo_path: str | Path, base_ref: str, *, limit: int = 30
) -> str:
    return _git(
        repo_path,
        "log",
        "--no-merges",
        "--pretty=%s",
        f"-n{limit}",
        f"{base_ref}..HEAD",
    ).strip()


def _commit_preimage_ranges(
    repo_path: str | Path, commit: str
) -> list[tuple[str, int, int]] | None:
    """Return ``(pre_image_path, start, count)`` for lines a commit edits/deletes.

    Pure additions (old hunk count 0) are skipped — they introduce code rather
    than refine existing code. Returns None on a git failure.
    """
    try:
        diff = _git(repo_path, "show", "--no-color", "-M", "-U0", "--format=", commit)
    except RuntimeError:
        return None
    ranges: list[tuple[str, int, int]] = []
    current_a: str | None = None
    for line in diff.splitlines():
        header_match = _DIFF_FILE_HEADER.match(line)
        if header_match:
            current_a = header_match.group("a")
            continue
        if line.startswith("@@") and current_a is not None:
            hunk = _HUNK_RE.match(line)
            if hunk:
                start = int(hunk.group(1))
                count = int(hunk.group(2)) if hunk.group(2) is not None else 1
                if count > 0:
                    ranges.append((current_a, start, count))
    return ranges


def _blame_introducers(
    repo_path: str | Path, rev: str, file: str, start: int, count: int
) -> set[str] | None:
    """Return the SHAs that introduced lines ``start..start+count-1`` of ``file``
    at ``rev``. Returns None when blame fails (e.g. file absent at ``rev``)."""
    end = start + count - 1
    result = subprocess.run(
        ["git", "blame", "--porcelain", "-l", f"-L{start},{end}", rev, "--", file],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    shas: set[str] = set()
    for line in result.stdout.splitlines():
        match = _PORCELAIN_SHA_RE.match(line)
        if match:
            shas.add(match.group(1))
    return shas


def get_branch_churn_subjects(
    repo_path: str | Path,
    branch_base: str,
    *,
    classify_base: str | None = None,
    limit: int = _MAX_CHURN_COMMITS,
) -> list[str]:
    """Subjects of commits that only refine code this branch itself introduced.

    A commit in ``classify_base..HEAD`` is *intra-branch churn* when ``git
    blame`` of its parent traces every pre-image line it edits or deletes back
    to ``branch_base..HEAD``. Such a follow-up (``fix``/``refactor``/``perf``/
    ``docs`` on code added earlier in the same PR) is invisible from the base
    branch, whose net diff shows only the final feature. Pure additions never
    count — they introduce code, so they keep their own section.

    ``classify_base`` defaults to ``branch_base``; pass the incremental base
    (e.g. a cached HEAD SHA) to classify only new commits while still treating
    the whole branch as "branch-introduced".

    Best-effort: ``[]`` on any git failure or a classify range over ``limit``.
    """
    if classify_base is None:
        classify_base = branch_base
    try:
        branch_shas = set(_git(repo_path, "rev-list", f"{branch_base}..HEAD").split())
        commits = _git(
            repo_path, "rev-list", "--no-merges", f"{classify_base}..HEAD"
        ).split()
    except RuntimeError:
        return []
    if not commits or len(commits) > limit:
        return []

    churn: list[str] = []
    for commit in commits:
        ranges = _commit_preimage_ranges(repo_path, commit)
        if not ranges:
            continue  # parse failure or pure-addition commit → not churn
        branch_local = True
        for file, start, count in ranges:
            shas = _blame_introducers(repo_path, f"{commit}^", file, start, count)
            if not shas or not shas <= branch_shas:
                branch_local = False
                break
        if branch_local:
            try:
                subject = _git(repo_path, "show", "-s", "--format=%s", commit).strip()
            except RuntimeError:
                continue
            if subject:
                churn.append(subject)
    return churn


def format_branch_context(
    *,
    branch_name: str | None = None,
    branch_commits: str | None = None,
    branch_diffstat: str | None = None,
) -> str:
    """Assemble the optional branch-context block for a commit prompt.

    Empty-valued tags are dropped, so a fresh branch or a commit made directly
    on the base branch yields ``""``.
    """
    segments: list[str] = []
    if branch_name and branch_name.strip():
        segments.append(f"<branch>{branch_name.strip()}</branch>")
    if branch_commits and branch_commits.strip():
        segments.append(
            f"<branch_commits>\n{branch_commits.strip()}\n</branch_commits>"
        )
    if branch_diffstat and branch_diffstat.strip():
        segments.append(
            f"<branch_diffstat>\n{branch_diffstat.strip()}\n</branch_diffstat>"
        )
    return "\n".join(segments)
