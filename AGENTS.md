<!-- Generated from docs/src/AGENTS.md by scripts/build_docs.py. Run `make docs-build` to regenerate. Do not edit directly. -->

# AGENTS.md

This file provides guidance to AI coding agents working in this repository.

## Overview

git-ai provides LLM-powered git workflow tools (`git-ai commit`, `git-ai pr`) that generate commit messages and PR titles/bodies using your configured LLM provider (via its CLI or API). The Bash CLI has no runtime dependencies beyond system binaries and provider CLIs.

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

- **`bin/git-ai`** — Single CLI entry point. Dispatches on first arg (`commit`, `pr`/`mr`, `setup`, `providers`, `models`, `options`). Holds the core command logic (`cmd_commit`/`cmd_pr`/`cmd_setup`/…) and sources `lib/ai-common.sh` + `lib/setup.sh`.
- **`bin/aigit`** — Thin alias wrapper; just execs `git-ai "$@"`.
- **`lib/ai-common.sh`** — **Umbrella** entry: holds core helpers (`die`, `_trim`, `strip_fences`, `.git-ai-ignore`/diff helpers, choice-state persistence) and sources the four split-out submodules below, so `source lib/ai-common.sh` still pulls the full helper surface (every test and `bin/git-ai` source only this file). Split for the per-file line limit.
  - **`lib/auth.sh`** — provider auth, key resolution (`resolve_api_key`, `store_api_key`, `format_key_export`), `provider_ready`, vertex token/ADC helpers, provider metadata (`provider_display_name`, `recommended_model`, `provider_key_meta`).
  - **`lib/discovery.sh`** — live, cached model discovery (`discover_models`, the per-provider `_fetch_models_*` fetchers, models.dev fallback).
  - **`lib/config.sh`** — `options.conf` parsing (`parse_user_options`), the in-place `conf_*` editors, `render_options_conf`, vertex config resolution, and the `list_providers`/`list_models`/`list_options` picker feeds.
  - **`lib/provider.sh`** — provider/model selection (`pick_or_recall_provider`, `resolve_model`, `default_model_for_provider`) and the `run_provider()` dispatcher + per-provider `_run_*` API/CLI calls.
