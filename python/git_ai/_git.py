"""Git helper utilities for git-ai."""
from __future__ import annotations

import re
import subprocess
from pathlib import Path

_CONVENTIONAL_TYPES = frozenset(
    ["feat", "fix", "refactor", "docs", "chore", "ci", "test", "style", "perf", "build"]
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
        return "Release context: no release tags found — treat all changes as unreleased"

    last_tag = result.stdout.strip()
    count = subprocess.run(
        ["git", "rev-list", "--count", f"{last_tag}..HEAD"],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
    )
    commits_since = count.stdout.strip() if count.returncode == 0 else "?"
    return f"Release context: last tag {last_tag}, {commits_since} commits since — staged changes are unreleased"


def get_mr_release_context(repo_path: str | Path) -> str:
    """Return release context string with semver guidance for MR descriptions."""
    result = subprocess.run(
        ["git", "describe", "--tags", "--abbrev=0"],
        cwd=str(repo_path),
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return "Release context: no release tags found — treat all changes as unreleased"

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
        major, minor, patch = int(match.group(1)), int(match.group(2)), int(match.group(3))
        semver_context = (
            f". Next release: breaking→v{major + 1}.0.0, "
            f"feature→v{major}.{minor + 1}.0, "
            f"fix→v{major}.{minor}.{patch + 1}"
        )

    return f"Release context: current version {last_tag}, {commits_since} commits since last release{semver_context}"


def get_commit_log(repo_path: str | Path, base_branch: str) -> str:
    """Return commit log with GITAI_COMMIT subject prefixes."""
    return _git(repo_path, "log", "--format=GITAI_COMMIT %s%n%b", f"{base_branch}..HEAD")


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
