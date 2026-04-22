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
git-ai pr [auth-method] [model-id] [--base <branch>] [--fresh] [--from-sha <commit>]
git-ai mr [...]   # alias for pr
```

- Reads the commit log and diff against the base branch
- Produces a Conventional Commits title + markdown body with a `### Test Plan` section
- Auto-detects the base branch from the remote default (falls back to `main`)
- Use `--base` to override (e.g. `--base dev`)
- Saves the generated output per current-branch/base-branch pair under `.git/pr-cache/`; subsequent runs with the same pair refine the previous result automatically
- Use `--fresh` to ignore the saved output and regenerate from scratch
- Use `--from-sha` to override the saved HEAD and regenerate only from commits after a specific prior generated commit
- No default auth method on a fresh repo; choose one explicitly
- Non-`vertex` auth methods default to a stronger model when `model-id` is omitted
- `vertex` always requires an explicit model ID

### options

List every auth-method / model combo as a flat pipe-delimited list, LRU-sorted. Primary input for the fzf-based Lazygit integration; also useful for custom pickers.

```bash
git-ai options [commit|pr]
```

- Emits one `provider:model|<label>` line per selectable combo
- For `commit`, also emits `last|reuse saved message` when a saved message exists
- Most-recent picks (from `.git/{tool}-choice-history`) float to the top; remaining combos follow in default order
- `git-ai commit <provider:model>` and `git-ai pr <provider:model>` accept the emitted value directly

### providers / models

List available auth methods and models, ordered by last-used. Kept for scripting and as a fallback when `options` isn't a fit.

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

## Narrowing the picker list

By default `git-ai options` enumerates every supported provider/model combo. Most users only have access to a couple. To restrict the picker to just the providers and models you actually use, drop a config file at `$XDG_CONFIG_HOME/git-ai/options.conf` (usually `~/.config/git-ai/options.conf`):

```ini
[claude-code]
claude-haiku-4-5-20251001
claude-sonnet-4-6

[codex]
gpt-5.4-mini

# Empty section hides this provider entirely
[vertex]
```

- `[provider]` headers must be one of: `vertex`, `gemini-api`, `claude-code`, `anthropic-api`, `codex`, `openai-api`. Unknown headers are silently dropped.
- Model IDs under a header are passed through to the provider verbatim, so you can list future model IDs (e.g. a newly released `claude-sonnet-5-0`) without waiting for a git-ai release.
- Delete the file to restore the full shipped catalog.
- See [`examples/options.conf`](examples/options.conf) for a starter.

## Terminal picker

Running `git-ai commit` or `git-ai pr` without a provider argument launches an inline [fzf](https://github.com/junegunn/fzf) picker over the same provider/model combos Lazygit uses. History entries float to the top. Pass `provider` or `provider:model` to skip the picker. Flags still parse, so `git-ai pr --base staging` opens the picker then runs against the chosen base.

Set `GIT_AI_NO_FZF=1` (or pipe stdout) to disable the picker for scripting. If fzf isn't installed, the tools fall back to the last saved choice.

## Lazygit integration

Requires [fzf](https://github.com/junegunn/fzf) on your PATH. Add the following under `customCommands:` in `~/.config/lazygit/config.yml`:

```yaml
customCommands:
  - key: "<c-g>"
    description: "AI commit message (git-ai + fzf)"
    context: "files"
    command: |
      choice=$(git-ai options commit | fzf --delimiter='|' --with-nth=2 --no-sort --tiebreak=index --prompt='git-ai> ') || exit 0
      git commit -m "$(git-ai commit "${choice%%|*}")" --edit
    output: terminal
```

Pressing `<c-g>` in the files panel opens an fzf picker showing every auth+model combo (plus `reuse saved message` when available). Typeahead narrows instantly; Enter commits with the generated message. Selections float to the top of the list on subsequent invocations.

## Python library

git-ai is also distributed as a Python package (`waxmard-git-ai`) so other tools can reuse the same commit-message and MR-description generation without shelling out. Gemini only.

```bash
pip install waxmard-git-ai
# or: uv add waxmard-git-ai
```

`generate_mr_description` handles both styles through one entry point and returns an `MrDescription(text, diff)` — `text` is the full PR, `diff` is a marker-style rendering of what changed vs. `existing_pr` (or `None` when there's no prior PR or the output matches it).

**Repo-mode** (reads staged diff / base..HEAD from a local checkout):

```python
from git_ai import generate_commit_message, generate_mr_description

msg = generate_commit_message(".")
pr = generate_mr_description(".", base_branch="main")
pr = generate_mr_description(".", base_branch="main", fresh=True)
pr = generate_mr_description(
    ".",
    base_branch="main",
    existing_pr=existing_pr_text,
    previous_head_sha=last_generated_head_sha,
)
print(pr.text)       # full PR (title line + body)
print(pr.diff or "") # marker-style delta vs existing_pr, if any
```

**Data-mode** (no local checkout required — pass raw diff strings, e.g. fetched from the GitHub/GitLab API):

```python
from git_ai import (
    create_gemini_client,
    format_commit_log,
    generate_commit_message_from_diff,
    generate_mr_description,
)

client = create_gemini_client()

commit_msg = generate_commit_message_from_diff(diff_text, client=client)

log = format_commit_log((c.title, c.message) for c in mr_commits)
pr = generate_mr_description(
    diff=diff_text,
    commit_log=log,
    existing_pr=current_pr_body or None,
    client=client,
)
# pr.text -> full updated PR to post as title + description
# pr.diff -> compact "what changed since last PR" markers, or None
```

`diff_stat` and `release_context` are optional — when omitted, the diff-stat is derived from the diff and a generic "no release tags found" context is used. Pass `model=` to override the default Gemini model (`COMMIT_MODEL` / `MR_MODEL`).

Repo-mode uses the same incremental PR efficiency path as the CLI: it reuses `.git/pr-cache/` automatically, returns the cached PR unchanged when `HEAD` has not advanced, and narrows generation to commits after the last generated `HEAD` when possible. Pass `fresh=True` to disable that behavior for one call, or `previous_head_sha=` to override the cached incremental base explicitly.

Data-mode is stateless by design. To get the same efficiency in remote consumers, persist the prior PR text and prior generated head SHA yourself, fetch only the incremental diff/log since that SHA from your SCM, then call `generate_mr_description(diff=..., existing_pr=...)`.

## Compatibility

git-ai does not depend on a specific terminal UI. It works in the CLI, in Lazygit, and in similar git environments as long as Git exposes the required repository state:

- `git-ai commit` needs staged changes (`git diff --staged`)
- `git-ai pr` needs commits and diff data relative to a base branch