- **`lib/setup.sh` + `lib/setup-edit.sh` + `lib/setup-shadow.sh`** — The `git-ai setup` wizard: all `_setup_*` helpers (pickers, fast path, auth-assist, `maybe_first_run_setup` auto-launch, the flow drivers `_setup_fresh`/`_setup_manual`/`_setup_fast_path`/`_setup_edit_existing`). `setup.sh` is the umbrella and sources two siblings, split for the line limit: `setup-edit.sh` holds the config-overview + in-place edit actions (`_setup_action_*`, `_setup_change_models`, the vertex-projects actions, and their `_conf_apply`/`_merge_vertex_projects` helpers); `setup-shadow.sh` holds the shadow-install detection (`_setup_check_shadow` + the `_setup_check_shadow_npm`/`_setup_check_shadow_pyx` package-manager probes). Sourced by `bin/git-ai`; calls into `lib/ai-common.sh`. The `cmd_setup` command entry itself stays in `bin/git-ai` as a thin dispatcher. `make install` symlinks every `lib/*.sh`.
- **Setup wizard** (`cmd_setup` in `bin/git-ai`, `_setup_*` helpers in `lib/setup.sh` + `lib/setup-edit.sh` + `lib/setup-shadow.sh`) — branches on whether `options.conf` already exists.
  - **No config → `_setup_fresh`**: probes `provider_ready` over every provider to build the **ready set**, then takes one of two paths. **Fast path** (`_setup_fast_path`, when the ready set is non-empty and `GIT_AI_NO_SETUP_FAST` is unset): a zero-question flow that enables every ready provider with its `recommended_model` pin, seeds the per-repo default, and lands on the config overview to tweak or finish. **Manual** (`_setup_manual`, empty ready set or `GIT_AI_NO_SETUP_FAST=1`): a `provider_ready` status table, then fzf/numbered provider and per-provider model pickers — models **live-discovered** (see below), recommended ones headed "(recommended)", custom ids via a sentinel row — written with `render_options_conf` and a plain exit.
  - **Config exists → `_setup_edit_existing`**: a `_setup_print_summary` plus an in-place edit menu (add/remove provider, change models, change vertex projects, confirmed reset). Edits mutate **only the targeted section** via the surgical `conf_*` editors (`conf_add_section`, `conf_remove_section`, `conf_set_section_models`, `conf_set_section_setting`, …), so comments and vertex settings survive. Change-models and change-projects are **replace-style**: one multi-select over `current ∪ discovered`, the marked set replaces the pins (Esc/blank keeps current).
  - **Vertex AI is a single user-facing option** — the wizard hides the internal `vertex-gemini`/`vertex-anthropic` split, routing each picked model to its backend by id (`claude*` → anthropic, else gemini) and folding both sections back to one entry for choosers/summary. Vertex projects live in a shared `[vertex] projects =` list that `parse_user_options` expands into per-project `vertex-<x>@<project>` profiles.
  - **Auth-assist** (`_setup_ensure_auth`) prompts for API keys after selection and stores them to keychain (`store_api_key`) or shell rc (`persist_key_to_rc`); vertex gets `_setup_vertex_assist` (offers ADC login, prompts for `project`/`region`/`account`). Recommended ids are **data, not code** — `recommended-models.conf` (a packaged asset under `python/git_ai/`, resolved via `GIT_AI_PKG_DIR`; `family = model-id`), with `recommended_model()` mapping provider → family; suggestions-only, *not* a catalog.
  - Auto-launches from `cmd_commit`/`cmd_pr` via `maybe_first_run_setup` when nothing is configured and stdin/stdout are a tty (gated off by `CI` / `GIT_AI_NO_SETUP` / non-tty; the auto path only ever hits the fresh flow).
