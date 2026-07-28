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

@test "_extract_anthropic_text: returns the text block" {
  printf '%s' '{"content":[{"type":"text","text":"feat: add thing"}]}' > "$TEST_TMP/r.json"
  run _extract_anthropic_text < "${TEST_TMP}/r.json"
  assert_success
  assert_output "feat: add thing"
}

@test "_extract_anthropic_text: skips a leading thinking block" {
  printf '%s' '{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"fix: bug"}]}' > "$TEST_TMP/r.json"
  run _extract_anthropic_text < "${TEST_TMP}/r.json"
  assert_success
  assert_output "fix: bug"
}

@test "_extract_anthropic_text: joins multiple text blocks" {
  printf '%s' '{"content":[{"type":"text","text":"line1\n"},{"type":"text","text":"line2"}]}' > "$TEST_TMP/r.json"
  run _extract_anthropic_text < "${TEST_TMP}/r.json"
  assert_success
  assert_line --index 0 "line1"
  assert_line --index 1 "line2"
}

@test "_extract_anthropic_text: fails when no text block is present" {
  printf '%s' '{"content":[{"type":"thinking","thinking":"hmm"}]}' > "$TEST_TMP/r.json"
  run _extract_anthropic_text < "${TEST_TMP}/r.json"
  assert_failure
}

@test "_extract_anthropic_text: fails on an error response" {
  printf '%s' '{"error":{"message":"nope"}}' > "$TEST_TMP/r.json"
  run _extract_anthropic_text < "${TEST_TMP}/r.json"
  assert_failure
}
