#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  source "${REPO_ROOT}/lib/ai-common.sh"
  export XDG_CONFIG_HOME="$(mktemp -d)"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO" "$XDG_CONFIG_HOME"
  unset XDG_CONFIG_HOME GIT_AI_NO_FZF
}

@test "pick_via_fzf returns 127 when fzf not on PATH" {
  PATH="/usr/bin:/bin" run -127 pick_via_fzf commit
  assert_failure 127
}

@test "pick_via_fzf returns 1 when GIT_AI_NO_FZF is set" {
  local stub_dir
  stub_dir="$(mktemp -d)"
  cat >"${stub_dir}/fzf" <<'SH'
#!/bin/bash
exit 0
SH
  chmod +x "${stub_dir}/fzf"
  GIT_AI_NO_FZF=1 PATH="${stub_dir}:${PATH}" run pick_via_fzf commit
  assert_failure 1
  rm -rf "$stub_dir"
}
