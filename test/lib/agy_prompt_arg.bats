#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
  export TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "_agy_prompt_arg: a small payload goes inline, prompt then input" {
  AGY_MAX_INLINE_PROMPT=100000
  run _agy_prompt_arg "PROMPT" "INPUT"
  assert_success
  assert_output "PROMPT

INPUT"
}

@test "_agy_prompt_arg: an oversize payload is staged as an @file reference" {
  AGY_MAX_INLINE_PROMPT=64
  local big
  big=$(printf 'x%.0s' {1..200})
  run _agy_prompt_arg "PROMPT" "$big"
  assert_success
  assert_output --regexp '^@/.+'
  assert_equal "$(cat "${output#@}")" "PROMPT

$big"
}

@test "_agy_prompt_arg: the limit counts bytes, not characters" {
  # 60 three-byte characters = 180 bytes: inline by a character count, staged by
  # a byte count.
  AGY_MAX_INLINE_PROMPT=100
  local wide
  wide=$(printf '\xe6\xbc\xa2%.0s' {1..60})
  run _agy_prompt_arg "" "$wide"
  assert_success
  assert_output --regexp '^@/.+'
}
