"""Git helper utilities for git-ai."""
from __future__ import annotations

import re
import subprocess
from collections.abc import Iterable
from pathlib import Path

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
    )
    return result.returncode == 0


def check_git_repo(repo_path: str | Path) -> None:
    """Raise RuntimeError if not inside a git repository."""
    result = subprocess.run(
        ["git", "rev-parse", "--git-dir"],
        cwd=str(repo_path),
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"{repo_path} is not inside a git repository")


def get_staged_diff(repo_path: str | Path) -> str:
    """Return staged diff. Raises RuntimeError if nothing is staged."""
    quiet = subprocess.run(
        ["git", "diff", "--staged", "--quiet"],
        cwd=str(repo_path),
        capture_output=True,
    )
    if quiet.returncode == 0:
        raise RuntimeError("No staged changes to summarize")
    return _git(repo_path, "diff", "--staged")


def get_release_context(repo_path: str | Path) -> str:
    """Return release context string (last tag + commits since)."""
    result = subprocess.run(
        ["git", "describe", "--tags", "--abbrev=0"],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return DEFAULT_RELEASE_CONTEXT

    last_tag = result.stdout.strip()
    count = subprocess.run(
        ["git", "rev-list", "--count", f"{last_tag}..HEAD"],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
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
    )
    if result.returncode != 0 or not result.stdout.strip():
        return DEFAULT_RELEASE_CONTEXT

    last_tag = result.stdout.strip()
    count = subprocess.run(
        ["git", "rev-list", "--count", f"{last_tag}..HEAD"],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
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


def get_commit_log(
    repo_path: str | Path, base_branch: str, *, rs_delimited: bool = False
) -> str:
    """Return commit log with configurable formatting."""
    fmt = "%s%n%b%x1e" if rs_delimited else "GITAI_COMMIT %s%n%b"
    return _git(
        repo_path,
        "log",
        "--first-parent",
        "--no-merges",
        f"--format={fmt}",
        f"{base_branch}..HEAD",
    )


def get_diff_stat(repo_path: str | Path, base: str, three_dot: bool = True) -> str:
    """Return git diff --stat between base and HEAD."""
    sep = "..." if three_dot else ".."
    return _git(repo_path, "diff", "--stat", f"{base}{sep}HEAD")


def get_diff(repo_path: str | Path, base: str, three_dot: bool = True) -> str:
    """Return git diff -U0 between base and HEAD."""
    sep = "..." if three_dot else ".."
    return _git(repo_path, "diff", "-U0", f"{base}{sep}HEAD")


def count_conventional_commits(log: str) -> tuple[int, int]:
    """Return (conventional_count, total_count) from a GITAI_COMMIT-prefixed log."""
    conventional = 0
    total = 0
    for line in log.splitlines():
        if not line.startswith("GITAI_COMMIT "):
            continue
        msg = line[len("GITAI_COMMIT "):]
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
                msg = line[len("GITAI_COMMIT "):]
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
