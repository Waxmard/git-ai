#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  source "${REPO_ROOT}/lib/ai-common.sh"
  source "${REPO_ROOT}/bin/git-ai"
  export XDG_CONFIG_HOME="$(mktemp -d)"
  mkdir -p "${XDG_CONFIG_HOME}/git-ai"
  CONF="${XDG_CONFIG_HOME}/git-ai/options.conf"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO" "$XDG_CONFIG_HOME"
  unset XDG_CONFIG_HOME
}

# --- _setup_select (numbered fallback) ---

_select() { # CHOICE DATA  -> runs _setup_select with numbered fallback, feeding CHOICE
  GIT_AI_NO_FZF=1 bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    printf "%s\n" "$1" | _setup_select "pick> " "$2"
  ' _ "$1" "$2"
}

@test "_setup_select: numbered fallback returns the chosen value" {
  run _select 2 $'add\tAdd\nremove\tRemove\ndone\tDone'
  assert_success
  assert_line "remove"
}

@test "_setup_select: out-of-range choice returns non-zero" {
  run _select 9 $'add\tAdd\ndone\tDone'
  assert_failure
}

@test "_setup_select: empty data returns non-zero" {
  run _select 1 ""
  assert_failure
}

# --- _setup_print_summary (models shown / empty flagged) ---

@test "_setup_print_summary: pinned models are listed, empty sections flagged" {
  cat >"$CONF" <<'EOF'
[claude-code]

[vertex-gemini]
gemini-3.5-flash
gemini-3.1-pro-preview
EOF
  run _setup_print_summary "$CONF"
  assert_success
  assert_output --partial "Vertex AI — gemini-3.5-flash, gemini-3.1-pro-preview"
  assert_output --partial "Claude Code — no models pinned"
}

@test "_setup_print_summary: vertex project + account shown in the header" {
  cat >"$CONF" <<'EOF'
[vertex]
projects = proj-a, proj-b

[vertex-gemini]
account = me@example.com
gemini-3.5-flash
EOF
  run _setup_print_summary "$CONF"
  assert_success
  assert_output --partial "(projects: proj-a, proj-b)"
  assert_output --partial "[account: me@example.com]"
}

@test "_setup_print_summary: single per-section vertex project shown" {
  cat >"$CONF" <<'EOF'
[vertex-anthropic]
project = solo-proj
claude-sonnet-4
EOF
  run _setup_print_summary "$CONF"
  assert_success
  assert_output --partial "(project: solo-proj)"
}

# --- _setup_existing_models (additive change-models support) ---

@test "_setup_existing_models: lists pinned models, folding @profiles to base" {
  cat >"$CONF" <<'EOF'
[vertex]
projects = a, b

[vertex-gemini]
gemini-3.5-flash
EOF
  run _setup_existing_models vertex-gemini
  assert_success
  assert_line "gemini-3.5-flash"
  # The two project profiles must collapse to a single base entry.
  [ "$(grep -c '^gemini-3.5-flash$' <<<"$output")" -eq 1 ]
}

# --- _setup_pick_projects (vertex project selection, free-text fallback) ---

@test "_setup_pick_projects: free-text fallback splits a comma list" {
  local stub; stub="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' >"${stub}/gcloud"  # no project list → free-text path
  chmod +x "${stub}/gcloud"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    printf "proj-a, proj-b\n" | GIT_AI_NO_FZF=1 _setup_pick_projects
  '
  rm -rf "$stub"
  assert_success
  assert_line "proj-a"
  assert_line "proj-b"
}

# --- vertex unification (one user-facing "Vertex AI") ---

@test "_setup_expand_provider: vertex expands to both internal providers" {
  run _setup_expand_provider vertex
  assert_success
  assert_line --index 0 "vertex-anthropic"
  assert_line --index 1 "vertex-gemini"
}

@test "_setup_expand_provider: concrete providers pass through" {
  run _setup_expand_provider gemini-api
  assert_success
  assert_output "gemini-api"
}

@test "_setup_provider_for_model: claude models route to vertex-anthropic" {
  run _setup_provider_for_model vertex "claude-sonnet-4-6"
  assert_success
  assert_output "vertex-anthropic"
}

@test "_setup_provider_for_model: non-claude models route to vertex-gemini" {
  run _setup_provider_for_model vertex "gemini-3.5-flash"
  assert_success
  assert_output "vertex-gemini"
}

@test "_setup_provider_for_model: concrete provider passes through regardless of model" {
  run _setup_provider_for_model anthropic-api "claude-sonnet-4-6"
  assert_success
  assert_output "anthropic-api"
}

@test "_setup_conf_wizard_providers: vertex sections fold into one entry" {
  cat >"$CONF" <<'EOF'
[gemini-api]
gemini-3.5-flash

[vertex-anthropic]
claude-sonnet-4-6

[vertex-gemini]
gemini-3.5-flash
EOF
  run _setup_conf_wizard_providers "$CONF"
  assert_success
  assert_line --index 0 "gemini-api"
  assert_line --index 1 "vertex"
  [ "${#lines[@]}" -eq 2 ]
}

@test "_setup_existing_models: vertex token folds both internal sections" {
  cat >"$CONF" <<'EOF'
[vertex-anthropic]
claude-sonnet-4-6

[vertex-gemini]
gemini-3.5-flash
EOF
  run _setup_existing_models vertex
  assert_success
  assert_line "claude-sonnet-4-6"
  assert_line "gemini-3.5-flash"
}

