# AGENTS.md — `lib/`

Guidance for AI coding agents working under `lib/`. The repo-wide guide is the root `AGENTS.md`.

Files load through the `lib/ai-common.sh` umbrella (core helpers + `auth`/`discovery`/`config`/`provider`); `lib/setup.sh` is a second umbrella over `setup-edit`/`setup-auth`/`setup-vertex`/`setup-shadow`. Both splits exist to stay under the 800-line cap without changing what a caller sources. `make install` symlinks every `lib/*.sh`.

## `run_provider()` (`provider.sh`)

Takes a tool name (`commit` or `pr`) plus prompt and input, and emits the model's **raw** text. Parsing and formatting happen once, in Python, at the two call sites that consume it (`_commit_cli.py format`, `_pr_repo_cli.py format`) — never add a Bash twin of a parsing rule, since a mirrored rule ships every fix twice and drifts in between.

A provider token may be profile-qualified (`base@profile`): dispatch on the base, but look up account/project config under the full token, which is the config section name.

Per-provider notes worth knowing before editing:

- **Every `curl` path** builds its JSON through `_stage_request_body SHAPE PROMPT [MODEL]`, which reads the payload on **stdin** and writes the body to a temp file the caller owns, posted as `--data-binary @path`. Neither the input nor the body may ride an argv or env string: Linux caps a *single* one of either at `MAX_ARG_STRLEN` (131072 bytes), so a diff well inside `GIT_AI_MAX_DIFF_BYTES` fails `execve` there. The prompt is a packaged file and stays in env. The four shapes are `gemini` (shared by AI Studio and Vertex), `openai`, `anthropic`, and `vertex-anthropic` (`anthropic_version` instead of `model`).
- **`gemini-api`** posts directly to `generativelanguage.googleapis.com` with an API key. Do not route it through a CLI. The key is a URL parameter, so the whole URL goes in a curl config file to keep it out of `ps`. This path deliberately drops curl's `-f`: a rejected key or bad model id returns a 4xx whose body explains why, and `_api_error_message` surfaces it.
- **`antigravity`** drives the `agy` CLI on a cached Google-account OAuth login — there is no key to probe, so `provider_ready` can only check for the binary. `agy` ignores stdin, so prompt and input both ride on `-p` via `_agy_prompt_arg`, which hits the same `MAX_ARG_STRLEN` ceiling as the curl paths and answers it the same way: past `AGY_MAX_INLINE_PROMPT` (120000 bytes) the payload is staged in a temp file and passed as `@path`, which agy expands client-side, so it stays one turn rather than becoming a tool call. An `@` return value is also how the caller knows it owns a temp file to delete — the helper cannot set a variable for it, being called in a subshell. `--disable-slash-commands` stops a diff line opening with `/` being read as a slash command. Its model ids pin reasoning effort (`gemini-3.7-flash-medium`), so `antigravity` is its own family in `recommended-models.conf`.
- **`claude-code`** passes `--max-turns 3`; a cap of 1 aborts a reasoning model with "Reached max turns" before any text is emitted.
- **`codex`** reads the payload on stdin and writes to `--output-last-message`, so its result comes from a temp file, not stdout.
- **Vertex** resolves `account` / `credentials` / `project` / `region` from the provider's own config section first, then the environment, and prints which combination it used to stderr before the call. Gemini and Anthropic share a request path but differ in publisher and response shape.

`_extract_gemini_text` is shared between the AI Studio and Vertex paths. It joins every non-`thought` text part: thinking models return reasoning as flagged parts, so `parts[0]` is not reliably the answer.

## Model discovery (`discovery.sh`)

There is **no hardcoded catalog** — lists come from each provider's own API so new models appear without a git-ai release. `discover_models PROVIDER [--refresh]` serves a disk cache (`$XDG_CONFIG_HOME/git-ai/models-cache/<provider>.list`, TTL via `GIT_AI_MODELS_TTL_MIN`, default 24h), else fetches and caches, else serves a stale cache on failure.

Resolution order is authed API → keyless `models.dev/api.json` → free-text entry, which is what lets a provider with no credentials still populate a picker. Notable per-provider behaviour:

- `claude-code` / `codex` have no list endpoint and borrow the matching API's catalog.
- `antigravity` uses `agy models`, the only source for its effort-suffixed ids, and therefore has no models.dev mapping to fall back to.
- Vertex reads Model Garden with a gcloud token, filtered to text-generation models.

Discovery is suggestions-only. `resolve_model` passes an explicit model through verbatim — the provider API is the real validator — falling back to the tool's last saved pick, then the first discovered model.

## `options.conf` (`config.sh`)

`list_options` treats a **present** `options.conf` as authoritative: only pinned entries are offered, and an empty `[provider]` section hides that provider. Live discovery feeds the picker **only** when no `options.conf` exists, otherwise enabling a provider with no pins would flood it with every discovered model.

Section headers are validated with `provider_is_valid`; an unrecognised header (including the shared `[vertex]` block, which is not a runnable provider) clears the current section so model ids under it are skipped, while its `key=value` lines are still read as settings. Model ids never contain `=`, which is how the two are told apart.

Vertex models are pinned **per project** in `[vertex-<family>@<project>]` sections. The older shared shape (base sections plus a `[vertex] projects =` list) still parses and expands.

## Setup wizard (`setup*.sh`)

`cmd_setup` in `bin/git-ai` is a thin dispatcher; everything else is `_setup_*` here. The flow branches on whether `options.conf` already exists.

