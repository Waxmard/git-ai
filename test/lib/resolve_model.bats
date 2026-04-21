#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
}

# --- explicit model ---

@test "resolve_model: vertex accepts claude model" {
  run resolve_model "commit" "vertex" "claude-sonnet-4-6"
  assert_success
  assert_output "claude-sonnet-4-6"
}

@test "resolve_model: gemini-api accepts gemini model" {
  run resolve_model "commit" "gemini-api" "gemini-3.1-pro-preview"
  assert_success
  assert_output "gemini-3.1-pro-preview"
}

@test "resolve_model: claude-code accepts claude model" {
  run resolve_model "commit" "claude-code" "claude-opus-4-6"
  assert_success
  assert_output "claude-opus-4-6"
}

@test "resolve_model: codex accepts openai model" {
  run resolve_model "commit" "codex" "gpt-5.4-mini"
  assert_success
  assert_output "gpt-5.4-mini"
}

@test "resolve_model: unknown model exits non-zero" {
  run resolve_model "commit" "claude-code" "bogus"
  assert_failure
}

# --- no explicit model ---

@test "resolve_model: pr+claude-code defaults to opus" {
  run resolve_model "pr" "claude-code" ""
  assert_success
  assert_output "claude-opus-4-6"
}

@test "resolve_model: pr+gemini-api defaults to pro" {
  run resolve_model "pr" "gemini-api" ""
  assert_success
  assert_output "gemini-3.1-pro-preview"
}

@test "resolve_model: pr+codex defaults to standard" {
  run resolve_model "pr" "codex" ""
  assert_success
  assert_output "gpt-5.4"
}

@test "resolve_model: commit+claude-code defaults to haiku" {
  run resolve_model "commit" "claude-code" ""
  assert_success
  assert_output "claude-haiku-4-5-20251001"
}

@test "resolve_model: commit+gemini-api defaults to flash-lite" {
  run resolve_model "commit" "gemini-api" ""
  assert_success
  assert_output "gemini-3.1-flash-lite-preview"
}

@test "resolve_model: commit+codex defaults to mini" {
  run resolve_model "commit" "codex" ""
  assert_success
  assert_output "gpt-5.4-mini"
}

@test "resolve_model: vertex requires explicit model" {
  run resolve_model "commit" "vertex" ""
  assert_failure
  assert_output --partial "requires an explicit model"
}