@test "_setup_write_vertex_models: splits picks per family into the right sections" {
  cat >"$CONF" <<'EOF'
[vertex-anthropic]
claude-sonnet-4-6
EOF
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_write_vertex_models "'"$CONF"'" claude-sonnet-4-6 claude-opus-4-6 gemini-3.5-flash
    cat "'"$CONF"'"
  '
  assert_success
  assert_line "[vertex-anthropic]"
  assert_line "claude-opus-4-6"
  assert_line "[vertex-gemini]"
  assert_line "gemini-3.5-flash"
}

# --- _setup_edit_existing menu (vertex-conditional projects action) ---

# Drive the edit loop with the numbered fallback and EOF stdin: the menu prints
# its options, then the action read hits EOF and exits via the Done default.
_edit_menu() {
  GIT_AI_NO_FZF=1 bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_edit_existing "$1"
  ' _ "$1" </dev/null 2>&1
}

@test "_setup_edit_existing: vertex configured offers the projects action" {
  printf '[vertex-gemini]\ngemini-3.5-flash\n' >"$CONF"
  run _edit_menu "$CONF"
  assert_success
  assert_output --partial "Change Vertex AI projects (GCP)"
}

@test "_setup_edit_existing: no vertex, no projects action" {
  printf '[gemini-api]\ngemini-3.5-flash\n' >"$CONF"
  run _edit_menu "$CONF"
  assert_success
  refute_output --partial "Change Vertex AI projects"
}

@test "_setup_edit_existing: no standalone auth action (add-provider covers it)" {
  printf '[gemini-api]\ngemini-3.5-flash\n' >"$CONF"
  run _edit_menu "$CONF"
  assert_success
  refute_output --partial "Set up auth"
}

# --- _setup_detect_vertex_project (gcloud-backed project auto-pick) ---

# _detect ACTIVE ENABLED_CSV -> runs _setup_detect_vertex_project against a
# stubbed gcloud: ACTIVE is `config get-value project` output, ENABLED_CSV the
# comma-list of projects where the Vertex API is "enabled". Project list is
# fixed at proj-a/proj-b/proj-c.
_detect() {
  local stub
  stub="$(mktemp -d)"
  cat >"${stub}/gcloud" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "config get-value") printf '%s\n' "${STUB_ACTIVE}" ;;
  "projects list") printf 'proj-a\nproj-b\nproj-c\n' ;;
  "services list")
    p=""
    for a in "$@"; do case "$a" in --project=*) p="${a#--project=}" ;; esac; done
    case ",${STUB_ENABLED}," in
      *",${p},"*) printf 'aiplatform.googleapis.com\n' ;;
    esac
    ;;
esac
EOF
  chmod +x "${stub}/gcloud"
  STUB_ACTIVE="$1" STUB_ENABLED="$2" PATH="${stub}:$PATH" bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_detect_vertex_project
  '
  local rc=$?
  rm -rf "$stub"
  return $rc
}

@test "_setup_detect_vertex_project: enabled active project wins immediately" {
  run _detect "proj-b" "proj-a,proj-b"
  assert_success
  assert_output "proj-b"
}

@test "_setup_detect_vertex_project: no active, single enabled project found" {
  run _detect "" "proj-b"
  assert_success
  assert_output "proj-b"
}

@test "_setup_detect_vertex_project: active without the API falls to an enabled project" {
  run _detect "proj-c" "proj-a"
  assert_success
  assert_output "proj-a"
}

@test "_setup_detect_vertex_project: nothing enabled falls back to the active project" {
  run _detect "proj-c" ""
  assert_success
  assert_output "proj-c"
}

@test "_setup_detect_vertex_project: gcloud erroring yields empty" {
  local stub
  stub="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' >"${stub}/gcloud"
  chmod +x "${stub}/gcloud"
  run env PATH="${stub}:$PATH" bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_detect_vertex_project
  '
  rm -rf "$stub"
  assert_success
  assert_output ""
}

# --- vertex projects editing (seeding + replace semantics) ---

@test "_setup_current_vertex_projects: prefers the shared projects list" {
  printf '[vertex]\nprojects = a, b\nproject = stray\n' >"$CONF"
  run _setup_current_vertex_projects
  assert_success
  assert_output "a, b"
}

@test "_setup_current_vertex_projects: falls back to a singular project=" {
  printf '[vertex]\nproject = solo\n' >"$CONF"
  run _setup_current_vertex_projects
  assert_success
  assert_output "solo"
}

@test "_setup_choose_vertex_projects: attaching a project keeps the one already configured" {
  printf '[vertex]\nproject = old-proj\n\n[vertex-gemini]\ngemini-3.5-flash\n' >"$CONF"
  local stub; stub="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' >"${stub}/gcloud"  # free-text fallback path
  chmod +x "${stub}/gcloud"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_suggest_models() { :; }  # no network — seed already carries the pins to inherit
    printf "new-proj\n" | GIT_AI_NO_FZF=1 _setup_choose_vertex_projects vertex "'"$CONF"'"
  '
  rm -rf "$stub"
  assert_success
  assert_output --partial "Added vertex project(s): new-proj"
  run cat "$CONF"
  assert_line "[vertex-gemini@old-proj]"
  assert_line "[vertex-gemini@new-proj]"
  # The singular key drove the old expansion; the sections are the record now.
  refute_line "project = old-proj"
}

# Numbered rows here are: 1) sentinel  2) a (current)  3) b (current)  4) custom.
@test "_setup_change_vertex_projects: custom row replaces the current list" {
  printf '[vertex]\nprojects = a, b\n' >"$CONF"
  local stub; stub="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' >"${stub}/gcloud"
  chmod +x "${stub}/gcloud"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_suggest_models() { :; }  # no network — seed already carries the pins to inherit
    printf "4\nc\n" | GIT_AI_NO_FZF=1 _setup_change_vertex_projects "'"$CONF"'"
  '
  rm -rf "$stub"
  assert_success
  assert_output --partial "Set vertex projects: c"
  assert_output --partial "Dropped: a, b"
  run cat "$CONF"
  assert_line "[vertex-gemini@c]"
  refute_line "[vertex-gemini@a]"
  refute_line "projects = a, b"
}

