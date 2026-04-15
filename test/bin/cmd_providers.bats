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

@test "cmd_providers: outputs pipe-delimited provider|display lines" {
  run cmd_providers "commit"
  assert_success
  # Each line must be "provider|Display Name"
  while IFS= read -r line; do
    [[ "$line" == *"|"* ]] || fail "line missing pipe delimiter: $line"
  done <<< "$output"
}

@test "cmd_providers: contains claude" {
  run cmd_providers "commit"
  assert_success
  assert_output --partial "claude|"
}

@test "cmd_providers: contains gemini" {
  run cmd_providers "commit"
  assert_success
  assert_output --partial "gemini|"
}

@test "cmd_providers: contains codex" {
  run cmd_providers "commit"
  assert_success
  assert_output --partial "codex|"
}

@test "cmd_providers: last provider appears first after save" {
  save_last_provider "commit" "codex"
  run cmd_providers "commit"
  assert_success
  assert_line --index 0 "codex|OpenAI (Codex)"
}
