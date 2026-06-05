## Overview

git-ai provides LLM-powered git workflow tools (`git-ai commit`, `git-ai pr`) that generate commit messages and PR titles/bodies using your configured LLM provider (via its CLI or API). The Bash CLI has no runtime dependencies beyond system binaries and provider CLIs. {{ include:partials/python-library.md }}

## Commands

```bash
make install        # Symlink tools to ~/.local/bin and ~/.local/lib (edits are live)
make uninstall      # Remove symlinks
make hooks          # Install git hooks via lefthook (also run by make install)
make lint           # Run shellcheck on all scripts
make test           # Run BATS unit tests (installs deps via npm ci if needed)

# Python package (uv-managed)
make sync           # uv sync — install Python deps
make py-lint        # ruff check python/ + test/python
make py-format      # ruff --fix + ruff format (python/ + test/python)
make py-type-check  # mypy python/git_ai test/python
make py-test        # uv run pytest

# Docs (generated from docs/src/ — never edit the generated root docs directly)
make docs-build     # Regenerate the root docs (README + agent guides) from docs/src/
make docs-check     # Fail if any generated doc is stale (CI gate)

# Validation (matches CI)
bash -n bin/git-ai bin/aigit lib/ai-common.sh   # Syntax check
shellcheck -x lib/*.sh && shellcheck -x bin/*   # Lint
npm test                                         # BATS tests
uv run pytest                                    # Python tests

# Smoke tests (require a real provider CLI or API key)
git-ai commit gemini          # After git add, generates commit message
git-ai pr codex --base main   # Generates PR title/body against base branch
git-ai pr codex --fresh       # Bypass per-branch PR cache
```

## Architecture

- **`bin/git-ai`** — Single CLI entry point. Dispatches on first arg (`commit`, `pr`/`mr`, `setup`, `providers`, `models`, `options`). Contains all command logic as shell functions.
- **`bin/aigit`** — Thin alias wrapper; just execs `git-ai "$@"`.
- **`lib/ai-common.sh`** — Shared utilities: `run_provider()` dispatches to the supported provider CLIs, `strip_fences()` cleans markdown artifacts from LLM output, provider-specific auth/env helpers.
- **Setup wizard** — `git-ai setup` (`cmd_setup` in `bin/git-ai`) branches on whether `options.conf` already exists. **No config → `_setup_fresh`**: a `provider_ready` status table, fzf/numbered provider+model selection, `render_options_conf` writes the file (the inverse of `list_options`), then auth-assist + a best-effort per-repo default seed. **Config exists → `_setup_edit_existing`**: an additive menu (add / remove provider, change models, set up auth) that mutates the file **in place** via the surgical `conf_*` editors (`conf_section_providers`, `conf_add_section`, `conf_remove_section`, `conf_set_section_models`) — each reads the file on stdin and writes it back touching only the targeted `[provider]` section, so comments and vertex `account=`/`projects=` settings are preserved and nothing is overwritten wholesale. Per-provider auth-assist (`_setup_ensure_auth`) prompts for API keys and stores them via `store_api_key` → keychain, or `persist_key_to_rc` → shell rc. It auto-launches from `cmd_commit`/`cmd_pr` via `maybe_first_run_setup` when nothing is configured and stdin/stdout are a tty (gated off by `CI` / `GIT_AI_NO_SETUP` / non-tty, so scripts and the lazygit capture path are never interrupted; the auto path only ever hits the fresh flow). Key resolution is unified: `resolve_api_key SERVICE ENVVAR` (env → macOS Keychain → libsecret → pass → kwallet) backs `gemini-api`, `anthropic-api`, and `openai-api` alike; `provider_key_meta` maps a provider to its `(service, envvar)`.
- **`run_provider()`** is the core dispatcher — takes a tool name (`commit` or `pr`) and prompt, handles stdin piping, temp file management, and error capture differently per provider.
- **`python/git_ai/`** — Python package (provider-agnostic, BYO-LLM). Owns prompt assembly, diff-stat derivation, fence-stripping, and `.git/pr-cache` management; never calls an LLM itself. Public surface (see `__init__.py`): `build_commit_prompt` / `build_mr_prompt` produce `(system_prompt, user_input)`; callers run their own LLM, then feed the response through `parse_commit_response` / `parse_mr_response`. `build_commit_prompt` also accepts optional `branch_name` / `branch_commits` / `branch_diffstat` so the prefix can be chosen from the perspective of the whole branch (assembled via `format_branch_context`). Helpers: `format_commit_log`, `derive_diff_stat`, `get_diff` / `get_staged_diff` / `get_diff_stat`, `get_commit_log`, `get_release_context` / `get_mr_release_context`, `get_current_branch` / `get_default_branch` / `get_git_dir` / `get_head_sha` / `check_git_repo`, `resolve_commit_base` / `get_branch_commit_subjects` / `get_branch_churn_subjects`, `strip_fences`. PR-cache: `RepoPrContext`, `prepare_repo_pr_context`, `load_cached_pr` / `load_cached_pr_sha` / `save_cached_pr`. PR-update display: `render_pr_diff` (unified diff w/ ANSI) and `summarize_pr_changes` (markdown-safe per-section delta summary). Zero LLM SDK dependencies.
- **`python/git_ai/prompts/*.txt`** — single source of truth for prompts: `commit.txt`, `pr-two-pass.txt`, `pr-two-pass-update.txt`, `pr-fallback.txt`, `pr-fallback-update.txt`. `bin/git-ai` reads them via `cat "${SCRIPT_DIR}/../python/git_ai/prompts/<name>.txt"`; the Python package loads them via `importlib.resources`.
- **`python/git_ai/_ignore.py`** — built-in lockfile defaults (`DEFAULT_EXCLUDES`) + `.git-ai-ignore` parser (gitignore-syntax with `!negation`). `lib/ai-common.sh` mirrors the same default list and parser logic for the shell `cmd_commit` path. Threaded through `get_staged_diff` / `get_diff` / `get_diff_stat` via `exclude_patterns=`. A post-exclude diff-size guard in `_generate.py` (`GIT_AI_MAX_DIFF_BYTES`, default `900000`) hard-fails with a "Largest changed files" hint when input would exceed an LLM provider's input cap (Codex's is 1 MiB).
- **`docs/src/` + `scripts/build_docs.py`** — the root `README.md` and the per-agent guide docs are generated from templates under `docs/src/`. Edit the templates, not the generated files, then run `make docs-build`. Shared prose lives in `docs/src/partials/` and is pulled in with double-brace `include:partials/<name>` directives. The agent guides are thin per-agent headers that both include `partials/guide-body.md`, so the shared guidance never drifts; `make docs-check` is the CI gate.
- Context payloads are wrapped in XML-style tags (`<release_context>`, `<branch>` / `<branch_commits>` / `<branch_diffstat>`, `<diff>`, `<commit_log>`, `<existing_pr>`) so the model can disambiguate sections.
- **Branch-aware commit prefixes** — `git-ai commit` resolves the branch's base via a local-only cascade (`--base` / `GIT_AI_COMMIT_BASE` → git-ai PR-cache base → nearest fork-parent → none) in `_git.py:resolve_commit_base`, then surfaces the branch name, its commit subjects, and its cumulative diffstat to the model. Fork-parent detection (`_nearest_fork_parent`) scores every local/origin branch by `(commits-ahead, commits-behind, name-rank)` and picks the smallest, so it finds the real base by name-agnostic ancestry — `main`/`master`/`dev` plus `release/*`, `staging`, and stacked parent branches — capped at 50 branches (newest first) for speed. Divergence for all candidates comes from a single `for-each-ref --format=%(ahead-behind:HEAD)` call (`_branch_ahead_behind`), falling back to per-ref `git rev-list` probing only on git too old (<2.41) for that token. The prompt uses this only to disambiguate the prefix when the staged diff alone is ambiguous — per-commit types are preserved. The shell path gathers it through `python/git_ai/_commit_cli.py` (`branch-context`).