@test "_setup_change_vertex_projects: cancelling keeps the current list" {
  printf '[vertex]\nprojects = a, b\n' >"$CONF"
  local stub; stub="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' >"${stub}/gcloud"
  chmod +x "${stub}/gcloud"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    printf "0\n" | GIT_AI_NO_FZF=1 _setup_change_vertex_projects "'"$CONF"'"
  '
  rm -rf "$stub"
  assert_success
  assert_output --partial "Vertex projects unchanged: a, b"
  run cat "$CONF"
  assert_line "projects = a, b"
}

# A projectless vertex cannot run, so the sentinel row keeps the list rather
# than clearing it (unlike the model editor).
@test "_setup_change_vertex_projects: selecting only the sentinel keeps the list" {
  printf '[vertex]\nprojects = a, b\n' >"$CONF"
  local stub; stub="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' >"${stub}/gcloud"
  chmod +x "${stub}/gcloud"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    printf "1\n" | GIT_AI_NO_FZF=1 _setup_change_vertex_projects "'"$CONF"'"
  '
  rm -rf "$stub"
  assert_success
  assert_output --partial "Vertex projects unchanged: a, b"
  run cat "$CONF"
  assert_line "projects = a, b"
}

@test "_setup_change_vertex_projects: blank entry keeps the current list" {
  printf '[vertex]\nprojects = a, b\n' >"$CONF"
  local stub; stub="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' >"${stub}/gcloud"
  chmod +x "${stub}/gcloud"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    printf "\n" | GIT_AI_NO_FZF=1 _setup_change_vertex_projects "'"$CONF"'"
  '
  rm -rf "$stub"
  assert_success
  assert_output --partial "Vertex projects unchanged: a, b"
  run cat "$CONF"
  assert_line "projects = a, b"
}

# --- per-project vertex models (normalization + scoped writes) ---

@test "_setup_vertex_normalize: shared shape converts to per-project sections" {
  cat >"$CONF" <<'EOF'
[vertex]
account  = me@acme.com
projects = proj-a, proj-b

[vertex-gemini]
gemini-3.5-flash

[vertex-anthropic]
claude-sonnet-4-6
EOF
  local before; before="$(parse_user_options | sort)"
  run _setup_vertex_normalize "$CONF"
  assert_success
  # The conversion must not change which provider:model combos exist.
  assert_equal "$(parse_user_options | sort)" "$before"
  run cat "$CONF"
  assert_line "[vertex-gemini@proj-a]"
  assert_line "[vertex-anthropic@proj-b]"
  assert_line "account  = me@acme.com"
  refute_line "[vertex-gemini]"
  refute_line "projects = proj-a, proj-b"
}

@test "_setup_vertex_normalize: a space-separated projects list splits like parse_user_options" {
  printf '[vertex]\nprojects = proj-a proj-b\n\n[vertex-gemini]\ngemini-y\n' >"$CONF"
  local before; before="$(parse_user_options | sort)"
  run _setup_vertex_normalize "$CONF"
  assert_success
  assert_equal "$(parse_user_options | sort)" "$before"
  run cat "$CONF"
  assert_line "[vertex-gemini@proj-a]"
  assert_line "[vertex-gemini@proj-b]"
}

@test "_setup_vertex_normalize: a hybrid config folds base models into the explicit profile" {
  cat >"$CONF" <<'EOF'
[vertex]
projects = proj-a, proj-b

[vertex-gemini]
gemini-base

[vertex-gemini@proj-b]
gemini-special
EOF
  local before; before="$(parse_user_options | sort)"
  run _setup_vertex_normalize "$CONF"
  assert_success
  assert_equal "$(parse_user_options | sort)" "$before"
  # The shared-only project gets a real section, and the explicit one absorbs
  # what the base section used to expand into it.
  run cat "$CONF"
  assert_line "[vertex-gemini@proj-a]"
  refute_line "[vertex-gemini]"
  refute_line "projects = proj-a, proj-b"
}

@test "_setup_vertex_normalize: folding a hybrid makes a scoped unpin actually unpin" {
  cat >"$CONF" <<'EOF'
[vertex]
projects = proj-a, proj-b

[vertex-gemini]
gemini-base

[vertex-gemini@proj-b]
gemini-special
EOF
  run _setup_write_vertex_models "$CONF" vertex@proj-b gemini-special
  assert_success
  run parse_user_options
  assert_line "vertex-gemini@proj-b:gemini-special"
  # Inherited through the base cross-product before the fold — must be gone now.
  refute_line "vertex-gemini@proj-b:gemini-base"
  assert_line "vertex-gemini@proj-a:gemini-base"
}

@test "_setup_current_vertex_projects: unions section projects with the shared list" {
  cat >"$CONF" <<'EOF'
[vertex]
projects = proj-a

[vertex-gemini@proj-b]
gemini-special
EOF
  run _setup_current_vertex_projects "$CONF"
  assert_success
  assert_output --partial "proj-a"
  assert_output --partial "proj-b"
}

@test "_setup_vertex_normalize: an already-folded config is left alone" {
  printf '[vertex-gemini@proj-a]\ngemini-y\n\n[vertex-anthropic@proj-a]\nclaude-x\n' >"$CONF"
  local before; before="$(cat "$CONF")"
  run _setup_vertex_normalize "$CONF"
  assert_success
  assert_output ""
  assert_equal "$(cat "$CONF")" "$before"
}

