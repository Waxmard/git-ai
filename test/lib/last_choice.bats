#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  source "${REPO_ROOT}/lib/ai-common.sh"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO"
}

# --- get_last_choice / save_last_choice ---

@test "get_last_choice: returns fallback when no state file exists" {
  run get_last_choice "commit-last-provider" "vertex" "vertex|gemini-api|claude-code|anthropic-api|codex|openai-api"
  assert_success
  assert_output "vertex"
}

@test "save_last_choice + get_last_choice: round-trips value" {
  save_last_choice "commit-last-provider" "claude-code"
  run get_last_choice "commit-last-provider" "vertex" "vertex|gemini-api|claude-code|anthropic-api|codex|openai-api"
  assert_success
  assert_output "claude-code"
}

@test "get_last_choice: rejects stored value not in valid set, returns fallback" {
  save_last_choice "commit-last-provider" "bogusprovider"
  run get_last_choice "commit-last-provider" "vertex" "vertex|gemini-api|claude-code|anthropic-api|codex|openai-api"
  assert_success
  assert_output "vertex"
}

@test "get_last_choice: returns fallback when outside a git repo" {
  cd /tmp
  run get_last_choice "commit-last-provider" "codex" "vertex|gemini-api|claude-code|anthropic-api|codex|openai-api"
  assert_success
  assert_output "codex"
}

# --- get_last_provider / save_last_provider ---

@test "get_last_provider: returns empty when nothing stored" {
  run get_last_provider "commit"
  assert_success
  assert_output ""
}

@test "save_last_provider + get_last_provider: round-trips" {
  save_last_provider "commit" "claude-code"
  run get_last_provider "commit"
  assert_success
  assert_output "claude-code"
}

# --- get_last_model / save_last_model ---

@test "get_last_model: returns fallback when nothing stored" {
  run get_last_model "commit" "claude-code" "claude-haiku-4-5-20251001"
  assert_success
  assert_output "claude-haiku-4-5-20251001"
}

@test "save_last_model + get_last_model: round-trips" {
  save_last_model "commit" "claude-code" "claude-sonnet-4-6"
  run get_last_model "commit" "claude-code" "claude-haiku-4-5-20251001"
  assert_success
  assert_output "claude-sonnet-4-6"
}

@test "get_last_model: per-provider isolation" {
  save_last_model "commit" "claude-code" "claude-opus-4-6"
  run get_last_model "commit" "gemini-api" "gemini-3.1-flash-lite-preview"
  assert_success
  assert_output "gemini-3.1-flash-lite-preview"
}
