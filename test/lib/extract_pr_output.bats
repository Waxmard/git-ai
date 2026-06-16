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

# extract_pr_output mirrors python/git_ai/_generate.py:_extract_pr_sections.
# A temp file feeds stdin to sidestep escaping in test strings.

@test "extract_pr_output: slices title/body from sentinels" {
  printf '%s\n' '===TITLE===' 'feat: title' '===BODY===' '### Features' '- x' > "$TEST_TMP/in.txt"
  expected=$(printf '%s\n' 'feat: title' '' '### Features' '- x')
  run extract_pr_output < "${TEST_TMP}/in.txt"
  assert_success
  assert_output "$expected"
}

@test "extract_pr_output: discards preamble before the title marker" {
  printf '%s\n' 'That title is 78 chars. Let me shorten.' 'Actually, output only title and body.' \
    '===TITLE===' 'feat: title' '===BODY===' '- x' > "$TEST_TMP/in.txt"
  expected=$(printf '%s\n' 'feat: title' '' '- x')
  run extract_pr_output < "${TEST_TMP}/in.txt"
  assert_success
  assert_output "$expected"
}

@test "extract_pr_output: passes through text without markers" {
  printf '%s\n' 'feat: title' '' '### Features' '- x' > "$TEST_TMP/in.txt"
  expected=$(printf '%s\n' 'feat: title' '' '### Features' '- x')
  run extract_pr_output < "${TEST_TMP}/in.txt"
  assert_success
  assert_output "$expected"
}

@test "extract_pr_output: passes through when body marker missing" {
  printf '%s\n' '===TITLE===' 'feat: title' 'no body marker here' > "$TEST_TMP/in.txt"
  expected=$(printf '%s\n' '===TITLE===' 'feat: title' 'no body marker here')
  run extract_pr_output < "${TEST_TMP}/in.txt"
  assert_success
  assert_output "$expected"
}