@test "_setup_vertex_normalize: a base project= that would override a profile is removed" {
  cat >"$CONF" <<'EOF'
[vertex-gemini]
project = wrong-proj

[vertex-gemini@proj-a]
gemini-y
EOF
  run _setup_vertex_normalize "$CONF"
  assert_success
  # Left in place it would win over the profile name for every gemini profile.
  run vertex_resolve "vertex-gemini@proj-a" project
  assert_output "proj-a"
}

@test "_setup_vertex_normalize: no project named anywhere leaves the file untouched" {
  printf '[vertex-gemini]\ngemini-3.5-flash\n' >"$CONF"
  local before; before="$(cat "$CONF")"
  run _setup_vertex_normalize "$CONF"
  assert_success
  assert_equal "$(cat "$CONF")" "$before"
}

@test "_setup_vertex_normalize: base-section settings survive for profiles to inherit" {
  cat >"$CONF" <<'EOF'
[vertex]
projects = proj-a

[vertex-gemini]
region = us-east5
gemini-3.5-flash
EOF
  run _setup_vertex_normalize "$CONF"
  assert_success
  run vertex_resolve "vertex-gemini@proj-a" region
  assert_output "us-east5"
  # The project keys that drove the expansion are gone, so the profile name is
  # the project — a leftover project= would override every profile.
  run vertex_resolve "vertex-gemini@proj-a" project
  assert_output "proj-a"
}

@test "_setup_vertex_normalize: a comment-only base section keeps its comment" {
  cat >"$CONF" <<'EOF'
[vertex]
projects = proj-a

[vertex-gemini]
# cheapest model, keep this one first
gemini-3.5-flash
EOF
  run _setup_vertex_normalize "$CONF"
  assert_success
  run cat "$CONF"
  assert_line "[vertex-gemini]"
  assert_line "# cheapest model, keep this one first"
  # The base section keeps its comment but loses its model to the new profile.
  [ "$(printf '%s\n' "$output" | sed -n '/^\[vertex-gemini\]$/,/^\[/p' | grep -c '^gemini-3.5-flash$')" -eq 0 ]
  assert_line "[vertex-gemini@proj-a]"
  [ "$(grep -c '^gemini-3.5-flash$' <<<"$output")" -eq 1 ]
}

@test "_setup_vertex_normalize: a base section with neither settings nor comments is dropped" {
  printf '[vertex]\nprojects = proj-a\n\n[vertex-gemini]\ngemini-3.5-flash\n' >"$CONF"
  run _setup_vertex_normalize "$CONF"
  assert_success
  run cat "$CONF"
  refute_line "[vertex-gemini]"
}

@test "_setup_vertex_normalize: a singular [vertex] project= keeps the base pins" {
  printf '[vertex]\nproject = proj-a\n\n[vertex-gemini]\ngemini-x\n\n[vertex-anthropic]\nclaude-x\n' >"$CONF"
  run _setup_vertex_normalize "$CONF"
  assert_success
  # Only `projects =` expands the base sections, so the fold has to copy the
  # literal models — reading them back out of parse_user_options finds nothing.
  run parse_user_options
  assert_line "vertex-gemini@proj-a:gemini-x"
  assert_line "vertex-anthropic@proj-a:claude-x"
}

@test "_setup_vertex_normalize: a base-section project= keeps the base pins" {
  printf '[vertex-anthropic]\nproject = acme-prod\nregion = us-east5\nclaude-x\n' >"$CONF"
  run _setup_vertex_normalize "$CONF"
  assert_success
  run parse_user_options
  assert_line "vertex-anthropic@acme-prod:claude-x"
  run vertex_resolve "vertex-anthropic@acme-prod" region
  assert_output "us-east5"
}

@test "_setup_vertex_normalize: base pins with no project of their own are left alone" {
  printf '[vertex-gemini]\ngemini-base\n\n[vertex-gemini@p1]\ngemini-p1\n' >"$CONF"
  local before; before="$(cat "$CONF")"
  run _setup_vertex_normalize "$CONF"
  assert_success
  # Nothing names a project for the base section, so its models still resolve
  # theirs from the environment — folding them into p1 would be a guess.
  assert_equal "$(cat "$CONF")" "$before"
}

@test "_setup_vertex_normalize: an overlapping base pin is not duplicated in the profile" {
  printf '[vertex]\nproject = proj-a\n\n[vertex-gemini]\ngemini-x\n\n[vertex-gemini@proj-a]\ngemini-x\ngemini-y\n' >"$CONF"
  run _setup_vertex_normalize "$CONF"
  assert_success
  run cat "$CONF"
  [ "$(grep -c '^gemini-x$' <<<"$output")" -eq 1 ]
  assert_line "gemini-y"
}

@test "_setup_vertex_resolved_project: falls back to the profile name with no override" {
  printf '[vertex-gemini@acme]\ngemini-x\n' >"$CONF"
  run _setup_vertex_resolved_project "$CONF" acme
  assert_success
  assert_output "acme"
}

@test "_setup_vertex_resolved_project: an explicit override wins, checked in either family" {
  printf '[vertex-anthropic@acme]\nproject = acme-prod\nclaude-x\n' >"$CONF"
  run _setup_vertex_resolved_project "$CONF" acme
  assert_success
  assert_output "acme-prod"
}

@test "_setup_vertex_add_project: re-adding the real id an alias already targets is a no-op" {
  printf '[vertex-anthropic@acme]\nproject = acme-prod\nclaude-x\n' >"$CONF"
  run _setup_vertex_add_project "$CONF" acme-prod
  # 2, not 0: callers pin models on every suffix they see reported as added.
  assert_equal "$status" 2
  run cat "$CONF"
  assert_line "[vertex-anthropic@acme]"
  refute_line "[vertex-anthropic@acme-prod]"
  refute_line "[vertex-gemini@acme-prod]"
}

