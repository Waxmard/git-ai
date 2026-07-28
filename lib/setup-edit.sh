#!/bin/bash
# setup-edit.sh - git-ai setup: config overview + in-place edit actions (conf_*-driven). Sourced via lib/setup.sh.

# Apply a surgical conf filter (conf_add_section / conf_remove_section / …) to
# CONF in place via a temp file, so a failed edit never truncates the config.
_conf_apply() {
  local conf="$1"
  shift
  local tmp
  # Temp file in the target's own dir so `mv` is a same-filesystem atomic rename
  # (a bare mktemp lands in $TMPDIR and degrades to a cross-device copy+delete).
  tmp=$(mktemp "$(dirname "$conf")/git-ai-conf.XXXXXX") || { printf 'edit failed (mktemp)\n' >&2; return 1; }
  if "$@" <"$conf" >"$tmp"; then
    mv "$tmp" "$conf"
  else
    rm -f "$tmp"
    printf 'edit failed\n' >&2
    return 1
  fi
}

# Atomically write stdin to CONF via a temp file + mv, so an interrupted write
# never leaves a truncated or empty config. Used by the fresh-setup paths, where
# `>"$conf"` would truncate before the new content lands.
_conf_write_fresh() {
  local conf="$1" tmp
  # Same-filesystem temp (see _conf_apply) so the mv below is an atomic rename.
  tmp=$(mktemp "$(dirname "$conf")/git-ai-conf.XXXXXX") || { printf 'write failed (mktemp)\n' >&2; return 1; }
  if cat >"$tmp"; then
    mv "$tmp" "$conf"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Join arguments with ", ".
_join_comma() {
  local joined
  joined=$(printf '%s, ' "$@")
  printf '%s' "${joined%, }"
}

# _merge_vertex_projects CURRENT NEW...
# Merge NEW project ids into the comma-separated CURRENT list (current order
# preserved, additions appended, deduped). Prints the merged comma list.
_merge_vertex_projects() {
  local current="$1" p
  shift
  local -a merged=()
  local seen=$'\n'
  while IFS= read -r p; do
    p=$(_trim "$p")
    [[ -n "$p" && "$seen" != *$'\n'"$p"$'\n'* ]] || continue
    merged+=("$p")
    seen+="$p"$'\n'
  done < <(
    printf '%s\n' "${current//,/$'\n'}"
    [[ $# -gt 0 ]] && printf '%s\n' "$@"
  )
  _join_comma ${merged[@]+"${merged[@]}"}
}

# For the merged `vertex` summary row, format a trailing " (project: …)" suffix
# (plus the pinned gcloud account when set) so the summary identifies the GCP
# project/account pair a vertex provider runs against. Empty for everything
# else — _setup_conf_wizard_providers always folds the internal sections to the
# `vertex` token, so that's the only vertex spelling that arrives here.
_setup_vertex_summary_detail() {
  [[ "$1" == vertex ]] || return 0
  local raw account detail="" pr s

  raw=$(_setup_current_vertex_projects)
  local -a projs=()
  while IFS= read -r pr || [[ -n "$pr" ]]; do [[ -n "$pr" ]] && projs+=("$pr"); done < <(printf '%s' "$raw" | tr ', ' '\n')
  if [[ ${#projs[@]} -gt 1 ]]; then
    detail+=" (projects: $(_join_comma "${projs[@]}"))"
  elif [[ ${#projs[@]} -eq 1 ]]; then
    detail+=" (project: ${projs[0]})"
  fi

  # The account can live in the shared [vertex] block or either internal section.
  for s in vertex vertex-anthropic vertex-gemini; do
    account=$(vertex_resolve "$s" account)
    [[ -n "$account" ]] && break
  done
  [[ -n "$account" ]] && detail+=" [account: ${account}]"
  printf '%s' "$detail"
}

_setup_print_summary() {
  local conf="$1" p any=0 models name
  printf 'Configured providers:\n'
  while IFS= read -r p; do
    any=1
    # Models pinned under this entry (deduped, @profiles folded to base; the
    # vertex entry folds both internal sections into one row).
    models=$(_setup_existing_models "$p" | paste -sd, - | sed 's/,/, /g')
    name="$(provider_display_name "$p")$(_setup_vertex_summary_detail "$p")"
    if [[ -n "$models" ]]; then
      printf '  • %s — %s\n' "$name" "$models"
    else
      printf '  • %s — no models pinned (hidden from the picker until you add one)\n' \
        "$name"
    fi
  done < <(_setup_conf_wizard_providers "$conf")
  [[ $any -eq 1 ]] || printf '  (none)\n'
}

# Set up a provider that isn't usable yet. A provider counts as "set up" only
# once it has >=1 pinned model — so this offers every provider that is absent OR
# present-but-empty (an empty section is practically "not configured").
_setup_action_add() {
  local conf="$1" p prov m
  # Providers that already have a pinned model (exclude these from the list).
  local with_models=$'\n'
  while IFS=: read -r prov _; do
    [[ -n "$prov" ]] && with_models+="${prov%%@*}"$'\n'
  done < <(parse_user_options)

  local -a cands=()
  for p in "${SETUP_PROVIDERS[@]}"; do
    case "$p" in
      # Vertex is a (project/account) pair, so it's always re-offered here even
      # when already configured — adding it again lets the user attach another
      # GCP project/account to the existing sections.
      vertex) cands+=("$p") ;;
      *) case "$with_models" in *$'\n'"$p"$'\n'*) ;; *) cands+=("$p") ;; esac ;;
    esac
  done
  local provider
  provider=$(_setup_choose_provider 'Set up which provider? ' "${cands[@]}") || { printf 'Cancelled.\n'; return 0; }

  # Present section → replace-style model edit. Truly absent → append a new
  # section. Either way no duplicate [provider] header is created.
  local present=$'\n'
  while IFS= read -r p; do present+="$p"$'\n'; done < <(_setup_conf_wizard_providers "$conf")
  if [[ "$present" == *$'\n'"$provider"$'\n'* ]]; then
    # Re-adding an already-configured vertex means "attach another GCP project",
    # so go straight to the project picker. Models live in the shared
    # [vertex-gemini]/[vertex-anthropic] sections and parse_user_options expands
    # them across every project in the list — the new project inherits the
    # existing pins with no re-pick. Dropping some is a later, separate edit.
    if [[ "$provider" == vertex ]]; then
      _setup_choose_vertex_projects "$provider" "$conf"
      local inherited
      inherited=$(_setup_existing_models vertex | paste -sd, - | sed 's/,/, /g')
      [[ -n "$inherited" ]] &&
        printf 'Models carried over to every project: %s\n' "$inherited"
      _setup_ensure_auth "$provider" "$conf"
      return 0
    fi
    _setup_change_models "$conf" "$provider"
  else
    local -a models=()
    while IFS= read -r m; do [[ -n "$m" ]] && models+=("$m"); done < <(_setup_pick_models "$provider")
    if [[ "$provider" == vertex ]]; then
      if [[ ${#models[@]} -gt 0 ]]; then
        _setup_write_vertex_models "$conf" "${models[@]}"
      else
        # Enabled with nothing pinned: both internal sections, empty (valid —
        # hidden from the picker until a model is added).
        _conf_apply "$conf" conf_add_section vertex-anthropic &&
          _conf_apply "$conf" conf_add_section vertex-gemini
      fi &&
        printf 'Added %s.\n' "$(provider_display_name "$provider")"
    else
      _conf_apply "$conf" conf_add_section "$provider" ${models[@]+"${models[@]}"} &&
        printf 'Added %s.\n' "$(provider_display_name "$provider")"
    fi
  fi
  _setup_choose_vertex_projects "$provider" "$conf"
  _setup_ensure_auth "$provider" "$conf"
}

# The projects the config currently names, as a comma list: the shared
# [vertex] `projects =` list, falling back to a stray singular `project =`
# (shared block or either internal section — hand-written configs may use it).
# Every wizard projects edit seeds from this so no key is ever overlooked.
_setup_current_vertex_projects() {
  local cur s
  cur=$(vertex_config_value vertex projects)
  if [[ -z "$cur" ]]; then
    for s in vertex vertex-anthropic vertex-gemini; do
      cur=$(vertex_resolve "$s" project)
      [[ -n "$cur" ]] && break
    done
  fi
  printf '%s' "$cur"
}

# For a vertex provider, let the user pick which GCP project(s) it runs against,
# merged into the shared [vertex] `projects =` list (expanded into per-project
# picker profiles at commit time) — picks never drop projects already listed.
# Shared across both vertex providers by design; a blank pick keeps the current
# list. No-op for non-vertex providers.
_setup_choose_vertex_projects() {
  local provider="$1" conf="$2"
  case "${provider%%@*}" in vertex | vertex-gemini | vertex-anthropic) ;; *) return 0 ;; esac

  local current
  current=$(_setup_current_vertex_projects)
  [[ -n "$current" ]] && printf 'Current vertex projects: %s\n' "$current"

  local -a projs=()
  local pr
  while IFS= read -r pr; do projs+=("$pr"); done < <(_setup_pick_projects)
  [[ ${#projs[@]} -gt 0 ]] || { printf 'Vertex projects unchanged.\n'; return 0; }

  # Additive like everything else in the wizard: picking a project attaches it
  # alongside the ones already configured; removal stays a manual config edit.
  local joined
  joined=$(_merge_vertex_projects "$current" "${projs[@]}")
  if [[ "$joined" == "$current" ]]; then
    printf 'Vertex projects unchanged: %s\n' "$joined"
    return 0
  fi
  _conf_apply "$conf" conf_set_section_setting vertex projects "$joined" &&
    printf 'Set vertex projects: %s\n' "$joined"
}

# Replace-style editor behind the menu's "Change Vertex AI projects": one
# multi-select over the union of the current list (labelled, listed first) and
# the account's gcloud projects — the marked set REPLACES the list, so a single
# gesture both adds and removes. Esc / nothing marked keeps the current list;
# the no-fzf fallback is a comma-list re-entry (blank keeps current).
_setup_change_vertex_projects() {
  local conf="$1" current p
  current=$(_setup_current_vertex_projects)
  [[ -n "$current" ]] && printf 'Current vertex projects: %s\n' "$current"

  # Union: current entries first (labelled "(current)"), then every project the
  # machine's gcloud logins can see, then the custom-id row — a project none of
  # those logins can list is the normal reason to be here, so there must always
  # be a way to type one.
  local rows="" seen=$'\n' preselect="" discovered
  while IFS= read -r p; do
    p=$(_trim "$p")
    [[ -n "$p" && "$seen" != *$'\n'"$p"$'\n'* ]] || continue
    seen+="$p"$'\n'
    rows+="${p}|${p} (current)"$'\n'
    preselect="$SETUP_PRESELECT_CURRENT"
  done < <(printf '%s\n' "${current//,/$'\n'}")
  discovered=$(_setup_project_rows "$seen")
  [[ -n "$discovered" ]] && rows+="${discovered}"$'\n'
  rows+="$SETUP_CUSTOM_PROJECT_ROW"

  local -a picked=()
  local selected want_custom="" line pseen=$'\n'
  if selected=$(_setup_multiselect 'vertex projects> ' \
      'Current projects start marked — Tab to add/drop; Enter saves the marked set; Esc keeps current' \
      '— keep current list —' "$rows" "$preselect"); then
    while IFS= read -r p; do
      [[ -n "$p" && "$pseen" != *$'\n'"$p"$'\n'* ]] || continue
      if [[ "$p" == '=custom=' ]]; then want_custom=1; else picked+=("$p"); pseen+="$p"$'\n'; fi
    done <<<"$selected"
    if [[ -n "$want_custom" ]]; then
      read -rp 'Additional project id(s), comma-separated: ' line || line=""
      while IFS= read -r p; do
        p=$(_trim "$p")
        [[ -n "$p" && "$pseen" != *$'\n'"$p"$'\n'* ]] && { picked+=("$p"); pseen+="$p"$'\n'; }
      done < <(printf '%s\n' "${line//,/$'\n'}")
    fi
  else
    read -rp 'Projects to keep, comma-separated (blank to keep current): ' line || line=""
    while IFS= read -r p; do
      p=$(_trim "$p")
      [[ -n "$p" && "$pseen" != *$'\n'"$p"$'\n'* ]] && { picked+=("$p"); pseen+="$p"$'\n'; }
    done < <(printf '%s\n' "${line//,/$'\n'}")
  fi

  if [[ ${#picked[@]} -eq 0 ]]; then
    printf 'Vertex projects unchanged%s.\n' "${current:+: $current}"
    return 0
  fi

  local joined
  joined=$(_join_comma "${picked[@]}")
  if [[ "$joined" == "$current" ]]; then
    printf 'Vertex projects unchanged: %s\n' "$joined"
    return 0
  fi
  _conf_apply "$conf" conf_set_section_setting vertex projects "$joined" &&
    printf 'Set vertex projects: %s\n' "$joined"
}

# Remove a provider section (preserving the rest of the file). Removing the
# wizard's `vertex` entry drops both internal sections plus the shared [vertex]
# settings block — nothing vertex-related is left behind.
_setup_action_remove() {
  local conf="$1" p
  local -a secs=()
  while IFS= read -r p; do secs+=("$p"); done < <(_setup_conf_wizard_providers "$conf")
  local provider
  provider=$(_setup_choose_provider 'Remove which provider? ' "${secs[@]}") || { printf 'Cancelled.\n'; return 0; }
  if [[ "$provider" == vertex ]]; then
    _conf_apply "$conf" conf_remove_section vertex-anthropic &&
      _conf_apply "$conf" conf_remove_section vertex-gemini &&
      _conf_apply "$conf" conf_remove_section vertex
  else
    _conf_apply "$conf" conf_remove_section "$provider"
  fi &&
    printf 'Removed %s.\n' "$(provider_display_name "$provider")"
}

# Print the models currently pinned under PROVIDER's base section (deduped),
# folding any @profile expansions back to the base. For the wizard's `vertex`
# token, both internal vertex sections fold together. Used to merge rather
# than overwrite when adding models.
_setup_existing_models() {
  parse_user_options | awk -F: -v p="$1" '{
    split($1, a, "@"); b = a[1]
    if (p == "vertex" && (b == "vertex-gemini" || b == "vertex-anthropic")) b = "vertex"
    if (b == p && $2 != "" && !seen[$2]++) print $2
  }'
}

# _setup_upsert_section_models CONF PROVIDER [MODEL...]
# Write MODELS as [PROVIDER]'s pinned set: replace the model lines of a present
# section (clearing them when MODELS is empty — needed so a replace-style edit
# can drop one vertex family's pins entirely), append a new section only when
# it has models — an absent section is never created empty.
_setup_upsert_section_models() {
  local conf="$1" provider="$2"
  shift 2
  local p present=0
  while IFS= read -r p; do
    [[ "$p" == "$provider" ]] && present=1
  done < <(conf_section_providers <"$conf")
  if [[ $present -eq 1 ]]; then
    _conf_apply "$conf" conf_set_section_models "$provider" "$@"
  elif [[ $# -gt 0 ]]; then
    _conf_apply "$conf" conf_add_section "$provider" "$@"
  fi
}

# Split MODELS by family and write each subset into its internal vertex section
# (creating sections only when they get models). This is how the wizard's
# single "Vertex AI" hides the vertex-gemini/vertex-anthropic split.
_setup_write_vertex_models() {
  local conf="$1" m
  shift
  local -a anth=() gem=()
  for m in "$@"; do
    case "$(_setup_provider_for_model vertex "$m")" in
      vertex-anthropic) anth+=("$m") ;;
      *) gem+=("$m") ;;
    esac
  done
  _setup_upsert_section_models "$conf" vertex-anthropic ${anth[@]+"${anth[@]}"} &&
    _setup_upsert_section_models "$conf" vertex-gemini ${gem[@]+"${gem[@]}"}
}

# Replace-style model editor (mirrors _setup_change_vertex_projects): one
# multi-select over the union of the models currently pinned (labelled
# "(current)", listed first) and the discovered catalog — the marked set
# REPLACES the provider's pins, so a single gesture adds *and* removes.
# Esc / nothing marked keeps the current pins; the custom-id row adds unlisted
# ids to the marked set; the no-fzf fallback is a comma-list re-entry (blank
# keeps current). Clearing every model is done via remove-provider.
_setup_change_models() {
  local conf="$1" provider="$2" m
  local current
  current=$(_setup_existing_models "$provider" | paste -sd, - | sed 's/,/, /g')
  [[ -n "$current" ]] && printf 'Current models: %s\n' "$current"

  local -a picked=()
  local selected want_custom="" line pseen=$'\n'
  if _setup_has_fzf; then
    # Union: current pins first (labelled "(current)"), then the suggestion
    # rows. Built only on the fzf path — the free-text fallback never shows
    # suggestions, so don't pay for discovery there.
    local rows="" seen=$'\n' lbl preselect=""
    while IFS= read -r m; do
      [[ -n "$m" && "$seen" != *$'\n'"$m"$'\n'* ]] || continue
      seen+="$m"$'\n'
      rows+="${m}|${m} (current)"$'\n'
      preselect="$SETUP_PRESELECT_CURRENT"
    done < <(_setup_existing_models "$provider")
    while IFS='|' read -r m lbl; do
      [[ -n "$m" && "$seen" != *$'\n'"$m"$'\n'* ]] || continue
      [[ "$m" != '=custom=' ]] && seen+="$m"$'\n'
      rows+="${m}|${lbl}"$'\n'
    done < <(_setup_model_rows "$provider" "$(_setup_suggest_models "$provider")")

    selected=$(_setup_multiselect "models for $(provider_display_name "$provider")> " \
      'Current pins start marked — Tab to add/drop; Enter saves the marked set; Esc keeps current' \
      '— keep current models —' "$rows" "$preselect")
    while IFS= read -r m; do
      [[ -n "$m" && "$pseen" != *$'\n'"$m"$'\n'* ]] || continue
      if [[ "$m" == '=custom=' ]]; then want_custom=1; else picked+=("$m"); pseen+="$m"$'\n'; fi
    done <<<"$selected"
    if [[ -n "$want_custom" ]]; then
      read -rp 'Additional model id(s), comma-separated: ' line || line=""
      while IFS= read -r m; do
        m=$(_trim "$m")
        [[ -n "$m" && "$pseen" != *$'\n'"$m"$'\n'* ]] && { picked+=("$m"); pseen+="$m"$'\n'; }
      done < <(printf '%s\n' "${line//,/$'\n'}")
    fi
  else
    read -rp 'Models to keep, comma-separated (blank to keep current): ' line || line=""
    while IFS= read -r m; do
      m=$(_trim "$m")
      [[ -n "$m" && "$pseen" != *$'\n'"$m"$'\n'* ]] && { picked+=("$m"); pseen+="$m"$'\n'; }
    done < <(printf '%s\n' "${line//,/$'\n'}")
  fi

  if [[ ${#picked[@]} -eq 0 ]]; then
    printf 'Models unchanged%s.\n' "${current:+: $current}"
    return 0
  fi

  if [[ "$provider" == vertex ]]; then
    _setup_write_vertex_models "$conf" "${picked[@]}"
  else
    _conf_apply "$conf" conf_set_section_models "$provider" "${picked[@]}"
  fi &&
    printf 'Set models for %s: %s\n' \
      "$(provider_display_name "$provider")" "$(_join_comma "${picked[@]}")"
}

# Change an existing provider's models (replace-style — see _setup_change_models).
_setup_action_models() {
  local conf="$1" p
  local -a secs=()
  while IFS= read -r p; do secs+=("$p"); done < <(_setup_conf_wizard_providers "$conf")
  local provider
  provider=$(_setup_choose_provider 'Change models for which provider? ' "${secs[@]}") || { printf 'Cancelled.\n'; return 0; }
  _setup_change_models "$conf" "$provider"
}
