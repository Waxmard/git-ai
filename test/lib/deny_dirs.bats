#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  source "${REPO_ROOT}/lib/ai-common.sh"
  source "${REPO_ROOT}/lib/setup.sh"
  export XDG_CONFIG_HOME="$(mktemp -d)"
  mkdir -p "${XDG_CONFIG_HOME}/git-ai"
  CONF="${XDG_CONFIG_HOME}/git-ai/options.conf"
  REPO_P="$(pwd -P)"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO" "$XDG_CONFIG_HOME"
  unset XDG_CONFIG_HOME
}

@test "provider_blocked_dir: blocks the listed dir and its subdirectories" {
  mkdir -p sub/deeper
  printf '[codex]\ngpt-5.4\ndeny_dirs = %s\n' "$TEST_REPO" >"$CONF"
  run provider_blocked_dir codex
  assert_success
  assert_output "$REPO_P"
  cd sub/deeper
  run provider_blocked_dir codex
  assert_success
  assert_output "$REPO_P"
}

@test "provider_blocked_dir: sibling path prefix does not match" {
  mkdir -p su sub
  printf '[codex]\ndeny_dirs = %s/su\n' "$TEST_REPO" >"$CONF"
  cd sub
  run provider_blocked_dir codex
  assert_failure
}

@test "provider_blocked_dir: / blocks every directory" {
  printf '[codex]\ndeny_dirs = /\n' >"$CONF"
  run provider_blocked_dir codex
  assert_success
  assert_output "/"
}

@test "provider_blocked_dir: ~ expands and nonexistent entries are skipped" {
  printf '[codex]\ndeny_dirs = /nonexistent/x, ~\n' >"$CONF"
  HOME="$TEST_REPO" run provider_blocked_dir codex
  assert_success
  assert_output "$REPO_P"
}

@test "provider_blocked_dir: base section applies to its @profile tokens" {
  printf '[vertex-gemini]\ndeny_dirs = %s\n' "$TEST_REPO" >"$CONF"
  run provider_blocked_dir vertex-gemini@p
  assert_success
  run provider_blocked_dir vertex-anthropic@p
  assert_failure
}

@test "list_options: hides every entry of a blocked provider, keeps others" {
  printf '[codex]\ngpt-5.4\ngpt-5.4-mini\ndeny_dirs = %s\n[claude-code]\nclaude-sonnet-4-6\n' "$TEST_REPO" >"$CONF"
  run list_options commit
  assert_success
  refute_output --partial "codex:"
  assert_output --partial "claude-code:claude-sonnet-4-6"
}

@test "run_provider: refuses a blocked provider before model resolution" {
  printf '[codex]\ndeny_dirs = %s\n' "$TEST_REPO" >"$CONF"
  resolve_model() { echo SHOULD-NOT-RUN; }
  run run_provider commit codex p i m
  assert_failure
  assert_output --partial "codex is blocked in"
  assert_output --partial "deny_dirs in"
  refute_output --partial SHOULD-NOT-RUN
}

@test "_setup_action_deny: sets and clears deny_dirs" {
  printf '[codex]\ngpt-5.4\n' >"$CONF"
  _setup_select() { echo codex; }
  _setup_read() { printf -v "$1" '%s' "$TEST_REPO"; }
  run _setup_action_deny "$CONF"
  assert_success
  run vertex_config_value codex deny_dirs
  assert_output "$TEST_REPO"
  _setup_read() { printf -v "$1" '%s' ''; }
  run _setup_action_deny "$CONF"
  assert_success
  run vertex_config_value codex deny_dirs
  assert_output ""
  run grep -F gpt-5.4 "$CONF"
  assert_success
}
