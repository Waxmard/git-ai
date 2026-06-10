#!/usr/bin/env bats
load '../helpers/common'

# Immutable fixtures built once per file (exported so per-test setup() sees
# them). No static catalog: list_options' no-config candidates come from live
# model discovery — block the network and seed EVERY provider so the listing
# is deterministic and no provider takes discover_models' fetch-fail cascade
# (a few hundred ms of subprocess churn) on every call.
setup_file() {
  export STUB_DIR="$(mktemp -d)"
  local c
  for c in curl security secret-tool pass kwallet-query gcloud; do
    printf '#!/bin/sh\nexit 1\n' >"${STUB_DIR}/${c}"
    chmod +x "${STUB_DIR}/${c}"
  done
  export CACHE_TPL="$(mktemp -d)"
  printf 'gpt-5.4-mini\ngpt-5.4\n' >"${CACHE_TPL}/codex.list"
  printf 'claude-haiku-4-5-20251001\nclaude-opus-4-6\n' >"${CACHE_TPL}/claude-code.list"
  printf 'gemini-3.1-pro-preview\n' >"${CACHE_TPL}/vertex-gemini.list"
  printf 'claude-opus-4-6\n' >"${CACHE_TPL}/vertex-anthropic.list"
  printf 'gemini-3.1-flash\n' >"${CACHE_TPL}/gemini-api.list"
  printf 'claude-opus-4-6\n' >"${CACHE_TPL}/anthropic-api.list"
  printf 'gpt-5.4\n' >"${CACHE_TPL}/openai-api.list"
}

teardown_file() {
  rm -rf "$STUB_DIR" "$CACHE_TPL"
}

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  source "${REPO_ROOT}/lib/ai-common.sh"
  source "${REPO_ROOT}/bin/git-ai"
  export XDG_CONFIG_HOME="$(mktemp -d)"
  export PATH="${STUB_DIR}:${PATH}"
  mkdir -p "${XDG_CONFIG_HOME}/git-ai"
  cp -R "$CACHE_TPL" "${XDG_CONFIG_HOME}/git-ai/models-cache"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO" "$XDG_CONFIG_HOME"
  unset XDG_CONFIG_HOME
}

@test "cmd_options commit: outputs pipe-delimited lines" {
  run cmd_options commit
  assert_success
  while IFS= read -r line; do
    [[ "$line" == *"|"* ]] || fail "line missing pipe: $line"
  done <<< "$output"
}

@test "cmd_options pr: default tool is commit when missing arg" {
  save_last_message commit "test message"
  run cmd_options
  assert_success
  assert_output --partial "last|reuse saved message"
}

@test "cmd_options pr: no last entry" {
  save_last_message commit "test message"
  run cmd_options pr
  assert_success
  refute_output --partial "last|"
}

@test "cmd_options commit: history entry floats to top" {
  push_choice_history commit "codex:gpt-5.4-mini"
  run cmd_options commit
  assert_success
  assert_line --index 0 "codex:gpt-5.4-mini|gpt-5.4-mini · Codex CLI"
}
