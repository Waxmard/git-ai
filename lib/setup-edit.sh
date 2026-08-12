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

# Trailing " [account: …]" for the vertex summary row. The account can live in
# the shared [vertex] block or either internal section.
_setup_vertex_account_detail() {
  local s account
  for s in vertex vertex-anthropic vertex-gemini; do
    account=$(vertex_resolve "$s" account)
    [[ -n "$account" ]] && break
  done
  [[ -n "$account" ]] && printf ' [account: %s]' "$account"
}

# For the merged `vertex` summary row, format a trailing " (project: …)" suffix
# so the summary identifies the GCP project a vertex provider runs against.
# Empty for everything else — _setup_conf_wizard_providers always folds the
# internal sections to the `vertex` token, so that's the only vertex spelling
# that arrives here.
_setup_vertex_summary_detail() {
  [[ "$1" == vertex ]] || return 0
  local raw pr detail=""

  raw=$(_setup_current_vertex_projects)
  local -a projs=()
  while IFS= read -r pr; do projs+=("$pr"); done < <(_setup_split_projects "$raw")
  if [[ ${#projs[@]} -gt 1 ]]; then
    detail+=" (projects: $(_join_comma "${projs[@]}"))"
  elif [[ ${#projs[@]} -eq 1 ]]; then
    detail+=" (project: ${projs[0]})"
  fi
  printf '%s%s' "$detail" "$(_setup_vertex_account_detail)"
}

# Vertex AI summarises as one row per GCP project, since each project carries
# its own pins.
_setup_vertex_summary_rows() {
  local conf="$1" pr models
  printf '  • %s%s\n' "$(provider_display_name vertex)" "$(_setup_vertex_account_detail)"
  while IFS= read -r pr; do
    models=$(_setup_existing_models "vertex@${pr}" | paste -sd, - | sed 's/,/, /g')
    printf '      %s — %s\n' "$pr" \
      "${models:-no models pinned (hidden from the picker until you add one)}"
  done < <(vertex_section_projects "$conf")
}

_setup_print_summary() {
  local conf="$1" p any=0 models name
  printf 'Configured providers:\n'
  while IFS= read -r p; do
    any=1
    if [[ "$p" == vertex && -n "$(vertex_section_projects "$conf")" ]]; then
      _setup_vertex_summary_rows "$conf"
      continue
    fi
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

  # Vertex is picked project-first, whether or not it is already configured:
  # models are pinned per project, so there is nowhere to put them until a
  # project exists. Re-adding it therefore means "attach another GCP project",
  # and the new project starts from what its siblings already run.
  if [[ "$provider" == vertex ]]; then
    _setup_choose_vertex_projects "$provider" "$conf"
    # No project anywhere: the base sections are the only place left to pin, and
    # vertex resolves its project from the environment at run time.
    [[ -n "$(vertex_section_projects "$conf")" ]] || _setup_change_models "$conf" vertex
    _setup_ensure_auth "$provider" "$conf"
    return 0
  fi

  # Present section → replace-style model edit. Truly absent → append a new
  # section. Either way no duplicate [provider] header is created.
  local present=$'\n'
  while IFS= read -r p; do present+="$p"$'\n'; done < <(_setup_conf_wizard_providers "$conf")
  if [[ "$present" == *$'\n'"$provider"$'\n'* ]]; then
    _setup_change_models "$conf" "$provider"
  else
    local -a models=()
    while IFS= read -r m; do [[ -n "$m" ]] && models+=("$m"); done < <(_setup_pick_models "$provider")
    _conf_apply "$conf" conf_add_section "$provider" ${models[@]+"${models[@]}"} &&
      printf 'Added %s.\n' "$(provider_display_name "$provider")"
  fi
  _setup_ensure_auth "$provider" "$conf"
}

# For a vertex provider, let the user attach GCP project(s), each getting its
# own [vertex-<family>@<project>] sections. Additive: a pick never drops a
# project already configured (that's the replace-style projects editor below),
# and a blank pick changes nothing. Returns immediately for non-vertex providers.
_setup_choose_vertex_projects() {
  local provider="$1" conf="$2"
  case "${provider%%@*}" in vertex | vertex-gemini | vertex-anthropic) ;; *) return 0 ;; esac

  local current sweep seed
  current=$(_setup_current_vertex_projects "$conf")
  [[ -n "$current" ]] && printf 'Current vertex projects: %s\n' "$current"
  # Read the pins to inherit before attaching anything, while they are still the
  # answer to "what is pinned elsewhere".
  seed=$(_setup_existing_models vertex)
  # One gcloud sweep serves both the picker rows and the account lookup below.
  sweep=$(_setup_gcloud_projects)

  local -a projs=()
  local pr
  while IFS= read -r pr; do projs+=("$pr"); done < <(_setup_pick_projects "$sweep")
  [[ ${#projs[@]} -gt 0 ]] || { printf 'Vertex projects unchanged.\n'; return 0; }

  local -a added=()
  local cseen=$'\n'
  while IFS= read -r pr; do cseen+="$pr"$'\n'; done < <(_setup_split_projects "$current")
  for pr in "${projs[@]}"; do
    case "$cseen" in *$'\n'"$pr"$'\n'*) continue ;; esac
    cseen+="$pr"$'\n'
    _setup_vertex_add_project "$conf" "$pr" && added+=("$pr")
  done
  if [[ ${#added[@]} -eq 0 ]]; then
    printf 'Vertex projects unchanged: %s\n' "$current"
    return 0
  fi
  printf 'Added vertex project(s): %s\n' "$(_join_comma "${added[@]}")"
  _setup_pin_new_projects "$conf" "$seed" "${added[@]}"
  _setup_offer_account_pin "$conf" "$sweep" "${added[@]}"
}

# _setup_pin_new_projects CONF SEED PROJECT...
# Pin models on freshly attached projects: one prompt for the whole batch,
# pre-marked with SEED (what vertex has pinned elsewhere), then that set written
# to each. Per-project divergence is a later "Change models" edit — asking the
# same question once per project is not a choice worth offering.
_setup_pin_new_projects() {
  local conf="$1" seed="$2" first p
  shift 2
  first="$1"
  shift
  [[ -n "$seed" ]] && printf 'Starting from the models pinned on your other projects.\n'
  _setup_change_models "$conf" "vertex@${first}" "$seed"
  [[ $# -gt 0 ]] || return 0

  local -a picked=()
  while IFS= read -r p; do [[ -n "$p" ]] && picked+=("$p"); done \
    < <(_setup_existing_models "vertex@${first}")
  for p in "$@"; do
    _setup_write_vertex_models "$conf" "vertex@${p}" ${picked[@]+"${picked[@]}"} || return 1
  done
  printf 'Applied the same models to: %s\n' "$(_join_comma "$@")"
}

# Replace-style editor behind the menu's "Change Vertex AI projects": one
# multi-select over the union of the current list (pre-marked, listed first) and
# every project the machine's gcloud logins can see — the marked set REPLACES
# the list, so a single gesture both adds and removes. Esc keeps the current
# list. Unlike the model editor, confirming with nothing marked also keeps it:
# a vertex provider with no project cannot run, so "clear the list" is not a
# state the wizard will write (drop vertex entirely via remove-provider).
_setup_change_vertex_projects() {
  local conf="$1" current p sweep seed
  current=$(_setup_current_vertex_projects "$conf")
  [[ -n "$current" ]] && printf 'Current vertex projects: %s\n' "$current"
  # Read the pins to inherit before the edit, while they are still the answer to
  # "what is pinned elsewhere".
  seed=$(_setup_existing_models vertex)
  # One gcloud sweep serves both the picker rows and the account lookup below.
  sweep=$(_setup_gcloud_projects)

  # Union: current entries first (labelled "(current)"), then the discovered
  # projects, then the custom-id row — a project none of those logins can list
  # is the normal reason to be here, so there must always be a way to type one.
  local rows="" seen=$'\n' preselect="" discovered
  local -a cur_list=()
  while IFS= read -r p; do
    [[ "$seen" != *$'\n'"$p"$'\n'* ]] || continue
    seen+="$p"$'\n'
    cur_list+=("$p")
    rows+="${p}|${p} (current)"$'\n'
    preselect="$SETUP_PRESELECT_CURRENT"
  done < <(_setup_split_projects "$current")
  discovered=$(_setup_project_rows "$seen" "$sweep")
  [[ -n "$discovered" ]] && rows+="${discovered}"$'\n'
  rows+="$SETUP_CUSTOM_PROJECT_ROW"

  local -a picked=()
  local selected want_custom="" line pseen=$'\n' st
  selected=$(_setup_multiselect 'vertex projects> ' \
    'Current projects start marked — Tab to add/drop; Enter saves the marked set; Esc keeps current' \
    '— keep current list —' "$rows" "$preselect")
  st=$?
  if [[ $st -ne 0 ]]; then
    printf 'Vertex projects unchanged%s.\n' "${current:+: $current}"
    return 0
  fi
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

  if [[ ${#picked[@]} -eq 0 ]]; then
    printf 'Vertex projects unchanged%s.\n' "${current:+: $current}"
    return 0
  fi

  local -a added=() dropped=()
  for p in "${picked[@]}"; do
    case "$seen" in *$'\n'"$p"$'\n'*) ;; *) added+=("$p") ;; esac
  done
  for p in ${cur_list[@]+"${cur_list[@]}"}; do
    case "$pseen" in *$'\n'"$p"$'\n'*) ;; *) dropped+=("$p") ;; esac
  done
  if [[ ${#added[@]} -eq 0 && ${#dropped[@]} -eq 0 ]]; then
    printf 'Vertex projects unchanged: %s\n' "$current"
    return 0
  fi

  # Dropping a project deletes its sections, and with them its model pins — the
  # sections are the only record either one has.
  for p in ${dropped[@]+"${dropped[@]}"}; do
    _setup_vertex_drop_project "$conf" "$p" || return 1
  done
  for p in ${added[@]+"${added[@]}"}; do
    _setup_vertex_add_project "$conf" "$p" || return 1
  done
  printf 'Set vertex projects: %s\n' "$(_join_comma "${picked[@]}")"
  [[ ${#dropped[@]} -gt 0 ]] && printf 'Dropped: %s\n' "$(_join_comma "${dropped[@]}")"
  [[ ${#added[@]} -gt 0 ]] || return 0
  _setup_pin_new_projects "$conf" "$seed" "${added[@]}"
  _setup_offer_account_pin "$conf" "$sweep" "${added[@]}"
}

# Remove a provider section (preserving the rest of the file). Removing the
# wizard's `vertex` entry drops every per-project section, both base sections,
# and the shared [vertex] settings block — nothing vertex-related is left behind.
_setup_action_remove() {
  local conf="$1" p
  local -a secs=()
  while IFS= read -r p; do secs+=("$p"); done < <(_setup_conf_wizard_providers "$conf")
  local provider
  provider=$(_setup_choose_provider 'Remove which provider? ' "${secs[@]}") || { printf 'Cancelled.\n'; return 0; }
  if [[ "$provider" == vertex ]]; then
    while IFS= read -r p; do
      _setup_vertex_drop_project "$conf" "$p"
    done < <(vertex_section_projects "$conf")
    _conf_apply "$conf" conf_remove_section vertex-anthropic &&
      _conf_apply "$conf" conf_remove_section vertex-gemini &&
      _conf_apply "$conf" conf_remove_section vertex
  else
    _conf_apply "$conf" conf_remove_section "$provider"
  fi &&
    printf 'Removed %s.\n' "$(provider_display_name "$provider")"
}

# Print the models PROVIDER currently pins (deduped). `vertex` is the union
# across both internal sections and every project; `vertex@<project>` narrows it
# to one project. An internal token (`vertex-gemini`) keeps the old base-section
# reading, @profiles folded in. Used to seed the replace-style model editor.
_setup_existing_models() {
  parse_user_options | awk -F: -v p="$1" '{
    split($1, a, "@"); b = a[1]; prof = a[2]
    if (b == "vertex-gemini" || b == "vertex-anthropic") {
      if (p == "vertex") b = "vertex"
      else if (index(p, "vertex@") == 1) b = (prof == "") ? "vertex" : "vertex@" prof
    }
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

# Replace-style model editor (mirrors _setup_change_vertex_projects): one
# multi-select over the union of the models currently pinned (pre-marked, listed
# first) and the discovered catalog — the marked set REPLACES the provider's
# pins, so a single gesture adds *and* removes. Esc keeps the current pins;
# confirming with nothing marked unpins every model (the provider stays
# configured but drops out of the picker, which is the documented empty-section
# state); the custom-id row adds unlisted ids to the marked set.
# PROVIDER may be `vertex@<project>` to edit one project's pins. SEED replaces
# the current pins as the pre-marked set, which is how a just-attached project
# starts from what its siblings run.
_setup_change_models() {
  local conf="$1" provider="$2" seed="${3:-}" m
  local base="${provider%%@*}" current premark
  current=$(_setup_existing_models "$provider" | paste -sd, - | sed 's/,/, /g')
  [[ -n "$current" ]] && printf 'Current models: %s\n' "$current"
  premark="${seed:-$(_setup_existing_models "$provider")}"

  # Union: pre-marked pins first (labelled "(current)"), then the suggestion rows.
  local rows="" seen=$'\n' lbl preselect=""
  while IFS= read -r m; do
    [[ -n "$m" && "$seen" != *$'\n'"$m"$'\n'* ]] || continue
    seen+="$m"$'\n'
    rows+="${m}|${m} (current)"$'\n'
    preselect="$SETUP_PRESELECT_CURRENT"
  done <<<"$premark"
  while IFS='|' read -r m lbl; do
    [[ -n "$m" && "$seen" != *$'\n'"$m"$'\n'* ]] || continue
    [[ "$m" != '=custom=' ]] && seen+="$m"$'\n'
    rows+="${m}|${lbl}"$'\n'
  done < <(_setup_model_rows "$base" "$(_setup_suggest_models "$base")")

  # Nothing pinned and nothing inherited (a provider being set up, or one
  # deliberately emptied): fall back to the recommended rows, so a bare Enter
  # still lands on a usable pin instead of pinning nothing.
  local header='Current pins start marked'
  if [[ -z "$preselect" ]]; then
    preselect="$SETUP_PRESELECT_RECOMMENDED"
    header='Recommended start marked'
  fi

  local -a picked=()
  local selected want_custom="" line pseen=$'\n' st
  selected=$(_setup_multiselect "models for $(provider_display_name "$provider")> " \
    "${header} — Tab to add/drop; Enter saves the marked set; Esc keeps current" \
    '— none: unpin every model —' "$rows" "$preselect")
  st=$?
  if [[ $st -ne 0 ]]; then
    if [[ -z "$current" ]]; then
      printf 'No models pinned for %s — hidden from the picker until you add one.\n' \
        "$(provider_display_name "$provider")"
    else
      printf 'Models unchanged: %s\n' "$current"
    fi
    return 0
  fi
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

  if [[ ${#picked[@]} -eq 0 ]]; then
    if [[ -z "$current" ]]; then
      printf 'No models pinned for %s.\n' "$(provider_display_name "$provider")"
      return 0
    fi
    if [[ "$base" == vertex ]]; then
      _setup_write_vertex_models "$conf" "$provider"
    else
      _conf_apply "$conf" conf_set_section_models "$provider"
    fi &&
      printf 'Unpinned every model for %s — hidden from the picker until you add one.\n' \
        "$(provider_display_name "$provider")"
    return 0
  fi

  # Accepting the pre-marked set unchanged is the common gesture (a bare Enter),
  # so say so rather than reporting a write that changes nothing.
  local joined
  joined=$(_join_comma "${picked[@]}")
  if [[ "$joined" == "$current" ]]; then
    printf 'Models unchanged: %s\n' "$joined"
    return 0
  fi

  if [[ "$base" == vertex ]]; then
    _setup_write_vertex_models "$conf" "$provider" "${picked[@]}"
  else
    _conf_apply "$conf" conf_set_section_models "$provider" "${picked[@]}"
  fi &&
    printf 'Set models for %s: %s\n' \
      "$(provider_display_name "$provider")" "$joined"
}

# Change an existing provider's models (replace-style — see _setup_change_models).
# Vertex AI with several projects picks a scope first: one project's pins, or
# the same set across all of them.
_setup_action_models() {
  local conf="$1" p
  local -a secs=()
  while IFS= read -r p; do secs+=("$p"); done < <(_setup_conf_wizard_providers "$conf")
  local provider scope
  provider=$(_setup_choose_provider 'Change models for which provider? ' "${secs[@]}") || { printf 'Cancelled.\n'; return 0; }
  if [[ "$provider" == vertex ]]; then
    scope=$(_setup_pick_vertex_scope "$conf") || { printf 'Cancelled.\n'; return 0; }
    provider="$scope"
  fi
  _setup_change_models "$conf" "$provider"
}