## PR caching

`git-ai pr` caches its output per `(branch, base)` pair under `.git/pr-cache/<key>/` (`last-output` + `last-head-sha`).

- If HEAD SHA matches the cached SHA, the cached title/body is reused and no LLM call is made.
- If new commits exist since the cache, the cached text is fed to the update-prompt variant (`pr-two-pass-update.txt` / `pr-fallback-update.txt`) so existing wording is preserved.
- `--fresh` bypasses the cache entirely and regenerates from scratch.

**Intra-branch refinement folding** — the two-pass draft groups commits into sections by their conventional type, but a follow-up `fix`/`refactor`/`perf`/`docs` commit that only touches code added earlier in the *same* branch is invisible from the base branch's perspective (the net diff shows only the final feature). `_git.py:get_branch_churn_subjects` classifies each commit in `base..HEAD` via hunk-level `git blame` of its parent: a commit is "churn" when every pre-image line it edits or deletes was introduced by a branch-local commit (pure additions never count — they introduce, not refine). `prepare_repo_pr_context` computes the churn subjects and threads them through `build_mr_prompt_input` → `_pr_draft.analyze`, which pulls those entries out of their type sections into a trailing `### Intra-branch refinements` block. The two-pass prompts instruct the model to fold that block's net effect into the feature it refines rather than emit standalone `### Performance`/`### Docs` sections. Best-effort: a git failure or a branch over 50 commits yields no churn subjects, falling back to plain type-grouping.

## Coding Conventions

- `#!/bin/bash`, POSIX-leaning Bash. Two-space indentation.
- `snake_case` functions, `UPPERCASE` exported constants/prompts.
- Fail fast: `die "message"`, `set -o pipefail`.
- Keep command logic in `bin/git-ai`, reusable helpers in `lib/`.
- Run `shellcheck` before opening a PR.
- Python lint/format via ruff (rule set `E,F,I,B,UP,SIM,RUF,PL,S` in `pyproject.toml`), strict mypy. `S603`/`S607` are ignored repo-wide because every `subprocess` call is a trusted list-form `git` invocation.

