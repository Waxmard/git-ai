#!/usr/bin/env bats
load '../helpers/common'

bats_require_minimum_version 1.5.0

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
}

@test "die: exits with status 1" {
  run die "something failed"
  assert_failure 1
}

@test "die: message appears in output" {
  run die "fatal error message"
  assert_output --partial "fatal error message"
}

@test "die: message goes to stderr" {
  run --separate-stderr die "stderr check"
  assert_failure
  # stdout should be empty; the message belongs on stderr
  assert_output ""
  [[ "$stderr" == *"stderr check" ]]
}
