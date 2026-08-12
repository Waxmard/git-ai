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

# Memoized readiness tag ("ready" / "setup") for PROVIDER. provider_ready shells
# out to keychains and gcloud, so each provider is probed at most once per
# wizard run. The label builders below run inside command substitution, where a
# cache write would be discarded — callers warm the cache first via
# _setup_warm_ready.
_SETUP_READY_CACHE=$'\n'
_setup_ready_tag() {
  local p="$1" rest tag
  case "$_SETUP_READY_CACHE" in
    *$'\n'"$p="*)
      rest="${_SETUP_READY_CACHE#*$'\n'"$p="}"
      printf '%s' "${rest%%$'\n'*}"
      return 0
      ;;
  esac
  if provider_ready "$p" 2>/dev/null; then tag=ready; else tag=setup; fi
  _SETUP_READY_CACHE+="$p=$tag"$'\n'
  printf '%s' "$tag"
}

_setup_warm_ready() {
  local p
  for p in "$@"; do _setup_ready_tag "$p" >/dev/null; done
}

# Drop PROVIDER's memoized tag so the next label re-probes — auth-assist can make
# a provider ready mid-run, and the wizard keeps drawing pickers after that.
_setup_ready_forget() {
  local p="$1" head tail
  case "$_SETUP_READY_CACHE" in
    *$'\n'"$p="*)
      head="${_SETUP_READY_CACHE%%$'\n'"$p="*}"
      tail="${_SETUP_READY_CACHE#*$'\n'"$p="}"
      _SETUP_READY_CACHE="$head"$'\n'"${tail#*$'\n'}"
      ;;
  esac
}

# Picker label for PROVIDER: display name plus its readiness, so a pick that
# will immediately demand an API key is visible before it's made.
_setup_provider_label() {
  local tag
  tag=$(_setup_ready_tag "$1")
  if [[ "$tag" == ready ]]; then
    printf '%s  [ready]\n' "$(provider_display_name "$1")"
  else
    printf '%s  [needs setup]\n' "$(provider_display_name "$1")"
  fi
}

# Print the readiness status table for every provider.
_setup_status_table() {
  local p reason
  printf 'Detected providers:\n\n'
  for p in "${SETUP_PROVIDERS[@]}"; do
    if reason=$(provider_ready "$p" 2>&1 1>/dev/null); then
      _SETUP_READY_CACHE+="$p=ready"$'\n'
      printf '  [ready]  %s\n' "$(provider_display_name "$p")"
    else
      _SETUP_READY_CACHE+="$p=setup"$'\n'
      printf '  [setup]  %-22s — %s\n' "$(provider_display_name "$p")" "$reason"
    fi
  done
  printf '\n'
}

# True when the wizard should drive selections through fzf.
_setup_has_fzf() {
  command -v fzf >/dev/null 2>&1 && [[ -z "${GIT_AI_NO_FZF:-}" ]]
}

# Shared fzf look-and-feel, so the provider, model, and project pickers don't
# each behave differently. Per-picker flags (--multi, --delimiter, --with-nth,
# --header, --prompt) stay at the call site.
SETUP_FZF_OPTS=(--height=40% --reverse --cycle --border --no-sort --tiebreak=index)

