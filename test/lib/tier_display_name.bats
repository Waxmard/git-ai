#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
}

@test "provider_family: vertex-gemini maps to gemini" {
  run provider_family "vertex-gemini"
  assert_success
  assert_output "gemini"
}

@test "provider_family: vertex-anthropic maps to claude" {
  run provider_family "vertex-anthropic"
  assert_success
  assert_output "claude"
}

@test "provider_family: antigravity maps to gemini" {
  run provider_family "antigravity"
  assert_success
  assert_output "gemini"
}

@test "provider_family: codex maps to openai runtime" {
  run provider_family "codex"
  assert_success
  assert_output "openai"
}
