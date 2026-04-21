# Repository Guidelines

## Project Structure & Module Organization
`bin/` contains the user-facing CLI entry points: `git-ai` (main dispatcher) and `aigit` (thin alias wrapper). Shared shell helpers live in `lib/ai-common.sh`. The companion Python package lives in `python/git_ai/`, with prompts in `python/git_ai/prompts/*.txt` (single source of truth — also read by `bin/git-ai`). Repository-level docs and release metadata are in `README.md`, `Makefile`, `release-please-config.json`, `package.json`, `pyproject.toml`, `uv.lock`, and `.github/workflows/`.

`git-ai` dispatches on its first argument (`commit`, `pr`/`mr`, `providers`, `models`). Keep command-specific logic in `bin/git-ai` and reusable provider, auth, or formatting helpers in `lib/`. Tests live in `test/`: BATS suites under `test/bin/` and `test/lib/`, pytest modules under `test/python/`.

## Build, Test, and Development Commands
Use `make install` to symlink the tools into `~/.local/bin` and `~/.local/lib` for live local development. Use `make uninstall` to remove those symlinks.

Helpful checks:

- `bash -n bin/git-ai bin/aigit lib/ai-common.sh` checks shell syntax.
- `shellcheck bin/git-ai bin/aigit lib/ai-common.sh` matches the CI lint job in `.github/workflows/shellcheck.yml`.
- `git-ai commit claude` runs the staged-diff commit generator after `git add`.
- `git-ai pr codex --base main` generates PR text against a chosen base branch.

## Coding Style & Naming Conventions
Write POSIX-leaning Bash with `#!/bin/bash` where current scripts already depend on Bash features. Use two-space indentation inside functions and control flow blocks. Prefer lowercase snake_case for function names like `load_gemini_env`; use uppercase variable names for exported config and prompt constants like `PROVIDER` and `PROMPT`.

Fail fast with explicit checks such as `die "message"` and `set -o pipefail`. Keep helpers small and composable. Run `shellcheck` before opening a PR.

## Testing Guidelines
Every change should include:

- Syntax validation with `bash -n`
- Linting with `shellcheck` (and `make py-lint` if Python files changed)
- `make test` (BATS) and `make py-test` (pytest) — both run in CI and via the parallelized `hooks/pre-commit`
- `make py-type-check` when touching `python/git_ai/`
- `uv run pre-commit run --all-files` matches what CI executes
- A manual smoke test of the affected CLI path in a git repo with staged changes or a topic branch

## Commit & Pull Request Guidelines
Follow Conventional Commits. The existing history uses prefixes like `feat:` and the generators themselves enforce that format. Keep commit subjects imperative and concise.

PRs should include a short description, the commands used for verification, and example CLI output when behavior changes. If a change affects release flow, mention any impact on `release-please` or versioning files.
