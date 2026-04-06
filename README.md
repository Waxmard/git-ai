# git-ai

LLM-powered git workflow tools. Generate commit messages and PR titles using Claude, Gemini, or Codex from the CLI, Lazygit, and other git environments that expose normal Git state.

## Install

```bash
make install
```

This creates symlinks in `~/.local/bin` and `~/.local/lib`. Edits to the repo are live immediately.

To uninstall:

```bash
make uninstall
```

## Commands

### ai-commit-gen

Generate a commit message from staged changes.

```bash
ai-commit-gen [claude|gemini|codex] [tier]
```

- Reads `git diff --staged` and produces a Conventional Commits message
- Includes a description body for non-trivial changes
- Default provider: `claude`
- Default tiers: `haiku`, `flash-lite`, `mini` (lightweight models for speed)
- Works anywhere you can stage changes, including Lazygit and similar git UIs

### ai-pr-title

Generate a PR title and body from the current branch.

```bash
ai-pr-title [claude|gemini|codex] [tier] [--base <branch>]
```

- Reads both the commit log and diff against the base branch
- Produces a Conventional Commits title + markdown body
- Auto-detects the base branch from the remote default (falls back to `main`)
- Use `--base` to override (e.g. `--base dev`)
- Default provider: `claude`
- Default tiers: `opus`, `pro`, `standard` (more capable models for richer output)
- Works from any git environment where the current branch is ahead of the base branch

### ai-provider-menu

List providers ordered by last-used, for Lazygit custom menu integration.

```bash
ai-provider-menu <tool-name>
```

### ai-tier-menu

List model tiers ordered by last-used, for Lazygit custom menu integration.

```bash
ai-tier-menu <provider> [tool-name]
```

## Compatibility

These tools do not depend on a specific terminal UI. They work in the CLI, in Lazygit, and in similar git environments as long as Git exposes the required repository state:

- `ai-commit-gen` needs staged changes from `git diff --staged`
- `ai-pr-title` needs commits and diff data relative to a base branch

## Providers

| Provider | Tier | Model | Auth |
|----------|------|-------|------|
| `claude` | `haiku` | claude-haiku-4-5-20251001 | Claude Code CLI login |
| `claude` | `sonnet` | claude-sonnet-4-6 | Claude Code CLI login |
| `claude` | `opus` | claude-opus-4-6 | Claude Code CLI login |
| `gemini` | `flash-lite` | gemini-3.1-flash-lite-preview | `GEMINI_API_KEY` env var or macOS Keychain |
| `gemini` | `pro` | gemini-3.1-pro-preview | `GEMINI_API_KEY` env var or macOS Keychain |
| `codex` | `mini` | gpt-5.4-mini | Codex CLI login |
| `codex` | `standard` | gpt-5.4 | Codex CLI login |

Last-used provider and tier are saved per repo (stored in `.git/`), so repeated runs remember your selection.
