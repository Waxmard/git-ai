"""Branch scope analysis: partition a branch's commits into distinct concerns.

The inverse of churn detection. :func:`get_branch_churn_subjects` asks "does
this commit only refine code the branch itself introduced?" to *fold* such
commits into the feature they refine. The same blame evidence, kept per-commit
instead of collapsed to a yes/no, says which commits belong together — and so
which ones are riding along on a branch that has nothing to do with them.

Deterministic throughout: blame and file overlap decide the partition, and the
labels are taken verbatim from commit subjects. Naming and merging clusters that
are one concern under two subjects is a job for a caller with an LLM.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from ._git import _DIFF_FILE_HEADER, _git, get_repo_root
    from ._git_branch import _blame_introducers
    from ._ignore import load_ignore_patterns, to_pathspec_args
elif __package__ in (None, ""):
    import importlib as _importlib

    _git_mod = _importlib.import_module("_git")
    _git = _git_mod._git
    _DIFF_FILE_HEADER = _git_mod._DIFF_FILE_HEADER
    get_repo_root = _git_mod.get_repo_root
    _blame_introducers = _importlib.import_module("_git_branch")._blame_introducers
    _ignore_mod = _importlib.import_module("_ignore")
    load_ignore_patterns = _ignore_mod.load_ignore_patterns
    to_pathspec_args = _ignore_mod.to_pathspec_args
else:
    from ._git import _DIFF_FILE_HEADER, _git, get_repo_root
    from ._git_branch import _blame_introducers
    from ._ignore import load_ignore_patterns, to_pathspec_args

# Every commit costs a `git show` plus a `git blame` per modified file, so the
# cap matches churn detection's. Over it, the branch comes back as one concern.
MAX_SCOPE_COMMITS = 50

_HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+")
_TYPE_RE = re.compile(r"^([a-zA-Z]+)(?:\([^)]*\))?(!?):")


@dataclass(frozen=True)
class ScopeCommit:
    """One commit's scope evidence.

    ``refines`` holds the in-branch SHAs whose lines this commit edits — the
    dependency edge that binds a follow-up to the work it follows up on.
    ``touches_pre_existing`` means at least one edited line predates the branch,
    which is what a rider commit looks like: it changes code the branch had no
    reason to be near.
    """

    sha: str
    subject: str
    commit_type: str
    files: tuple[str, ...]
    refines: frozenset[str] = frozenset()
    touches_pre_existing: bool = False
    branch_local: bool = False


@dataclass(frozen=True)
class Concern:
    """A cluster of commits that the evidence says belong to one another."""

    commits: tuple[ScopeCommit, ...]
    files: tuple[str, ...]
    primary: bool = False
    adds_new_files: bool = False

    @property
    def label(self) -> str:
        """Heuristic name: the first feature-ish subject, else the oldest one.

        A placeholder for a caller that titles clusters with an LLM — never a
        claim that the cluster is *about* the commit it borrows from.
        """
        for commit in self.commits:
            if commit.commit_type == "feat":
                return commit.subject
        return self.commits[0].subject if self.commits else ""

    @property
    def touches_pre_existing(self) -> bool:
        return any(c.touches_pre_existing for c in self.commits)


@dataclass(frozen=True)
class BranchScope:
    """Result of :func:`analyze_branch_scope`.

    ``degraded`` marks a partition that evidence didn't produce — an over-cap or
    git-failed run yields every commit in one concern, which must not be read as
    "this branch is focused".
    """

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
    def secondary(self) -> tuple[Concern, ...]:
        return tuple(c for c in self.concerns if not c.primary)


@dataclass
class _Union:
    """Union-find over commit indices."""

    parent: list[int] = field(default_factory=list)

    def add(self) -> int:
        self.parent.append(len(self.parent))
        return len(self.parent) - 1

    def find(self, i: int) -> int:
        while self.parent[i] != i:
            self.parent[i] = self.parent[self.parent[i]]
            i = self.parent[i]
        return i

    def union(self, a: int, b: int) -> None:
        root_a, root_b = self.find(a), self.find(b)
        if root_a != root_b:
            self.parent[root_b] = root_a


def _commit_type(subject: str) -> str:
    match = _TYPE_RE.match(subject)
    return match.group(1).lower() if match else ""


def _commit_files_and_ranges(
    repo_path: str | Path, commit: str, pathspec: list[str]
) -> tuple[list[str], list[tuple[str, int, int]]] | None:
    """Return ``(files, (pre_image_path, start, count) ranges)`` for one commit.

    One ``git show`` serves both — walking the same ``-U0`` diff twice would
    double the subprocess cost of the whole analysis. Pure-addition hunks (old
    count 0) yield no range, matching churn detection.
    """
    try:
        diff = _git(
            repo_path,
            "show",
            "--no-color",
            "-M",
            "-U0",
            "--format=",
            commit,
            *pathspec,
        )
    except RuntimeError:
        return None
    files: list[str] = []
    ranges: list[tuple[str, int, int]] = []
    current_a: str | None = None
    for line in diff.splitlines():
        header_match = _DIFF_FILE_HEADER.match(line)
        if header_match:
            current_a = header_match.group("a")
            path = header_match.group("b")
            if path not in files:
                files.append(path)
            continue
        if line.startswith("@@") and current_a is not None:
            hunk = _HUNK_RE.match(line)
            if hunk:
                start = int(hunk.group(1))
                count = int(hunk.group(2)) if hunk.group(2) is not None else 1
                if count > 0:
                    ranges.append((current_a, start, count))
    return files, ranges


def _classify_commit(
    repo_path: str | Path,
    commit: str,
    branch_shas: frozenset[str],
    pathspec: list[str],
) -> ScopeCommit | None:
    """Blame every line ``commit`` edits and record where those lines came from."""
    parsed = _commit_files_and_ranges(repo_path, commit, pathspec)
    if parsed is None:
        return None
    files, ranges = parsed
    try:
        subject = _git(repo_path, "show", "-s", "--format=%s", commit).strip()
    except RuntimeError:
        return None

    refines: set[str] = set()
    touches_pre_existing = False
    for file, start, count in ranges:
        shas = _blame_introducers(repo_path, f"{commit}^", file, start, count)
        if shas is None:
            # Blame failed (file absent at the parent, unreadable rev). Unknown
            # provenance is treated as pre-existing so a rider can't hide behind
            # a failed probe.
            touches_pre_existing = True
            continue
        in_branch = shas & branch_shas
        refines |= in_branch
        if shas - branch_shas:
            touches_pre_existing = True

    return ScopeCommit(
        sha=commit,
        subject=subject,
        commit_type=_commit_type(subject),
        files=tuple(files),
        refines=frozenset(refines),
        touches_pre_existing=touches_pre_existing,
        branch_local=bool(ranges) and not touches_pre_existing,
    )


def _cluster(commits: list[ScopeCommit], linkable: dict[str, set[str]]) -> list[int]:
    """Assign each commit a cluster id.

    Two edges join commits: a blame edge (this commit edits lines an in-branch
    commit introduced) and a file edge (both touch the same file). The blame
    edge is the load-bearing one — file overlap alone would merge two unrelated
    changes that happen to share a config file, which is why ``linkable`` has
    already dropped the paths ``.git-ai-ignore`` excludes.
    """
    union = _Union()
    index_of: dict[str, int] = {}
    for i, commit in enumerate(commits):
        union.add()
        index_of[commit.sha] = i

    for i, commit in enumerate(commits):
        for sha in commit.refines:
            other = index_of.get(sha)
            if other is not None:
                union.union(i, other)

    first_toucher: dict[str, int] = {}
    for i, commit in enumerate(commits):
        for file in linkable.get(commit.sha, set()):
            other = first_toucher.setdefault(file, i)
            union.union(i, other)

    return [union.find(i) for i in range(len(commits))]


def _build_concerns(
    commits: list[ScopeCommit], cluster_ids: list[int], new_files: frozenset[str]
) -> tuple[Concern, ...]:
    """Group commits by cluster id, oldest-first, and mark the primary one."""
    order: list[int] = []
    grouped: dict[int, list[ScopeCommit]] = {}
    for commit, cluster_id in zip(commits, cluster_ids, strict=True):
        if cluster_id not in grouped:
            grouped[cluster_id] = []
            order.append(cluster_id)
        grouped[cluster_id].append(commit)

    drafts: list[Concern] = []
    for cluster_id in order:
        members = grouped[cluster_id]
        files: list[str] = []
        for commit in members:
            for file in commit.files:
                if file not in files:
                    files.append(file)
        drafts.append(
            Concern(
                commits=tuple(members),
                files=tuple(files),
                adds_new_files=any(f in new_files for f in files),
            )
        )

    if not drafts:
        return ()
    primary = max(
        range(len(drafts)),
        key=lambda i: (len(drafts[i].commits), len(drafts[i].files), -i),
    )
    return tuple(
        Concern(
            commits=draft.commits,
            files=draft.files,
            primary=(i == primary),
            adds_new_files=draft.adds_new_files,
        )
        for i, draft in enumerate(drafts)
    )


def _branch_new_files(
    repo_path: str | Path, base_ref: str, pathspec: list[str]
) -> frozenset[str]:
    """Paths the branch adds that the base doesn't have. Empty on git failure."""
    try:
        out = _git(
            repo_path,
            "diff",
            "--name-only",
            "--diff-filter=A",
            f"{base_ref}...HEAD",
            *pathspec,
        )
    except RuntimeError:
        return frozenset()
    return frozenset(line for line in out.splitlines() if line)


