#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
}

@test "order_by_recent: moves last item to front" {
  run order_by_recent "gemini" "claude" "gemini" "codex"
  assert_success
  assert_line --index 0 "gemini"
  assert_line --index 1 "claude"
  assert_line --index 2 "codex"
}

@test "order_by_recent: no duplication when last is already first" {
  run order_by_recent "claude" "claude" "gemini" "codex"
  assert_success
  assert_output "$(printf 'claude\ngemini\ncodex')"
}

@test "order_by_recent: last not in list still prepended" {
  run order_by_recent "openai" "claude" "gemini"
  assert_success
  assert_line --index 0 "openai"
  assert_line --index 1 "claude"
  assert_line --index 2 "gemini"
}

@test "order_by_recent: last at end of list moved to front" {
  run order_by_recent "codex" "claude" "gemini" "codex"
  assert_success
  assert_line --index 0 "codex"
  assert_line --index 1 "claude"
  assert_line --index 2 "gemini"
}

@test "order_by_recent: single item list" {
  run order_by_recent "claude" "claude"
  assert_success
  assert_output "claude"
}