**No config → `_setup_fresh`** probes `provider_ready` across providers to build the ready set, then either:

- **`_setup_fast_path`** (ready set non-empty, `GIT_AI_NO_SETUP_FAST` unset) — zero questions: enable every ready provider with its `recommended_model` pin, seed the per-repo default, land on the config overview.
- **`_setup_manual`** — status table, then provider and model pickers (fzf, or numbered when `GIT_AI_NO_FZF` is set). Recommended ids come **pre-marked** so a bare Enter accepts them; a sentinel row takes a custom id.

`setup-shadow.sh` detects a second git-ai installed through a package manager (npm global, pipx, `uv tool`) and offers to remove it, since the shadowing copy is what `PATH` actually runs. It acts only on installs attributable to a package manager, and skips the pip vectors when *this* copy is the pip install (bundled Bash under `_sh/`) rather than nagging it to uninstall itself.

Backing out of the provider pick returns cleanly with nothing written rather than dying — the wizard also auto-launches from `cmd_commit`/`cmd_pr` via `maybe_first_run_setup`, where dying would fail that commit. Auto-launch is gated off by `CI`, `GIT_AI_NO_SETUP`, and a non-tty stdin/stdout, and only ever reaches the fresh flow.

**Config exists → `_setup_edit_existing`** prints a summary plus an edit menu. Edits go through the surgical `conf_*` editors (`conf_add_section`, `conf_set_section_models`, `conf_set_section_setting`, …) and touch only the targeted section, so comments and vertex settings survive.

Model and project edits are **replace-style**: one multi-select over `current ∪ discovered` with current entries pre-marked, so the gesture is unmarking what to drop. `_setup_multiselect` distinguishes **cancel (2)** from **confirmed-empty (0)** — Esc keeps the current set, while confirming with only the sentinel marked unpins every model, which is otherwise unreachable without deleting the provider. Projects deliberately do *not* honour confirmed-empty: a vertex provider with no project cannot run, so clearing the list means removing vertex.

`provider_ready` mirrors `run_provider`'s preconditions and is memoized per run through `_setup_ready_tag`, since it shells out to keychains and gcloud. Call `_setup_ready_forget` after auth-assist makes a provider ready mid-run.

### Vertex is a single user-facing option

The wizard hides the internal `vertex-gemini` / `vertex-anthropic` split, routing each picked model by id (`claude*` → anthropic, else gemini) and folding both sections into one entry for choosers and summaries.

- Per-project section headers — not a `projects =` key — are the record of which projects are configured (`vertex_section_projects`, which `provider_ready` also counts).
- `_setup_vertex_normalize` folds the legacy shared shape down to per-project sections, copying each base section's models into every project and then dropping the base sections and the `project=`/`projects=` keys that drove the expansion; a leftover base `project =` would override every profile's own project. It runs **only from the three write paths**, so an edit the user backs out of leaves the file untouched.
- Only a shared `projects =` list expands the base sections, so the fold reads `parse_user_options` for the plural shape but has to copy the **literal** base models for the singular `project =` shape (README's documented single-project config) — reading the parsed output there finds nothing and would silently erase the pins. Base models with no project named anywhere stay put: they resolve theirs from the environment at run time, and folding them into some other profile's project would be a guess.
- A section suffix is an *address*, not necessarily the GCP project: a hand-written `project =` can point `[vertex-anthropic@acme]` at `acme-prod`. `_setup_vertex_resolved_project` resolves that (checking both family sections, since either can carry the override) and `_setup_vertex_add_project` consults it before writing, so re-picking `acme-prod` recognises the existing alias instead of creating a second profile — returning **2**, not 0, because both callers pin models on every suffix they see reported as added and would recreate the duplicate the guard just declined to write. The summary renders the divergence as `acme (project: acme-prod)`. Fast-path reset snapshots and restores the override, or it would silently repoint the profile at its own suffix.
- Re-adding an already-configured `vertex` means "attach another GCP project": straight to the project picker, then the model editor pre-marked with what vertex pins elsewhere. A batch of new projects is asked once and written to each.
- `_setup_pick_vertex_scope` asks one-project-or-all only when more than one is configured. A config with no project anywhere stays on the base sections — vertex resolves its project from the environment at run time and must keep working.
- Project suggestions sweep **every** `gcloud auth list` login (capped at 5, active first), not just the active one, and both pickers carry a `=custom=` row for an id no login can see. A login whose listing fails is named on stderr, or a dead credential is indistinguishable from an account with no projects. Picking a project only a *non-active* login can see prompts to pin `account =` (`_setup_offer_account_pin`), since vertex otherwise mints its token from the active login and fails at run time.

### Auth-assist

`_setup_ensure_auth` prompts for API keys after selection and checks each pasted key against the provider's models endpoint (`_setup_probe_key`: 0 accepted, 1 rejected, 2 indeterminate — a network failure saves rather than blocks, and `GIT_AI_NO_KEY_PROBE=1` skips it), then stores to the keychain (`store_api_key`) or the shell rc (`persist_key_to_rc`, plaintext — warn the user). CLI providers get an install hint instead. Vertex gets `_setup_vertex_assist`: ADC login, then `project` / `region` / `account`, with the project recorded and normalized so models already on the base sections land in it rather than being stranded.

Recommended ids are **data, not code**: `recommended-models.conf` (`family = model-id`, resolved via `GIT_AI_PKG_DIR`) with `recommended_model()` mapping provider → family. Bumping one is a routine data change.
