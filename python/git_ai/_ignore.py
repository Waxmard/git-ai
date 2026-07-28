"""git-ai ignore patterns: built-in lockfile defaults + repo-root `.git-ai-ignore`.

Patterns become repo-root git pathspec excludes
(`:(top,exclude,glob)**/<pattern>`) so generated noise never reaches the LLM.
A leading `!` removes a pattern, opting back into a built-in default.
"""

from __future__ import annotations

from pathlib import Path

DEFAULT_EXCLUDES_FILE = "default-excludes.txt"
IGNORE_FILENAME = ".git-ai-ignore"


def _read_pattern_file(path: Path) -> tuple[str, ...]:
    patterns: list[str] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        patterns.append(line)
    return tuple(patterns)


DEFAULT_EXCLUDES: tuple[str, ...] = _read_pattern_file(
    Path(__file__).with_name(DEFAULT_EXCLUDES_FILE)
)


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


def load_ignore_patterns(
    repo_path: str | Path, *, include_defaults: bool = True
) -> list[str]:
    """Return the active exclude pattern list for the repo.

    ``DEFAULT_EXCLUDES`` first, then non-negated ``.git-ai-ignore`` lines;
    ``!`` entries are removed by exact match. Deduped, order-preserving.

    ``include_defaults=False`` drops the lockfile defaults but still honours
    ``.git-ai-ignore``. Used for the PR diff *stat*, where lockfile bumps are
    one high-signal line each — without them a lockfile-only bot bump leaves
    the model no evidence to describe.
    """
    additions: list[str] = []
    negations: list[str] = []
    ignore_path = Path(repo_path) / IGNORE_FILENAME
    if ignore_path.is_file():
        additions, negations = _parse_ignore_file(
            ignore_path.read_text(encoding="utf-8")
        )

    defaults = DEFAULT_EXCLUDES if include_defaults else ()
    negated = set(negations)
    seen: set[str] = set()
    result: list[str] = []
    for pattern in (*defaults, *additions):
        if pattern in negated or pattern in seen:
            continue
        seen.add(pattern)
        result.append(pattern)
    return result


def to_pathspec_args(patterns: list[str] | tuple[str, ...] | None) -> list[str]:
    """Build trailing ``-- :/ :(top,exclude,glob)**/X ...`` args for ``git diff``.

    Empty when ``patterns`` is empty/None, so callers can splat unconditionally.
    """
    if not patterns:
        return []
    return ["--", ":/", *(f":(top,exclude,glob)**/{p}" for p in patterns)]