## Test Coverage

Two suites run in CI on every push/PR:

- **BATS** — `test/bin/`, `test/lib/`, run via `make test` or `npm test` (`.github/workflows/test.yml`).
- **pytest** — `test/python/`, run via `make py-test` or `uv run pytest` (`.github/workflows/python.yml`).

**Covered (BATS)** — pure/deterministic functions with no external deps:
- `lib/ai-common.sh`: `strip_fences`, `resolve_model`, `provider_display_name`, `tier_display_name`, `order_by_recent`, `die`, `get/save_last_choice`, `get/save_last_provider`, `get/save_last_tier`
- Setup wizard helpers (`lib/ai-common.sh`): `resolve_api_key` + `provider_ready` (`resolve_api_key.bats`, `provider_ready.bats`, with PATH-stubbed `security`/`gcloud`/CLIs), `render_options_conf` (`render_options_conf.bats`), the in-place `conf_*` config editors `conf_section_providers` / `conf_add_section` / `conf_remove_section` / `conf_set_section_models` incl. vertex-settings preservation (`conf_edit.bats`), `provider_key_meta` / `store_api_key` / `shell_rc_path` / `format_key_export` / `persist_key_to_rc` (`key_storage.bats`)
- `bin/git-ai`: `branch_cache_path`, `load_cached_pr`, `load_cached_pr_sha`, `save_cached_pr` (with head-sha), `cmd_providers`, argument dispatch incl. `setup` routing (`argument_parsing.bats`), `maybe_first_run_setup` no-op/CI-safety guard (`first_run_setup.bats`)

**Covered (pytest)** — Python package internals:
- `_generate.py`: prompt builders + response parsers (`test_build_prompts.py`), fence-stripping (`test_strip_fences.py`), diff-size guard (`test_generate_size_guard.py`)
- `_git.py`: git helpers incl. branch-base resolution cascade + branch-context assembly (`test_git_utils.py`)
- `_ignore.py`: `.git-ai-ignore` parsing + defaults (`test_ignore.py`)
- `_pr_incremental.py`: repo-mode incremental PR cache (`test_pr_incremental.py`); PR draft assembly (`test_pr_draft.py`)
- `_pr_render.py`: unified-diff render + summary (`test_pr_render.py`)
- Prompt loading (`test_prompts.py`)

**Intentionally not covered** — functions that require live external processes:
- `run_provider()` and its API helpers (`_run_anthropic_api`, `_run_openai_api`) — need real LLM calls or an HTTP mock server
- `cmd_commit()` / `cmd_pr()` end-to-end — depend on `run_provider` and real git state with staged changes
- `resolve_gemini_bin()` / `resolve_gemini_api_key()` — platform-specific (Keychain, nvm paths, etc.)
- `_gemini_has_adc()` — requires mocking `gcloud`

No coverage threshold is enforced: the excluded functions are untestable without a live provider, not accidentally missed. When adding new helper functions, add a corresponding `.bats` file in `test/lib/` or `test/bin/`, or a `test_*.py` file in `test/python/`.

## Commits & Releases

- Conventional Commits required (`feat:`, `fix:`, `chore:`, etc.).
- Releases automated via release-please (config in `release-please-config.json`, version tracked in `package.json` and `pyproject.toml`).
- CI runs shellcheck + BATS on push to main and all PRs; the Python workflow runs ruff, mypy, and pytest. A Security workflow (`.github/workflows/security.yml`) runs semgrep (SAST) + trivy (filesystem vuln/secret scan) on PRs and a weekly cron, uploading SARIF to GitHub Code Scanning. A Docs workflow (`.github/workflows/docs.yml`) runs `make docs-check` to block stale generated docs.
- npm publish runs automatically on release tag push via `.github/workflows/npm-publish.yml`.
- PyPI publish runs automatically on release tag push via `.github/workflows/pypi-publish.yml` (package name `waxmard-git-ai`).
- Pre-commit hooks managed by [lefthook](https://github.com/evilmartians/lefthook) (`lefthook.yml`). Jobs run in parallel, file-scoped via `glob`: shell-lint (shellcheck), bats (BATS tests), python (ruff format + ruff lint + `dmypy run` + pytest, serialized to avoid autofix/read races), and docs (`make docs-check`). `stage_fixed: true` auto-restages ruff-formatted files. Mypy uses `dmypy` (daemon) for warm-cache speed; `dmypy run` auto-starts the daemon. Install: `make hooks` (lefthook provided by mise).
- Tool versions pinned via [mise](https://mise.jdx.dev/) (`mise.toml`): node, uv, lefthook, shellcheck. Run `mise install` once after cloning; mise auto-activates the right versions on `cd`.
