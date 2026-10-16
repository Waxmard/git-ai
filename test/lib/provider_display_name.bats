#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
}

@test "provider_display_name: vertex-gemini collapses to the unified label" {
  run provider_display_name "vertex-gemini"
  assert_success
  assert_output "Vertex AI"
  run provider_display_name "openai-api"
  assert_success
  assert_output "OpenAI API"
}

@test "provider_display_name: unknown produces no output" {
  run provider_display_name "unknown"
  assert_success
  assert_output ""
}

@test "provider_display_name: profile-qualified token is labelled with [profile]" {
  run provider_display_name "vertex-anthropic@acme"
  assert_success
  assert_output "Vertex AI [acme]"
}
