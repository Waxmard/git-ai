# git-ai

LLM-powered git workflow tools. Generate commit messages and PR titles using Claude, Gemini, or Codex from the CLI, Lazygit, and other git environments that expose normal Git state.

## Prerequisites

At least one provider must be available:

| Provider | CLI | Auth |
|----------|-----|------|
| `claude` | [Claude Code CLI](https://claude.ai/code) — run `claude login` | Claude Code CLI session, or `ANTHROPIC_API_KEY` |
| `gemini` | [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `GEMINI_API_KEY`, system keychain, or Google ADC |
| `codex`  | [Codex CLI](https://github.com/openai/codex) — run `codex login` | Codex CLI session, or `OPENAI_API_KEY` |

`ANTHROPIC_API_KEY` and `OPENAI_API_KEY` modes require `curl` and `python3`, both standard on macOS and most Linux systems.

### Gemini auth

git-ai tries these in order until one succeeds:

1. `GEMINI_API_KEY` environment variable
2. System keychain — store the key as `gemini-api-key`:
   - **macOS:** `security add-generic-password -s gemini-api-key -a "$USER" -w YOUR_KEY`
   - **GNOME / libsecret:** `secret-tool store --label="Gemini API Key" service gemini-api-key`
   - **pass:** `pass insert gemini-api-key`
   - **KDE Wallet:** `kwallet-query kdewallet -w gemini-api-key`
3. Google Application Default Credentials (ADC):
   - `gcloud auth application-default login`
   - or set `GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json`

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
- Default provider: `gemini`
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
- Default provider: `gemini`
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
| `claude` | `haiku` | claude-haiku-4-5-20251001 | Claude Code CLI login, or `ANTHROPIC_API_KEY` |
| `claude` | `sonnet` | claude-sonnet-4-6 | Claude Code CLI login, or `ANTHROPIC_API_KEY` |
| `claude` | `opus` | claude-opus-4-6 | Claude Code CLI login, or `ANTHROPIC_API_KEY` |
| `gemini` | `flash-lite` | gemini-3.1-flash-lite-preview | `GEMINI_API_KEY`, system keychain, or Google ADC |
| `gemini` | `pro` | gemini-3.1-pro-preview | `GEMINI_API_KEY`, system keychain, or Google ADC |
| `codex` | `mini` | gpt-5.4-mini | Codex CLI login, or `OPENAI_API_KEY` |
| `codex` | `standard` | gpt-5.4 | Codex CLI login, or `OPENAI_API_KEY` |

Last-used provider and tier are saved per repo (stored in `.git/`), so repeated runs remember your selection.
