#!/usr/bin/env bats
load '../helpers/common'

# Models are no longer validated against a fixed catalog: an explicit model is
# passed through verbatim, and the default (when none is given) is the tool's
# last saved pick, else the first model discovery returns. These tests run fully
# offline — a stub PATH neutralises curl/keychain/gcloud so discovery only ever
# sees the seeded on-disk cache.
setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  source "${REPO_ROOT}/lib/ai-common.sh"

  TEST_XDG="$(mktemp -d)"
  export XDG_CONFIG_HOME="$TEST_XDG"
  CACHE="${TEST_XDG}/git-ai/models-cache"
  mkdir -p "$CACHE"

  # Block all live discovery: no env keys, and stubs that fail for every network
  # / secret-store binary the fetchers consult.
  unset GEMINI_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY
  STUB="$(mktemp -d)"
  local c
  for c in curl security secret-tool pass kwallet-query gcloud; do
    printf '#!/bin/sh\nexit 1\n' >"${STUB}/${c}"
    chmod +x "${STUB}/${c}"
  done
  export PATH="${STUB}:${PATH}"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO" "$TEST_XDG" "$STUB"
  unset XDG_CONFIG_HOME
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

@test "resolve_model: default is the first discovered model" {
  printf 'gemini-3.5-pro\ngemini-3.5-flash\n' >"${CACHE}/gemini-api.list"
  run resolve_model "commit" "gemini-api" ""
  assert_success
  assert_output "gemini-3.5-pro"
}

@test "resolve_model: a saved last pick takes precedence over discovery" {
  printf 'gemini-3.5-pro\ngemini-3.5-flash\n' >"${CACHE}/gemini-api.list"
  save_last_model commit gemini-api "gemini-3.5-flash"
  run resolve_model "commit" "gemini-api" ""
  assert_success
  assert_output "gemini-3.5-flash"
}

@test "resolve_model: no model, no discovery, no saved pick exits non-zero" {
  run resolve_model "commit" "gemini-api" ""
  assert_failure
  assert_output --partial "could not determine a model"
}