# Numbered rows here are: 1) sentinel  2) acme (current)  3) custom.
@test "_setup_change_vertex_projects: picking the id an alias targets adds nothing" {
  printf '[vertex-anthropic@acme]\nproject = acme-prod\nclaude-x\n' >"$CONF"
  local stub; stub="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' >"${stub}/gcloud"
  chmod +x "${stub}/gcloud"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_suggest_models() { :; }
    printf "2 3\nacme-prod\n" | GIT_AI_NO_FZF=1 _setup_change_vertex_projects "'"$CONF"'"
  '
  rm -rf "$stub"
  assert_success
  run cat "$CONF"
  assert_line "[vertex-anthropic@acme]"
  refute_line "[vertex-anthropic@acme-prod]"
  refute_line "[vertex-gemini@acme-prod]"
}

@test "_setup_print_summary: an aliased profile shows its resolved project" {
  printf '[vertex-anthropic@acme]\nproject = acme-prod\nclaude-x\n' >"$CONF"
  run _setup_print_summary "$CONF"
  assert_success
  assert_output --partial "acme (project: acme-prod)"
}

@test "_setup_fast_path: reset preserves a profile's project= override" {
  cat >"$CONF" <<'EOF'
[vertex-anthropic@acme]
project = acme-prod
claude-x

[vertex-gemini@acme]
gemini-y
EOF
  run env -u GOOGLE_VERTEX_PROJECT -u GOOGLE_CLOUD_PROJECT bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    GIT_AI_NO_FZF=1 _setup_fast_path "'"$CONF"'" vertex </dev/null
  '
  assert_success
  source "${REPO_ROOT}/lib/ai-common.sh"
  run vertex_resolve "vertex-anthropic@acme" project
  assert_output "acme-prod"
}

@test "_setup_write_vertex_models: a project scope leaves its siblings alone" {
  cat >"$CONF" <<'EOF'
[vertex]
projects = proj-a, proj-b

[vertex-gemini]
gemini-3.5-flash
EOF
  run _setup_write_vertex_models "$CONF" "vertex@proj-b" gemini-3.1-pro-preview
  assert_success
  run parse_user_options
  assert_line "vertex-gemini@proj-a:gemini-3.5-flash"
  assert_line "vertex-gemini@proj-b:gemini-3.1-pro-preview"
  refute_line "vertex-gemini@proj-b:gemini-3.5-flash"
}

@test "_setup_write_vertex_models: the vertex scope writes every project at once" {
  printf '[vertex-gemini@proj-a]\nold\n\n[vertex-gemini@proj-b]\nold\n' >"$CONF"
  run _setup_write_vertex_models "$CONF" vertex gemini-3.5-flash claude-sonnet-4-6
  assert_success
  run parse_user_options
  assert_line "vertex-gemini@proj-a:gemini-3.5-flash"
  assert_line "vertex-gemini@proj-b:gemini-3.5-flash"
  assert_line "vertex-anthropic@proj-a:claude-sonnet-4-6"
  refute_line "vertex-gemini@proj-a:old"
}

@test "_setup_pick_vertex_scope: one project needs no question" {
  printf '[vertex-gemini@solo]\ngemini-3.5-flash\n' >"$CONF"
  run _setup_pick_vertex_scope "$CONF" </dev/null
  assert_success
  assert_output "vertex"
}

@test "_setup_pick_vertex_scope: several projects offer all-or-one, with current pins" {
  cat >"$CONF" <<'EOF'
[vertex-gemini@proj-a]
gemini-3.5-flash

[vertex-gemini@proj-b]
EOF
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    printf "3\n" | GIT_AI_NO_FZF=1 _setup_pick_vertex_scope "'"$CONF"'" 2>&1
  '
  assert_success
  assert_output --partial "All projects"
  assert_output --partial "proj-a — gemini-3.5-flash"
  assert_output --partial "proj-b — no models pinned"
  assert_line "vertex@proj-b"
}

@test "_setup_print_summary: per-project pins list one row per project" {
  cat >"$CONF" <<'EOF'
[vertex]
account = me@acme.com

[vertex-gemini@proj-a]
gemini-3.5-flash

[vertex-gemini@proj-b]
gemini-3.1-pro-preview
EOF
  run _setup_print_summary "$CONF"
  assert_success
  assert_output --partial "Vertex AI [account: me@acme.com]"
  assert_output --partial "proj-a — gemini-3.5-flash"
  assert_output --partial "proj-b — gemini-3.1-pro-preview"
}

# --- _setup_change_models (replace-style model editing) ---

# Pin discovery and recommendations so the numbered rows are stable and no
# network call is made: rows become 1) sentinel, 2..) current, custom, suggested.
_models_env() {
  printf '%s\n' '
    _setup_suggest_models() { printf "%s\n" '"$1"'; }
    recommended_model() { return 0; }
  '
}

@test "_setup_change_models: custom row replaces the pinned models" {
  printf '[gemini-api]\ngemini-old\ngemini-keep\n' >"$CONF"
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    '"$(_models_env gemini-sugg)"'
    printf "4\ngemini-new\n" | GIT_AI_NO_FZF=1 _setup_change_models "'"$CONF"'" gemini-api
  '
  assert_success
  assert_output --partial "Set models for Gemini API: gemini-new"
  run cat "$CONF"
  assert_line "gemini-new"
  refute_line "gemini-old"
  refute_line "gemini-keep"
}

@test "_setup_change_models: blank entry keeps the pre-marked pins" {
  printf '[gemini-api]\ngemini-old\n' >"$CONF"
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    '"$(_models_env gemini-sugg)"'
    printf "\n" | GIT_AI_NO_FZF=1 _setup_change_models "'"$CONF"'" gemini-api
  '
  assert_success
  assert_output --partial "Models unchanged: gemini-old"
  run cat "$CONF"
  assert_line "gemini-old"
}

