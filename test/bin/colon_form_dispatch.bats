#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  source "${REPO_ROOT}/lib/ai-common.sh"
  source "${REPO_ROOT}/bin/git-ai"

  # Stub run_provider so cmd_commit / cmd_pr are exercised without hitting a real LLM.
  run_provider() {
    printf 'STUB provider=%s model=%s tool=%s\n' "$2" "$5" "$1"
  }
  export -f run_provider

  # Stage a trivial change so cmd_commit's "no staged changes" guard passes.
  echo "hello" > file.txt
  git add file.txt
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO"
}

@test "cmd_commit: accepts provider:model single-arg form" {
  run cmd_commit "claude-code:claude-sonnet-4-6"
  assert_success
  assert_output --partial "provider=claude-code model=claude-sonnet-4-6"
}

@test "cmd_commit: two-arg form still resolves identically" {
  run cmd_commit "claude-code" "claude-sonnet-4-6"
  assert_success
  assert_output --partial "provider=claude-code model=claude-sonnet-4-6"
}

@test "cmd_commit: success pushes provider:model into history" {
  run cmd_commit "codex:gpt-5.4-mini"
  assert_success
  run get_choice_history commit
  assert_success
  assert_line --index 0 "codex:gpt-5.4-mini"
}

@test "cmd_commit last: pushes last into history" {
  save_last_message commit "saved message"
  run cmd_commit "last"
  assert_success
  run get_choice_history commit
  assert_success
  assert_line --index 0 "last"
}
