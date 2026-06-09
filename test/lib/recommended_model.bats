#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
}

@test "recommended_model: anthropic family maps to sonnet" {
  for p in claude-code anthropic-api vertex-anthropic; do
    run recommended_model "$p"
    assert_success
    assert_output "claude-sonnet-4-6"
  done
}

@test "recommended_model: gemini/google family maps to flash" {
  for p in gemini-api vertex-gemini; do
    run recommended_model "$p"
    assert_success
    assert_output "gemini-3.5-flash"
  done
}

@test "recommended_model: openai family maps to gpt mini" {
  for p in openai-api codex; do
    run recommended_model "$p"
    assert_success
    assert_output "gpt-5.4-mini"
  done
}

@test "recommended_model: profile-qualified vertex token resolves to base family" {
  run recommended_model "vertex-anthropic@acme"
  assert_success
  assert_output "claude-sonnet-4-6"
}

@test "recommended_model: unknown provider produces no output" {
  run recommended_model "last"
  assert_success
  assert_output ""
}