@test "_setup_change_models: cancelling keeps the current pins" {
  printf '[gemini-api]\ngemini-old\n' >"$CONF"
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    '"$(_models_env gemini-sugg)"'
    printf "0\n" | GIT_AI_NO_FZF=1 _setup_change_models "'"$CONF"'" gemini-api
  '
  assert_success
  assert_output --partial "Models unchanged: gemini-old"
  run cat "$CONF"
  assert_line "gemini-old"
}

# The point of the cancel/confirm split: an explicitly empty confirmation is the
# only way to unpin everything without deleting the provider.
@test "_setup_change_models: selecting only the sentinel unpins every model" {
  printf '[gemini-api]\ngemini-old\n' >"$CONF"
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    '"$(_models_env gemini-sugg)"'
    printf "1\n" | GIT_AI_NO_FZF=1 _setup_change_models "'"$CONF"'" gemini-api
  '
  assert_success
  assert_output --partial "Unpinned every model for Gemini API"
  run cat "$CONF"
  assert_line "[gemini-api]"
  refute_line "gemini-old"
}

@test "_setup_change_models: vertex replace clears a family whose models were all dropped" {
  printf '[vertex-anthropic]\nclaude-x\n\n[vertex-gemini]\ngemini-y\n' >"$CONF"
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    '"$(_models_env gemini-z)"'
    printf "5\n" | GIT_AI_NO_FZF=1 _setup_change_models "'"$CONF"'" vertex
  '
  assert_success
  assert_output --partial "Set models for Vertex AI: gemini-z"
  run cat "$CONF"
  # The emptied anthropic section stays (hidden from the picker) but loses its pin.
  assert_line "[vertex-anthropic]"
  refute_line "claude-x"
  assert_line "gemini-z"
  refute_line "gemini-y"
}

@test "_setup_change_models: a project scope repins only that project" {
  cat >"$CONF" <<'EOF'
[vertex]
projects = proj-a, proj-b

[vertex-gemini]
gemini-y
EOF
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    '"$(_models_env gemini-z)"'
    printf "4\n" | GIT_AI_NO_FZF=1 _setup_change_models "'"$CONF"'" vertex@proj-b
  '
  assert_success
  assert_output --partial "Set models for Vertex AI [proj-b]: gemini-z"
  run parse_user_options
  assert_line "vertex-gemini@proj-a:gemini-y"
  assert_line "vertex-gemini@proj-b:gemini-z"
}

# --- _setup_action_reset (re-run fresh flow over an existing config) ---

@test "_setup_action_reset: declining keeps the config untouched" {
  printf '[gemini-api]\ngemini-3.5-flash\n' >"$CONF"
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    printf "n\n" | _setup_action_reset "'"$CONF"'"
  '
  assert_failure
  assert_output --partial "Kept as-is."
  run cat "$CONF"
  assert_line "[gemini-api]"
  assert_line "gemini-3.5-flash"
}

@test "_setup_action_reset: confirming re-runs the fresh flow" {
  printf '[gemini-api]\ngemini-3.5-flash\n' >"$CONF"
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_fresh() { printf "FRESH %s\n" "$1"; }
    printf "y\n" | _setup_action_reset "'"$CONF"'"
  '
  assert_success
  assert_output --partial "FRESH $CONF"
}

@test "_setup_print_summary: both vertex sections render as one Vertex AI row" {
  cat >"$CONF" <<'EOF'
[vertex-anthropic]
claude-sonnet-4-6

[vertex-gemini]
gemini-3.5-flash
EOF
  run _setup_print_summary "$CONF"
  assert_success
  assert_output --partial "Vertex AI — claude-sonnet-4-6, gemini-3.5-flash"
  # Exactly one bullet row — the split must not leak.
  [ "$(grep -c 'Vertex AI' <<<"$output")" -eq 1 ]
}

# --- _setup_multiselect (preselect, cancel-vs-confirm) ---

# fzf stub that echoes its argv and confirms with no selection.
_stub_fzf() {
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >&2\ncat >/dev/null\nexit 0\n' >"${1}/fzf"
  chmod +x "${1}/fzf"
}

@test "_setup_multiselect: preselect query marks the (current) rows on load" {
  local stub; stub="$(mktemp -d)"
  _stub_fzf "$stub"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    unset GIT_AI_NO_FZF
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_multiselect "p> " "h" "skip" "a|a (current)" "$SETUP_PRESELECT_CURRENT"
  '
  rm -rf "$stub"
  assert_success
  assert_output --partial "--query='(current)"
  assert_output --partial "--bind=load:select-all+clear-query"
}

@test "_setup_multiselect: no preselect query leaves the bind off" {
  local stub; stub="$(mktemp -d)"
  _stub_fzf "$stub"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    unset GIT_AI_NO_FZF
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_multiselect "p> " "h" "skip" "a|a"
  '
  rm -rf "$stub"
  assert_success
  refute_output --partial "select-all"
}

@test "_setup_multiselect: shared fzf opts reach every picker" {
  local stub; stub="$(mktemp -d)"
  _stub_fzf "$stub"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    unset GIT_AI_NO_FZF
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_multiselect "p> " "h" "skip" "a|a"
  '
  rm -rf "$stub"
  assert_output --partial "--cycle"
  assert_output --partial "--border"
  assert_output --partial "--height=40%"
}

