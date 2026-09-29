#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  source "${REPO_ROOT}/lib/ai-common.sh"
  export XDG_CONFIG_HOME="$(mktemp -d)"
  mkdir -p "${XDG_CONFIG_HOME}/git-ai"
  STUB="$(mktemp -d)"
  export LOG="${STUB}/log"
  PATH="${STUB}:$PATH"
  for cli in claude codex agy; do
    cat >"${STUB}/${cli}" <<'EOF'
#!/bin/sh
pwd -P >"$LOG"
printf '[%s]' "$@" >>"$LOG"
prev=
for arg in "$@"; do
  [ "$prev" = --output-last-message ] && printf ok >"$arg"
  prev=$arg
done
[ "${0##*/}" = codex ] || echo ok
EOF
    chmod +x "${STUB}/${cli}"
  done
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO" "$XDG_CONFIG_HOME" "$STUB"
  unset XDG_CONFIG_HOME
}

assert_ran_outside_repo() {
  local cwd
  cwd=$(sed -n 1p "$LOG")
  [[ "$cwd" != "$(pwd -P)" ]]
  [[ ! -e "$cwd" ]]
}

@test "run_provider: claude-code runs in a removed empty dir with tools off" {
  run run_provider commit claude-code p i m
  assert_success
  assert_output --partial ok
  assert_ran_outside_repo
  grep -qF '[--tools][]' "$LOG"
}

@test "run_provider: codex runs in a removed empty dir, read-only, no user config" {
  run run_provider commit codex p i m
  assert_success
  assert_output --partial ok
  assert_ran_outside_repo
  grep -qF '[--sandbox][read-only]' "$LOG"
  grep -qF '[--ignore-user-config]' "$LOG"
}

@test "run_provider: antigravity runs in a removed empty dir, sandboxed" {
  run run_provider commit antigravity p i m
  assert_success
  assert_output --partial ok
  assert_ran_outside_repo
  grep -qF '[--sandbox]' "$LOG"
}
