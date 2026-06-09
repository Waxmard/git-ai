#!/bin/bash
# setup.sh - git-ai interactive setup wizard (sourced by bin/git-ai).
# Owns the `git-ai setup` flow: provider/model pickers, the fast path,
# the in-place config editors, auth-assist, and first-run auto-launch.
# Calls into lib/ai-common.sh (provider_ready, discover_models, conf_*,
# render_options_conf, key storage); cmd_setup itself stays in bin/git-ai.

# Canonical provider order for the setup wizard, by strength of intent signal:
# an installed CLI or a configured gcloud project is a deliberate act, while an
# exported API key can be stray spillover from another project. The fast path
# seeds the per-repo default from the FIRST ready provider in this order, so it
# must never let a stray key outrank a deliberate install.
# `vertex` is the single user-facing Vertex AI entry: the wizard never shows
# the vertex-gemini/vertex-anthropic split — it expands the token itself and
# routes each model to the right internal provider by its id.
SETUP_PROVIDERS=(claude-code codex vertex gemini-api anthropic-api openai-api)

# Expand a wizard provider token into the concrete runnable provider(s) it
# stands for: `vertex` covers both internal vertex providers; everything else
# is already concrete.
_setup_expand_provider() {
  case "$1" in
    vertex) printf 'vertex-anthropic\nvertex-gemini\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Map a wizard provider token to the concrete provider that should run MODEL.
# Only `vertex` needs inference (claude* models live under publishers/anthropic,
# everything else under publishers/google); concrete tokens pass through.
_setup_provider_for_model() {
  local provider="$1" model="$2"
  if [[ "$provider" == vertex ]]; then
    case "$model" in
      claude*) printf 'vertex-anthropic\n' ;;
      *) printf 'vertex-gemini\n' ;;
    esac
  else
    printf '%s\n' "$provider"
  fi
}

# Best-effort: pick the GCP project fast setup should pin for Vertex AI when
# neither the config nor the environment names one. The gcloud-active project
# is probed first (cheap, the common case — note `gcloud projects list` sorts
# alphabetically, it does NOT lead with the active project); then the account's
# other projects (assumed few; capped) are filtered to those with the Vertex AI
# API enabled. Exactly one match wins outright, several fall back to the first,
# none falls back to the active project. Empty when gcloud is absent or nothing
# resolves — the user can always add/change projects later via the wizard's
# "Change Vertex AI projects" action.
_setup_detect_vertex_project() {
  command -v gcloud >/dev/null 2>&1 || return 0

  local active
  active=$(_gcloud_active_project)
  if [[ -n "$active" ]] && _setup_vertex_api_enabled "$active"; then
    printf '%s\n' "$active"
    return 0
  fi

  # Each enablement probe is a gcloud API round-trip, so cap the sweep — a
  # pathological org account must not hang setup for minutes.
  local p probed=0
  local -a enabled=()
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != "$active" ]] || continue
    [[ $probed -ge 10 ]] && break
    probed=$((probed + 1))
    _setup_vertex_api_enabled "$p" && enabled+=("$p")
  done < <(gcloud projects list --format="value(projectId)" 2>/dev/null)

  if [[ ${#enabled[@]} -gt 0 ]]; then
    printf '%s\n' "${enabled[0]}"
  elif [[ -n "$active" ]]; then
    printf '%s\n' "$active"
  fi
}

# True when PROJECT has the Vertex AI API (aiplatform.googleapis.com) enabled.
_setup_vertex_api_enabled() {
  gcloud services list --enabled --project="$1" \
    --filter="config.name=aiplatform.googleapis.com" \
    --format="value(config.name)" 2>/dev/null | grep -q aiplatform
}

# Collapse the config's provider sections into wizard tokens for choosers and
# summaries: the two vertex sections fold into a single `vertex` entry (deduped,
# first-seen order) so the user is never asked to tell them apart.
_setup_conf_wizard_providers() {
  local conf="$1" p
  local seen=$'\n'
  while IFS= read -r p; do
    case "${p%%@*}" in vertex-gemini | vertex-anthropic) p=vertex ;; esac
    case "$seen" in *$'\n'"$p"$'\n'*) continue ;; esac
    seen+="$p"$'\n'
    printf '%s\n' "$p"
  done < <(conf_section_providers <"$conf")
}

