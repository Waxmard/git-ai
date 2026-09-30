#!/usr/bin/env bats
load '../helpers/common'

# Models are no longer validated against a fixed catalog: an explicit model is
# passed through verbatim, and the default (when none is given) is the tool's
# last saved pick, else the family's recommended model. Discovery never picks
# the default.
setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  TEST_XDG="$(mktemp -d)"
  export XDG_CONFIG_HOME="$TEST_XDG"
  export GIT_AI_RECOMMENDED_MODELS_FILE="${TEST_XDG}/rec.conf"
  printf 'google = gemini-rec\n' >"$GIT_AI_RECOMMENDED_MODELS_FILE"
  source "${REPO_ROOT}/lib/ai-common.sh"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO" "$TEST_XDG"
  unset XDG_CONFIG_HOME GIT_AI_RECOMMENDED_MODELS_FILE
}

# --- explicit model passes through verbatim ---

@test "resolve_model: explicit model is returned unchanged" {
  run resolve_model "commit" "vertex-anthropic" "claude-sonnet-4-6"
  assert_success
  assert_output "claude-sonnet-4-6"
}

@test "resolve_model: any id passes through (no catalog validation)" {
  run resolve_model "commit" "gemini-api" "gemini-9.9-experimental-xyz"
  assert_success
  assert_output "gemini-9.9-experimental-xyz"
}

@test "resolve_model: profile-qualified provider passes the model through" {
  run resolve_model "commit" "vertex-gemini@proj-01" "gemini-3.5-flash"
  assert_success
  assert_output "gemini-3.5-flash"
}

# --- default (no explicit model) ---

@test "resolve_model: default is the recommended model, not the first discovered" {
  mkdir -p "${TEST_XDG}/git-ai/models-cache"
  printf 'gemini-3.5-pro\n' >"${TEST_XDG}/git-ai/models-cache/gemini-api.list"
  run resolve_model "commit" "gemini-api" ""
  assert_success
  assert_output "gemini-rec"
}

@test "resolve_model: a saved last pick takes precedence over the recommendation" {
  save_last_model commit gemini-api "gemini-3.5-flash"
  run resolve_model "commit" "gemini-api" ""
  assert_success
  assert_output "gemini-3.5-flash"
}

@test "resolve_model: no model, no recommendation, no saved pick exits non-zero" {
  run resolve_model "commit" "codex" ""
  assert_failure
  assert_output --partial "could not determine a model"
}
