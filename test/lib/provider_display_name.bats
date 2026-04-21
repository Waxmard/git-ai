#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
}

@test "provider_display_name: vertex" {
  run provider_display_name "vertex"
  assert_success
  assert_output "Vertex AI"
}

@test "provider_display_name: gemini-api" {
  run provider_display_name "gemini-api"
  assert_success
  assert_output "Gemini API"
}

@test "provider_display_name: claude-code" {
  run provider_display_name "claude-code"
  assert_success
  assert_output "Claude Code"
}

@test "provider_display_name: anthropic-api" {
  run provider_display_name "anthropic-api"
  assert_success
  assert_output "Anthropic API"
}

@test "provider_display_name: codex" {
  run provider_display_name "codex"
  assert_success
  assert_output "Codex CLI"
}

@test "provider_display_name: openai-api" {
  run provider_display_name "openai-api"
  assert_success
  assert_output "OpenAI API"
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
