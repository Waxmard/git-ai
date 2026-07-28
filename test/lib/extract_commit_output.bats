#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# extract_commit_output mirrors python/git_ai/_generate.py:_extract_commit_message.
# A temp file feeds stdin to sidestep escaping in test strings.

@test "extract_commit_output: takes everything after the ===COMMIT=== marker" {
  printf '%s\n' 'Reasoning: feat, since new capability.' '===COMMIT===' 'feat: add thing' '' 'Body line.' > "$TEST_TMP/in.txt"
  expected=$(printf '%s\n' 'feat: add thing' '' 'Body line.')
  run extract_commit_output < "${TEST_TMP}/in.txt"
  assert_success
  assert_output "$expected"
}

@test "extract_commit_output: no marker drops preamble before the first conventional subject" {
  printf '%s\n' 'docs+test changes. feat, since new user-facing wizard capability.' '' 'fix: preselect current entries' '' 'Body line.' > "$TEST_TMP/in.txt"
  expected=$(printf '%s\n' 'fix: preselect current entries' '' 'Body line.')
  run extract_commit_output < "${TEST_TMP}/in.txt"
  assert_success
  assert_output "$expected"
}

@test "extract_commit_output: a clean message passes through unchanged" {
  printf '%s\n' 'chore(deps): bump x' '' 'Body line.' > "$TEST_TMP/in.txt"
  expected=$(printf '%s\n' 'chore(deps): bump x' '' 'Body line.')
  run extract_commit_output < "${TEST_TMP}/in.txt"
  assert_success
  assert_output "$expected"
}

@test "extract_commit_output: no marker and no conventional subject passes through" {
  printf '%s\n' 'just some text' > "$TEST_TMP/in.txt"
  run extract_commit_output < "${TEST_TMP}/in.txt"
  assert_success
  assert_output "just some text"
}

@test "extract_commit_output: an empty marker section falls back to the subject scan" {
  printf '%s\n' '===COMMIT===' > "$TEST_TMP/in.txt"
  run extract_commit_output < "${TEST_TMP}/in.txt"
  assert_success
  assert_output "===COMMIT==="
}

@test "extract_commit_output: drops a trailing closing marker" {
  printf '%s\n' '===COMMIT===' 'feat: add thing' '' 'Body.' '===COMMIT===' > "$TEST_TMP/in.txt"
  expected=$(printf '%s\n' 'feat: add thing' '' 'Body.')
  run extract_commit_output < "${TEST_TMP}/in.txt"
  assert_success
  assert_output "$expected"
}

@test "extract_commit_output: falls back to an indented conventional subject" {
  printf '%s\n' 'Reasoning:' '  fix: correct the guard' '' 'Body.' > "$TEST_TMP/in.txt"
  expected=$(printf '%s\n' 'fix: correct the guard' '' 'Body.')
  run extract_commit_output < "${TEST_TMP}/in.txt"
  assert_success
  assert_output "$expected"
}
