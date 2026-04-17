# git-ai

LLM-powered git workflow tools. Generate commit messages and PR titles using explicit auth methods and model IDs from the CLI, Lazygit, and other git environments that expose normal Git state.

## Install

```bash
npm install -g @waxmard/git-ai
```

Or clone and symlink for local development:

```bash
make install   # symlinks to ~/.local/bin and ~/.local/lib; edits are live
make uninstall
```

## Prerequisites

At least one auth method must be available:

| Auth Method | Runtime | Auth |
|-------------|---------|------|
| `vertex` | [Gemini CLI](https://github.com/google-gemini/gemini-cli) | Google ADC / Vertex credentials |
| `gemini-api` | [Gemini CLI](https://github.com/google-gemini/gemini-cli) | `GEMINI_API_KEY` or system keychain |
| `claude-code` | [Claude Code CLI](https://claude.ai/code) | Claude Code CLI session |
| `anthropic-api` | `curl` + `python3` | `ANTHROPIC_API_KEY` |
| `codex` | [Codex CLI](https://github.com/openai/codex) | Codex CLI session |
| `openai-api` | `curl` + `python3` | `OPENAI_API_KEY` |

`anthropic-api` and `openai-api` require `curl` and `python3`, both standard on macOS and most Linux systems.

### Gemini API auth

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

## Commands

Both `git-ai` and `aigit` work identically — use whichever you prefer.

### commit

Generate a commit message from staged changes.

```bash
git-ai commit [auth-method] [model-id]
```

- Reads `git diff --staged` and produces a Conventional Commits message
- Includes a description body for non-trivial changes
- No default auth method on a fresh repo; choose one explicitly
- Non-`vertex` auth methods default to a lightweight model when `model-id` is omitted
- `vertex` always requires an explicit model ID
- Pass `last` as the provider to reuse the previously generated message

### pr

Generate a PR title and body from the current branch.

```bash
git-ai pr [auth-method] [model-id] [--base <branch>] [--fresh]
git-ai mr [...]   # alias for pr
```

- Reads the commit log and diff against the base branch
- Produces a Conventional Commits title + markdown body with a `### Test Plan` section
- Auto-detects the base branch from the remote default (falls back to `main`)
- Use `--base` to override (e.g. `--base dev`)
- Saves the generated output per current-branch/base-branch pair under `.git/pr-cache/`; subsequent runs with the same pair refine the previous result automatically
- Use `--fresh` to ignore the saved output and regenerate from scratch
- No default auth method on a fresh repo; choose one explicitly
- Non-`vertex` auth methods default to a stronger model when `model-id` is omitted
- `vertex` always requires an explicit model ID

### providers / models

List available auth methods and models, ordered by last-used. Primarily for Lazygit integration.

`last` is only a commit provider option; PR refinement reuses cached prior output automatically.

```bash
git-ai providers [commit|pr]
git-ai models <auth-method> [commit|pr]
```

## Auth Methods And Models

| Auth Method | Models |
|-------------|--------|
| `vertex` | `gemini-3.1-flash-lite-preview`, `gemini-3.1-pro-preview`, `claude-haiku-4-5-20251001`, `claude-sonnet-4-6`, `claude-opus-4-6`, `gpt-5.4-mini`, `gpt-5.4` |
| `gemini-api` | `gemini-3.1-flash-lite-preview`, `gemini-3.1-pro-preview` |
| `claude-code` | `claude-haiku-4-5-20251001`, `claude-sonnet-4-6`, `claude-opus-4-6` |
| `anthropic-api` | `claude-haiku-4-5-20251001`, `claude-sonnet-4-6`, `claude-opus-4-6` |
| `codex` | `gpt-5.4-mini`, `gpt-5.4` |
| `openai-api` | `gpt-5.4-mini`, `gpt-5.4` |

Last-used auth method and model are saved per repo in `.git/`, so repeated runs remember your selection.

## Lazygit integration

Add to `~/.config/lazygit/config.yml`:

```yaml
customCommands:
  - key: "<c-g>"
    description: "AI commit message"
    command: 'git commit -m "$(git-ai commit {{.Form.Provider}} {{.Form.Model}})" --edit'
    context: "files"
    prompts:
      - type: "menuFromCommand"
        title: "Select Auth Method"
        key: "Provider"
        command: "git-ai providers commit"
        filter: '(?P<value>[^|]+)\|(?P<label>.+)'
        valueFormat: '{{ .value }}'
        labelFormat: '{{ .label }}'
      - type: "menuFromCommand"
        title: "Select Model"
        key: "Model"
        command: "git-ai models {{.Form.Provider}} commit"
        filter: '(?P<value>[^|]+)\|(?P<label>.+)'
        valueFormat: '{{ .value }}'
        labelFormat: '{{ .label }}'
    output: terminal
```

## Python library

git-ai is also distributed as a Python package (`waxmard-git-ai`) so other tools can reuse the same commit-message and MR-description generation without shelling out. Gemini only.

```bash
pip install waxmard-git-ai
# or: uv add waxmard-git-ai
```

**Repo-mode** (reads staged diff / base..HEAD from a local checkout):

```python
from git_ai import generate_commit_message, generate_mr_description

msg = generate_commit_message(".")
pr = generate_mr_description(".", base_branch="main")
```

**Data-mode** (no local checkout required — pass raw diff strings, e.g. fetched from the GitHub/GitLab API):

```python
from git_ai import (
    create_gemini_client,
    format_commit_log,
    generate_commit_message_from_diff,
    generate_mr_description_from_data,
)

client = create_gemini_client()

commit_msg = generate_commit_message_from_diff(diff_text, client=client)

log = format_commit_log((c.title, c.message) for c in mr_commits)
pr_text = generate_mr_description_from_data(
    diff=diff_text,
    commit_log=log,
    existing_pr=current_pr_body or None,
    client=client,
)
```

`diff_stat` and `release_context` are optional — when omitted, the diff-stat is derived from the diff and a generic "no release tags found" context is used. Pass `model=` to override the default Gemini model (`COMMIT_MODEL` / `MR_MODEL`).

## Compatibility

git-ai does not depend on a specific terminal UI. It works in the CLI, in Lazygit, and in similar git environments as long as Git exposes the required repository state:

- `git-ai commit` needs staged changes (`git diff --staged`)
- `git-ai pr` needs commits and diff data relative to a base branch
