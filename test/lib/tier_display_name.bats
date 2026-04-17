#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
}

@test "models_for_provider: claude-code includes sonnet" {
  run models_for_provider "claude-code"
  assert_success
  assert_output --partial "claude-sonnet-4-6"
}

@test "models_for_provider: gemini-api includes pro" {
  run models_for_provider "gemini-api"
  assert_success
  assert_output --partial "gemini-3.1-pro-preview"
}

@test "models_for_provider: openai-api includes gpt-5.4" {
  run models_for_provider "openai-api"
  assert_success
  assert_output --partial "gpt-5.4"
}

@test "models_for_provider: vertex includes all families" {
  run models_for_provider "vertex"
  assert_success
  assert_output --partial "gemini-3.1-flash-lite-preview"
  assert_output --partial "claude-opus-4-6"
  assert_output --partial "gpt-5.4-mini"
}

@test "models_for_provider: unknown exits non-zero" {
  run models_for_provider "unknown"
  assert_failure
}

@test "default_model_for_provider: pr+anthropic-api uses opus" {
  run default_model_for_provider "pr" "anthropic-api"
  assert_success
  assert_output "claude-opus-4-6"
}

@test "default_model_for_provider: commit+openai-api uses mini" {
  run default_model_for_provider "commit" "openai-api"
  assert_success
  assert_output "gpt-5.4-mini"
}

@test "provider_family: vertex maps to gemini runtime" {
  run provider_family "vertex"
  assert_success
  assert_output "gemini"
}

@test "provider_family: codex maps to openai runtime" {
  run provider_family "codex"
  assert_success
  assert_output "openai"
}
