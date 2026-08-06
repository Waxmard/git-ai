"""Branch scope analysis: partition a branch's commits into distinct concerns.

A branch that has picked up unrelated riders can be split *before* it is pushed,
where rewriting is still free. This module assembles the evidence and parses the
partition; like the rest of the package it never calls an LLM itself.

The partition is the model's, not a clustering algorithm's, because the question
is semantic. Structural clustering was tried first — union-find over commits
joined by shared files and by ``git blame`` of the lines each commit edits — and
measured against real branches it does not work. A blame edge implies a file
edge (a commit cannot refine another's lines without touching its file), so the
expensive half was inert; and file connectivity tracks how coupled the codebase
is, not how related the work is. A 25-commit branch touching 57 files of one
subsystem is one connected component however many unrelated things it carries.
The commit subjects, meanwhile, say plainly which work belongs together.

What stays deterministic is everything the model should not be trusted with:
gathering the commits, and checking that the returned partition covers every one
of them exactly once.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, replace
from pathlib import Path
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from ._generate import _load_prompt, strip_fences
    from ._git import _git, get_repo_root
    from ._ignore import load_ignore_patterns, to_pathspec_args
elif __package__ in (None, ""):
    import importlib as _importlib

    _git_mod = _importlib.import_module("_git")
    _git = _git_mod._git
    get_repo_root = _git_mod.get_repo_root
    _generate_mod = _importlib.import_module("_generate")
    _load_prompt = _generate_mod._load_prompt
    strip_fences = _generate_mod.strip_fences
    _ignore_mod = _importlib.import_module("_ignore")
    load_ignore_patterns = _ignore_mod.load_ignore_patterns
    to_pathspec_args = _ignore_mod.to_pathspec_args
else:
    from ._generate import _load_prompt, strip_fences
    from ._git import _git, get_repo_root
    from ._ignore import load_ignore_patterns, to_pathspec_args

# Past this the prompt stops being worth its tokens, and a branch that long has
# problems no split suggestion addresses. Over the cap the branch is reported
# degraded rather than partitioned.
MAX_SCOPE_COMMITS = 60

SCOPE_MARKER = "===SCOPE==="

_RECORD_SEP = "\x1e"
_FIELD_SEP = "\x1f"
_TYPE_RE = re.compile(r"^([a-zA-Z]+)(?:\([^)]*\))?!?:")


@dataclass(frozen=True)
class ScopeCommit:
    sha: str
    subject: str
    commit_type: str
    files: tuple[str, ...]


@dataclass(frozen=True)
class Concern:
    """One unit of intent the branch carries.

    ``adds_new_files`` and ``touches_pre_existing_files`` are answered against
    the base tree at file granularity — a rider is usually recognisable as a
    concern that only edits files the branch had no other reason to open. The
    line-level version of that question is deliberately not asked: ``git blame``
    reports the commit that *last* wrote a line, so a branch editing a shared
    line early "adopts" it, and every later commit touching that line then looks
    branch-local. File-level provenance is weaker, but it is exact.
    """

    label: str
    commits: tuple[ScopeCommit, ...]
    files: tuple[str, ...]
    primary: bool = False
    adds_new_files: bool = False
    touches_pre_existing_files: bool = False


@dataclass(frozen=True)
class ScopeContext:
    """Deterministic input for the partition, and the reason there isn't one.

    ``degraded`` means no partition should be attempted or believed — an empty,
    unreadable, or over-long range. Callers must not read it as "this branch is
    focused"; it means the question went unanswered.
    """

    base: str
    commits: tuple[ScopeCommit, ...] = ()
    branch: str | None = None
    base_files: frozenset[str] = frozenset()
    degraded: bool = False
    degraded_reason: str = ""


@dataclass(frozen=True)
class BranchScope:
    base: str
    concerns: tuple[Concern, ...] = ()
    branch: str | None = None
    degraded: bool = False
    degraded_reason: str = ""

    @property
    def commit_count(self) -> int:
        return sum(len(c.commits) for c in self.concerns)

    @property
    def is_split(self) -> bool:
        return not self.degraded and len(self.concerns) > 1

    @property
    def primary(self) -> Concern | None:
        return next((c for c in self.concerns if c.primary), None)

    @property
    def riders(self) -> tuple[Concern, ...]:
        return tuple(c for c in self.concerns if not c.primary)


def _commit_type(subject: str) -> str:
    match = _TYPE_RE.match(subject)
    return match.group(1).lower() if match else ""


def _parse_files_log(output: str) -> dict[str, tuple[str, ...]]:
    """``sha -> touched paths`` from a ``log --name-only`` run."""
    by_sha: dict[str, tuple[str, ...]] = {}
    for record in output.split(_RECORD_SEP):
        if not record.strip():
            continue
        sha, _, body = record.partition("\n")
        sha = sha.strip()
        if sha:
            by_sha[sha] = tuple(
                dict.fromkeys(f for f in body.splitlines() if f.strip())
            )
    return by_sha


def _base_files(repo_path: str | Path, base_ref: str) -> frozenset[str]:
    """Every path in the base tree. Empty on git failure — provenance is advisory."""
    try:
        out = _git(repo_path, "ls-tree", "-r", "--name-only", base_ref)
    except RuntimeError:
        return frozenset()
    return frozenset(line for line in out.splitlines() if line)


def prepare_branch_scope(
    repo_path: str | Path,
    base_ref: str,
    *,
    tip: str = "HEAD",
    branch: str | None = None,
    limit: int = MAX_SCOPE_COMMITS,
    exclude_patterns: list[str] | tuple[str, ...] | None = None,
) -> ScopeContext:
    """Gather ``base_ref..tip`` as the input to a scope partition.

    Three git calls: the commit list, the per-commit paths, and the base tree.

    The commit list is taken **without** the ``.git-ai-ignore`` pathspec and the
    paths **with** it, then joined. Passing the pathspec to a single
    ``log --name-only`` would drop any commit whose every path is excluded —
    silently deleting a lockfile-only dependency bump from a report whose entire
    job is noticing that the bump rode along. Such a commit keeps its subject
    and comes through with no files; only the path noise is filtered.

    Never raises — an unreadable range comes back ``degraded``, since the
    caller's real job (a commit, a PR) must not fail over advice.
    """
    if exclude_patterns is None:
        try:
            exclude_patterns = load_ignore_patterns(get_repo_root(repo_path))
        except RuntimeError:
            exclude_patterns = []
    rng = f"{base_ref}..{tip}"
    try:
        listing = _git(
            repo_path,
            "log",
            "--no-merges",
            "--reverse",
            f"--format=%H{_FIELD_SEP}%s",
            rng,
        )
        paths = _git(
            repo_path,
            "log",
            "--no-merges",
            "--name-only",
            f"--format={_RECORD_SEP}%H",
            rng,
            *to_pathspec_args(exclude_patterns),
        )
    except RuntimeError as exc:
        return ScopeContext(
            base=base_ref, branch=branch, degraded=True, degraded_reason=str(exc)
        )

    files_by_sha = _parse_files_log(paths)
    commits = []
    for line in listing.splitlines():
        sha, _, subject = line.partition(_FIELD_SEP)
        sha, subject = sha.strip(), subject.strip()
        if not sha:
            continue
        commits.append(
            ScopeCommit(
                sha=sha,
                subject=subject,
                commit_type=_commit_type(subject),
                files=files_by_sha.get(sha, ()),
            )
        )
    if not commits:
        return ScopeContext(
            base=base_ref,
            branch=branch,
            degraded=True,
            degraded_reason=f"no commits in {base_ref}..{tip}",
        )
    if len(commits) > limit:
        return ScopeContext(
            base=base_ref,
            commits=tuple(commits),
            branch=branch,
            degraded=True,
            degraded_reason=f"{len(commits)} commits exceeds the {limit}-commit cap",
        )
    return ScopeContext(
        base=base_ref,
        commits=tuple(commits),
        branch=branch,
        base_files=_base_files(repo_path, base_ref),
    )


def build_scope_prompt(context: ScopeContext) -> tuple[str, str]:
    """Return ``(system_prompt, user_input)`` for the partition."""
    lines: list[str] = []
    if context.branch:
        lines.append(f"<branch>{context.branch}</branch>")
    lines.append("<branch_commits>")
    for i, commit in enumerate(context.commits, 1):
        listed = ", ".join(commit.files) if commit.files else "(none)"
        lines.append(f"{i}. {commit.subject}")
        lines.append(f"   files: {listed}")
    lines.append("</branch_commits>")
    return _load_prompt("scope.txt"), "\n".join(lines)


def _extract_scope_json(response: str) -> str:
    """Slice the JSON out, discarding any reasoning the model emitted first."""
    text = strip_fences(response.strip())
    if SCOPE_MARKER in text:
        text = text.rsplit(SCOPE_MARKER, 1)[1]
    text = strip_fences(text.strip())
    start = text.find("{")
    end = text.rfind("}")
    if start == -1 or end <= start:
        return ""
    return text[start : end + 1]


def _read_concerns(
    payload: Any, total: int
) -> list[tuple[str, bool, list[int]]] | None:
    """Validate the model's shape and its coverage of the commit list.

    Every commit must be claimed exactly once. A partition that drops or
    duplicates one is rejected outright rather than repaired: a silently dropped
    commit is the exact failure this tool exists to catch.
    """
    if not isinstance(payload, dict):
        return None
    raw = payload.get("concerns")
    if not isinstance(raw, list) or not raw:
        return None
    parsed: list[tuple[str, bool, list[int]]] = []
    claimed: list[int] = []
    for entry in raw:
        if not isinstance(entry, dict):
            return None
        label = str(entry.get("label", "")).strip()
        indexes = entry.get("commits")
        if not label or not isinstance(indexes, list) or not indexes:
            return None
        numbers: list[int] = []
        for value in indexes:
            # bool is an int subclass, and `true` in the array is a shape error.
            if not isinstance(value, int) or isinstance(value, bool):
                return None
            if not 1 <= value <= total:
                return None
            numbers.append(value)
        claimed.extend(numbers)
        parsed.append((label, bool(entry.get("primary")), numbers))
    if sorted(claimed) != list(range(1, total + 1)):
        return None
    return parsed


def _pick_primary(concerns: list[Concern]) -> tuple[Concern, ...]:
    """Keep exactly one primary, falling back to the largest concern."""
    flagged = [i for i, c in enumerate(concerns) if c.primary]
    if len(flagged) == 1:
        return tuple(concerns)
    winner = (
        flagged[0]
        if flagged
        else max(range(len(concerns)), key=lambda i: len(concerns[i].commits))
    )
    return tuple(replace(c, primary=(i == winner)) for i, c in enumerate(concerns))


def parse_scope_response(response: str, context: ScopeContext) -> BranchScope:
    """Turn the model's partition into a :class:`BranchScope`.

    A response that is unparseable, or that does not account for every commit
    exactly once, yields a ``degraded`` result rather than a partial one.
    """
    if context.degraded:
        return degraded_scope(context)

    raw = _extract_scope_json(response)
    try:
        payload = json.loads(raw) if raw else None
    except json.JSONDecodeError:
        payload = None
    parsed = _read_concerns(payload, len(context.commits)) if payload else None
    if parsed is None:
        return BranchScope(
            base=context.base,
            branch=context.branch,
            degraded=True,
            degraded_reason="could not read a complete partition from the response",
        )

    concerns: list[Concern] = []
    for label, primary, numbers in parsed:
        members = tuple(context.commits[n - 1] for n in sorted(numbers))
        files = tuple(dict.fromkeys(f for c in members for f in c.files))
        concerns.append(
            Concern(
                label=label,
                commits=members,
                files=files,
                primary=primary,
                adds_new_files=any(f not in context.base_files for f in files),
                touches_pre_existing_files=any(f in context.base_files for f in files),
            )
        )
    return BranchScope(
        base=context.base,
        concerns=_pick_primary(concerns),
        branch=context.branch,
    )


def degraded_scope(context: ScopeContext) -> BranchScope:
    """The unanswered result, for callers skipping the LLM call outright."""
    return BranchScope(
        base=context.base,
        branch=context.branch,
        degraded=True,
        degraded_reason=context.degraded_reason or "scope analysis unavailable",
    )


def suggested_split(concern: Concern, base_ref: str) -> list[str]:
    """Git commands that lift ``concern`` onto its own branch off ``base_ref``.

    Cherry-picks are emitted oldest-first so the replayed order matches the
    original one; a concern whose commits interleave with others' may still
    conflict, so these are a starting point, not a scripted migration.
    """
    if not concern.commits:
        return []
    slug = _slug(concern.label) or "split"
    picks = " ".join(c.sha[:7] for c in concern.commits)
    return [
        f"git switch -c {slug} {base_ref.removeprefix('origin/')}",
        f"git cherry-pick {picks}",
    ]


def _slug(label: str) -> str:
    """`Lock TTL off-by-one` → `lock-ttl-off-by-one`."""
    return "-".join(re.findall(r"[a-zA-Z0-9]+", label.lower())[:6])
