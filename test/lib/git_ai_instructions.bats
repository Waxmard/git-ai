#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_DIR="$(mktemp -d)"
  source "${REPO_ROOT}/lib/ai-common.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "load_git_ai_instructions: prints nothing when file absent" {
  run load_git_ai_instructions "$TEST_DIR"
  assert_success
  assert_output ""
}

@test "load_git_ai_instructions: prints nothing when file is whitespace-only" {
  printf '   \n\n' >"${TEST_DIR}/.git-ai-instructions"
  run load_git_ai_instructions "$TEST_DIR"
  assert_success
  assert_output ""
}

@test "load_git_ai_instructions: prints nothing for non-UTF-8 file" {
  if ! command -v iconv >/dev/null 2>&1; then
    skip "iconv not available"
  fi
  # Invalid UTF-8 byte sequence (lone 0xff) — Python path skips it; bash mirrors.
  printf '\xff\xfeScopes: api.\n' >"${TEST_DIR}/.git-ai-instructions"
  run load_git_ai_instructions "$TEST_DIR"
  assert_success
  assert_output ""
}

@test "load_git_ai_instructions: returns trimmed contents" {
  printf '\n  Scopes: api, web.\ntag bump = chore.\n\n' \
    >"${TEST_DIR}/.git-ai-instructions"
  run load_git_ai_instructions "$TEST_DIR"
  assert_success
  assert_line 'Scopes: api, web.'
  assert_line 'tag bump = chore.'
  # Leading/trailing blank lines are trimmed.
  assert_equal "${lines[0]}" 'Scopes: api, web.'
  assert_equal "${lines[1]}" 'tag bump = chore.'
  assert_equal "${#lines[@]}" 2
}