# Print the readiness status table for every provider.
_setup_status_table() {
  local p reason
  printf 'Detected providers:\n\n'
  for p in "${SETUP_PROVIDERS[@]}"; do
    if reason=$(provider_ready "$p" 2>&1 1>/dev/null); then
      printf '  [ready]  %s\n' "$(provider_display_name "$p")"
    else
      printf '  [setup]  %-22s — %s\n' "$(provider_display_name "$p")" "$reason"
    fi
  done
  printf '\n'
}

# True when the wizard should drive selections through fzf.
_setup_has_fzf() {
  command -v fzf >/dev/null 2>&1 && [[ -z "${GIT_AI_NO_FZF:-}" ]]
}

# Pick one or more providers. Prefers fzf; falls back to a numbered prompt.
# Prints chosen provider tokens, one per line.
_setup_pick_providers() {
  local p line
  if _setup_has_fzf; then
    for p in "${SETUP_PROVIDERS[@]}"; do
      printf '%s|%s\n' "$p" "$(provider_display_name "$p")"
    done | env -u FZF_DEFAULT_OPTS -u FZF_DEFAULT_OPTS_FILE \
      fzf --multi --delimiter='|' --with-nth=2 --no-sort --tiebreak=index \
      --prompt='enable providers (tab to multi-select)> ' --height=50% --reverse |
      while IFS='|' read -r p _; do printf '%s\n' "$p"; done
    return
  fi

  # Numbered fallback.
  local i=1
  for p in "${SETUP_PROVIDERS[@]}"; do
    printf '  %d) %s\n' "$i" "$(provider_display_name "$p")" >&2
    i=$((i + 1))
  done
  printf 'Select providers by number (space-separated): ' >&2
  read -r line
  local n
  for n in $line; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    ((n >= 1 && n <= ${#SETUP_PROVIDERS[@]})) || continue
    printf '%s\n' "${SETUP_PROVIDERS[$((n - 1))]}"
  done
}

# Discovered model suggestions for a wizard provider token: vertex merges both
# publishers' lists (each pick is routed to the right internal provider later
# by _setup_provider_for_model); everything else is one discovery call.
_setup_suggest_models() {
  local provider="$1" listed
  if [[ "$provider" == vertex ]]; then
    listed=$(
      discover_models vertex-anthropic 2>/dev/null
      discover_models vertex-gemini 2>/dev/null
    )
    listed="${listed#$'\n'}"
    listed="${listed%$'\n'}"
  else
    listed=$(discover_models "$provider" 2>/dev/null)
  fi
  printf '%s\n' "$listed"
}

# Build "id|label" picker rows for PROVIDER from the LISTED suggestions: the
# family's recommended model(s) lead, labelled "(recommended)", so the user
# never has to know which id in a noisy catalog is the good default; then an
# explicit custom-id sentinel; then the rest in discovery order (deduped).
_setup_model_rows() {
  local provider="$1" listed="$2" c rec m
  local rows="" seen=$'\n'
  while IFS= read -r c; do
    rec=$(recommended_model "$c")
    [[ -n "$rec" && "$seen" != *$'\n'"$rec"$'\n'* ]] || continue
    seen+="$rec"$'\n'
    rows+="${rec}|${rec} (recommended)"$'\n'
  done < <(_setup_expand_provider "$provider")
  rows+=$'=custom=|— type a custom model id… —\n'
  while IFS= read -r m; do
    [[ -n "$m" && "$seen" != *$'\n'"$m"$'\n'* ]] || continue
    seen+="$m"$'\n'
    rows+="${m}|${m}"$'\n'
  done <<<"$listed"
  printf '%s' "$rows"
}

# Pick zero or more models for PROVIDER. Models are discovered live from the
# provider's API (cached) and offered as suggestions — recommended first — but
# nothing is selected unless the user *explicitly* marks it (Tab) or types it.
# Prints chosen model IDs, one per line — empty output is valid (the provider
# is enabled with no pinned model and the model is chosen at commit/pr time).
# Never adds a model the user didn't deliberately choose.
_setup_pick_models() {
  local provider="$1" listed line m
  listed=$(_setup_suggest_models "$provider")

  if [[ -n "$listed" ]]; then
    local rows selected want_custom=""
    rows=$(_setup_model_rows "$provider" "$listed")
    if selected=$(_setup_multiselect "models for ${provider}> " \
        'Tab marks a model; Enter confirms marked rows; Esc selects none' \
        '— skip / no model —' "$rows"); then
      # The fzf choice is final: skipping does NOT fall through to the
      # free-text prompt — unlisted ids go via the explicit custom row, which
      # emits any models marked alongside it and then drops to the prompt.
      while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        if [[ "$m" == '=custom=' ]]; then want_custom=1; else printf '%s\n' "$m"; fi
      done <<<"$selected"
      [[ -n "$want_custom" ]] || return 0
    else
      printf 'Suggested models for %s:\n' "$provider" >&2
      printf '%s\n' "$listed" | sed 's/^/  /' >&2
    fi
  fi

  # Reached via the explicit custom-id row, when fzf is unavailable, or when
  # the provider has no discoverable models (e.g. claude-code/codex without a
  # key). Blank = leave the provider with no pinned model.
  read -rp "Model id(s) for ${provider}, comma-separated (blank for none): " line || line=""
  [[ -n "$line" ]] || return 0
  while IFS= read -r m; do
    m=$(_trim "$m")
    [[ -n "$m" ]] && printf '%s\n' "$m"
  done < <(printf '%s\n' "${line//,/$'\n'}")
}

# _setup_multiselect PROMPT HEADER SKIP_LABEL ROWS
# fzf multi-select over "value|label" ROWS, led by a skip sentinel so a bare
# Enter (nothing marked) selects nothing — fzf otherwise returns the focused
# row. Prints the marked values one per line (possibly none); returns non-zero
# when fzf is unavailable so callers fall back to their free-text prompt.
# FZF_DEFAULT_OPTS is cleared so a user's keybindings can't auto-select.
_setup_multiselect() {
  local prompt="$1" header="$2" skip_label="$3" rows="$4"
  _setup_has_fzf || return 1
  local selected v
  selected=$(printf '—|%s\n%s' "$skip_label" "$rows" \
    | env -u FZF_DEFAULT_OPTS -u FZF_DEFAULT_OPTS_FILE fzf --multi \
      --delimiter='|' --with-nth=2 --no-sort --tiebreak=index \
      --height=40% --reverse --header="$header" --prompt="$prompt") || selected=""
  while IFS='|' read -r v _; do
    [[ -n "$v" && "$v" != "—" ]] && printf '%s\n' "$v"
  done <<<"$selected"
  return 0
}

# Multi-select GCP projects for vertex providers, sourced from `gcloud projects
# list` (fzf multi-select with a free-text fallback). Prints chosen project ids,
# one per line; empty output means "leave the current projects unchanged".
_setup_pick_projects() {
  local listed="" line p rows="" selected
  command -v gcloud >/dev/null 2>&1 &&
    listed=$(gcloud projects list --format="value(projectId)" 2>/dev/null)

  if [[ -n "$listed" ]]; then
    while IFS= read -r p; do [[ -n "$p" ]] && rows+="${p}|${p}"$'\n'; done <<<"$listed"
    if selected=$(_setup_multiselect 'vertex projects> ' \
        'Tab marks GCP project(s); Enter confirms; Esc keeps current' \
        '— skip / keep current —' "$rows"); then
      if [[ -n "$selected" ]]; then
        printf '%s\n' "$selected"
        return 0
      fi
    else
      printf 'Your GCP projects:\n' >&2
      printf '%s\n' "$listed" | sed 's/^/  /' >&2
    fi
  fi

  read -rp "GCP project id(s), comma-separated (blank to keep current): " line || line=""
  [[ -n "$line" ]] || return 0
  while IFS= read -r p; do
    p=$(_trim "$p")
    [[ -n "$p" ]] && printf '%s\n' "$p"
  done < <(printf '%s\n' "${line//,/$'\n'}")
}

# maybe_first_run_setup TOOL
# Launch the setup wizard the first time a user runs commit/pr with nothing
# configured, mimicking Claude Code's first-run flow. No-ops (returns 0) when
# anything is already configured, when not on an interactive tty, or when
# explicitly disabled — so scripts and the lazygit capture path are never
# interrupted.
maybe_first_run_setup() {
  local tool="$1"
  local conf sentinel
  conf=$(user_options_path)
  sentinel="$(dirname "$conf")/.setup-done"

  # Already configured / already prompted → nothing to do.
  [[ -e "$conf" || -e "$sentinel" ]] && return 0
  [[ -n "$(get_last_provider "$tool" 2>/dev/null)" ]] && return 0
  # Interactive only; never in CI, pipes, or when opted out.
  [[ -t 0 && -t 1 ]] || return 0
  [[ -z "${CI:-}" && -z "${GIT_AI_NO_SETUP:-}" ]] || return 0

  printf 'git-ai: no providers configured — launching setup (GIT_AI_NO_SETUP=1 to skip).\n' >&2
  cmd_setup
  mkdir -p "$(dirname "$sentinel")" 2>/dev/null || true
  : >"$sentinel" 2>/dev/null || true
}

# Interactive vertex auth assist: offer ADC login, then prompt for the common
# per-section settings (project required, region/account optional) and write
# them into [PROVIDER] via conf_set_section_setting — for the wizard's `vertex`
# token that is the shared [vertex] block. [vertex-x@profile] profiles and
# service-account credentials= stay manual (see the README).
_setup_vertex_assist() {
  local provider="$1" conf="$2"
  local label account project region input ans
  label=$(provider_display_name "$provider")
  printf '\n%s needs Google Cloud access.\n' "$label"

  # 1. Application Default Credentials (or a per-section account).
  account=$(vertex_resolve "$provider" account)
  if ! _vertex_has_auth "$account"; then
    read -rp '  Run "gcloud auth application-default login" now? [y/N]: ' ans
    case "$ans" in
      y | Y | yes | Yes)
        if command -v gcloud >/dev/null 2>&1; then
          gcloud auth application-default login || printf '  gcloud login failed.\n'
        else
          printf '  gcloud not installed — see https://cloud.google.com/sdk\n'
        fi
        ;;
      *) printf '  Skipped — run it yourself, then re-run setup.\n' ;;
    esac
  fi

  # 2. Project (required). Default-fill from gcloud's active config.
  project=$(vertex_resolve "$provider" project)
  project="${project:-${GOOGLE_VERTEX_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}}"
  if [[ -z "$project" ]]; then
    local default_project
    default_project=$(_gcloud_active_project)
    read -rp "  GCP project${default_project:+ [$default_project]}: " input
    input="${input:-$default_project}"
    if [[ -n "$input" ]]; then
      _conf_apply "$conf" conf_set_section_setting "$provider" project "$input" &&
        printf '  Set project = %s\n' "$input"
    else
      printf '  No project set — vertex requires one to run.\n'
    fi
  fi

  # 3. Region (optional; default us-central1).
  region=$(vertex_resolve "$provider" region)
  if [[ -z "$region" ]]; then
    read -rp '  Vertex region [Enter for us-central1]: ' input
    if [[ -n "$input" ]]; then
      _conf_apply "$conf" conf_set_section_setting "$provider" region "$input" &&
        printf '  Set region = %s\n' "$input"
    fi
  fi

  # 4. Account (optional; pin a specific gcloud login for token minting).
  if [[ -z "$account" ]]; then
    if command -v gcloud >/dev/null 2>&1; then
      local accts
      accts=$(gcloud auth list --format="value(account)" 2>/dev/null)
      [[ -n "$accts" ]] && printf '  Known gcloud accounts:\n%s\n' "$(printf '%s\n' "$accts" | sed 's/^/    /')"
    fi
    read -rp '  Pin a gcloud account? [Enter for default ADC]: ' input
    if [[ -n "$input" ]]; then
      _conf_apply "$conf" conf_set_section_setting "$provider" account "$input" &&
        printf '  Set account = %s\n' "$input"
    fi
  fi
}

# Help the user authenticate PROVIDER if it isn't ready yet. Key providers get
# an interactive key prompt + storage choice; vertex gets project/region/account
# assist; CLI providers get an install hint. CONF is the options.conf being
# edited (vertex settings are written there).
_setup_ensure_auth() {
  local provider="$1" conf="${2:-$(user_options_path)}"
  local label
  label=$(provider_display_name "$provider")

  if provider_ready "$provider" 2>/dev/null; then
    printf '  %s: already authenticated.\n' "$label"
    case "${provider%%@*}" in
      vertex | vertex-gemini | vertex-anthropic)
        printf '  (To change GCP projects, use "Change Vertex AI projects" in the setup menu.)\n' ;;
    esac
    return 0
  fi

  local meta service envvar
  if meta=$(provider_key_meta "$provider"); then
    read -r service envvar <<<"$meta"
    printf '\n%s needs an API key.\n' "$label"
    local key
    read -rsp "  Paste key (blank to skip): " key
    printf '\n'
    if [[ -z "$key" ]]; then
      printf '  Skipped — set %s later or re-run "git-ai setup".\n' "$envvar"
      return 0
    fi
    printf '  Store it: 1) OS keychain  2) shell rc (plaintext)  3) skip saving\n'
    local how
    read -rp "  Choice [1]: " how
    case "${how:-1}" in
      1)
        if store_api_key "$service" "$key"; then
          printf '  Saved to your keychain (service: %s).\n' "$service"
        else
          printf '  No keychain backend found. Falling back to shell rc.\n'
          local rc
          rc=$(persist_key_to_rc "$envvar" "$key") &&
            printf '  Appended export to %s — open a new shell or "source" it.\n' "$rc"
        fi
        ;;
      2)
        local rc
        rc=$(persist_key_to_rc "$envvar" "$key") &&
          printf '  Appended export to %s (plaintext) — open a new shell or "source" it.\n' "$rc"
        ;;
      *)
        printf '  Not saved — export %s yourself to use this provider.\n' "$envvar"
        ;;
    esac
    return 0
  fi

  # Non-key providers: point at the right install/auth step.
  case "${provider%%@*}" in
    claude-code)
      printf '  %s: install the CLI — https://claude.ai/code\n' "$label" ;;
    codex)
      printf '  %s: install the CLI — https://github.com/openai/codex\n' "$label" ;;
    # The wizard's `vertex` token lands settings in the shared [vertex] block
    # (one auth/project setup covers both internal vertex providers).
    vertex|vertex-gemini|vertex-anthropic)
      _setup_vertex_assist "$provider" "$conf" ;;
  esac
  return 0
}

