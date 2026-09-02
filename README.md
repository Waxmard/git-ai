# git-ai

LLM-powered git workflow tools. Generate Conventional Commits messages and PR descriptions from your staged changes and branch — in the CLI, Lazygit, or any git environment.

## Install

```bash
npm install -g @waxmard/git-ai
```

Or via pip / uv — the `waxmard-git-ai` package ships the same `git-ai` CLI **and** the importable [Python library](#python-library):

```bash
pip install waxmard-git-ai     # or: uv tool install waxmard-git-ai
```

The pip CLI runs the bundled Bash program, so it needs `bash` on your `PATH` (already present on macOS/Linux) plus your provider's CLI or API key — same runtime as the npm install.

Or clone and symlink for local development (edits are live):

```bash
make install   # symlinks to ~/.local/bin and ~/.local/lib
make uninstall
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full dev setup, test commands, and PR/release process.

## Quickstart

Run the setup wizard once — it detects your installed provider CLIs and keys, helps you authenticate, and writes your config:

```bash
git-ai setup
```

If you already have a provider CLI installed or a key in your environment, the wizard does the work for you: it enables every provider you can use right now, pins a sensible recommended model for each, and drops you on a summary of the resulting config — a single `Enter` finishes, or pick an action there to tweak it (add/remove providers, change models, reset and re-detect). No provider/model picking required. Set `GIT_AI_NO_SETUP_FAST=1` to skip straight to the full manual picker.

The first time you run `git-ai commit` or `git-ai pr` with nothing configured, the wizard launches automatically (skip with `GIT_AI_NO_SETUP=1`). Then generate:

```bash
git add -A
git-ai commit                         # prints a Conventional Commits message to stdout
git commit -m "$(git-ai commit)"      # …or commit with it in one line

git-ai pr --base main                 # PR title + body for the current branch
```

With no auth method on the command line, git-ai uses your configured default or pops an interactive [fzf](https://github.com/junegunn/fzf) picker. You can still pass one explicitly — `git-ai commit gemini-api`. Both `git-ai` and `aigit` are interchangeable.

## Auth methods

`git-ai setup` is the way in — it shows which of these are ready, authenticates you, and writes the config. The table is a reference for what exists; you don't configure any of it by hand unless you want to (see [Manual configuration](#manual-configuration-advanced)).

git-ai needs at least one of these. `gemini-api` and the two Vertex methods are the common choices; the rest are available if you already use that provider's CLI or API.

| Auth Method | Runtime | Credentials |
|-------------|---------|-------------|
| `gemini-api` | `curl` + `python3` | `GEMINI_API_KEY` or system keychain |
| `antigravity` | [Antigravity CLI](https://antigravity.google) (`agy`) | Antigravity CLI session |
| `vertex-gemini` | `curl` + `python3` + `gcloud` | Google ADC / Vertex credentials |
| `vertex-anthropic` | `curl` + `python3` + `gcloud` | Google ADC / Vertex credentials |
| `claude-code` | [Claude Code CLI](https://claude.ai/code) | Claude Code CLI session |
| `codex` | [Codex CLI](https://github.com/openai/codex) | Codex CLI session |
| `anthropic-api` | `curl` + `python3` | `ANTHROPIC_API_KEY` |
| `openai-api` | `curl` + `python3` | `OPENAI_API_KEY` |

`curl` and `python3` are standard on macOS and most Linux systems.

> **Vertex AI support covers only the Gemini (`vertex-gemini`) and Anthropic (`vertex-anthropic`) model families.** Other Vertex publishers (Meta Llama, Mistral, etc.) are not yet supported. To pin a GCP account or run multiple projects, see [Pinning a GCP account (Vertex)](#pinning-a-gcp-account-vertex).

> **`antigravity` runs on the Google account you sign into `agy` with**, not an API key — run `agy` once interactively so the login is cached, since a headless run cannot authenticate on its own. Its model ids pin reasoning effort in the id itself (`gemini-3.7-flash-medium`), and `agy models` is where git-ai discovers them.

For API-key providers (`gemini-api`, `anthropic-api`, `openai-api`), `git-ai setup` prompts for the key and stores it in your OS keychain or shell rc. For Google ADC / service-account credentials, use a `vertex-gemini` or `vertex-anthropic` method and let setup run `gcloud auth application-default login`. To wire any of this up by hand instead, see [Manual configuration](#manual-configuration-advanced).

## Commands

### setup

Interactive wizard to configure providers and authentication.

```bash
git-ai setup
```

- **First run** (no config yet): enables every provider that already authenticates, pins each one's recommended model, and drops you on the config overview — a bare `Enter` finishes. For Vertex AI it also picks your GCP project automatically (your active gcloud project if it has the Vertex API enabled, else the first of your projects that does). When nothing is ready (or `GIT_AI_NO_SETUP_FAST=1` is set), falls back to a readiness table and a manual provider/model picker (each family's recommended model leads the list) that exits when done — re-run `git-ai setup` anytime to make changes
- **Later runs** (config exists): opens the overview with an edit menu — add a provider, remove one, change a provider's models, change Vertex AI projects, or **reset** (re-detect and start over) — applied **in place**, one change at a time, preserving everything else in the file (comments, vertex `account=`/`projects=` settings). Only a confirmed reset rewrites the file wholesale. The models and projects edits are both replace-style multi-selects: your current entries open **already marked**, and the set you leave marked replaces the old one — so you unmark what you want dropped and Tab in what you want added, in a single pass (`Esc` or a blank entry keeps things as they are). Re-adding Vertex AI when it's already configured jumps straight to the project picker and keeps your pinned models, which apply to every project in the list
- Shows a single **Vertex AI** entry; whether a model runs via `vertex-gemini` or `vertex-anthropic` is inferred from the model id, never asked
- For API-key providers, prompts for the key and offers to store it in your OS keychain or shell rc
- For Vertex AI, offers to run `gcloud auth application-default login` and prompts for `project` (required) / `region` / `account`, written to the shared `[vertex]` block. Profiles and `credentials=` stay manual — see [Pinning a GCP account (Vertex)](#pinning-a-gcp-account-vertex)
- Seeds the per-repo default so the next `commit`/`pr` runs without prompting
- Runs automatically on first use when nothing is configured; set `GIT_AI_NO_SETUP=1` to disable that

### commit

Generate a commit message from staged changes.

```bash
git-ai commit [auth-method] [model-id]
```

- Reads `git diff --staged` and produces a Conventional Commits message
- Includes a description body for non-trivial changes
- Uses your configured default (from `git-ai setup`) or the interactive picker; pass an auth method to override
- All auth methods default to a lightweight model when `model-id` is omitted
- Pass `last` as the provider to reuse the previously generated message

### pr

Generate a PR title and body from the current branch.

```bash
git-ai pr [auth-method] [model-id] [--base <branch>] [--fresh] [--from-sha <commit>]
git-ai mr [...]   # alias for pr
```

- Reads the commit log and diff against the base branch
- Produces a Conventional Commits title + a markdown body structured by purpose (`## Overview`/`## Problem` → `## Change` → `## Verification`), scaled to the size of the change — a one-concern PR gets a few sentences and no headings at all
- Auto-detects the base branch from the remote default (falls back to `main`)
- Use `--base` to override (e.g. `--base dev`)
- Saves the generated output per current-branch/base-branch pair under `.git/pr-cache/`; subsequent runs with the same pair refine the previous result automatically
- A rebase or amend that leaves the branch's content unchanged reuses the cached text without an LLM call; one that carries new work (or rewords a commit) regenerates from the full branch diff
- Cache entries for branches you've since deleted are pruned automatically
- Use `--fresh` to ignore the saved output and regenerate from scratch
- Use `--from-sha` to override the saved HEAD and regenerate only from commits after a specific prior generated commit
- Uses your configured default (from `git-ai setup`) or the interactive picker; pass an auth method to override
- All auth methods default to a stronger model when `model-id` is omitted

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

## Python library

Beyond the `git-ai` CLI it installs, the `waxmard-git-ai` package is an importable library, so other tools can reuse the same commit-message and MR-description prompt assembly without shelling out.

```bash
pip install waxmard-git-ai
# or: uv add waxmard-git-ai
```

Bring your own Claude / Gemini / OpenAI / ADK / anything — sync or async.

**Commit message** (data-mode):

```python
import git_ai

system, user = git_ai.build_commit_prompt(diff_text)
raw = my_llm(system, user)               # your call: SDK, agent framework, REST, etc.
commit_msg = git_ai.parse_commit_response(raw)
```

`diff_stat=` is optional and normally derived from `diff_text`. Supply it when intentionally omitting a large generated patch; an empty diff remains valid when the stat lists the changed files.

`parse_commit_response` only parses — fences off, `===COMMIT===` marker unwrapped, agent trailers dropped. The two formatting rules the `git-ai` CLI enforces deterministically are separate calls, so a library consumer opts into them:

```python
msg = git_ai.wrap_commit_body(commit_msg)          # hard-wrap prose at BODY_WRAP_WIDTH (72)
trim = git_ai.enforce_subject_limit(msg)           # cut the subject to SUBJECT_LIMIT (70)
commit_msg = trim.message
if trim.over_limit:
    warn(f"subject is {trim.subject_length} chars with no clean clause break")
elif trim.dropped:
    warn(f'trimmed: dropped "{trim.dropped}"')
```

They stay separate because `enforce_subject_limit` returns a `SubjectTrim`, not a string: a subject with no usable clause break is returned untouched, and the caller is expected to surface that rather than ship an over-long subject silently.

**MR/PR description** (data-mode — no local checkout, e.g. fetched from the GitHub/GitLab API):

```python
import git_ai

log = git_ai.format_commit_log((c.title, c.message) for c in mr_commits)
system, user = git_ai.build_mr_prompt(
    diff=diff_text,
    commit_log=log,
    existing_pr=current_pr_body or None,
    # "since_existing" (default): diff covers only the commits added since
    # current_pr_body was written. Pass "branch" only when it spans the whole MR.
    diff_scope="since_existing",
)
raw = my_llm(system, user)
pr_text = git_ai.parse_mr_response(raw)

# Optional: render a compact ~ / + / - delta against the prior PR
delta = git_ai.render_pr_diff(current_pr_body, pr_text, color=False) or None
```

`diff_stat` and `release_context` are optional — when omitted, the diff stat is derived from the diff and a generic "no release tags found" context is used. As with commit prompts, a supplied stat permits an intentionally omitted diff.

`diff_scope` matters only alongside `existing_pr`, and it is the one argument worth getting right: it declares what `diff` and `commit_log` span, and the update prompt is written to match. Under `"branch"` the model may prune content the branch no longer contains — so declaring it while passing an incremental diff makes it rewrite away everything `existing_pr` covers but the diff omits. The default is `"since_existing"`, whose failure mode is only a stale sentence left unpruned. Model selection, retries, auth, and error handling are the caller's responsibility (inside `my_llm`).

**Repo-mode** (reads staged diff / `base..HEAD` from a local checkout):

```python
import git_ai

# Commit message from staged changes (auto-loads .git-ai-ignore)
diff = git_ai.get_staged_diff(".")
system, user = git_ai.build_commit_prompt(
    diff, release_context=git_ai.get_release_context("."),
)
commit_msg = git_ai.parse_commit_response(my_llm(system, user))

# PR description with incremental cache reuse
ctx = git_ai.prepare_repo_pr_context(".", base_branch="main")
if ctx.no_changes:
    pr_text = ctx.existing_pr            # HEAD unchanged, reuse cached PR
else:
    system, user = git_ai.build_mr_prompt(
        diff=ctx.diff,
        commit_log=ctx.commit_log,
        diff_stat=ctx.diff_stat,
        release_context=ctx.release_context,
        existing_pr=ctx.existing_pr,
        diff_scope=ctx.diff_scope,
    )
    pr_text = git_ai.parse_mr_response(my_llm(system, user))
    if ctx.current_branch:
        git_ai.save_cached_pr(
            git_ai.get_git_dir("."),
            ctx.current_branch,
            "main",
            pr_text,
            ctx.head_sha,
            ctx.content_id,
        )
```

`prepare_repo_pr_context` reuses `.git/pr-cache/` automatically, sets `no_changes=True` when `HEAD` matches the cached SHA — or when a rebase/amend rewrote the branch without changing `ctx.content_id`, its diff-and-message content fingerprint — so callers can skip the LLM entirely, and narrows the `diff`/`commit_log` to commits after the last generated `HEAD` when possible — reporting which it did as `ctx.diff_scope`, to forward straight to `build_mr_prompt`. Pass `fresh=True` to bypass the cache for one call, or `previous_head_sha=` to override the cached incremental base explicitly.

Data-mode is stateless. To get the same efficiency in remote consumers, persist the prior PR text + last generated head SHA yourself, fetch the incremental diff/log since that SHA from your SCM, and pass them to `build_mr_prompt(diff=..., commit_log=..., existing_pr=..., diff_scope="since_existing")`.

**Async / agent-framework example** — the prompt builders are pure, so anything goes inside the LLM call. Pass `system` and `user` to whatever your SDK expects (Anthropic `system=` + `messages=[{"role": "user", ...}]`, OpenAI/Gemini message lists, ADK agent `instruction` + input, etc.):

```python
import git_ai
from anthropic import AsyncAnthropic

client = AsyncAnthropic()

async def commit_msg(diff: str) -> str:
    system, user = git_ai.build_commit_prompt(diff)
    resp = await client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=1024,
        system=system,
        messages=[{"role": "user", "content": user}],
    )
    return git_ai.parse_commit_response(resp.content[0].text)
```

## Excluding noisy files (`.git-ai-ignore`)

Lockfiles and other generated artifacts can dominate a diff and push it past the LLM provider's input cap. git-ai includes their patch when the aggregate lockfile content is at most 25 KB. Above that limit, it sends only the compact diff stat so lockfile-only commits and PRs remain visible without flooding the context window. This applies to the following filenames:

```
package-lock.json    yarn.lock         pnpm-lock.yaml      npm-shrinkwrap.json
Gemfile.lock         Cargo.lock        go.sum              poetry.lock
uv.lock              composer.lock     Pipfile.lock        pubspec.lock
mix.lock             flake.lock
```

Drop a `.git-ai-ignore` file at the repo root to add more patterns (one per line, `#` comments and blank lines ignored). Patterns are Git pathspec glob fragments, **not `.gitignore` syntax** — a leading `/` is not root-anchoring. Each pattern matches at any depth: `generated/**/*.ts` matches TypeScript files under any `generated/` directory, and a bare directory name (`vendor`, or `vendor/`) excludes everything beneath it. Lines starting with `!` re-include a pattern, useful when you actually want to review a built-in default:

```
build/dist.js
generated/**/*.ts
vendor/

# Always re-include this lockfile, even above the adaptive limit
!package-lock.json
```

`!` removes a pattern by exact string match, so it only re-includes a built-in default (or an earlier line spelled identically) — it is not `.gitignore` negation precedence.

If the post-exclude diff is still over `GIT_AI_MAX_DIFF_BYTES` (default `900000`, set `0` to disable), git-ai aborts with a "Largest changed files" hint pointing at what to ignore or unstage.

In the Python library, `get_staged_diff`, `get_diff`, and `get_diff_stat` auto-load `.git-ai-ignore` and apply built-in lockfile defaults when `exclude_patterns` is omitted. Pass `exclude_patterns=[]` to opt out of all filtering.

## Repo-specific conventions (`.git-ai-instructions`)

git-ai's commit-type and scope heuristics are tuned for typical app repos. Some repos break those assumptions — a GitOps/deploy repo where *every* change is "user-facing" so the default feat-bias misfires, or a repo with its own commit scopes. Drop a free-form `.git-ai-instructions` file at the repo root to teach git-ai the local rules. Its contents are injected verbatim into the commit **and** PR prompts inside a `<repo_guidance>` block, and the prompts treat it as **authoritative** — when it conflicts with the built-in type heuristics, your guidance wins.

**Lead with the repo's user POV.** The single biggest lever on prefix accuracy is stating *who consumes what this repo produces and what they perceive as its output*. git-ai's prompts already reason from that POV — "user-facing" means visible to that audience — so the same edit can be `feat` in one repo and `chore` in another. Start with a `User POV:` line, then a few type rules expressed in that POV's terms. The examples below are illustrative — write your own repo's POV:

```
# .git-ai-instructions
User POV: the running app a deploy serves. "User-facing" = what changes for someone using it.

- Bumping an image tag to ship the same app's next build → chore
- A brand-new deployed service, or a capability its users gain → feat
```

```
# .git-ai-instructions
User POV: the report this tool prints. Its wording and layout are the product's UI.

- Rewording or restyling the printed report → style (or fix when correcting wrong output)
- A new export path that consumers of the report never see → build or ci, not feat
```

An absent or empty file is a no-op. In the Python library, `load_repo_instructions(repo_path)` returns the trimmed text (or `None`), and `build_commit_prompt` / `build_mr_prompt` accept a `repo_guidance=` argument.

## Manual configuration (advanced)

Everything below is handled for you by `git-ai setup`. Reach for it only when you want to script config, edit it by hand, or set up an advanced case the wizard leaves alone (service accounts, multi-project Vertex profiles).

### API keys by hand

For `gemini-api`, `anthropic-api`, and `openai-api`, git-ai resolves each key in this order until one succeeds:

1. The environment variable — `GEMINI_API_KEY`, `ANTHROPIC_API_KEY`, or `OPENAI_API_KEY`.
2. System keychain, under the service name `<provider>-api-key` (e.g. `gemini-api-key`, `anthropic-api-key`, `openai-api-key`):
   - **macOS:** `security add-generic-password -s gemini-api-key -a "$USER" -w YOUR_KEY`
   - **GNOME / libsecret:** `secret-tool store --label="Gemini API Key" service gemini-api-key`
   - **pass:** `pass insert gemini-api-key`
   - **KDE Wallet:** `kwallet-query kdewallet -w gemini-api-key`

For Google ADC / service-account credentials, use a `vertex-gemini` or `vertex-anthropic` method (`gcloud auth application-default login` or `GOOGLE_APPLICATION_CREDENTIALS`).

### Narrowing the picker list

By default `git-ai options` enumerates every supported provider/model combo. Most users only have access to a couple. To restrict the picker to just the providers and models you actually use, drop a config file at `$XDG_CONFIG_HOME/git-ai/options.conf` (usually `~/.config/git-ai/options.conf`):

```ini
[claude-code]
claude-haiku-4-5-20251001
claude-sonnet-4-6

[codex]
gpt-5.4-mini

# Empty sections hide these providers entirely
[vertex-gemini]

[vertex-anthropic]
```

- `[provider]` headers must be one of: `vertex-gemini`, `vertex-anthropic`, `gemini-api`, `antigravity`, `claude-code`, `anthropic-api`, `codex`, `openai-api`. Unknown headers are silently dropped.
- Model IDs under a header are passed through to the provider verbatim, so you can list future model IDs (e.g. a newly released `claude-sonnet-5-0`) without waiting for a git-ai release.
- Delete the file to restore the full shipped catalog.
- See [`examples/options.conf`](examples/options.conf) for a starter.

### Pinning a GCP account (Vertex)

`git-ai setup` writes `project` / `region` / `account` for a single Vertex provider for you. This section is the manual reference for that, plus the advanced cases the wizard leaves alone: service-account `credentials=`, the shared `[vertex]` block, and multi-project profiles.

A `[vertex-*]` section accepts optional `key = value` lines alongside its model IDs to pin which account and project that provider uses (these keys are not models and never appear in the picker):

```ini
[vertex-anthropic]
project     = acme-prod        # overrides $GOOGLE_CLOUD_PROJECT / $GOOGLE_VERTEX_PROJECT
region      = us-east5         # overrides $VERTEX_LOCATION (default us-central1)
account     = me@acme.com      # token via `gcloud auth print-access-token --account=…`
credentials = ~/keys/sa.json   # or: point ADC at a service-account JSON (~ expands to $HOME)
claude-sonnet-4-6
```

- `account=` selects a human Google login (authenticate each once with `gcloud auth login`); `credentials=` selects a service-account JSON. Set one or the other — with neither, plain gcloud ADC is used.
- Config values override the corresponding environment variables.
- Before each call, git-ai prints the account/project it used to stderr (e.g. `git-ai: Vertex account me@acme.com · project acme-prod (us-east5)`).

To choose between **multiple projects/accounts from the picker**, give each a profile suffix — `[vertex-anthropic@<profile>]`. Every profile becomes its own picker entry (labelled `Vertex AI [<profile>]`), so the same account across two projects is fully supported:

```ini
[vertex-anthropic@acme]
project = acme-prod
account = me@acme.com
claude-sonnet-4-6

[vertex-anthropic@sandbox]
project = acme-sandbox
account = me@acme.com
claude-sonnet-4-6
```

Pass one explicitly with `git-ai commit vertex-anthropic@sandbox` or `git-ai pr vertex-anthropic@acme:claude-sonnet-4-6`.

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

## Compatibility

git-ai does not depend on a specific terminal UI. It works in the CLI, in Lazygit, and in similar git environments as long as Git exposes the required repository state:

- `git-ai commit` needs staged changes (`git diff --staged`)
- `git-ai pr` needs commits and diff data relative to a base branch