def _degraded(base_ref: str, branch: str | None, reason: str) -> BranchScope:
    return BranchScope(
        base=base_ref, branch=branch, degraded=True, degraded_reason=reason
    )


def analyze_branch_scope(
    repo_path: str | Path,
    base_ref: str,
    *,
    branch: str | None = None,
    limit: int = MAX_SCOPE_COMMITS,
    exclude_patterns: list[str] | tuple[str, ...] | None = None,
) -> BranchScope:
    """Partition ``base_ref..HEAD`` into the distinct concerns it carries.

    Each commit's edited lines are blamed against its own parent: lines the
    branch introduced bind the commit to the commit that introduced them, lines
    that predate the base don't. Commits sharing a file are joined too, ignoring
    the paths ``.git-ai-ignore`` and the lockfile defaults exclude so a
    dependency bump can't glue two features together.

    Best-effort, like churn detection — a git failure or a range over ``limit``
    comes back ``degraded`` with every commit in one concern rather than raising,
    since the caller's real job (a commit, a PR) must not fail over advice.
    """
    try:
        branch_shas = frozenset(
            _git(repo_path, "rev-list", f"{base_ref}..HEAD").split()
        )
        shas = _git(repo_path, "rev-list", "--no-merges", f"{base_ref}..HEAD").split()
    except RuntimeError as exc:
        return _degraded(base_ref, branch, str(exc))
    if not shas:
        return BranchScope(base=base_ref, branch=branch)

    if exclude_patterns is None:
        try:
            exclude_patterns = load_ignore_patterns(get_repo_root(repo_path))
        except RuntimeError:
            exclude_patterns = []
    pathspec = to_pathspec_args(exclude_patterns)

    shas.reverse()
    commits: list[ScopeCommit] = []
    for sha in shas:
        classified = _classify_commit(repo_path, sha, branch_shas, pathspec)
        if classified is not None:
            commits.append(classified)
    if not commits:
        return _degraded(base_ref, branch, "no commit could be classified")

    if len(shas) > limit:
        return BranchScope(
            base=base_ref,
            branch=branch,
            concerns=_build_concerns(commits, [0] * len(commits), frozenset()),
            degraded=True,
            degraded_reason=f"{len(shas)} commits exceeds the {limit}-commit cap",
        )

    linkable = {c.sha: set(c.files) for c in commits}
    concerns = _build_concerns(
        commits,
        _cluster(commits, linkable),
        _branch_new_files(repo_path, base_ref, pathspec),
    )
    return BranchScope(base=base_ref, branch=branch, concerns=concerns)


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


def _slug(subject: str) -> str:
    """`fix: lock TTL off-by-one` → `fix/lock-ttl-off-by-one`."""
    match = _TYPE_RE.match(subject)
    prefix = ""
    rest = subject
    if match:
        prefix = f"{match.group(1).lower()}/"
        rest = subject[match.end() :]
    words = re.findall(r"[a-zA-Z0-9]+", rest.lower())[:5]
    return f"{prefix}{'-'.join(words)}" if words else ""
