#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  export XDG_CONFIG_HOME="$(mktemp -d)"
  mkdir -p "${XDG_CONFIG_HOME}/git-ai"
  CONF="${XDG_CONFIG_HOME}/git-ai/options.conf"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO" "$XDG_CONFIG_HOME"
  unset XDG_CONFIG_HOME
}

# _fast INPUT CONF PROVIDER...  -> sources the CLI and runs _setup_fast_path,
# feeding INPUT on stdin (the [Y/n] confirm then the advanced-loop [y/N]).
_fast() {
  local input="$1" conf="$2"
  shift 2
  printf '%b' "$input" | bash -c '
    source "'"${REPO_ROOT}"'/lib/ai-common.sh"
    source "'"${REPO_ROOT}"'/bin/git-ai"
    conf="$1"; shift
    _setup_fast_path "$conf" "$@"
  ' _ "$conf" "$@"
}

@test "_setup_fast_path: accepting pins each provider's recommended model" {
  run _fast 'Y\nN\n' "$CONF" claude-code gemini-api
  assert_success
  assert_output --partial "Detected providers you can use right now"
  assert_output --partial "claude-sonnet-4-6"
  assert_output --partial "gemini-3.5-flash"

  run cat "$CONF"
  assert_line "[claude-code]"
  assert_line "claude-sonnet-4-6"
  assert_line "[gemini-api]"
  assert_line "gemini-3.5-flash"
}

@test "_setup_fast_path: a bare Enter accepts (default yes)" {
  run _fast '\nN\n' "$CONF" anthropic-api
  assert_success
  [ -f "$CONF" ]
  run cat "$CONF"
  assert_line "[anthropic-api]"
  assert_line "claude-sonnet-4-6"
}

@test "_setup_fast_path: declining returns non-zero and writes nothing" {
  run _fast 'n\n' "$CONF" claude-code
  assert_failure 1
  [ ! -f "$CONF" ]
}

@test "_setup_fast_path: seeds the per-repo default provider" {
  run _fast 'Y\nN\n' "$CONF" gemini-api claude-code
  assert_success
  # First ready provider becomes the saved default for commit + pr.
  source "${REPO_ROOT}/lib/ai-common.sh"
  run get_last_provider commit
  assert_output "gemini-api"
}
