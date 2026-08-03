<!-- Generated from docs/src/python-CLAUDE.md by scripts/build_docs.py. Run `make docs-build` to regenerate. Do not edit directly. -->

# CLAUDE.md — `python/`

Guidance for Claude Code (claude.ai/code) when working under `python/`. The repo-wide guide is the root `CLAUDE.md`.

## Package internals

Provider-agnostic and BYO-LLM: the package owns prompt assembly, diff-stat derivation, fence-stripping, and `.git/pr-cache` management, and never calls an LLM itself. `build_commit_prompt` / `build_mr_prompt` produce `(system_prompt, user_input)`; callers run their own LLM, then feed the response through `parse_commit_response` / `parse_mr_response`. `build_commit_prompt` also accepts optional `branch_name` / `branch_commits` / `branch_diffstat` so the prefix can be chosen from the perspective of the whole branch (assembled via `format_branch_context`). `__init__.py`'s `__all__` is the authoritative public surface. Zero LLM SDK dependencies.

`parse_commit_response` is parse-only. The deterministic formatting rules — `wrap_commit_body` and `enforce_subject_limit` — are exported separately and applied by `bin/git-ai`'s commit flow, not folded into the parser: `enforce_subject_limit` returns a `SubjectTrim`, not a string, because a subject with no usable clause break comes back untouched and the caller has to surface that. Folding it in would either break the parser's `str` return or swallow the note. Library consumers call both explicitly (see the README's Python library section).

The branch-context machinery (`get_default_branch`, `resolve_commit_base`, `_nearest_fork_parent`, `get_branch_commit_subjects`, `get_branch_churn_subjects`, `format_branch_context`) lives in **`_git_branch.py`**, split out from `_git.py` for the per-file line limit; it imports the low-level git helpers one-directionally from `_git.py` (no cycle), and `__init__.py` re-exports both so the public surface is unchanged.

## pip-installable CLI (`_launcher.py` + `_build_backend.py`)

The same `waxmard-git-ai` package that ships the Python library also exposes the `git-ai` / `aigit` console scripts (`[project.scripts]` in `pyproject.toml`). There is **no Python reimplementation**: the launcher just `execvpe`s `bash` on the wheel-bundled CLI.

The canonical Bash lives at the repo root (`bin/`, `lib/`) — shared with the npm package and `make install` — so it can't sit inside the package where the wheel needs it. The **in-tree PEP 517 backend** (`_build_backend.py`, wired via `build-backend = "_build_backend"` + `backend-path = ["."]`) copies `bin/` + `lib/` into `python/git_ai/_sh/{bin,lib}` on every build (wheel/sdist/editable), so the bundled Bash is fresh build output and never drifts (`_sh/` is gitignored; `MANIFEST.in` grafts the root Bash into the sdist so from-sdist builds can re-copy).

The Bash layer resolves all its sibling assets (prompts, the `_*_cli.py` helpers, `default-excludes.txt`) through one variable, **`GIT_AI_PKG_DIR`** (defined in `lib/ai-common.sh`, default = the repo-layout sibling `python/git_ai`); the launcher overrides it to the installed package dir so the wheel's flattened layout (`git_ai/prompts/`, `git_ai/_pr_repo_cli.py`, …) resolves. npm + `make install` are unaffected — they hit the default. The `python` CI workflow's wheel-smoke steps build the wheel, assert `git_ai/_sh/` is bundled, then `pip install` it and run `git-ai providers` from outside the repo to prove the whole chain.