- **`run_provider()`** is the core dispatcher — takes a tool name (`commit` or `pr`) and prompt, handles stdin piping, temp file management, and error capture differently per provider.
- **Model discovery (`discover_models` in `lib/discovery.sh`)** — there is **no hardcoded model catalog**; lists are fetched live from each provider's own API so new models appear without a git-ai release. `discover_models PROVIDER [--refresh]` serves a disk cache (`$XDG_CONFIG_HOME/git-ai/models-cache/<provider>.list`, TTL via `GIT_AI_MODELS_TTL_MIN`, default 24h), else fetches+caches, else serves a stale cache on failure. Per-provider `_fetch_models_*` hit each API — Gemini, Anthropic, OpenAI (chat-filtered), and Vertex Model Garden (gcloud token, text-generation models only). The CLIs (`claude-code`/`codex`) have no list endpoint, and any provider whose creds aren't set up falls back to the **keyless `models.dev/api.json` catalog** — so authed API first, models.dev second, free-text always. Discovery is suggestions-only: `resolve_model` passes an explicit model through verbatim (the provider API is the real validator), defaulting to the tool's last saved pick, else the first discovered model. `list_options` treats a **present** `options.conf` as authoritative — only pinned entries are offered, an empty `[provider]` section hides that provider; live discovery feeds the picker **only** when no `options.conf` exists.
- **`python/git_ai/`** — Python package (provider-agnostic, BYO-LLM). Owns prompt assembly, diff-stat derivation, fence-stripping, and `.git/pr-cache` management; never calls an LLM itself. Public surface (see `__init__.py`): `build_commit_prompt` / `build_mr_prompt` produce `(system_prompt, user_input)`; callers run their own LLM, then feed the response through `parse_commit_response` / `parse_mr_response`. `build_commit_prompt` also accepts optional `branch_name` / `branch_commits` / `branch_diffstat` so the prefix can be chosen from the perspective of the whole branch (assembled via `format_branch_context`). Helpers: `format_commit_log`, `derive_diff_stat`, `get_diff` / `get_staged_diff` / `get_diff_stat`, `get_commit_log`, `get_release_context` / `get_mr_release_context`, `get_current_branch` / `get_default_branch` / `get_git_dir` / `get_head_sha` / `check_git_repo`, `resolve_commit_base` / `get_branch_commit_subjects` / `get_branch_churn_subjects`, `strip_fences`. PR-cache: `RepoPrContext`, `prepare_repo_pr_context`, `load_cached_pr` / `load_cached_pr_sha` / `save_cached_pr`. PR-update display: `render_pr_diff` (unified diff w/ ANSI) and `summarize_pr_changes` (markdown-safe per-section delta summary). Zero LLM SDK dependencies. The branch-context machinery (`get_default_branch`, `resolve_commit_base`, `_nearest_fork_parent`, `get_branch_commit_subjects`, `get_branch_churn_subjects`, `format_branch_context`) lives in **`_git_branch.py`**, split out from `_git.py` for the per-file line limit; it imports the low-level git helpers one-directionally from `_git.py` (no cycle), and `__init__.py` re-exports both so the public surface is unchanged.
- **pip-installable CLI (`python/git_ai/_launcher.py` + `_build_backend.py`)** — the same `waxmard-git-ai` package that ships the Python library also exposes the `git-ai` / `aigit` console scripts (`[project.scripts]` in `pyproject.toml`). There is **no Python reimplementation**: the launcher just `execvpe`s `bash` on the wheel-bundled CLI. The canonical Bash lives at the repo root (`bin/`, `lib/`) — shared with the npm package and `make install` — so it can't sit inside the package where the wheel needs it; the **in-tree PEP 517 backend** (`_build_backend.py`, wired via `build-backend = "_build_backend"` + `backend-path = ["."]`) copies `bin/` + `lib/` into `python/git_ai/_sh/{bin,lib}` on every build (wheel/sdist/editable), so the bundled Bash is fresh build output and never drifts (`_sh/` is gitignored; `MANIFEST.in` grafts the root Bash into the sdist so from-sdist builds can re-copy). The Bash layer resolves all its sibling assets (prompts, the `_*_cli.py` helpers, `default-excludes.txt`) through one variable, **`GIT_AI_PKG_DIR`** (defined in `lib/ai-common.sh`, default = the repo-layout sibling `python/git_ai`); the launcher overrides it to the installed package dir so the wheel's flattened layout (`git_ai/prompts/`, `git_ai/_pr_repo_cli.py`, …) resolves. npm + `make install` are unaffected — they hit the default. The `python` CI workflow's wheel-smoke steps build the wheel, assert `git_ai/_sh/` is bundled, then `pip install` it and run `git-ai providers` from outside the repo to prove the whole chain.
- **`python/git_ai/prompts/*.txt`** — the prompts consumed at runtime: `commit.txt`, `pr-two-pass.txt`, `pr-two-pass-update.txt`, `pr-fallback.txt`, `pr-fallback-update.txt`. `bin/git-ai` reads them via `cat "${GIT_AI_PKG_DIR}/prompts/<name>.txt"`; the Python package loads them via `importlib.resources`. The four `pr-*.txt` files are **generated** — edit their templates under `prompts/src/`, not these files (see below); `commit.txt` is hand-written here (it shares no verbatim text with the PR prompts). The four PR prompts make the model wrap its answer in `===TITLE===` / `===BODY===` line markers; `parse_mr_response` (`_extract_pr_sections`) and the shell mirror `extract_pr_output` in `lib/ai-common.sh` slice the sections out, discarding any out-of-band preamble/reasoning the model emits before the title, and fall back to the raw fence-stripped text when the markers are absent.
- **`prompts/src/` + `scripts/build_prompts.py`** — the four `pr-*.txt` prompts are generated from templates under `prompts/src/` that pull shared prose in with double-brace `include:partials/<name>.txt` directives, so wording that must stay in lockstep across the PR prompts (type classification, the `===TITLE===`/`===BODY===` output markers, the `<existing_pr>` preservation rules) lives once under `prompts/src/partials/`. Edit the templates, then run `make prompts-build`; `make prompts-check` is the CI gate (mirrors the docs system). Unlike `build_docs.py`, no header comment is prepended — a generated prompt is fed verbatim to the LLM, so the generated files carry no "do not edit" banner; the staleness gate is what guards against hand-edits drifting. `commit.txt` is intentionally excluded (standalone, edited directly).
- **`python/git_ai/_ignore.py`** — built-in lockfile defaults (`DEFAULT_EXCLUDES`) + `.git-ai-ignore` parser (gitignore-syntax with `!negation`). `lib/ai-common.sh` mirrors the same default list and parser logic for the shell `cmd_commit` path. Threaded through `get_staged_diff` / `get_diff` / `get_diff_stat` via `exclude_patterns=`. A post-exclude diff-size guard in `_generate.py` (`GIT_AI_MAX_DIFF_BYTES`, default `900000`) hard-fails with a "Largest changed files" hint when input would exceed an LLM provider's input cap (Codex's is 1 MiB).
- **`python/git_ai/_instructions.py`** — repo-local guidance: the repo-root `.git-ai-instructions` file (free-form prose for commit scopes + type-classification overrides). `load_repo_instructions` reads/trims it; `format_repo_guidance` wraps it in an authoritative `<repo_guidance>` block injected into both commit (`build_commit_prompt`) and PR (`build_mr_prompt` → `build_mr_prompt_input`) prompts. `lib/ai-common.sh:load_git_ai_instructions` mirrors the reader for the shell `cmd_commit` path; `cmd_pr` passes the file to `_pr_repo_cli.py build-input --repo-instructions-file`. The prompts (`commit.txt` + the four `pr-*.txt`) instruct the model to let repo guidance override the default heuristics. Absent/empty file is a no-op; the single-conventional-commit verbatim PR fast-path skips guidance (no LLM call).
- **`docs/src/` + `scripts/build_docs.py`** — the root `README.md` and the per-agent guide docs are generated from templates under `docs/src/`. Edit the templates, not the generated files, then run `make docs-build`. Shared prose lives in `docs/src/partials/` and is pulled in with double-brace `include:partials/<name>` directives. The agent guides are thin per-agent headers that both include `partials/guide-body.md`, so the shared guidance never drifts; `make docs-check` is the CI gate.
- Context payloads are wrapped in XML-style tags (`<release_context>`, `<branch>` / `<branch_commits>` / `<branch_diffstat>`, `<diff>`, `<commit_log>`, `<existing_pr>`) so the model can disambiguate sections.
- **Branch-aware commit prefixes** — `git-ai commit` resolves the branch's base via a local-only cascade (`--base` / `GIT_AI_COMMIT_BASE` → git-ai PR-cache base → nearest fork-parent → none) in `_git_branch.py:resolve_commit_base`, then surfaces the branch name, its commit subjects, and its cumulative diffstat to the model. Fork-parent detection (`_nearest_fork_parent`) scores every local/origin branch by `(commits-ahead, commits-behind, name-rank)` and picks the smallest, so it finds the real base by name-agnostic ancestry — `main`/`master`/`dev` plus `release/*`, `staging`, and stacked parent branches — capped at 50 branches (newest first) for speed. Divergence for all candidates comes from a single `for-each-ref --format=%(ahead-behind:HEAD)` call (`_branch_ahead_behind`), falling back to per-ref `git rev-list` probing only on git too old (<2.41) for that token. The prompt uses this only to disambiguate the prefix when the staged diff alone is ambiguous — per-commit types are preserved. The shell path gathers it through `python/git_ai/_commit_cli.py` (`branch-context`).

