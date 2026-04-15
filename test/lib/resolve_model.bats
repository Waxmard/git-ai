#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
}

# --- explicit tier ---

@test "resolve_model: claude+haiku" {
  run resolve_model "commit" "claude" "haiku"
  assert_success
  assert_output "claude-haiku-4-5-20251001"
}

@test "resolve_model: claude+sonnet" {
  run resolve_model "commit" "claude" "sonnet"
  assert_success
  assert_output "claude-sonnet-4-6"
}

@test "resolve_model: claude+opus" {
  run resolve_model "commit" "claude" "opus"
  assert_success
  assert_output "claude-opus-4-6"
}

@test "resolve_model: gemini+flash-lite" {
  run resolve_model "commit" "gemini" "flash-lite"
  assert_success
  assert_output "gemini-3.1-flash-lite-preview"
}

@test "resolve_model: gemini+pro" {
  run resolve_model "commit" "gemini" "pro"
  assert_success
  assert_output "gemini-3.1-pro-preview"
}

@test "resolve_model: codex+mini" {
  run resolve_model "commit" "codex" "mini"
  assert_success
  assert_output "gpt-5.4-mini"
}

@test "resolve_model: codex+standard" {
  run resolve_model "commit" "codex" "standard"
  assert_success
  assert_output "gpt-5.4"
}

@test "resolve_model: unknown tier exits non-zero" {
  run resolve_model "commit" "claude" "bogus"
  assert_failure
}

# --- no tier (tool-name defaults) ---

@test "resolve_model: pr+claude defaults to opus" {
  run resolve_model "pr" "claude" ""
  assert_success
  assert_output "claude-opus-4-6"
}

@test "resolve_model: pr+gemini defaults to pro" {
  run resolve_model "pr" "gemini" ""
  assert_success
  assert_output "gemini-3.1-pro-preview"
}

@test "resolve_model: pr+codex defaults to standard" {
  run resolve_model "pr" "codex" ""
  assert_success
  assert_output "gpt-5.4"
}

@test "resolve_model: commit+claude defaults to haiku" {
  run resolve_model "commit" "claude" ""
  assert_success
  assert_output "claude-haiku-4-5-20251001"
}

@test "resolve_model: commit+gemini defaults to flash-lite" {
  run resolve_model "commit" "gemini" ""
  assert_success
  assert_output "gemini-3.1-flash-lite-preview"
}

@test "resolve_model: commit+codex defaults to mini" {
  run resolve_model "commit" "codex" ""
  assert_success
  assert_output "gpt-5.4-mini"
}
