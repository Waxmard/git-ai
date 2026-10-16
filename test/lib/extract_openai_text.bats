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

@test "_extract_openai_text: returns the message content" {
  printf '%s' '{"choices":[{"message":{"content":"feat: x"}}]}' > "$TEST_TMP/r.json"
  run _extract_openai_text < "${TEST_TMP}/r.json"
  assert_success
  assert_output "feat: x"
}

@test "_extract_openai_text: fails on null content" {
  printf '%s' '{"choices":[{"message":{"content":null}}]}' > "$TEST_TMP/r.json"
  run _extract_openai_text < "${TEST_TMP}/r.json"
  assert_failure
}

@test "_extract_openai_text: fails on an error response" {
  printf '%s' '{"error":{"message":"nope"}}' > "$TEST_TMP/r.json"
  run _extract_openai_text < "${TEST_TMP}/r.json"
  assert_failure
}
