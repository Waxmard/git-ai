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

@test "strip_fences: unwraps subject wrapped in an inline code span" {
  printf '%s' '`feat: add git-ai-instructions playbook page and root file`' > "$TEST_TMP/input.txt"
  run strip_fences < "${TEST_TMP}/input.txt"
  assert_success
  assert_output "feat: add git-ai-instructions playbook page and root file"
}

@test "strip_fences: unwraps subject but keeps body code spans" {
  printf '%s\n' '`feat: add thing`' '' 'Body uses the `foo` helper.' > "$TEST_TMP/input.txt"
  expected=$(printf '%s\n' 'feat: add thing' '' 'Body uses the `foo` helper.')
  run strip_fences < "${TEST_TMP}/input.txt"
  assert_success
  assert_output "$expected"
}

@test "strip_fences: leaves ambiguous multi-span line untouched" {
  printf '%s' '`a` and `b`' > "$TEST_TMP/input.txt"
  run strip_fences < "${TEST_TMP}/input.txt"
  assert_success
  assert_output '`a` and `b`'
}

@test "strip_fences: inner fenced block survives" {
  printf '%s\n' '===TITLE===' 'fix: thing' '===BODY===' '## Verification' '' '```bash' 'npm test' '```' '' 'All pass.' > "$TEST_TMP/input.txt"
  expected=$(printf '%s\n' '===TITLE===' 'fix: thing' '===BODY===' '## Verification' '' '```bash' 'npm test' '```' '' 'All pass.')
  run strip_fences < "${TEST_TMP}/input.txt"
  assert_success
  assert_output "$expected"
}

@test "strip_fences: unwraps outer fence around an inner block" {
  printf '%s\n' '```markdown' '## Verification' '' '```bash' 'npm test' '```' '```' > "$TEST_TMP/input.txt"
  expected=$(printf '%s\n' '## Verification' '' '```bash' 'npm test' '```')
  run strip_fences < "${TEST_TMP}/input.txt"
  assert_success
  assert_output "$expected"
}

@test "strip_fences: lone trailing fence is not a wrapper" {
  printf '%s\n' '## Verification' '' '```bash' 'npm test' '```' > "$TEST_TMP/input.txt"
  expected=$(printf '%s\n' '## Verification' '' '```bash' 'npm test' '```')
  run strip_fences < "${TEST_TMP}/input.txt"
  assert_success
  assert_output "$expected"
}

@test "strip_fences: lone leading fence is not a wrapper" {
  printf '%s\n' '```bash' 'npm test' '```' '' 'All suites should pass.' > "$TEST_TMP/input.txt"
  expected=$(printf '%s\n' '```bash' 'npm test' '```' '' 'All suites should pass.')
  run strip_fences < "${TEST_TMP}/input.txt"
  assert_success
  assert_output "$expected"
}