@test "_setup_multiselect: Esc returns 2 so callers can keep the current state" {
  local stub; stub="$(mktemp -d)"
  printf '#!/bin/sh\ncat >/dev/null\nexit 130\n' >"${stub}/fzf"
  chmod +x "${stub}/fzf"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    unset GIT_AI_NO_FZF
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_multiselect "p> " "h" "skip" "a|a"
  '
  rm -rf "$stub"
  assert_equal "$status" 2
  assert_output ""
}

@test "_setup_multiselect: confirming with only the sentinel returns 0 and no rows" {
  local stub; stub="$(mktemp -d)"
  printf '#!/bin/sh\ncat >/dev/null\nprintf "%%s\\n" "—|skip"\nexit 0\n' >"${stub}/fzf"
  chmod +x "${stub}/fzf"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    unset GIT_AI_NO_FZF
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_multiselect "p> " "h" "skip" "a|a"
  '
  rm -rf "$stub"
  assert_success
  assert_output ""
}

# --- _setup_multiselect_numbered (no-fzf fallback) ---

@test "_setup_multiselect_numbered: pre-marked rows show [x] and a bare Enter keeps them" {
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    printf "\n" | GIT_AI_NO_FZF=1 _setup_multiselect_numbered "p> " "h" "skip" \
      "a|a (current)
b|b" "$SETUP_PRESELECT_CURRENT"
  '
  assert_success
  assert_line "   2) [x] a (current)"
  assert_line "   3) [ ] b"
  assert_line "a"
  refute_line "b"
}

@test "_setup_multiselect_numbered: numbers select rows and 0 cancels" {
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    printf "3\n" | GIT_AI_NO_FZF=1 _setup_multiselect_numbered "p> " "h" "skip" "a|a
b|b"
  '
  assert_success
  assert_line "b"
  refute_line "a"

  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    printf "0\n" | GIT_AI_NO_FZF=1 _setup_multiselect_numbered "p> " "h" "skip" "a|a"
  '
  assert_equal "$status" 2
}

# --- provider picker readiness labels ---

@test "_setup_provider_label: tags providers with their readiness" {
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    provider_ready() { [ "$1" = codex ]; }
    _setup_provider_label codex
    _setup_provider_label openai-api
  '
  assert_success
  assert_line "Codex CLI  [ready]"
  assert_line "OpenAI API  [needs setup]"
}

@test "_setup_ready_tag: probes each provider at most once" {
  run bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    probes=0
    provider_ready() { probes=$((probes + 1)); return 1; }
    _setup_warm_ready codex codex codex
    printf "probes=%s tag=%s\n" "$probes" "$(_setup_ready_tag codex)"
  '
  assert_success
  assert_output "probes=1 tag=setup"
}

# --- _setup_action_add (re-adding vertex attaches a project, keeps models) ---

@test "_setup_action_add: re-adding vertex attaches a project inheriting the current pins" {
  cat >"$CONF" <<'EOF'
[vertex-anthropic]
claude-sonnet-5

[vertex-gemini]
gemini-3.6-flash

[vertex]
projects = old-proj
EOF
  local stub; stub="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' >"${stub}/gcloud"
  chmod +x "${stub}/gcloud"
  # "4" picks vertex, "new-proj" is the free-text project, the bare Enter accepts
  # the inherited pins the model editor opens pre-marked with.
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_suggest_models() { :; }  # no network — seed already carries the pins to inherit
    printf "4\nnew-proj\n\n\n\n\n" | GIT_AI_NO_FZF=1 _setup_action_add "'"$CONF"'"
  '
  rm -rf "$stub"
  assert_success
  assert_output --partial "Added vertex project(s): new-proj"
  assert_output --partial "Starting from the models pinned on your other projects."
  run cat "$CONF"
  # Both projects keep the pins the base sections used to expand into.
  assert_line "[vertex-anthropic@old-proj]"
  assert_line "[vertex-gemini@new-proj]"
  [ "$(grep -c '^claude-sonnet-5$' <<<"$output")" -eq 2 ]
  [ "$(grep -c '^gemini-3.6-flash$' <<<"$output")" -eq 2 ]
  refute_line "projects = old-proj"
}

# --- GCP project discovery / picking ---

@test "_setup_gcloud_projects: sweeps every gcloud login, active account first" {
  local stub; stub="$(mktemp -d)"
  cat >"${stub}/gcloud" <<'SH'
#!/bin/sh
case "$*" in
  *"auth list --filter=status:ACTIVE"*) echo b@y.com ;;
  *"auth list"*) printf 'a@x.com\nb@y.com\n' ;;
  *"projects list --account=a@x.com"*) printf 'proj-a\nshared\n' ;;
  *"projects list --account=b@y.com"*) printf 'proj-b\nshared\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "${stub}/gcloud"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_gcloud_projects
  '
  rm -rf "$stub"
  assert_success
  assert_line --index 0 "$(printf 'proj-b\tb@y.com')"
  assert_line --index 1 "$(printf 'shared\tb@y.com')"
  assert_line --index 2 "$(printf 'proj-a\ta@x.com')"
  refute_line "$(printf 'shared\ta@x.com')"
}

@test "_setup_project_rows: tags rows with the account only when logins differ" {
  local stub; stub="$(mktemp -d)"
  cat >"${stub}/gcloud" <<'SH'
#!/bin/sh
case "$*" in
  *"auth list --filter=status:ACTIVE"*) echo a@x.com ;;
  *"auth list"*) echo a@x.com ;;
  *"projects list --account=a@x.com"*) printf 'proj-a\nproj-b\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "${stub}/gcloud"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_project_rows $'\''\nproj-a\n'\''
  '
  rm -rf "$stub"
  assert_success
  assert_output "proj-b|proj-b"
}

