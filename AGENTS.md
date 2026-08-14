# AGENTS.md

Guidance for AI coding agents working in this repository. The detail lives beside the code: **`lib/AGENTS.md`** (Bash internals — providers, discovery, config, setup wizard), **`python/AGENTS.md`** (package internals, response formatting, PR caching), **`test/AGENTS.md`** (suites and deliberate gaps).

## Overview

git-ai generates commit messages and PR titles/bodies (`git-ai commit`, `git-ai pr`) using whichever LLM provider you configure, via its CLI or API. The Bash CLI needs nothing at runtime beyond system binaries, `python3`, and provider CLIs.

Python backs response formatting, model discovery, and every provider API call. Invoke it as `"${GIT_AI_PYTHON:-python3}"`, never bare `python3` — `require_python` accepts that override, so a bare call breaks setups where `python3` is not on `PATH`.

## Commands

```bash
make install        # Symlink tools to ~/.local/bin and ~/.local/lib (edits are live)
make hooks          # Install git hooks via lefthook (also run by make install)
make lint           # shellcheck all scripts
make test           # BATS unit tests
make line-limit     # Per-file line cap (override with GIT_AI_LINE_LIMIT)
make prompts-build  # Regenerate the pr-*.txt prompts; prompts-check is the CI gate

# Python package (uv-managed)
make sync py-lint py-format py-type-check py-test

# Validation (matches CI)
bash -n bin/git-ai bin/aigit lib/ai-common.sh
shellcheck -x lib/*.sh && shellcheck -x bin/*
npm test && uv run pytest

# Smoke tests (need a real provider CLI or API key)
git-ai commit gemini-api
git-ai pr codex --base main [--fresh]
```

## Layout

| Path | Owns |
|---|---|
| `bin/git-ai` | Single entry point. Dispatches `commit`, `pr`/`mr`, `setup`, `providers`, `models`, `options`; holds the `cmd_*` command logic. |
| `lib/ai-common.sh` | Umbrella: core helpers (`die`, `_trim`, `require_python`, diff/ignore helpers, choice-state persistence) plus `source`s `lib/{auth,discovery,config,provider}.sh`. |
| `lib/setup*.sh` | The `git-ai setup` wizard. `setup.sh` is an umbrella over `setup-edit`/`-auth`/`-vertex`/`-shadow`. |
| `python/git_ai/` | Prompt assembly, response parsing/formatting, `.git/pr-cache`, `.git-ai-ignore`. Also ships the pip-installable console scripts. |
| `python/git_ai/prompts/*.txt` | Runtime prompts. The six `pr-*.txt` are generated from `prompts/src/`. |
| `prompts/src/`, `scripts/` | Prompt templates + the build/check and line-limit gates. |

Keep command logic in `bin/git-ai` and reusable helpers in `lib/`. Everything loads through the `lib/ai-common.sh` umbrella — tests and `bin/git-ai` source only that file, so a new helper file must be sourced from an umbrella, not imported directly.

## Contracts that bite from anywhere

- **`GIT_AI_PKG_DIR`** resolves every packaged asset (prompts, the `_*_cli.py` bridges, `recommended-models.conf`). Default is the repo-layout sibling `python/git_ai`; the pip launcher repoints it at the installed package, so never hardcode a path to one of those assets.
- **npm ships the Python modules.** `package.json`'s `files` whitelist must keep `python/git_ai/*.py`: the Bash CLI shells out to `_commit_cli.py` / `_pr_repo_cli.py` / `_pr_render.py`, and npm has no pip step to supply them. For the same reason `dependencies = []` in `pyproject.toml` is a hard contract — npm installs nothing from PyPI, so any module the Bash path imports must be stdlib-only. The `npm-pack` CI job packs the tarball and drives the bridges from it.
- **Per-file line cap: 800** for hand-written shell and Python, enforced by `scripts/check-line-limit.sh` in lefthook and CI. When a file nears the cap, split it into focused modules using the umbrella pattern so the public source contract is unchanged.
- **Prompts are generated.** Edit the templates under `prompts/src/`, then `make prompts-build`; hand-editing `python/git_ai/prompts/pr-*.txt` is reverted by the staleness gate. `commit.txt` is the exception — standalone and edited directly.
- **There is no model catalog.** Lists are discovered live from each provider; `recommended-models.conf` holds one default per family, not a catalog. Never hardcode model ids in code.
- **`AGENTS.md` is the real file** at each level (root, `lib/`, `python/`, `test/`); the `CLAUDE.md` beside it is a symlink. Edit `AGENTS.md`.
- Context payloads are wrapped in XML-style tags (`<release_context>`, `<branch>`, `<branch_commits>`, `<branch_diffstat>`, `<diff>`, `<commit_log>`, `<existing_pr>`) so the model can tell sections apart.

## Coding conventions

- `#!/bin/bash`, POSIX-leaning Bash, two-space indent. `snake_case` functions, `UPPERCASE` constants.
- Fail fast: `die "message"`, `set -o pipefail`. Run `shellcheck` before opening a PR.
- Python: ruff (`E,F,I,B,UP,SIM,RUF,PL,S`) and strict mypy. `S603`/`S607` are ignored repo-wide because every `subprocess` call is a trusted list-form `git` invocation.

## Test coverage

**BATS** (`test/bin/`, `test/lib/`) and **pytest** (`test/python/`) both run in CI on every push and PR. Add a `.bats` or `test_*.py` file alongside any new helper. A test that fails after your change is usually encoding a deliberate invariant — find the rationale in the relevant guide before editing the assertion.

## Commits & releases

- Conventional Commits required (`feat:`, `fix:`, `chore:`, …).
- release-please automates releases (`release-please-config.json`; version in `package.json` + `pyproject.toml`). npm and PyPI (`waxmard-git-ai`) publish on release tag push.
- lefthook (`lefthook.yml`) runs shell-lint, line-limit, BATS, python (ruff + `dmypy` + pytest, serialized to avoid autofix/read races), and prompts. `stage_fixed: true` re-stages ruff-formatted files. Install with `make hooks`.
- Tool versions pinned via mise (`mise.toml`): node, uv, lefthook, shellcheck. Run `mise install` once after cloning.
