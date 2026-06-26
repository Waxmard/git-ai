<!-- Generated from docs/src/CONTRIBUTING.md by scripts/build_docs.py. Run `make docs-build` to regenerate. Do not edit directly. -->

# Contributing to git-ai

Thanks for helping improve git-ai. This guide covers local setup, the dev loop, and how changes get reviewed and released. For the full architecture and module map, see [`CLAUDE.md`](CLAUDE.md) / [`AGENTS.md`](AGENTS.md).

## Prerequisites

Tool versions are pinned with [mise](https://mise.jdx.dev/) (`mise.toml`) — node, uv, lefthook, and shellcheck. After cloning:

```bash
mise install        # install the pinned toolchain (mise auto-activates on cd)
make install        # symlink git-ai/aigit into ~/.local/bin (edits are live) + install hooks
make sync           # uv sync — install Python dev deps
```

`make install` symlinks the scripts, so your edits to `bin/`, `lib/`, and `python/` take effect immediately — no reinstall between changes. If `which git-ai` doesn't resolve to `~/.local/bin/git-ai`, an older install is shadowing it on PATH; `make install` warns when it detects this, and `git-ai setup` offers to remove a stale `waxmard-git-ai` npm global.

## Development commands

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

## Project layout

- **`bin/git-ai`** — the CLI entry point; all command logic lives here as shell functions.
- **`bin/aigit`** — thin alias that execs `git-ai`.
- **`lib/ai-common.sh`** — shared shell helpers (provider dispatch, auth resolution, fence stripping).
- **`python/git_ai/`** — the provider-agnostic `waxmard-git-ai` Python package (prompt assembly, git helpers, PR cache). Zero LLM SDK dependencies. It also ships the pip-installable `git-ai` CLI: `_launcher.py` execs the bundled Bash, and the in-tree build backend (`_build_backend.py`) copies `bin/` + `lib/` into `git_ai/_sh/` at build time (so don't hand-edit `_sh/` — it's generated). See [`CLAUDE.md`](CLAUDE.md) for the full packaging flow.
- **`docs/src/`** — templates for the generated root docs. **Never edit `README.md`, `CLAUDE.md`, `AGENTS.md`, or `CONTRIBUTING.md` directly** — edit the template under `docs/src/` (shared prose lives in `docs/src/partials/`), then run `make docs-build`.
- **`test/bin/`, `test/lib/`** — BATS tests. **`test/python/`** — pytest.

See [`CLAUDE.md`](CLAUDE.md) for the full architecture, the setup-wizard internals, PR caching, and the branch-aware commit-prefix logic.

## Making a change

1. **Branch off `dev`** (the default branch). PRs target `dev`; `main` is release-only.
2. **Write code that matches the surrounding style** — `#!/bin/bash`, POSIX-leaning Bash, two-space indent, `snake_case` functions, `UPPERCASE` constants, fail-fast (`die`, `set -o pipefail`). Python is ruff-formatted with strict mypy.
3. **Add tests.** New shell helpers get a `.bats` file in `test/bin/` or `test/lib/`; new Python gets a `test_*.py` in `test/python/`. Functions that need a live provider or real LLM call are intentionally left uncovered — see the Test Coverage section in `CLAUDE.md`.
4. **Update docs if behavior changed** — edit the relevant `docs/src/` template and run `make docs-build`.
5. **Run the full local gate** (mirrors CI):

   ```bash
   bash -n bin/git-ai bin/aigit lib/ai-common.sh   # shell syntax
   shellcheck -x lib/*.sh && shellcheck -x bin/*   # shell lint
   npm test                                         # BATS
   uv run pytest                                    # pytest
   make py-lint && make py-type-check               # ruff + mypy
   make docs-check                                  # generated docs not stale
   ```

   Most of this also runs automatically as a pre-commit hook via [lefthook](https://github.com/evilmartians/lefthook) (installed by `make install` / `make hooks`).

## Commits & pull requests

- **Conventional Commits are required** (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `perf:`, `test:`, …). Releases are automated by release-please, which derives the version and changelog from commit types — a non-conforming message breaks the release.
- Open PRs against `dev`, not `main`. Keep each PR focused; a green CI run is expected before review.
- CI runs three workflows on every push and PR: shellcheck + BATS (`test.yml`), ruff + mypy + pytest (`python.yml`), and a security scan (semgrep + trivy). A docs workflow blocks stale generated docs.

## Releases

Releases are fully automated — **you do not tag or publish manually.** Day-to-day work merges into `dev`. When `dev` is promoted to `main`, release-please (which targets `main`) opens a release PR derived from the conventional commits; merging that PR tags the version, and the npm (`@waxmard/git-ai`) and PyPI (`waxmard-git-ai`) packages publish automatically on the tag.