# Single-select over DATA — newline-separated "value<TAB>label" lines passed as
# $2 (an argument, not stdin, so the numbered-fallback prompt still reads the
# terminal). Prefers fzf (label shown, value returned); falls back to a numbered
# prompt. Prints the chosen value; returns non-zero on cancel/empty.
# FZF_DEFAULT_OPTS is cleared so a user's keybindings can't auto-select.
_setup_select() {
  local prompt="$1" data="$2"
  local -a vals=() labels=()
  local v l
  while IFS=$'\t' read -r v l; do
    [[ -n "$v" ]] || continue
    vals+=("$v")
    labels+=("${l:-$v}")
  done <<<"$data"
  [[ ${#vals[@]} -gt 0 ]] || return 1

  if _setup_has_fzf; then
    local i out
    out=$(for i in "${!vals[@]}"; do printf '%s\t%s\n' "$i" "${labels[$i]}"; done \
      | env -u FZF_DEFAULT_OPTS -u FZF_DEFAULT_OPTS_FILE fzf \
        --delimiter=$'\t' --with-nth=2 --no-sort --tiebreak=index \
        --height=40% --reverse --prompt="$prompt") || return 1
    [[ -n "$out" ]] || return 1
    printf '%s\n' "${vals[${out%%$'\t'*}]}"
    return 0
  fi

  # Numbered fallback.
  local i n
  for i in "${!vals[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${labels[$i]}" >&2; done
  read -rp "$prompt" n
  [[ "$n" =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#vals[@]})) || return 1
  printf '%s\n' "${vals[$((n - 1))]}"
}

# Single-choice over provider tokens (fzf or numbered). Echoes the chosen token;
# returns non-zero on cancel/empty.
_setup_choose_provider() {
  local prompt="$1"
  shift
  [[ $# -gt 0 ]] || return 1
  local p data=""
  for p in "$@"; do data+="${p}"$'\t'"$(provider_display_name "$p")"$'\n'; done
  _setup_select "$prompt" "$data"
}

# ---------------------------------------------------------------------------
# Config overview + in-place edit actions live in setup-edit.sh (kept under the
# repo's per-file line limit). Sourced here so the full wizard surface is
# available whether bin/git-ai or a test sources setup.sh.
# ---------------------------------------------------------------------------
_SETUP_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib/setup-edit.sh
source "${_SETUP_DIR}/setup-edit.sh"


# Replace the whole config by re-running the fresh flow (fast path first, so
# detected providers are enabled with recommended models in one stroke).
# Destructive — providers, models, and vertex settings are all rebuilt — so it
# confirms first. Returns 0 when the reset ran, 1 when declined.
_setup_action_reset() {
  local conf="$1" ans
  read -rp 'Replace your whole config (providers, models, vertex settings)? [y/N]: ' ans || ans=""
  case "$ans" in
    y | Y | yes | Yes) ;;
    *)
      printf 'Kept as-is.\n'
      return 1
      ;;
  esac
  printf '\n'
  _setup_fresh "$conf"
}

# Edit an existing config additively: add/remove providers or change models, one
# operation at a time, each preserving the rest of the file. No overwrite.
_setup_edit_existing() {
  local conf="$1"
  printf 'Editing your config: %s\n(Each change is applied in place — nothing else is touched.)\n\n' "$conf"
  while true; do
    _setup_print_summary "$conf"
    printf '\n'
    # Done leads so the focused default — a bare Enter — finishes; everything
    # below it is the advanced setup.
    local act menu has_vertex=""
    local wp
    while IFS= read -r wp; do
      [[ "$wp" == vertex ]] && has_vertex=1
    done < <(_setup_conf_wizard_providers "$conf")
    menu=$'done\tDone — looks good\n'
    menu+=$'add\tAdd a provider\n'
    menu+=$'remove\tRemove a provider\n'
    menu+="models"$'\t'"Change a provider's models"$'\n'
    # No standalone auth action: "Add a provider" runs auth-assist itself, and
    # a broken setup is recovered via reset. Project selection IS surfaced —
    # it's the vertex edit users actually reach for.
    [[ -n "$has_vertex" ]] && menu+=$'projects\tChange Vertex AI projects (GCP)\n'
    menu+=$'reset\tReset — re-detect providers and start over'
    act=$(_setup_select 'Action (Enter to finish)> ' "$menu") || act="done"
    printf '\n'
    case "$act" in
      add) _setup_action_add "$conf" ;;
      remove) _setup_action_remove "$conf" ;;
      models) _setup_action_models "$conf" ;;
      projects) _setup_change_vertex_projects "$conf" ;;
      # A confirmed reset re-runs the fresh flow, which lands in its own edit
      # loop — return instead of break so this one doesn't re-print on top.
      reset) if _setup_action_reset "$conf"; then return 0; fi ;;
      done | *) break ;;
    esac
    printf '\n'
  done
  printf 'Done. Config saved at %s\n' "$conf"
}

