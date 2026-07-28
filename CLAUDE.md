<!-- Generated from docs/src/CLAUDE.md by scripts/build_docs.py. Run `make docs-build` to regenerate. Do not edit directly. -->

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
- **`lib/ai-common.sh`** — **Umbrella** entry: holds core helpers (`die`, `_trim`, `strip_fences`, `.git-ai-ignore`/diff helpers, choice-state persistence) and sources `lib/{auth,discovery,config,provider}.sh`, so `source lib/ai-common.sh` still pulls the full helper surface (every test and `bin/git-ai` source only this file). Split for the per-file line limit.
- **`lib/setup.sh` + `lib/setup-edit.sh` + `lib/setup-vertex.sh` + `lib/setup-shadow.sh`** — The `git-ai setup` wizard: all `_setup_*` helpers (pickers, fast path, auth-assist, `maybe_first_run_setup` auto-launch, the flow drivers `_setup_fresh`/`_setup_manual`/`_setup_fast_path`/`_setup_edit_existing`). `setup.sh` is the umbrella and sources three siblings, split for the line limit: `setup-edit.sh` holds the config-overview + in-place edit actions (`_setup_action_*`, `_setup_change_models`, the vertex-projects actions, and their `_conf_apply`/`_merge_vertex_projects` helpers); `setup-vertex.sh` holds the Vertex AI side (`_setup_detect_vertex_project`, the multi-login `_setup_gcloud_projects`/`_setup_project_rows` discovery, `_setup_pick_projects`, `_setup_vertex_assist`); `setup-shadow.sh` holds the shadow-install detection (`_setup_check_shadow` + the `_setup_check_shadow_npm`/`_setup_check_shadow_pyx` package-manager probes). Sourced by `bin/git-ai`; calls into `lib/ai-common.sh`. The `cmd_setup` command entry itself stays in `bin/git-ai` as a thin dispatcher. `make install` symlinks every `lib/*.sh`.
- **Setup wizard** (`cmd_setup` in `bin/git-ai`, `_setup_*` helpers in `lib/setup.sh` + `lib/setup-edit.sh` + `lib/setup-vertex.sh` + `lib/setup-shadow.sh`) — branches on whether `options.conf` already exists.
  - **No config → `_setup_fresh`**: probes `provider_ready` over every provider to build the **ready set**, then takes one of two paths. **Fast path** (`_setup_fast_path`, when the ready set is non-empty and `GIT_AI_NO_SETUP_FAST` is unset): a zero-question flow that enables every ready provider with its `recommended_model` pin, seeds the per-repo default, and lands on the config overview to tweak or finish. **Manual** (`_setup_manual`, empty ready set or `GIT_AI_NO_SETUP_FAST=1`): a `provider_ready` status table, then fzf/numbered provider and per-provider model pickers — models **live-discovered** (see below), recommended ones headed "(recommended)", custom ids via a sentinel row — written with `render_options_conf` and a plain exit.
  - **Config exists → `_setup_edit_existing`**: a `_setup_print_summary` plus an in-place edit menu (add/remove provider, change models, change vertex projects, confirmed reset). Edits mutate **only the targeted section** via the surgical `conf_*` editors (`conf_add_section`, `conf_remove_section`, `conf_set_section_models`, `conf_set_section_setting`, …), so comments and vertex settings survive. Change-models and change-projects are **replace-style**: one multi-select over `current ∪ discovered` with the current entries **pre-marked** (`_setup_multiselect`'s `PRESELECT_QUERY` → fzf `--query` + `load:select-all+clear-query`), so the gesture is unmarking what to drop rather than re-marking everything to keep; the marked set replaces the pins (Esc/blank keeps current). Re-adding an already-configured `vertex` is treated as "attach another GCP project": it goes straight to the project picker and skips the model editor, since the shared vertex sections' models expand across every project in the list.
  - **Vertex AI is a single user-facing option** — the wizard hides the internal `vertex-gemini`/`vertex-anthropic` split, routing each picked model to its backend by id (`claude*` → anthropic, else gemini) and folding both sections back to one entry for choosers/summary. Vertex projects live in a shared `[vertex] projects =` list that `parse_user_options` expands into per-project `vertex-<x>@<project>` profiles. Project suggestions come from `_setup_gcloud_projects`, which sweeps **every** `gcloud auth list` login (capped at 5, active account first) rather than just the active one, and both project pickers carry a `=custom=` row so an id no login can list is still typeable. A login whose listing fails (expired/revoked/reauth-required) is named on stderr rather than swallowed — otherwise a dead credential is indistinguishable from an account with no projects.
  - **Auth-assist** (`_setup_ensure_auth`) prompts for API keys after selection and stores them to keychain (`store_api_key`) or shell rc (`persist_key_to_rc`); vertex gets `_setup_vertex_assist` (offers ADC login, prompts for `project`/`region`/`account`). Recommended ids are **data, not code** — `recommended-models.conf` (a packaged asset under `python/git_ai/`, resolved via `GIT_AI_PKG_DIR`; `family = model-id`), with `recommended_model()` mapping provider → family; suggestions-only, *not* a catalog.
  - Auto-launches from `cmd_commit`/`cmd_pr` via `maybe_first_run_setup` when nothing is configured and stdin/stdout are a tty (gated off by `CI` / `GIT_AI_NO_SETUP` / non-tty; the auto path only ever hits the fresh flow).
- **`run_provider()`** is the core dispatcher — takes a tool name (`commit` or `pr`) and prompt, handles stdin piping, temp file management, and error capture differently per provider.
- **Model discovery (`discover_models` in `lib/discovery.sh`)** — there is **no hardcoded model catalog**; lists are fetched live from each provider's own API so new models appear without a git-ai release. `discover_models PROVIDER [--refresh]` serves a disk cache (`$XDG_CONFIG_HOME/git-ai/models-cache/<provider>.list`, TTL via `GIT_AI_MODELS_TTL_MIN`, default 24h), else fetches+caches, else serves a stale cache on failure. Per-provider `_fetch_models_*` hit each API — Gemini, Anthropic, OpenAI (chat-filtered), and Vertex Model Garden (gcloud token, text-generation models only). The CLIs (`claude-code`/`codex`) have no list endpoint, and any provider whose creds aren't set up falls back to the **keyless `models.dev/api.json` catalog** — so authed API first, models.dev second, free-text always. Discovery is suggestions-only: `resolve_model` passes an explicit model through verbatim (the provider API is the real validator), defaulting to the tool's last saved pick, else the first discovered model. `list_options` treats a **present** `options.conf` as authoritative — only pinned entries are offered, an empty `[provider]` section hides that provider; live discovery feeds the picker **only** when no `options.conf` exists.
- **`python/git_ai/`** — Python package (provider-agnostic, BYO-LLM). Owns prompt assembly, diff-stat derivation, fence-stripping, and `.git/pr-cache` management; never calls an LLM itself, and carries zero LLM SDK dependencies. It also ships the pip-installable `git-ai` / `aigit` console scripts, which exec the wheel-bundled copy of the root Bash CLI. See the guide under `python/` for the package internals and the wheel-bundling contract.
- **`python/git_ai/prompts/*.txt`** — the prompts consumed at runtime: `commit.txt`, `pr-two-pass.txt`, `pr-two-pass-update.txt`, `pr-fallback.txt`, `pr-fallback-update.txt`. `bin/git-ai` reads them via `cat "${GIT_AI_PKG_DIR}/prompts/<name>.txt"`; the Python package loads them via `importlib.resources`. The four `pr-*.txt` files are **generated** — edit their templates under `prompts/src/`, not these files (see below); `commit.txt` is hand-written here (it shares no verbatim text with the PR prompts). The four PR prompts make the model wrap its answer in `===TITLE===` / `===BODY===` line markers; `parse_mr_response` (`_extract_pr_sections`) and the shell mirror `extract_pr_output` in `lib/ai-common.sh` slice the sections out, discarding any out-of-band preamble/reasoning the model emits before the title, and fall back to the raw fence-stripped text when the markers are absent. `commit.txt` gets the same treatment with a single `===COMMIT===` marker: `parse_commit_response` (`_extract_commit_message`) and the shell mirror `extract_commit_output` take everything after it, falling back to the first Conventional Commits subject line onward so a reasoning model's rationale can't become the subject.
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
- **Per-file line cap: 800** (hand-written shell + Python source). Enforced by `scripts/check-line-limit.sh` via the `line-limit` lefthook job and CI workflow; `make line-limit` runs it locally (override with `GIT_AI_LINE_LIMIT`). When a file approaches the cap, split it into focused modules — for shell, use the umbrella pattern (`lib/ai-common.sh` sources its siblings; `lib/setup.sh` sources `setup-edit.sh` + `setup-vertex.sh` + `setup-shadow.sh`) so the public source contract is unchanged.
- Run `shellcheck` before opening a PR.
- Python lint/format via ruff (rule set `E,F,I,B,UP,SIM,RUF,PL,S` in `pyproject.toml`), strict mypy. `S603`/`S607` are ignored repo-wide because every `subprocess` call is a trusted list-form `git` invocation.

## Test Coverage

Two suites run in CI on every push/PR: **BATS** (`test/bin/`, `test/lib/`) and **pytest** (`test/python/`). When adding a helper function, add a corresponding `.bats` file in `test/lib/` or `test/bin/`, or a `test_*.py` file in `test/python/`. See the guide under `test/` for what is deliberately left uncovered and why.

## Commits & Releases

- Conventional Commits required (`feat:`, `fix:`, `chore:`, etc.).
- Releases automated via release-please (config in `release-please-config.json`, version tracked in `package.json` and `pyproject.toml`).
- npm publish runs automatically on release tag push via `.github/workflows/npm-publish.yml`.
- PyPI publish runs automatically on release tag push via `.github/workflows/pypi-publish.yml` (package name `waxmard-git-ai`).
- Pre-commit hooks managed by [lefthook](https://github.com/evilmartians/lefthook) (`lefthook.yml`). Jobs run in parallel, file-scoped via `glob`: shell-lint (shellcheck), line-limit (`scripts/check-line-limit.sh` over the staged source files), bats (BATS tests), python (ruff format + ruff lint + `dmypy run` + pytest, serialized to avoid autofix/read races), and docs (`make docs-check`). `stage_fixed: true` auto-restages ruff-formatted files. Mypy uses `dmypy` (daemon) for warm-cache speed; `dmypy run` auto-starts the daemon. Install: `make hooks` (lefthook provided by mise).
- Tool versions pinned via [mise](https://mise.jdx.dev/) (`mise.toml`): node, uv, lefthook, shellcheck. Run `mise install` once after cloning; mise auto-activates the right versions on `cd`.
