#!/usr/bin/env bats
load '../helpers/common'

# Immutable fixtures built once per file (exported so per-test setup() sees
# them): command stubs that block the network/keychain, and a seeded model
# cache covering EVERY provider list_options iterates — a provider with no
# cache would take discover_models' fetch-fail cascade (a few hundred ms of
# subprocess churn) on every single call.
setup_file() {
  export STUB_DIR="$(mktemp -d)"
  local c
  for c in curl security secret-tool pass kwallet-query gcloud; do
    printf '#!/bin/sh\nexit 1\n' >"${STUB_DIR}/${c}"
    chmod +x "${STUB_DIR}/${c}"
  done
  export CACHE_TPL="$(mktemp -d)"
  printf 'claude-haiku-4-5-20251001\nclaude-sonnet-4-6\nclaude-opus-4-6\n' >"${CACHE_TPL}/claude-code.list"
  printf 'claude-haiku-4-5-20251001\nclaude-opus-4-6\n' >"${CACHE_TPL}/anthropic-api.list"
  printf 'gemini-3.1-pro-preview\ngemini-3.1-flash\n' >"${CACHE_TPL}/vertex-gemini.list"
  printf 'gpt-5.4\ngpt-5.4-mini\n' >"${CACHE_TPL}/codex.list"
  printf 'claude-opus-4-6\n' >"${CACHE_TPL}/vertex-anthropic.list"
  printf 'gemini-3.1-flash\n' >"${CACHE_TPL}/gemini-api.list"
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
  # Isolate from any real ~/.config/git-ai/options.conf; history/saved-message
  # writes land here, so each test gets its own copy of the seeded cache.
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

@test "list_options commit: emits pipe-delimited provider:model combos" {
  run list_options commit
  assert_success
  while IFS= read -r line; do
    [[ "$line" == *"|"* ]] || fail "line missing pipe: $line"
  done <<< "$output"
  assert_output --partial "vertex-gemini:gemini-3.1-pro-preview|gemini-3.1-pro-preview · Vertex AI"
  # Display strips the trailing date suffix from claude-haiku-4-5-20251001
  assert_output --partial "claude-code:claude-haiku-4-5-20251001|claude-haiku-4-5 · Claude Code"
}

@test "list_options: date suffix stripped from display, kept in value" {
  run list_options commit
  assert_success
  # Value portion still has the full model ID
  assert_output --partial "anthropic-api:claude-haiku-4-5-20251001|"
  # Label portion shows short form without -20251001
  refute_output --partial "· claude-haiku-4-5-20251001"
}

@test "list_options commit: no last entry when no saved message" {
  run list_options commit
  assert_success
  refute_output --partial "last|reuse saved message"
}

@test "list_options commit: includes last when saved message exists" {
  save_last_message commit "test message"
  run list_options commit
  assert_success
  assert_output --partial "last|reuse saved message"
}

@test "list_options pr: never includes last" {
  save_last_message commit "test message"
  run list_options pr
  assert_success
  refute_output --partial "last|"
}

@test "list_options: history entries float to the top" {
  push_choice_history commit "codex:gpt-5.4"
  push_choice_history commit "claude-code:claude-sonnet-4-6"
  run list_options commit
  assert_success
  assert_line --index 0 "claude-code:claude-sonnet-4-6|claude-sonnet-4-6 · Claude Code"
  assert_line --index 1 "codex:gpt-5.4|gpt-5.4 · Codex CLI"
}

@test "list_options: stale last history entry is skipped when no saved message" {
  push_choice_history commit "last"
  push_choice_history commit "claude-code:claude-opus-4-6"
  run list_options commit
  assert_success
  # "last" pushed to history but saved message never existed — should be skipped
  refute_output --partial "last|reuse saved message"
  assert_line --index 0 "claude-code:claude-opus-4-6|claude-opus-4-6 · Claude Code"
}

@test "list_options: last entry floats when both in history and saved message exists" {
  save_last_message commit "test message"
  push_choice_history commit "last"
  run list_options commit
  assert_success
  assert_line --index 0 "last|reuse saved message"
}
