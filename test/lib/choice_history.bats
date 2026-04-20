#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  source "${REPO_ROOT}/lib/ai-common.sh"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO"
}

@test "get_choice_history: empty when nothing stored" {
  run get_choice_history commit
  assert_success
  assert_output ""
}

@test "push_choice_history + get_choice_history: round-trips single value" {
  push_choice_history commit "claude-code:claude-haiku-4-5-20251001"
  run get_choice_history commit
  assert_success
  assert_output "claude-code:claude-haiku-4-5-20251001"
}

@test "push_choice_history: most-recent first, dedupes prior occurrence" {
  push_choice_history commit "vertex:gemini-3.1-pro-preview"
  push_choice_history commit "claude-code:claude-sonnet-4-6"
  push_choice_history commit "vertex:gemini-3.1-pro-preview"
  run get_choice_history commit
  assert_success
  assert_line --index 0 "vertex:gemini-3.1-pro-preview"
  assert_line --index 1 "claude-code:claude-sonnet-4-6"
  # Prior "vertex:..." entry was deduped
  [ "${#lines[@]}" -eq 2 ]
}

@test "push_choice_history: caps at CHOICE_HISTORY_CAP entries" {
  local i
  for i in $(seq 1 40); do
    push_choice_history commit "fake:entry-${i}"
  done
  run get_choice_history commit
  assert_success
  [ "${#lines[@]}" -eq "$CHOICE_HISTORY_CAP" ]
  assert_line --index 0 "fake:entry-40"
}

@test "push_choice_history: separate history per tool" {
  push_choice_history commit "claude-code:claude-haiku-4-5-20251001"
  push_choice_history pr "vertex:gemini-3.1-pro-preview"
  run get_choice_history commit
  assert_success
  assert_output "claude-code:claude-haiku-4-5-20251001"
  run get_choice_history pr
  assert_success
  assert_output "vertex:gemini-3.1-pro-preview"
}

@test "push_choice_history: outside a git repo is a no-op" {
  cd /tmp
  run push_choice_history commit "claude-code:claude-haiku-4-5-20251001"
  assert_success
}
