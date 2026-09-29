#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
}

@test "recommended_model: each provider resolves to its family's pin" {
  GIT_AI_RECOMMENDED_MODELS_FILE="$BATS_TEST_TMPDIR/rec.conf"
  printf '%s\n' 'anthropic = a-model' 'google = g-model' 'openai = o-model' \
    'deepseek = d-model' 'antigravity = ag-model' >"$GIT_AI_RECOMMENDED_MODELS_FILE"
  for pair in claude-code:a-model anthropic-api:a-model vertex-anthropic:a-model \
              vertex-anthropic@acme:a-model gemini-api:g-model vertex-gemini:g-model \
              openai-api:o-model codex:o-model deepseek-api:d-model antigravity:ag-model; do
    run recommended_model "${pair%%:*}"
    assert_success
    assert_output "${pair#*:}"
  done
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
