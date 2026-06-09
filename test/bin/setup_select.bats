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

# --- _merge_vertex_projects (additive project attach) ---

@test "_merge_vertex_projects: new project appended to current list" {
  run _merge_vertex_projects "the-file-system" "sierra-data-den"
  assert_success
  assert_output "the-file-system, sierra-data-den"
}

@test "_merge_vertex_projects: re-picking an existing project dedupes" {
  run _merge_vertex_projects "proj-a, proj-b" "proj-b" "proj-c"
  assert_success
  assert_output "proj-a, proj-b, proj-c"
}

@test "_merge_vertex_projects: empty current list yields just the picks" {
  run _merge_vertex_projects "" "proj-a" "proj-b"
  assert_success
  assert_output "proj-a, proj-b"
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
