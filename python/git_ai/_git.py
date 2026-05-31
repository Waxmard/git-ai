"""Git helper utilities for git-ai."""

from __future__ import annotations

import re
import subprocess
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import TYPE_CHECKING, cast

if TYPE_CHECKING:
    from ._ignore import load_ignore_patterns, to_pathspec_args
elif __package__ in (None, ""):
    import importlib

    _ignore_mod = importlib.import_module("_ignore")
    to_pathspec_args = _ignore_mod.to_pathspec_args
    load_ignore_patterns = _ignore_mod.load_ignore_patterns
else:
    from ._ignore import load_ignore_patterns, to_pathspec_args

_CONVENTIONAL_TYPES = frozenset(
    ["feat", "fix", "refactor", "docs", "chore", "ci", "test", "style", "perf", "build"]
)

DEFAULT_RELEASE_CONTEXT = (
    "Release context: no release tags found — treat all changes as unreleased"
)


def _git(repo_path: str | Path, *args: str) -> str:
    """Run a git command and return stdout. Raises RuntimeError on failure."""
    result = subprocess.run(
        ["git", *args],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def get_git_dir(repo_path: str | Path) -> str:
    """Return the repository git dir path."""
    git_dir = _git(repo_path, "rev-parse", "--git-dir").strip()
    git_dir_path = Path(git_dir)
    if git_dir_path.is_absolute():
        return str(git_dir_path)
    return str((Path(repo_path) / git_dir_path).resolve())


def get_repo_root(repo_path: str | Path) -> Path:
    """Return the repository top-level directory."""
    return Path(_git(repo_path, "rev-parse", "--show-toplevel").strip())


def get_current_branch(repo_path: str | Path) -> str | None:
    """Return the current branch name, or None when detached."""
    branch = _git(repo_path, "branch", "--show-current").strip()
    return branch or None


def get_head_sha(repo_path: str | Path) -> str:
    """Return HEAD commit SHA."""
    return _git(repo_path, "rev-parse", "HEAD").strip()


def git_ref_exists(repo_path: str | Path, ref: str) -> bool:
    """Return True when ref resolves to a commit in this repo."""
    result = subprocess.run(
        ["git", "cat-file", "-e", f"{ref}^{{commit}}"],
        cwd=str(repo_path),
        capture_output=True,
        check=False,
    )
    return result.returncode == 0


def git_is_ancestor(
    repo_path: str | Path, ancestor_ref: str, descendant_ref: str
) -> bool:
    """Return True if ancestor_ref is an ancestor of descendant_ref."""
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor_ref, descendant_ref],
        cwd=str(repo_path),
        capture_output=True,
        check=False,
    )
    return result.returncode == 0


def check_git_repo(repo_path: str | Path) -> None:
    """Raise RuntimeError if not inside a git repository."""
    result = subprocess.run(
        ["git", "rev-parse", "--git-dir"],
        cwd=str(repo_path),
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"{repo_path} is not inside a git repository")


def _resolve_exclude_patterns(
    repo_path: str | Path,
    exclude_patterns: list[str] | tuple[str, ...] | None,
) -> list[str] | tuple[str, ...]:
    """Auto-load ``.git-ai-ignore`` + lockfile defaults when patterns is None.

    Pass an empty list/tuple to opt out of all filtering.
    """
    if exclude_patterns is not None:
        return exclude_patterns
    return load_ignore_patterns(get_repo_root(repo_path))


def get_staged_diff(
    repo_path: str | Path,
    *,
    exclude_patterns: list[str] | tuple[str, ...] | None = None,
) -> str:
    """Return staged diff. Raises RuntimeError if nothing is staged.

    When ``exclude_patterns`` is omitted, auto-loads ``.git-ai-ignore`` from the
    repo root and applies built-in lockfile defaults. Pass ``exclude_patterns=[]``
    to opt out of all filtering.
    """
    pathspec = to_pathspec_args(_resolve_exclude_patterns(repo_path, exclude_patterns))
    quiet = subprocess.run(
        ["git", "diff", "--staged", "--quiet", *pathspec],
        cwd=str(repo_path),
        capture_output=True,
        check=False,
    )
    if quiet.returncode == 0:
        raise RuntimeError("No staged changes to summarize")
    return _git(repo_path, "diff", "--staged", *pathspec)


