#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  source "${REPO_ROOT}/lib/ai-common.sh"
  export XDG_CONFIG_HOME="$(mktemp -d)"
  mkdir -p "${XDG_CONFIG_HOME}/git-ai"
  POLICY="${XDG_CONFIG_HOME}/git-ai/dirs.conf"
  REPO_P="$(pwd -P)"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO" "$XDG_CONFIG_HOME"
  unset XDG_CONFIG_HOME
}

@test "dirs_rule: no policy file matches nothing" {
  run dirs_rule
  assert_failure
}

@test "dirs_rule: longest matching path wins" {
  mkdir -p sub/deeper
  printf '%s codex\n%s/sub deepseek-api\n' "$TEST_REPO" "$TEST_REPO" >"$POLICY"
  cd sub/deeper
  run dirs_rule
  assert_success
  assert_output "${REPO_P}/sub deepseek-api"
}

@test "dirs_rule: sibling path prefix does not match" {
  mkdir -p su sub
  printf '%s/su codex\n' "$TEST_REPO" >"$POLICY"
  cd sub
  run dirs_rule
  assert_failure
}

@test "dirs_rule: leading ~ expands to HOME" {
  printf '~ codex\n' >"$POLICY"
  HOME="$TEST_REPO" run dirs_rule
  assert_success
  assert_output "${REPO_P} codex"
}

@test "dirs_rule: comments, blanks and one-field lines are ignored" {
  printf '# %s vertex-*\n\n%s\n%s codex\n' "$TEST_REPO" "$TEST_REPO" "$TEST_REPO" >"$POLICY"
  run dirs_rule
  assert_success
  assert_output "${REPO_P} codex"
}

@test "_policy_permits: allow, profile, deny and precedence rules" {
  run _policy_permits 'vertex-*' vertex-anthropic@proj; assert_success
  run _policy_permits 'vertex-*' deepseek-api; assert_failure
  run _policy_permits vertex-anthropic vertex-anthropic@proj; assert_success
  run _policy_permits vertex-anthropic@a vertex-anthropic@b; assert_failure
  run _policy_permits '!vertex-*' codex; assert_success
  run _policy_permits '!vertex-*' vertex-gemini; assert_failure
  run _policy_permits 'codex,!codex' codex; assert_failure
}

@test "run_provider: refuses a disallowed provider before model resolution" {
  printf '%s vertex-*\n' "$TEST_REPO" >"$POLICY"
  resolve_model() { echo SHOULD-NOT-RUN; }
  run run_provider commit deepseek-api p i m
  assert_failure
  assert_output --partial "deepseek-api is not allowed in"
  assert_output --partial "dirs.conf:"
  refute_output --partial SHOULD-NOT-RUN
}
