#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
}

@test "provider_display_name: claude" {
  run provider_display_name "claude"
  assert_success
  assert_output "Claude"
}

@test "provider_display_name: gemini" {
  run provider_display_name "gemini"
  assert_success
  assert_output "Gemini"
}

@test "provider_display_name: codex" {
  run provider_display_name "codex"
  assert_success
  assert_output "OpenAI (Codex)"
}

@test "provider_display_name: last" {
  run provider_display_name "last"
  assert_success
  assert_output "Reuse last message"
}

@test "provider_display_name: unknown produces no output" {
  run provider_display_name "unknown"
  assert_success
  assert_output ""
}