# Best-effort: seed the per-repo default so the next commit/pr has a pick ready
# without prompting. Only meaningful inside a git repo. TOKEN is a wizard
# provider token; the saved pick is its first concrete runnable provider.
_setup_seed_default_provider() {
  local token="$1" first
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  first=$(_setup_expand_provider "$token" | head -n1)
  save_last_provider commit "$first"
  save_last_provider pr "$first"
  printf 'Default provider for this repo set to %s.\n' "$(provider_display_name "$token")"
}

# Fast path for the fresh flow: every provider that already authenticates is
# enabled immediately with its family's recommended model pinned — no questions
# asked. The user then lands on the config overview (the additive edit loop),
# where a bare Enter finishes and the other actions are the advanced setup.
_setup_fast_path() {
  local conf="$1"
  shift
  local -a ready=("$@")
  local p c model recs

  printf 'Detected providers you can use right now — enabling them with recommended models:\n\n'
  local combos=""
  for p in "${ready[@]}"; do
    recs=""
    while IFS= read -r c; do
      model=$(recommended_model "$c")
      combos+="${c}:${model}"$'\n'
      [[ -n "$model" ]] && recs="${recs:+${recs}, }${model}"
    done < <(_setup_expand_provider "$p")
    printf '  ✓ %-14s → %s\n' "$(provider_display_name "$p")" "${recs:-(pick a model later)}"
  done

  # Vertex readiness came from somewhere — a prior config (the reset case) or
  # the environment. Capture those settings BEFORE the overwrite so the fresh
  # config stays self-sufficient; without this a reset would silently strand a
  # "ready" vertex provider with no project to run against.
  local carry_projects="" carry_account="" carry_region="" s
  case " ${ready[*]} " in *" vertex "*)
    # Project priority: the config's own projects/project keys, then the
    # environment, then — last resort — the project detected during the
    # readiness probe (set when vertex entered the ready set on ADC +
    # detection alone).
    carry_projects=$(_setup_current_vertex_projects)
    carry_projects="${carry_projects:-${GOOGLE_VERTEX_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}}"
    carry_projects="${carry_projects:-${SETUP_VERTEX_DETECTED:-}}"
    for s in vertex vertex-anthropic vertex-gemini; do
      [[ -z "$carry_account" ]] && carry_account=$(vertex_resolve "$s" account)
      [[ -z "$carry_region" ]] && carry_region=$(vertex_resolve "$s" region)
    done
    ;;
  esac

  local conf_dir
  conf_dir=$(dirname "$conf")
  mkdir -p "$conf_dir" || die "Cannot create config dir: $conf_dir"
  printf '%s' "$combos" | render_options_conf >"$conf" ||
    die "Failed to write $conf"

  # Restore the captured vertex settings into the shared [vertex] block. The
  # wizard always writes the plural `projects =` key — even for one project —
  # so every later edit (additive attach, replace action) seeds from one place.
  if [[ -n "$carry_projects" ]]; then
    _conf_apply "$conf" conf_set_section_setting vertex projects "$carry_projects"
  fi
  [[ -n "$carry_account" ]] && _conf_apply "$conf" conf_set_section_setting vertex account "$carry_account"
  [[ -n "$carry_region" ]] && _conf_apply "$conf" conf_set_section_setting vertex region "$carry_region"

  printf '\nWrote %s\n' "$conf"

  _setup_seed_default_provider "${ready[0]}"

  # Land on the overview: the edit loop shows the resulting config and offers
  # the advanced actions; its default action is Done, so a bare Enter finishes.
  printf '\n'
  _setup_edit_existing "$conf"

  printf '\nWhen you have changes to commit:  git add -A && git-ai commit\n'
  return 0
}