## PR caching

`git-ai pr` caches its output per `(branch, base)` pair under `.git/pr-cache/<key>/` (`last-output` + `last-head-sha`).

- If HEAD SHA matches the cached SHA, the cached title/body is reused and no LLM call is made.
- If new commits exist since the cache, the cached text is fed to the update-prompt variant (`pr-two-pass-update.txt` / `pr-fallback-update.txt`) so existing wording is preserved.
- `--fresh` bypasses the cache entirely and regenerates from scratch.

**Intra-branch refinement folding** — the two-pass draft groups commits by conventional type, but a follow-up `fix`/`refactor`/`perf`/`docs` commit that only touches code added earlier in the *same* branch is invisible from the base branch's net diff (which shows only the final feature). `_git_branch.py:get_branch_churn_subjects` flags such "churn" commits via hunk-level `git blame` of each parent (every pre-image line it edits or deletes was introduced branch-locally; pure additions never count). `prepare_repo_pr_context` threads them through `build_mr_prompt_input` → `_pr_draft.analyze`, which pulls them into a trailing `### Intra-branch refinements` block the prompts fold into the feature they refine rather than emitting standalone sections. Best-effort: a git failure or a branch over 50 commits yields none, falling back to plain type-grouping.

## Coding Conventions

- `#!/bin/bash`, POSIX-leaning Bash. Two-space indentation.
- `snake_case` functions, `UPPERCASE` exported constants/prompts.
- Fail fast: `die "message"`, `set -o pipefail`.
- Keep command logic in `bin/git-ai`, reusable helpers in `lib/`.
- **Per-file line cap: 800** (hand-written shell + Python source). Enforced by `scripts/check-line-limit.sh` via the `line-limit` lefthook job and CI workflow; `make line-limit` runs it locally (override with `GIT_AI_LINE_LIMIT`). When a file approaches the cap, split it into focused modules — for shell, use the umbrella pattern (`lib/ai-common.sh` sources its siblings; `lib/setup.sh` sources `setup-edit.sh` + `setup-shadow.sh`) so the public source contract is unchanged.
- Run `shellcheck` before opening a PR.
- Python lint/format via ruff (rule set `E,F,I,B,UP,SIM,RUF,PL,S` in `pyproject.toml`), strict mypy. `S603`/`S607` are ignored repo-wide because every `subprocess` call is a trusted list-form `git` invocation.

