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

# setup() sources ai-common.sh, so strip_fences is called directly (no re-source
# subshell). A temp file feeds stdin to sidestep backtick escaping in test strings.

@test "strip_fences: removes plain triple-backtick fence" {
  printf '%s\n' '```' 'hello' '```' > "$TEST_TMP/input.txt"
  run strip_fences < "${TEST_TMP}/input.txt"
  assert_success
  assert_output "hello"
}

@test "strip_fences: removes language-tagged fence (bash)" {
  printf '%s\n' '```bash' 'echo hi' '```' > "$TEST_TMP/input.txt"
  run strip_fences < "${TEST_TMP}/input.txt"
  assert_success
  assert_output "echo hi"
}

@test "strip_fences: removes language-tagged fence (sh)" {
  printf '%s\n' '```sh' 'ls' '```' > "$TEST_TMP/input.txt"
  run strip_fences < "${TEST_TMP}/input.txt"
  assert_success
  assert_output "ls"
}

@test "strip_fences: passes through plain text unchanged" {
  printf '%s\n' 'plain text' > "$TEST_TMP/input.txt"
  run strip_fences < "${TEST_TMP}/input.txt"
  assert_success
  assert_output "plain text"
}

@test "strip_fences: strips surrounding blank lines" {
  printf '\n\ntext\n\n' > "$TEST_TMP/input.txt"
  run strip_fences < "${TEST_TMP}/input.txt"
  assert_success
  assert_output "text"
}

@test "strip_fences: multiline content preserved" {
  printf '%s\n' '```' 'line1' 'line2' '```' > "$TEST_TMP/input.txt"
  run strip_fences < "${TEST_TMP}/input.txt"
  assert_success
  assert_line --index 0 "line1"
  assert_line --index 1 "line2"
}

@test "strip_fences: body line starting with single backtick preserved" {
  printf '%s\n' 'feat: add foo' '' '`backtick_var` improves things' 'more stuff' > "$TEST_TMP/input.txt"
  expected=$(printf '%s\n' 'feat: add foo' '' '`backtick_var` improves things' 'more stuff')
  run strip_fences < "${TEST_TMP}/input.txt"
  assert_success
  assert_output "$expected"
}