# Pick one or more providers. Prefers fzf; falls back to a numbered prompt.
# Prints chosen provider tokens, one per line.
_setup_pick_providers() {
  local p line
  _setup_warm_ready "${SETUP_PROVIDERS[@]}"
  if _setup_has_fzf; then
    for p in "${SETUP_PROVIDERS[@]}"; do
      printf '%s|%s\n' "$p" "$(_setup_provider_label "$p")"
    done | env -u FZF_DEFAULT_OPTS -u FZF_DEFAULT_OPTS_FILE \
      fzf --multi --delimiter='|' --with-nth=2 "${SETUP_FZF_OPTS[@]}" \
      --header='Tab marks a provider; Enter confirms; Esc cancels' \
      --prompt='enable providers> ' |
      while IFS='|' read -r p _; do printf '%s\n' "$p"; done
    return
  fi

  # Numbered fallback.
  local i=1
  for p in "${SETUP_PROVIDERS[@]}"; do
    printf '  %d) %s\n' "$i" "$(_setup_provider_label "$p")" >&2
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
# provider's API (cached) and offered as suggestions, with the family's
# recommended id(s) pre-marked so the common case is a bare Enter. Prints chosen
# model IDs, one per line — empty output is valid (the provider is enabled with
# no pinned model and the model is chosen at commit/pr time).
_setup_pick_models() {
  local provider="$1" listed line m st
  listed=$(_setup_suggest_models "$provider")

  if [[ -n "$listed" ]]; then
    local rows selected want_custom=""
    rows=$(_setup_model_rows "$provider" "$listed")
    selected=$(_setup_multiselect "models for $(provider_display_name "$provider")> " \
      'Recommended start marked — Tab to add/drop; Enter confirms; Esc picks none' \
      '— no model (pick one at commit time) —' "$rows" "$SETUP_PRESELECT_RECOMMENDED")
    st=$?
    # Cancel and a confirmed-empty pick collapse here: nothing is configured yet,
    # so there is no current set for "cancel" to preserve.
    [[ $st -eq 0 ]] || return 0
    # The picker's answer is final: unlisted ids go via its explicit custom row,
    # which emits any models marked alongside it and then drops to the prompt.
    while IFS= read -r m; do
      [[ -n "$m" ]] || continue
      if [[ "$m" == '=custom=' ]]; then want_custom=1; else printf '%s\n' "$m"; fi
    done <<<"$selected"
    [[ -n "$want_custom" ]] || return 0
  fi

  # Reached via the explicit custom-id row, or when the provider has no
  # discoverable models (e.g. claude-code/codex without a key). Blank = leave
  # the provider with no pinned model.
  read -rp "Model id(s) for $(provider_display_name "$provider"), comma-separated (blank for none): " line || line=""
  [[ -n "$line" ]] || return 0
  while IFS= read -r m; do
    m=$(_trim "$m")
    [[ -n "$m" ]] && printf '%s\n' "$m"
  done < <(printf '%s\n' "${line//,/$'\n'}")
}

# _setup_multiselect PROMPT HEADER SKIP_LABEL ROWS [PRESELECT_QUERY]
# Multi-select over "value|label" ROWS, led by a skip sentinel so a bare Enter
# with nothing marked resolves to the empty set — fzf otherwise returns the
# focused row. Prints the marked values one per line and returns:
#   0 — confirmed; empty output means the user deliberately chose nothing
#   2 — cancelled (Esc / ctrl-c); callers keep whatever is configured now
# That 0-vs-2 split is what makes "unpin everything" reachable: collapsing both
# to empty output leaves a replace-style editor unable to tell "clear it" from
# "leave it alone". fzf drives it when available, the numbered picker otherwise.
# FZF_DEFAULT_OPTS is cleared so a user's keybindings can't auto-select.
#
# PRESELECT_QUERY is an fzf query (matched against the *labels*, since
# --with-nth=2 makes the label the searchable string) whose matches are marked
# on load before the query is cleared — fzf's only way to open with rows already
# selected. The numbered picker marks the same rows by substring-matching the
# query's literal tail. Editors use it so the set worth keeping arrives
# pre-marked and the gesture is unmarking what to drop. The sentinel must never
# match it.
_setup_multiselect() {
  local prompt="$1" header="$2" skip_label="$3" rows="$4" preselect="${5:-}"
  if ! _setup_has_fzf; then
    _setup_multiselect_numbered "$prompt" "$header" "$skip_label" "$rows" "$preselect"
    return $?
  fi
  local selected v st
  local -a preselect_opts=()
  [[ -n "$preselect" ]] &&
    preselect_opts=(--query="$preselect" --bind='load:select-all+clear-query')
  selected=$(printf '—|%s\n%s' "$skip_label" "$rows" \
    | env -u FZF_DEFAULT_OPTS -u FZF_DEFAULT_OPTS_FILE fzf --multi \
      --delimiter='|' --with-nth=2 "${SETUP_FZF_OPTS[@]}" \
      --header="$header" --prompt="$prompt" \
      ${preselect_opts[@]+"${preselect_opts[@]}"})
  st=$?
  [[ $st -eq 0 ]] || return 2
  while IFS='|' read -r v _; do
    [[ -n "$v" && "$v" != "—" ]] && printf '%s\n' "$v"
  done <<<"$selected"
  return 0
}

# Numbered stand-in for _setup_multiselect on terminals without fzf: same
# contract (0 confirmed / 2 cancelled), same sentinel, same preselection —
# pre-marked rows show "[x]" and a bare Enter keeps exactly them, so accepting
# the suggested set costs one keystroke here too. Prompts go to stderr because
# stdout is the value channel.
_setup_multiselect_numbered() {
  local prompt="$1" header="$2" skip_label="$3" rows="$4" preselect="${5:-}"
  # The preselect query is an fzf exact-match token ("'(current)"); its literal
  # tail is what the labels actually contain.
  local mark="${preselect#\'}"
  local -a vals=("—") labels=("$skip_label") marked=("")
  local v l i n box reply
  while IFS='|' read -r v l; do
    [[ -n "$v" ]] || continue
    vals+=("$v")
    labels+=("${l:-$v}")
    if [[ -n "$mark" && "$l" == *"$mark"* ]]; then marked+=(1); else marked+=(""); fi
  done <<<"$rows"
  [[ ${#vals[@]} -gt 1 ]] || return 2

  printf '%s\n' "$header" >&2
  printf '   0) cancel — keep as-is\n' >&2
  for i in "${!vals[@]}"; do
    if [[ -n "${marked[$i]}" ]]; then box=x; else box=' '; fi
    printf '  %2d) [%s] %s\n' "$((i + 1))" "$box" "${labels[$i]}" >&2
  done
  read -rp "${prompt}(numbers space-separated; Enter keeps [x]; 0 cancels) " reply || return 2

  if [[ -z "${reply//[[:space:]]/}" ]]; then
    for i in "${!vals[@]}"; do
      [[ -n "${marked[$i]}" && "${vals[$i]}" != "—" ]] && printf '%s\n' "${vals[$i]}"
    done
    return 0
  fi
  for n in $reply; do [[ "$n" == 0 ]] && return 2; done
  for n in $reply; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    ((n >= 1 && n <= ${#vals[@]})) || continue
    [[ "${vals[$((n - 1))]}" != "—" ]] && printf '%s\n' "${vals[$((n - 1))]}"
  done
  return 0
}

# PRESELECT_QUERY values: fzf's exact-match operator (') against the label
# suffix each picker tags its already-good rows with.
SETUP_PRESELECT_CURRENT="'(current)"
SETUP_PRESELECT_RECOMMENDED="'(recommended)"

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
        --delimiter=$'\t' --with-nth=2 "${SETUP_FZF_OPTS[@]}" \
        --prompt="$prompt") || return 1
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
  _setup_warm_ready "$@"
  local p data=""
  for p in "$@"; do data+="${p}"$'\t'"$(_setup_provider_label "$p")"$'\n'; done
  _setup_select "$prompt" "$data"
}

# ---------------------------------------------------------------------------
# Config overview + in-place edit actions live in setup-edit.sh, key/CLI
# auth-assist in setup-auth.sh, the Vertex AI project discovery/picker + vertex
# auth-assist in setup-vertex.sh, and the shadow-install detection in
# setup-shadow.sh (all kept under the repo's per-file line limit). Sourced here
# so the full wizard surface is available whether bin/git-ai or a test sources
# setup.sh.
# ---------------------------------------------------------------------------
_SETUP_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib/setup-edit.sh
source "${_SETUP_DIR}/setup-edit.sh"
# shellcheck source=lib/setup-auth.sh
source "${_SETUP_DIR}/setup-auth.sh"
# shellcheck source=lib/setup-vertex.sh
source "${_SETUP_DIR}/setup-vertex.sh"
# shellcheck source=lib/setup-shadow.sh
source "${_SETUP_DIR}/setup-shadow.sh"

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
# provider token; the saved pick is its first concrete runnable provider —
# profile-qualified for vertex, whose project lives in the profile.
_setup_seed_default_provider() {
  local token="$1" conf="${2:-$(user_options_path)}" first pr
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  first=$(_setup_expand_provider "$token" | head -n1)
  if [[ "$token" == vertex ]]; then
    pr=$(vertex_section_projects "$conf" | head -n1)
    [[ -n "$pr" ]] && first="${first}@${pr}"
  fi
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
  local p c model recs pr

  # Vertex readiness came from somewhere — a prior config (the reset case) or
  # the environment. Capture those settings BEFORE the overwrite so the fresh
  # config stays self-sufficient; without this a reset would silently strand a
  # "ready" vertex provider with no project to run against.
  local carry_projects="" carry_account="" carry_region="" s
  local -a projects=()
  case " ${ready[*]} " in *" vertex "*)
    # Project priority: the config's own per-project sections and project keys,
    # then the environment, then — last resort — the project detected during the
    # readiness probe (set when vertex entered the ready set on ADC +
    # detection alone).
    carry_projects=$(_setup_current_vertex_projects "$conf")
    carry_projects="${carry_projects:-${GOOGLE_VERTEX_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}}"
    carry_projects="${carry_projects:-${SETUP_VERTEX_DETECTED:-}}"
    while IFS= read -r pr; do projects+=("$pr"); done \
      < <(_setup_split_projects "$carry_projects")
    for s in vertex vertex-anthropic vertex-gemini; do
      [[ -z "$carry_account" ]] && carry_account=$(vertex_resolve "$s" account)
      [[ -z "$carry_region" ]] && carry_region=$(vertex_resolve "$s" region)
    done
    ;;
  esac

  # A profile carried above by its section suffix may target a different real
  # GCP project via a hand-written `project =` override — capture that BEFORE
  # the overwrite below, or the rewritten profile would silently point at the
  # suffix itself instead of the project it used to run against.
  local -a carry_overrides=()
  local fam ov
  for pr in "${projects[@]}"; do
    for fam in vertex-gemini vertex-anthropic; do
      ov=$(vertex_config_value "${fam}@${pr}" project)
      [[ -n "$ov" && "$ov" != "$pr" ]] && carry_overrides+=("${fam}@${pr}"$'\t'"${ov}")
    done
  done

  printf 'Detected providers you can use right now — enabling them with recommended models:\n\n'
  local combos=""
  for p in "${ready[@]}"; do
    recs=""
    while IFS= read -r c; do
      model=$(recommended_model "$c")
      # Vertex pins per project, so each known project gets its own section.
      if [[ "$p" == vertex && ${#projects[@]} -gt 0 ]]; then
        for pr in "${projects[@]}"; do combos+="${c}@${pr}:${model}"$'\n'; done
      else
        combos+="${c}:${model}"$'\n'
      fi
      [[ -n "$model" ]] && recs="${recs:+${recs}, }${model}"
    done < <(_setup_expand_provider "$p")
    printf '  ✓ %-14s → %s%s\n' "$(provider_display_name "$p")" \
      "${recs:-(pick a model later)}" \
      "$([[ "$p" == vertex && ${#projects[@]} -gt 0 ]] && printf ' (projects: %s)' "$(_join_comma "${projects[@]}")")"
  done

  local conf_dir
  conf_dir=$(dirname "$conf")
  mkdir -p "$conf_dir" || die "Cannot create config dir: $conf_dir"
  printf '%s' "$combos" | render_options_conf | _conf_write_fresh "$conf" ||
    die "Failed to write $conf"

  # Restore the captured vertex settings into the shared [vertex] block, which
  # every per-project section inherits from.
  [[ -n "$carry_account" ]] && _conf_apply "$conf" conf_set_section_setting vertex account "$carry_account"
  [[ -n "$carry_region" ]] && _conf_apply "$conf" conf_set_section_setting vertex region "$carry_region"

  # Restore any per-profile project override onto the freshly written section —
  # the profile was carried above by its suffix, so without this the rewrite
  # would target that suffix as the project instead of what it actually named.
  local entry
  for entry in ${carry_overrides[@]+"${carry_overrides[@]}"}; do
    _setup_conf_has_section "$conf" "${entry%%$'\t'*}" &&
      _conf_apply "$conf" conf_set_section_setting "${entry%%$'\t'*}" project "${entry#*$'\t'}"
  done

  printf '\nWrote %s\n' "$conf"

  _setup_seed_default_provider "${ready[0]}" "$conf"

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
  # Backing out of the first picker is a normal "not now", not an error — the
  # wizard also auto-launches on first commit, where dying would fail the commit.
  if [[ ${#chosen[@]} -eq 0 ]]; then
    printf 'No providers selected — nothing written.\n'
    printf 'Run "git-ai setup" whenever you are ready (GIT_AI_NO_SETUP=1 silences the prompt).\n'
    return 0
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
  printf '%s' "$combos" | render_options_conf | _conf_write_fresh "$conf" ||
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
