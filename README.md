# git-ai

LLM-powered git workflow tools. Generate commit messages and PR titles using Claude, Gemini, or Codex.

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
ai-commit-gen [claude|gemini|codex]
```

- Reads `git diff --staged` and produces a Conventional Commits message
- Includes a description body for non-trivial changes
- Default provider: `claude`

### ai-pr-title

Generate a PR title and body from the current branch.

```bash
ai-pr-title [claude|gemini|codex] [--base <branch>]
```

- Reads both the commit log and diff against the base branch
- Produces a Conventional Commits title + markdown body
- Auto-detects the base branch from the remote default (falls back to `main`)
- Use `--base` to override (e.g. `--base dev`)
- Default provider: `claude`

## Providers

| Provider | Model | Auth |
|----------|-------|------|
| `claude` | claude-haiku-4-5-20251001 | Claude Code CLI login |
| `gemini` | gemini-3.1-flash-lite-preview | `GEMINI_API_KEY` env var or macOS Keychain |
| `codex` | gpt-5.4-mini | Codex CLI login |
