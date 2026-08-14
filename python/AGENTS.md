# AGENTS.md — `python/`

Guidance for AI coding agents working under `python/`. The repo-wide guide is the root `AGENTS.md`; the Bash side is `lib/AGENTS.md`.

## Package internals

Provider-agnostic and BYO-LLM: the package owns prompt assembly, diff-stat derivation, fence-stripping, and `.git/pr-cache` management, and never calls an LLM itself. `build_commit_prompt` / `build_mr_prompt` produce `(system_prompt, user_input)`; callers run their own LLM, then feed the response through `parse_commit_response` / `parse_mr_response`. `__init__.py`'s `__all__` is the authoritative public surface. Zero LLM SDK dependencies, and stdlib-only for anything the Bash path imports (see the npm contract in the root guide).

`build_commit_prompt` also accepts optional `branch_name` / `branch_commits` / `branch_diffstat` so the prefix can be chosen from the perspective of the whole branch (assembled via `format_branch_context`).

`build_mr_prompt` takes `diff_scope` — `"since_existing"` (default) when `diff` covers only the commits added since `existing_pr` was written, `"branch"` when it covers the whole branch. The update prompts cannot describe both truthfully at once, and telling the model a partial slice is the whole branch makes it delete the work `existing_pr` describes but the diff omits. The destructive declaration has to be opted into.

`parse_commit_response` is parse-only. The deterministic formatting rules — `wrap_commit_body` and `enforce_subject_limit` — are exported separately and applied by `bin/git-ai`'s commit flow (through `_commit_cli.py format`), not folded into the parser: `enforce_subject_limit` returns a `SubjectTrim`, not a string, because a subject with no usable clause break comes back untouched and the caller has to surface that. Folding it in would either break the parser's `str` return or swallow the note. Library consumers call both explicitly.

The branch-context machinery (`get_default_branch`, `resolve_commit_base`, `_nearest_fork_parent`, `get_branch_commit_subjects`, `get_branch_churn_subjects`, `format_branch_context`) lives in **`_git_branch.py`**, split out from `_git.py` for the per-file line limit; it imports the low-level git helpers one-directionally from `_git.py` (no cycle), and `__init__.py` re-exports both so the public surface is unchanged.

## Shell bridges

The Bash CLI reaches this package through `_commit_cli.py` (`format`, `instructions`, `ignore-pathspec`, `branch-context`), `_pr_repo_cli.py` (`prepare`, `build-input`, `format`, `save-cache`), and `_pr_render.py`. `_commit_cli.py format` puts the finished message on stdout, the subject-trim note in `--note-file`, and empty stdout means an empty model response the shell reports with the provider's name.

`ignore-pathspec` emits finished `git` pathspec args one per line; the shell captures them and checks the exit status rather than reading through a process substitution, since a pathspec that silently came back empty would send ignored files to the model.

## Prompts and response parsing

Runtime prompts live in `git_ai/prompts/*.txt` and are loaded here via `importlib.resources` (the shell `cat`s them from `GIT_AI_PKG_DIR`, choosing the name from a whitelist). The six `pr-*.txt` files are generated from `prompts/src/` — edit the templates, then `make prompts-build`. `commit.txt` is hand-written.

Templates pull shared prose in with `include:partials/<name>.txt`, so wording that must stay in lockstep lives once: `type-classification.txt`, `output-markers.txt`, `preservation-rules.txt`, `repo-guidance.txt`, plus the three that define the body — `body-structure.txt` (purpose sections and a ~200-word/400-word-ceiling budget scaled to the number of distinct concerns, never conventional-commit-type headings), `voice.txt` (cause first, backticked code refs without line numbers, no invented numbers or observed behavior), and `verification.txt` (reviewer-runnable steps, never a claim that anything was executed). The update prompts include all three but scope them to newly added content, since `preservation-rules.txt` forbids restructuring an existing body. A `{{ var:<name> }}` directive resolves to a partial chosen per output, which is how each update template renders twice (`scope-*-branch.txt` / `scope-*-incremental.txt`) and how `diff_scope` gets a prompt stating one unambiguous truth instead of a conditional. No "do not edit" banner is prepended — the files are fed verbatim to the LLM; the staleness gate is what catches hand-edits.

Parsing:

- PR prompts wrap the answer in `===TITLE===` / `===BODY===` markers. `parse_mr_response` (`_extract_pr_sections`) slices those out, discarding any preamble or reasoning emitted before the title, and falls back to the raw fence-stripped text when the markers are absent.
- `commit.txt` uses a single `===COMMIT===` marker. `parse_commit_response` (`_extract_commit_message`) takes everything after it, falling back to the first Conventional Commits subject line onward so a reasoning model's rationale cannot become the subject.
- Both then run `_drop_trailing_noise`, stripping trailing `Co-Authored-By:` / `Generated with [...]` lines and stray `===WORD===` sentinels. Agent CLIs carry their own system prompt telling them to sign their work, and that outranks the git-ai prompt, so the trailer is removed after the fact rather than argued with. Both kinds are stripped in **one pass** because they interleave: an agent that signs below its own invented `===END===` would otherwise strand the marker. A response that is *only* trailers passes through untouched.
- `strip_fences` unwraps a fence **only** when one opens the first line and closes the last — a PR body's own fenced blocks are content the `## Verification` and `## Deployment` sections depend on.

## Deterministic formatting

A prompt alone cannot guarantee either rule, so both are enforced in `_generate.py`.

**Subject length** is capped at 70 characters (`SUBJECT_LIMIT`). An over-long subject is cut at the last clause boundary (` and `, ` plus `, `, `, `; `) that yields a whole subject within the limit, skipping separators inside the Conventional Commits prefix so a multi-word scope survives, and separators nested in brackets or a code span so a code reference (`parse(foo, bar)`) is not cut into a half-identifier — spans close on a backtick run of the same length, per CommonMark, so a multi-backtick span holding a literal backtick is not read as two spans. The dropped clause is already covered by the body. A subject with no usable break is left **untouched**, because a mid-word truncation reads worse than an over-long subject. Either outcome surfaces as a comment line in the commit editor buffer (stderr when not a tty), so nothing is trimmed without the author seeing it.

**Body wrapping** (`wrap_commit_body`, `BODY_WRAP_WIDTH` = 72) hard-wraps because git renders the body verbatim and models wrap inconsistently; the prompt asks for 72 too, which makes the pass a rewrite of nothing rather than a reflow. Reflow is confined to plain prose — indented lines, list items, fenced blocks, and a trailing trailer block keep their line structure, and a token longer than the width overflows rather than being split, so URLs and paths survive. The trailer exemption applies to the **final** paragraph only: git reads trailers from the last block, while mid-body prose routinely opens `Verified: …` and should still wrap.

## Repo-local inputs

**`_ignore.py`** holds the built-in lockfile defaults (`DEFAULT_EXCLUDES`) and the `.git-ai-ignore` parser. Patterns are **git pathspec glob fragments, not gitignore syntax**: a leading `/` is not root-anchoring, and `!` removes a pattern by exact string match (its only real use is opting back into a built-in default). `to_pathspec_args` emits **two** specs per pattern, `**/<p>` and `**/<p>/**`, because under `glob` magic `*` does not cross `/` — a bare `**/vendor` matches only a *file* named `vendor`, so a `vendor/` line would silently exclude nothing. The second spec is inert for a filename. Threaded through `get_staged_diff` / `get_diff` / `get_diff_stat` via `exclude_patterns=`.

A post-exclude size guard (`GIT_AI_MAX_DIFF_BYTES`, default `900000`) hard-fails with a "Largest changed files" hint when input would exceed a provider's input cap (Codex's is 1 MiB).

**`_instructions.py`** reads the repo-root `.git-ai-instructions` file (free-form prose for commit scopes and type-classification overrides). `load_repo_instructions` reads and trims it; `format_repo_guidance` wraps it in an authoritative `<repo_guidance>` block injected into both the commit and PR prompts, which instruct the model to let it override the default heuristics. An absent or empty file changes nothing.

## Branch-aware commit prefixes

`git-ai commit` resolves the branch's base through a local-only cascade (`--base` / `GIT_AI_COMMIT_BASE` → git-ai PR-cache base → nearest fork-parent → none) in `resolve_commit_base`, then surfaces the branch name, its commit subjects, and its cumulative diffstat to the model. The prompt uses this **only** to disambiguate the prefix when the staged diff alone is ambiguous; per-commit types are preserved.

`_nearest_fork_parent` scores every local and origin branch by `(commits-ahead, commits-behind, name-rank)` and takes the smallest, so the base is found by ancestry rather than by name — `main`/`master`/`dev` plus `release/*`, `staging`, and stacked parent branches all work. Capped at 50 branches (newest first) for speed. Divergence comes from a single `for-each-ref --format=%(ahead-behind:HEAD)` call, falling back to per-ref `git rev-list` probing only on git older than 2.41.

## PR caching

`git-ai pr` caches per `(branch, base)` pair under `.git/pr-cache/<key>/` (`last-output`, `last-head-sha`, `last-content-id`, `branch-name`).

