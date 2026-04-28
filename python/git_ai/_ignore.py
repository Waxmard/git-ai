"""git-ai ignore patterns: built-in lockfile defaults + repo-root `.git-ai-ignore`.

Patterns become git pathspec excludes (`:(exclude,glob)**/<pattern>`) so noisy
generated files (lockfiles especially) never reach the LLM. Lines starting with
`!` in `.git-ai-ignore` remove a pattern from the active set, letting users
opt back into a built-in default when they actually want to review it.
"""

from __future__ import annotations

from pathlib import Path

DEFAULT_EXCLUDES: tuple[str, ...] = (
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "npm-shrinkwrap.json",
    "Gemfile.lock",
    "Cargo.lock",
    "go.sum",
    "poetry.lock",
    "uv.lock",
    "composer.lock",
    "Pipfile.lock",
    "pubspec.lock",
    "mix.lock",
    "flake.lock",
)

IGNORE_FILENAME = ".git-ai-ignore"


def _parse_ignore_file(text: str) -> tuple[list[str], list[str]]:
    additions: list[str] = []
    negations: list[str] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("!"):
            negated = line[1:].strip()
            if negated:
                negations.append(negated)
            continue
        additions.append(line)
    return additions, negations


def load_ignore_patterns(repo_path: str | Path) -> list[str]:
    """Return the active exclude pattern list for the repo.

    Order: ``DEFAULT_EXCLUDES`` first, then non-negated lines from
    ``.git-ai-ignore``. Patterns listed with a leading ``!`` are removed
    (exact match). Result is deduped while preserving order.
    """
    additions: list[str] = []
    negations: list[str] = []
    ignore_path = Path(repo_path) / IGNORE_FILENAME
    if ignore_path.is_file():
        additions, negations = _parse_ignore_file(
            ignore_path.read_text(encoding="utf-8")
        )

    negated = set(negations)
    seen: set[str] = set()
    result: list[str] = []
    for pattern in (*DEFAULT_EXCLUDES, *additions):
        if pattern in negated or pattern in seen:
            continue
        seen.add(pattern)
        result.append(pattern)
    return result


def to_pathspec_args(patterns: list[str] | tuple[str, ...] | None) -> list[str]:
    """Build trailing ``-- . :(exclude,glob)**/X ...`` args for ``git diff`` calls.

    Returns an empty list when ``patterns`` is empty/None so callers can
    splat it unconditionally.
    """
    if not patterns:
        return []
    return ["--", ".", *(f":(exclude,glob)**/{p}" for p in patterns)]
