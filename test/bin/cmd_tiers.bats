#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  source "${REPO_ROOT}/lib/ai-common.sh"
  source "${REPO_ROOT}/bin/git-ai"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO"
}

@test "cmd_models: vertex-gemini returns gemini models" {
  run cmd_models "vertex-gemini" "commit"
  assert_success
  assert_output --partial "gemini-3.1-flash-lite-preview|"
  assert_output --partial "gemini-3.1-pro-preview|"
}

@test "cmd_models: vertex-anthropic returns claude models" {
  run cmd_models "vertex-anthropic" "commit"
  assert_success
  assert_output --partial "claude-sonnet-4-6|"
  assert_output --partial "claude-opus-4-6|"
}

@test "cmd_models: gemini-api returns gemini models" {
  run cmd_models "gemini-api" "commit"
  assert_success
  assert_output --partial "gemini-3.1-flash-lite-preview|"
  assert_output --partial "gemini-3.1-pro-preview|"
}

@test "cmd_models: codex returns openai models" {
  run cmd_models "codex" "commit"
  assert_success
  assert_output --partial "gpt-5.4-mini|"
  assert_output --partial "gpt-5.4|"
}

@test "cmd_models: last provider returns single reuse-message line" {
  run cmd_models "last" "commit"
  assert_success
  assert_output --partial "n/a|"
}

@test "cmd_models: outputs pipe-delimited model|display lines" {
  run cmd_models "claude-code" "commit"
  assert_success
  while IFS= read -r line; do
    [[ "$line" == *"|"* ]] || fail "line missing pipe delimiter: $line"
  done <<< "$output"
}

@test "cmd_models: last model appears first after save" {
  save_last_model "commit" "claude-code" "claude-opus-4-6"
  run cmd_models "claude-code" "commit"
  assert_success
  assert_line --index 0 "claude-opus-4-6|claude-opus-4-6"
}