- HEAD SHA matches the cached SHA → cached title/body reused, no LLM call.
- New commits since the cache → the cached text is fed to the update-prompt variant so existing wording is preserved. `prepare_repo_pr_context` derives `diff_scope` from `input_base`: the cached SHA is still an ancestor, so `<diff>` and `<commit_log>` cover only `cached_sha..HEAD` and the `-incremental` prompt tells the model `<existing_pr>` is the only record of the earlier work. The plain `"branch"` variant is for paths that re-describe the whole branch, and is the only one allowed to prune content the branch no longer contains.
- `--fresh` bypasses the cache entirely.

**Rewritten history (rebase / amend / force-push)** makes the cached SHA a non-ancestor, so the branch is re-described from the full three-dot diff against the base, with the cached text still riding along as `<existing_pr>`. To keep the common "target moved, branch rebased" case free, `branch_content_id` fingerprints the branch as `sha256(normalized three-dot diff + full commit messages)`. `_normalize_diff_position` drops `index` blob-id lines and blanks the line numbers out of `@@` headers so the id survives a rebase onto a moved base, while the `-U3` context lines and the hunk header's retained section heading keep a change's *position* in the hash — without the heading, the same edit made in two identically-shaped functions hashes the same. Messages are in the fingerprint so a reword- or body-only rewrite still regenerates.

A rewrite whose fingerprint matches `last-content-id` short-circuits to `no_changes=True`. Hashing the net diff rather than a per-commit `git patch-id` set is deliberate: `patch-id` ignores whitespace (an indentation-only edit would read as unchanged) and `--no-merges` would hide a merge's conflict resolution. That path re-stamps the cache onto the rewritten HEAD before returning, or every later run would re-fingerprint the whole branch and re-warn instead of taking the cheap exact-SHA path. Conversely, saving with **no** fingerprint (`content_id=None`: over the commit cap, or a git failure) deletes any previous `last-content-id`, since a stale id paired with newer text would let a later rewrite back onto that content reuse the wrong PR. The fingerprint is computed only where it is needed, and skipped entirely on branches over 200 non-merge commits. A base branch replaced with unrelated history is a different case: no merge-base, which is a hard error naming force-push as the likely cause.

**Pruning** runs once per `prepare_repo_pr_context`: entries whose recorded `branch-name` is gone from `refs/heads` are deleted, and pre-`branch-name` entries age out after 90 days. Best-effort — an unreadable branch list skips pruning rather than deleting on unknown. `save_cached_pr` never prunes, so a caller can cache a branch with no local ref.

**Intra-branch refinement folding** — the two-pass draft groups commits by conventional type, but a follow-up `fix`/`refactor`/`perf`/`docs` commit that only touches code added earlier in the *same* branch is invisible in the base branch's net diff, which shows only the final feature. `get_branch_churn_subjects` flags such commits via hunk-level `git blame` of each parent (every pre-image line it edits or deletes was introduced branch-locally; pure additions never count). They are threaded through `build_mr_prompt_input` → `_pr_draft.analyze` into a trailing `### Intra-branch refinements` block that the prompts fold into the feature being refined rather than emitting standalone sections. Best-effort: a git failure or a branch over 50 commits yields none.

## pip-installable CLI (`_launcher.py` + `_build_backend.py`)

The same `waxmard-git-ai` package that ships the Python library also exposes the `git-ai` / `aigit` console scripts (`[project.scripts]`). There is **no Python reimplementation**: the launcher `execvpe`s `bash` on the wheel-bundled CLI.

The canonical Bash lives at the repo root (`bin/`, `lib/`) — shared with the npm package and `make install` — so it cannot sit inside the package where the wheel needs it. The **in-tree PEP 517 backend** (`_build_backend.py`, wired via `build-backend = "_build_backend"` + `backend-path = ["."]`) copies `bin/` + `lib/` into `python/git_ai/_sh/{bin,lib}` on every build, so the bundled Bash is fresh build output and never drifts (`_sh/` is gitignored; `MANIFEST.in` grafts the root Bash into the sdist so from-sdist builds can re-copy).

The Bash layer resolves its sibling assets through **`GIT_AI_PKG_DIR`** (defined in `lib/ai-common.sh`, default = the repo-layout sibling `python/git_ai`); the launcher overrides it to the installed package dir so the wheel's flattened layout resolves. npm and `make install` hit the default and are unaffected. The `python` CI workflow builds the wheel, asserts `git_ai/_sh/` is bundled, then `pip install`s it and runs `git-ai providers` from outside the repo to prove the chain.
