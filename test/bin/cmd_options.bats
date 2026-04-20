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

@test "cmd_options commit: outputs pipe-delimited lines" {
  run cmd_options commit
  assert_success
  while IFS= read -r line; do
    [[ "$line" == *"|"* ]] || fail "line missing pipe: $line"
  done <<< "$output"
}

@test "cmd_options pr: default tool is commit when missing arg" {
  save_last_message commit "test message"
  run cmd_options
  assert_success
  assert_output --partial "last|reuse saved message"
}

@test "cmd_options pr: no last entry" {
  save_last_message commit "test message"
  run cmd_options pr
  assert_success
  refute_output --partial "last|"
}

@test "cmd_options commit: history entry floats to top" {
  push_choice_history commit "codex:gpt-5.4-mini"
  run cmd_options commit
  assert_success
  assert_line --index 0 "codex:gpt-5.4-mini|gpt-5.4-mini · Codex CLI"
}