def get_release_context(repo_path: str | Path) -> str:
    """Return release context string (last tag + commits since)."""
    result = subprocess.run(
        ["git", "describe", "--tags", "--abbrev=0"],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return DEFAULT_RELEASE_CONTEXT

    last_tag = result.stdout.strip()
    count = subprocess.run(
        ["git", "rev-list", "--count", f"{last_tag}..HEAD"],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
        check=False,
    )
    commits_since = count.stdout.strip() if count.returncode == 0 else "?"
    return (
        f"Release context: last tag {last_tag}, {commits_since} commits since"
        " — staged changes are unreleased"
    )


def get_mr_release_context(repo_path: str | Path) -> str:
    """Return release context string with semver guidance for MR descriptions."""
    result = subprocess.run(
        ["git", "describe", "--tags", "--abbrev=0"],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return DEFAULT_RELEASE_CONTEXT

    last_tag = result.stdout.strip()
    count = subprocess.run(
        ["git", "rev-list", "--count", f"{last_tag}..HEAD"],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
        check=False,
    )
    commits_since = count.stdout.strip() if count.returncode == 0 else "?"

    semver_context = ""
    match = re.match(r"^v?(\d+)\.(\d+)\.(\d+)", last_tag)
    if match:
        major = int(match.group(1))
        minor = int(match.group(2))
        patch = int(match.group(3))
        semver_context = (
            f". Next release: breaking→v{major + 1}.0.0, "
            f"feature→v{major}.{minor + 1}.0, "
            f"fix→v{major}.{minor}.{patch + 1}"
        )

    return (
        f"Release context: current version {last_tag},"
        f" {commits_since} commits since last release{semver_context}"
    )


_BASE_CANDIDATE_NAMES = ("main", "master", "dev")


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
    """Return the remote's default branch name (origin/HEAD), or None.

    Strips the ``origin/`` prefix so the result is a bare branch name such as
    ``main`` or ``dev``.
    """
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


def _commits_ahead(repo_path: str | Path, base_ref: str) -> int | None:
    """Count commits on HEAD not reachable from base_ref. None on git failure."""
    result = subprocess.run(
        ["git", "rev-list", "--count", f"{base_ref}..HEAD"],
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


def _base_name_from_pr_cache(
    git_dir: str | Path | None, branch: str | None, names: list[str]
) -> str | None:
    """Return the most-recent candidate base the user drafted a PR against.

    git-ai's PR cache lives under ``<git-dir>/pr-cache/<hash(branch+base)>/``;
    the base is not stored, so we probe each candidate's cache dir and pick the
    most recently written match. Reflects an explicit ``git-ai pr`` choice.
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


# Cap on branches scored by the fork-parent heuristic, so a repo with
# thousands of stale remote branches can't make a commit crawl. Branches are
# considered most-recently-committed first, so the relevant ones are kept.
_MAX_ENUMERATED_BRANCHES = 50


def _list_branch_refs(repo_path: str | Path, current_branch: str | None) -> list[str]:
    """Local + origin branch short-refs, newest first, minus the current branch.

    Excludes the current branch (and its ``origin/`` counterpart) and the
    ``origin/HEAD`` pointer, then caps the list at
    :data:`_MAX_ENUMERATED_BRANCHES`.
    """
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

    Uses ``for-each-ref``'s ``ahead-behind:HEAD`` token (git >= 2.41) to compute
    each branch's divergence from HEAD in a single subprocess, replacing one
    ``git rev-list`` probe per branch. ``ahead``/``behind`` match
    :func:`_ahead_behind` (``ahead`` = HEAD-only commits, ``behind`` = ref-only).
    Returns None when the token is unsupported (older git exits non-zero) so the
    caller can fall back to per-ref probing. Same exclusions and
    :data:`_MAX_ENUMERATED_BRANCHES` cap as :func:`_list_branch_refs`.
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
    and picks the smallest: the nearest ancestor with the least divergence.
    This finds the real base regardless of name — ``release/*``, ``staging``, a
    parent feature branch in a stacked PR — not just ``main``/``master``/``dev``.
    Branches that already contain all of HEAD (nothing ahead) are skipped.

    Divergence comes from a single :func:`_branch_ahead_behind` call, falling
    back to per-ref :func:`_ahead_behind` probing only on git too old for the
    ``ahead-behind`` token.
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


def get_branch_commit_subjects(
    repo_path: str | Path, base_ref: str, *, limit: int = 30
) -> str:
    """Return up to ``limit`` non-merge commit subjects on HEAD since base_ref."""
    return _git(
        repo_path,
        "log",
        "--no-merges",
        "--pretty=%s",
        f"-n{limit}",
        f"{base_ref}..HEAD",
    ).strip()


def format_branch_context(
    *,
    branch_name: str | None = None,
    branch_commits: str | None = None,
    branch_diffstat: str | None = None,
) -> str:
    """Assemble the optional branch-context block for a commit prompt.

    Each tag is emitted only when its value is non-empty, so a fresh branch
    (no commits yet) or a commit made directly on the base branch yields an
    empty string. Returns the block without surrounding blank lines.
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


def get_commit_log(repo_path: str | Path, base_branch: str) -> str:
    """Return commit log in GITAI_COMMIT-prefixed format."""
    return _git(
        repo_path,
        "log",
        "--no-merges",
        "--format=GITAI_COMMIT %s%n%b",
        f"{base_branch}..HEAD",
    )


def get_diff_stat(
    repo_path: str | Path,
    base: str,
    three_dot: bool = True,
    *,
    exclude_patterns: list[str] | tuple[str, ...] | None = None,
) -> str:
    """Return git diff --stat between base and HEAD.

    When ``exclude_patterns`` is omitted, auto-loads ``.git-ai-ignore`` from the
    repo root and applies built-in lockfile defaults. Pass ``exclude_patterns=[]``
    to opt out of all filtering.
    """
    sep = "..." if three_dot else ".."
    return _git(
        repo_path,
        "diff",
        "--stat",
        f"{base}{sep}HEAD",
        *to_pathspec_args(_resolve_exclude_patterns(repo_path, exclude_patterns)),
    )


def get_diff(
    repo_path: str | Path,
    base: str,
    three_dot: bool = True,
    *,
    exclude_patterns: list[str] | tuple[str, ...] | None = None,
) -> str:
    """Return git diff -U0 between base and HEAD.

    When ``exclude_patterns`` is omitted, auto-loads ``.git-ai-ignore`` from the
    repo root and applies built-in lockfile defaults. Pass ``exclude_patterns=[]``
    to opt out of all filtering.
    """
    sep = "..." if three_dot else ".."
    return _git(
        repo_path,
        "diff",
        "-U0",
        f"{base}{sep}HEAD",
        *to_pathspec_args(_resolve_exclude_patterns(repo_path, exclude_patterns)),
    )


def count_conventional_commits(log: str) -> tuple[int, int]:
    """Return (conventional_count, total_count) from a GITAI_COMMIT-prefixed log."""
    conventional = 0
    total = 0
    for line in log.splitlines():
        if not line.startswith("GITAI_COMMIT "):
            continue
        msg = line[len("GITAI_COMMIT ") :]
        type_match = re.match(r"^([a-z]+)[!(:]", msg)
        total += 1
        if type_match and type_match.group(1) in _CONVENTIONAL_TYPES:
            conventional += 1
    return conventional, total


def format_commit_log(commits: Iterable[tuple[str, str]]) -> str:
    """Build a GITAI_COMMIT-prefixed log from (subject, body) pairs.

    Produces the same shape as `git log --format=GITAI_COMMIT %s%n%b`.
    """
    parts: list[str] = []
    for subject, body in commits:
        parts.append(f"GITAI_COMMIT {subject}")
        if body:
            parts.append(body)
    if not parts:
        return ""
    return "\n".join(parts) + "\n"


_DIFF_FILE_HEADER = re.compile(r"^diff --git a/(?P<a>.+?) b/(?P<b>.+)$")


def derive_diff_stat(diff: str) -> str:
    """Derive a git-diff-stat-style summary from a raw unified diff string.

    Output shape approximates `git diff --stat`: one line per file with change
    count and a +/- bar, plus a summary footer. Binary files are reported with
    "Bin" instead of counts.
    """
    files: list[tuple[str, int, int, bool]] = []
    current_path: str | None = None
    insertions = 0
    deletions = 0
    binary = False

    def flush() -> None:
        if current_path is not None:
            files.append((current_path, insertions, deletions, binary))

    for line in diff.splitlines():
        header_match = _DIFF_FILE_HEADER.match(line)
        if header_match:
            flush()
            current_path = header_match.group("b")
            insertions = 0
            deletions = 0
            binary = False
            continue
        if current_path is None:
            continue
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("Binary files ") or line.startswith("GIT binary patch"):
            binary = True
            continue
        if line.startswith("+"):
            insertions += 1
        elif line.startswith("-"):
            deletions += 1
    flush()

    if not files:
        return ""

    max_path = max(len(p) for p, _, _, _ in files)
    total_ins = sum(i for _, i, _, _ in files)
    total_del = sum(d for _, _, d, _ in files)

    lines: list[str] = []
    for path, ins, dels, is_binary in files:
        if is_binary:
            lines.append(f" {path.ljust(max_path)} | Bin")
            continue
        total = ins + dels
        bar = "+" * ins + "-" * dels
        if len(bar) > 40:
            scale = 40 / len(bar)
            bar = "+" * max(1, int(ins * scale)) + "-" * max(1, int(dels * scale))
        lines.append(f" {path.ljust(max_path)} | {total:>3} {bar}")

    file_word = "file" if len(files) == 1 else "files"
    pieces = [f"{len(files)} {file_word} changed"]
    if total_ins:
        pieces.append(f"{total_ins} insertion{'' if total_ins == 1 else 's'}(+)")
    if total_del:
        pieces.append(f"{total_del} deletion{'' if total_del == 1 else 's'}(-)")
    lines.append(" " + ", ".join(pieces))
    return "\n".join(lines)


def largest_diff_files(diff: str, n: int = 5) -> list[tuple[str, int, int]]:
    """Return top-``n`` files in ``diff`` by (insertions + deletions), descending.

    Each entry is ``(path, insertions, deletions)``. Used to format the
    "Largest staged files" hint when a diff exceeds the size guard.
    """
    files: list[tuple[str, int, int]] = []
    current_path: str | None = None
    insertions = 0
    deletions = 0

    def flush() -> None:
        if current_path is not None:
            files.append((current_path, insertions, deletions))

    for line in diff.splitlines():
        header_match = _DIFF_FILE_HEADER.match(line)
        if header_match:
            flush()
            current_path = header_match.group("b")
            insertions = 0
            deletions = 0
            continue
        if current_path is None:
            continue
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("+"):
            insertions += 1
        elif line.startswith("-"):
            deletions += 1
    flush()

    files.sort(key=lambda entry: entry[1] + entry[2], reverse=True)
    return files[:n]


def build_draft_body(log: str) -> str:
    """Build a draft PR body from conventional commit messages."""
    sections = [
        ("Features", "feat"),
        ("Bug Fixes", "fix"),
        ("Refactors", "refactor"),
        ("Docs", "docs"),
        ("Chores", "chore"),
        ("Continuous Integration", "ci"),
        ("Tests", "test"),
        ("Style", "style"),
        ("Performance", "perf"),
        ("Build", "build"),
    ]

    draft = ""
    for header, commit_type in sections:
        lines: list[str] = []
        capturing = False
        for line in log.splitlines():
            if line.startswith("GITAI_COMMIT "):
                capturing = False
                msg = line[len("GITAI_COMMIT ") :]
                type_match = re.match(r"^([a-z]+)[!(:]", msg)
                if type_match and type_match.group(1) == commit_type:
                    desc = msg.split(": ", 1)[-1] if ": " in msg else msg
                    lines.append(f"- {desc}")
                    capturing = True
            elif capturing and line.strip():
                lines.append(f"  {line}")

        if lines:
            draft += f"### {header}\n" + "\n".join(lines) + "\n\n"

    return draft