## Test Coverage

Two suites run in CI on every push/PR:

- **BATS** — `test/bin/`, `test/lib/`, run via `make test` or `npm test` (`.github/workflows/test.yml`).
- **pytest** — `test/python/`, run via `make py-test` or `uv run pytest` (`.github/workflows/python.yml`).

**Covered (BATS)** — pure/deterministic functions with no external deps:
- `lib/ai-common.sh` umbrella (functions now live across `lib/{auth,discovery,config,provider}.sh` but load via the umbrella): `strip_fences`, `resolve_model` (now pass-through; default = last pick → first discovered, `resolve_model.bats`), `provider_display_name`, `tier_display_name`, `order_by_recent`, `die`, `get/save_last_choice`, `get/save_last_provider`, `get/save_last_tier`
- Model discovery (`lib/discovery.sh`): `discover_models` cache hit / `--refresh` / stale-fallback / write-through, and the per-provider fetch parsers `_fetch_models_gemini_api` / `_fetch_models_anthropic_api` / `_fetch_models_openai_api` / `_fetch_models_vertex` / `_fetch_models_modelsdev` (incl. the keyless models.dev CLI fallback) with PATH-stubbed `curl`/`gcloud` fixtures (`discover_models.bats`); the `list_options` / `cmd_models` no-config paths run against seeded caches with the network blocked.
- Setup wizard helpers (`lib/auth.sh` / `lib/config.sh`): `resolve_api_key` + `provider_ready` (`resolve_api_key.bats`, `provider_ready.bats`, with PATH-stubbed `security`/`gcloud`/CLIs), `render_options_conf` (`render_options_conf.bats`), `recommended_model` family mapping + `recommended-models.conf` data-file parsing (`recommended_model.bats`), the in-place `conf_*` config editors `conf_section_providers` / `conf_add_section` / `conf_remove_section` / `conf_set_section_models` / `conf_set_section_setting` incl. vertex-settings preservation + key upsert (`conf_edit.bats`), `provider_key_meta` / `store_api_key` / `shell_rc_path` / `format_key_export` / `persist_key_to_rc` (`key_storage.bats`)
- `bin/git-ai` + the wizard libs (`lib/setup.sh` / `lib/setup-edit.sh` / `lib/setup-shadow.sh`, exercised by sourcing `bin/git-ai`): `branch_cache_path`, `load_cached_pr`, `load_cached_pr_sha`, `save_cached_pr` (with head-sha), `cmd_providers`, argument dispatch incl. `setup` routing (`argument_parsing.bats`), `maybe_first_run_setup` no-op/CI-safety guard (`first_run_setup.bats`), `_setup_check_shadow` shadow detection + opt-in removal across npm-global and the pip CLI vectors (`_setup_check_shadow_pyx` for pipx / uv tool) with stubbed `npm`/`uv`/`pipx` (`setup_check_shadow.bats`), `_setup_select` numbered-fallback single-select, `_setup_print_summary` models/empty/merged-vertex rendering, `_setup_existing_models` profile- and vertex-fold, `_setup_pick_projects` free-text fallback, the vertex-unification helpers `_setup_expand_provider` / `_setup_provider_for_model` / `_setup_conf_wizard_providers` / `_setup_write_vertex_models`, `_setup_action_reset` confirm/decline routing, `_setup_detect_vertex_project` active-first/API-filter/fallback cascade with a stubbed `gcloud`, the vertex-conditional projects menu action, `_setup_current_vertex_projects` plural/singular seeding, `_setup_change_vertex_projects` replace/keep semantics, `_setup_change_models` replace/keep + vertex-family-clear semantics (`setup_select.bats`), `_setup_fast_path` zero-question enable + recommended-model config write + vertex expansion + per-repo default seed + overview landing (`setup_fast_path.bats`)