# Fresh, from-scratch configuration when no options.conf exists yet. Tries the
# one-keystroke fast path first (enable everything already usable); only when
# nothing is ready, or the user declines it, falls back to manual selection.
_setup_fresh() {
  local conf="$1"
  printf 'Configure which LLM providers and models git-ai offers in its picker.\n\n'

  # GIT_AI_NO_SETUP_FAST forces the full manual picker (used by tests and by
  # power users who want every provider offered regardless of readiness).
  if [[ -z "${GIT_AI_NO_SETUP_FAST:-}" ]]; then
    local -a ready=()
    local p
    for p in "${SETUP_PROVIDERS[@]}"; do
      if provider_ready "$p" 2>/dev/null; then
        ready+=("$p")
      elif [[ "$p" == vertex ]] && _vertex_has_auth ""; then
        # ADC works but no project is named anywhere — try to detect one from
        # the account's GCP projects (stashed for the fast path to persist, so
        # readiness claimed here is made real in the written config).
        SETUP_VERTEX_DETECTED=$(_setup_detect_vertex_project)
        [[ -n "$SETUP_VERTEX_DETECTED" ]] && ready+=(vertex)
      fi
    done

    if [[ ${#ready[@]} -gt 0 ]] && _setup_fast_path "$conf" "${ready[@]}"; then
      return 0
    fi
  fi

  _setup_manual "$conf"
}

# Manual selection flow: the full status table, multi-provider pick, and
# per-provider model picking. Reached when no provider is ready yet, or the
# user declined the fast path.
_setup_manual() {
  local conf="$1"

  _setup_status_table

  printf 'Tip: pick as many providers as you want now — you can add more after.\n\n'

  local -a chosen=()
  local p
  while IFS= read -r p; do [[ -n "$p" ]] && chosen+=("$p"); done < <(_setup_pick_providers)
  if [[ ${#chosen[@]} -eq 0 ]]; then
    die "No providers selected — nothing to configure."
  fi

  # Build provider:model lines for the chosen providers. Wizard tokens are
  # expanded to concrete providers here: each vertex model is routed to its
  # internal provider by id.
  local combos="" provider model c
  for provider in "${chosen[@]}"; do
    local got_model=""
    while IFS= read -r model; do
      [[ -n "$model" ]] || continue
      combos+="$(_setup_provider_for_model "$provider" "$model"):${model}"$'\n'
      got_model=1
    done < <(_setup_pick_models "$provider")
    # A provider with no model picked still gets enabled (empty header is valid).
    if [[ -z "$got_model" ]]; then
      while IFS= read -r c; do
        combos+="${c}:"$'\n'
      done < <(_setup_expand_provider "$provider")
    fi
  done

  local conf_dir
  conf_dir=$(dirname "$conf")
  mkdir -p "$conf_dir" || die "Cannot create config dir: $conf_dir"
  printf '%s' "$combos" | render_options_conf >"$conf" ||
    die "Failed to write $conf"
  printf 'Wrote %s\n' "$conf"

  # Authenticate any chosen provider that isn't ready yet.
  printf '\nChecking access:\n'
  for provider in "${chosen[@]}"; do
    _setup_ensure_auth "$provider" "$conf"
  done

  _setup_seed_default_provider "${chosen[0]}"

  # The user just made every choice themselves — no need to re-show them.
  # (The fast path differs: it chooses FOR the user, so it lands on the
  # overview as the consent moment.)
  printf '\nDone. Config saved at %s\n' "$conf"
  printf 'Run "git-ai setup" again anytime to add providers or change models.\n'
  printf '\nWhen you have changes to commit:  git add -A && git-ai commit\n'
}

# Detect a second git-ai install that may shadow this one and offer to remove
# it. Targets the identifiable case: a stale `waxmard-git-ai` npm global. We
# only offer to remove installs we can positively attribute to npm; anything
# else on PATH we leave alone. Best-effort and silent when npm is absent or no
# duplicate is found.
_setup_check_shadow() {
  command -v npm >/dev/null 2>&1 || return 0
  local groot
  groot=$(npm root -g 2>/dev/null) || return 0
  [[ -n "$groot" && -d "$groot/waxmard-git-ai" ]] || return 0

  printf 'Heads up: an npm-global git-ai is also installed:\n'
  printf '  %s\n' "$groot/waxmard-git-ai"

  # Note when that npm copy is what PATH actually resolves (i.e. it shadows the
  # make-install symlink). npm's bin dir is $(npm prefix -g)/bin.
  local gprefix on_path
  gprefix=$(npm prefix -g 2>/dev/null)
  on_path=$(command -v git-ai 2>/dev/null)
  if [[ -n "$gprefix" && "$on_path" == "$gprefix/bin/git-ai" ]]; then
    printf '  It currently shadows this install on your PATH.\n'
  fi

  local ans
  read -rp '  Remove it with "npm rm -g waxmard-git-ai"? [y/N]: ' ans
  case "$ans" in
    y | Y | yes | Yes)
      if npm rm -g waxmard-git-ai; then
        printf '  Removed. Re-open your shell so PATH re-resolves git-ai.\n\n'
      else
        printf '  npm rm failed — remove it manually.\n\n'
      fi
      ;;
    *) printf '  Left as-is. Ensure ~/.local/bin precedes the npm bin on PATH.\n\n' ;;
  esac
}