@test "_setup_change_vertex_projects: the custom row accepts an unlistable project id" {
  printf '[vertex]\nprojects = a\n' >"$CONF"
  local stub; stub="$(mktemp -d)"
  printf '#!/bin/sh\nexit 1\n' >"${stub}/gcloud"
  # Only the project picker is answered; the model prompt that follows a newly
  # attached project is cancelled, which leaves its pins alone.
  cat >"${stub}/fzf" <<SH
#!/bin/sh
cat >/dev/null
[ -e "${stub}/picked" ] && exit 130
: >"${stub}/picked"
printf 'a|a (current)\n=custom=|custom\n'
SH
  chmod +x "${stub}/gcloud" "${stub}/fzf"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    unset GIT_AI_NO_FZF
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_suggest_models() { :; }  # no network — the model prompt is cancelled anyway
    printf "typed-proj\n" | _setup_change_vertex_projects "'"$CONF"'"
  '
  rm -rf "$stub"
  assert_success
  assert_output --partial "Set vertex projects: a, typed-proj"
  run cat "$CONF"
  assert_line "[vertex-gemini@typed-proj]"
  assert_line "[vertex-anthropic@typed-proj]"
}

@test "_setup_gcloud_projects: names the logins whose project listing failed" {
  local stub; stub="$(mktemp -d)"
  cat >"${stub}/gcloud" <<'SH'
#!/bin/sh
case "$*" in
  *"auth list --filter=status:ACTIVE"*) echo a@x.com ;;
  *"auth list"*) printf 'a@x.com\nb@y.com\n' ;;
  *"projects list --account=a@x.com"*) echo proj-a ;;
  *"projects list --account=b@y.com"*) echo "ERROR: Reauthentication failed." >&2; exit 1 ;;
  *) exit 1 ;;
esac
SH
  chmod +x "${stub}/gcloud"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_gcloud_projects 2>&1 >/dev/null
  '
  rm -rf "$stub"
  assert_success
  assert_output --partial "gcloud could not list projects for: b@y.com"
  refute_output --partial "a@x.com"
}

# --- _setup_offer_account_pin (project visible only to a non-active login) ---

_account_stub() { # DIR — gcloud active as a@x.com, projects split across logins
  cat >"${1}/gcloud" <<'SH'
#!/bin/sh
case "$*" in
  *"auth list --filter=status:ACTIVE"*) echo a@x.com ;;
  *) exit 1 ;;
esac
SH
  chmod +x "${1}/gcloud"
}

@test "_setup_offer_account_pin: offers to pin the login that can see the project" {
  printf '[vertex]\nprojects = proj-b\n' >"$CONF"
  local stub; stub="$(mktemp -d)"
  _account_stub "$stub"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    printf "\n" | _setup_offer_account_pin "'"$CONF"'" "proj-b'$'\t''b@y.com" proj-b
  '
  rm -rf "$stub"
  assert_success
  assert_output --partial "visible to b@y.com, but gcloud is active as a@x.com"
  assert_output --partial "Set account = b@y.com"
  run cat "$CONF"
  assert_line "account = b@y.com"
}

@test "_setup_offer_account_pin: silent when the project belongs to the active login" {
  printf '[vertex]\nprojects = proj-a\n' >"$CONF"
  local stub; stub="$(mktemp -d)"
  _account_stub "$stub"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_offer_account_pin "'"$CONF"'" "proj-a'$'\t''a@x.com" proj-a
  '
  rm -rf "$stub"
  assert_success
  assert_output ""
}

@test "_setup_offer_account_pin: silent when an account is already pinned" {
  printf '[vertex]\nprojects = proj-b\naccount = pinned@x.com\n' >"$CONF"
  local stub; stub="$(mktemp -d)"
  _account_stub "$stub"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_offer_account_pin "'"$CONF"'" "proj-b'$'\t''b@y.com" proj-b
  '
  rm -rf "$stub"
  assert_success
  assert_output ""
}

# --- _setup_probe_key (API key validation before storing) ---

_curl_code_stub() { # DIR CODE
  printf '#!/bin/sh\nprintf "%%s" "%s"\n' "$2" >"${1}/curl"
  chmod +x "${1}/curl"
}

@test "_setup_probe_key: a 200 accepts the key" {
  local stub; stub="$(mktemp -d)"
  _curl_code_stub "$stub" 200
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_probe_key anthropic-api sk-test
  '
  rm -rf "$stub"
  assert_success
}

@test "_setup_probe_key: a 401 rejects the key" {
  local stub; stub="$(mktemp -d)"
  _curl_code_stub "$stub" 401
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_probe_key openai-api sk-bad
  '
  rm -rf "$stub"
  assert_equal "$status" 1
}

@test "_setup_probe_key: a server error is indeterminate, not a rejection" {
  local stub; stub="$(mktemp -d)"
  _curl_code_stub "$stub" 503
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_probe_key gemini-api key
  '
  rm -rf "$stub"
  assert_equal "$status" 2
}

@test "_setup_probe_key: keeps the key out of argv" {
  local stub; stub="$(mktemp -d)"
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >&2\nprintf 200\n' >"${stub}/curl"
  chmod +x "${stub}/curl"
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    _setup_probe_key gemini-api super-secret 2>&1
  '
  rm -rf "$stub"
  refute_output --partial "super-secret"
}

@test "_setup_prompt_api_key: a rejected key is not stored unless confirmed" {
  local stub; stub="$(mktemp -d)"
  _curl_code_stub "$stub" 401
  run bash -c '
    export PATH="'"${stub}"':$PATH"
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    store_api_key() { printf "STORED\n"; }
    printf "sk-bad\nn\n" | _setup_prompt_api_key openai-api openai-api-key OPENAI_API_KEY "OpenAI API"
  '
  rm -rf "$stub"
  assert_success
  assert_output --partial "OpenAI API rejected it."
  refute_output --partial "STORED"
}