**Covered (pytest)** — Python package internals:
- `_generate.py`: prompt builders + response parsers (`test_build_prompts.py`), fence-stripping (`test_strip_fences.py`), diff-size guard (`test_generate_size_guard.py`)
- `_git.py` / `_git_branch.py`: git helpers incl. branch-base resolution cascade + branch-context assembly (`test_git_utils.py`)
- `_ignore.py`: `.git-ai-ignore` parsing + defaults (`test_ignore.py`)
- `_instructions.py`: `.git-ai-instructions` loading + `<repo_guidance>` formatting + commit/PR prompt injection (`test_instructions.py`, `test_build_prompts.py`)
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
- CI runs shellcheck + BATS on push to main and all PRs; the Python workflow runs ruff, mypy, and pytest, then a wheel-smoke step that builds the wheel, asserts the bundled Bash CLI is present, and `pip install`s + runs it from outside the repo. A Security workflow (`.github/workflows/security.yml`) runs semgrep (SAST) + trivy (filesystem vuln/secret scan) on PRs and a weekly cron, uploading SARIF to GitHub Code Scanning. A Docs workflow (`.github/workflows/docs.yml`) runs `make docs-check` to block stale generated docs. A Line-limit workflow (`.github/workflows/line-limit.yml`) runs `scripts/check-line-limit.sh` to enforce the 800-line per-file source cap.
- npm publish runs automatically on release tag push via `.github/workflows/npm-publish.yml`.
- PyPI publish runs automatically on release tag push via `.github/workflows/pypi-publish.yml` (package name `waxmard-git-ai`).
- Pre-commit hooks managed by [lefthook](https://github.com/evilmartians/lefthook) (`lefthook.yml`). Jobs run in parallel, file-scoped via `glob`: shell-lint (shellcheck), line-limit (`scripts/check-line-limit.sh` over the staged source files), bats (BATS tests), python (ruff format + ruff lint + `dmypy run` + pytest, serialized to avoid autofix/read races), and docs (`make docs-check`). `stage_fixed: true` auto-restages ruff-formatted files. Mypy uses `dmypy` (daemon) for warm-cache speed; `dmypy run` auto-starts the daemon. Install: `make hooks` (lefthook provided by mise).
- Tool versions pinned via [mise](https://mise.jdx.dev/) (`mise.toml`): node, uv, lefthook, shellcheck. Run `mise install` once after cloning; mise auto-activates the right versions on `cd`.
