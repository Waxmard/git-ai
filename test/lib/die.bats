#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
}

@test "die: exits with status 1" {
  run bash -c 'source "'"${REPO_ROOT}"'/lib/ai-common.sh"; die "something failed"'
  assert_failure 1
}

@test "die: message appears in output" {
  run bash -c 'source "'"${REPO_ROOT}"'/lib/ai-common.sh"; die "fatal error message"'
  assert_output --partial "fatal error message"
}

@test "die: message goes to stderr" {
  run bash -c 'source "'"${REPO_ROOT}"'/lib/ai-common.sh"; die "stderr check" 2>/dev/null'
  assert_failure
  # stdout should be empty since message goes to stderr
  assert_output ""
}
