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
  run get_last_choice "commit-last-provider" "gemini" "claude|gemini|codex"
  assert_success
  assert_output "gemini"
}

@test "save_last_choice + get_last_choice: round-trips value" {
  save_last_choice "commit-last-provider" "claude"
  run get_last_choice "commit-last-provider" "gemini" "claude|gemini|codex"
  assert_success
  assert_output "claude"
}

@test "get_last_choice: rejects stored value not in valid set, returns fallback" {
  save_last_choice "commit-last-provider" "bogusprovider"
  run get_last_choice "commit-last-provider" "gemini" "claude|gemini|codex"
  assert_success
  assert_output "gemini"
}

@test "get_last_choice: returns fallback when outside a git repo" {
  cd /tmp
  run get_last_choice "commit-last-provider" "codex" "claude|gemini|codex"
  assert_success
  assert_output "codex"
}

# --- get_last_provider / save_last_provider ---

@test "get_last_provider: defaults to gemini when nothing stored" {
  run get_last_provider "commit"
  assert_success
  assert_output "gemini"
}

@test "save_last_provider + get_last_provider: round-trips" {
  save_last_provider "commit" "claude"
  run get_last_provider "commit"
  assert_success
  assert_output "claude"
}

# --- get_last_tier / save_last_tier ---

@test "get_last_tier: returns fallback when nothing stored" {
  run get_last_tier "commit" "claude" "haiku"
  assert_success
  assert_output "haiku"
}

@test "save_last_tier + get_last_tier: round-trips" {
  save_last_tier "commit" "claude" "sonnet"
  run get_last_tier "commit" "claude" "haiku"
  assert_success
  assert_output "sonnet"
}

@test "get_last_tier: per-provider isolation (claude tier doesn't affect gemini)" {
  save_last_tier "commit" "claude" "opus"
  run get_last_tier "commit" "gemini" "flash-lite"
  assert_success
  assert_output "flash-lite"
}
