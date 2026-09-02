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
    assert_output "claude-sonnet-5"
  done
}

@test "recommended_model: gemini/google family maps to flash" {
  for p in gemini-api vertex-gemini; do
    run recommended_model "$p"
    assert_success
    assert_output "gemini-3.7-flash"
  done
}

@test "recommended_model: antigravity has its own effort-suffixed pin" {
  run recommended_model antigravity
  assert_success
  assert_output "gemini-3.8-flash-low"
}

@test "recommended_model: openai family maps to gpt terra" {
  for p in openai-api codex; do
    run recommended_model "$p"
    assert_success
    assert_output "gpt-5.6-terra"
  done
}

@test "recommended_model: profile-qualified vertex token resolves to base family" {
  run recommended_model "vertex-anthropic@acme"
  assert_success
  assert_output "claude-sonnet-5"
}

@test "recommended_model: unknown provider produces no output" {
  run recommended_model "last"
  assert_success
  assert_output ""
}

@test "recommended_model: reads from the data file, not code" {
  GIT_AI_RECOMMENDED_MODELS_FILE="$(mktemp)"
  printf '# comment\nanthropic = claude-test-9\n' >"$GIT_AI_RECOMMENDED_MODELS_FILE"
  run recommended_model "claude-code"
  rm -f "$GIT_AI_RECOMMENDED_MODELS_FILE"
  assert_success
  assert_output "claude-test-9"
}

@test "recommended_model: missing data file yields no recommendation" {
  GIT_AI_RECOMMENDED_MODELS_FILE="/nonexistent/recommended-models.conf"
  run recommended_model "claude-code"
  assert_success
  assert_output ""
}

@test "recommended_model: family absent from the data file yields no recommendation" {
  GIT_AI_RECOMMENDED_MODELS_FILE="$(mktemp)"
  printf 'anthropic = claude-test-9\n' >"$GIT_AI_RECOMMENDED_MODELS_FILE"
  run recommended_model "openai-api"
  rm -f "$GIT_AI_RECOMMENDED_MODELS_FILE"
  assert_success
  assert_output ""
}
