#!/usr/bin/env bats
load '../helpers/common'

GIT_AI="${REPO_ROOT}/bin/git-ai"

setup() {
  load_bats_libs
  TEST_DIR="$(mktemp -d)"
  export XDG_CONFIG_HOME="$TEST_DIR"
  # Sourcing bin/git-ai defines its functions without running dispatch
  # (guarded by BASH_SOURCE == $0).
  source "$GIT_AI"
}

teardown() {
  rm -rf "$TEST_DIR"
}

@test "maybe_first_run_setup: no-ops on a non-interactive stdin/stdout" {
  # BATS has no controlling tty, so the wizard must never launch here.
  run maybe_first_run_setup commit
  assert_success
  refute_output --partial "launching setup"
}

@test "maybe_first_run_setup: no-ops when options.conf already exists" {
  mkdir -p "${XDG_CONFIG_HOME}/git-ai"
  : >"${XDG_CONFIG_HOME}/git-ai/options.conf"
  run maybe_first_run_setup commit
  assert_success
  refute_output --partial "launching setup"
}

@test "git-ai commit: first-run guard stays inert without a tty (CI safety)" {
  local repo
  repo=$(make_test_repo)
  # No config, no saved provider, no tty → must fall through to the normal
  # 'no saved auth method' error, NOT block on the interactive wizard.
  run bash -c "cd '$repo' && XDG_CONFIG_HOME='$XDG_CONFIG_HOME' '$GIT_AI' commit </dev/null"
  rm -rf "$repo"
  assert_failure
  assert_output --partial "no saved auth method"
  refute_output --partial "launching setup"
}
