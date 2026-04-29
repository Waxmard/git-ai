#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(mktemp -d)"
  git -C "$TEST_REPO" init -q -b main
  git -C "$TEST_REPO" config user.email "test@test.com"
  git -C "$TEST_REPO" config user.name "Test"
  git -C "$TEST_REPO" commit -q --allow-empty -m "init"
  git -C "$TEST_REPO" checkout -q -b feature/test
  cd "$TEST_REPO"

  source "${REPO_ROOT}/lib/ai-common.sh"
  source "${REPO_ROOT}/bin/git-ai"

  run_provider() {
    printf 'PROVIDER_CALLED\n%s' "$4"
  }
  export -f run_provider

  echo "one" > one.txt
  git add one.txt
  git commit -q -m "feat: add first"
  FIRST_SHA="$(git rev-parse HEAD)"

  echo "two" > two.txt
  git add two.txt
  git commit -q -m "fix: add second"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO"
}

@test "cmd_pr: --from-sha narrows generation to new commits" {
  run cmd_pr codex gpt-5.4-mini --base main --from-sha "$FIRST_SHA"

  assert_success
  # two-pass prompt strips type prefix; check description word in <draft>
  assert_output --partial "add second"
  refute_output --partial "add first"
}

@test "cmd_pr: from subdirectory includes repo-root changed files" {
  mkdir -p nested
  cd nested

  run cmd_pr codex gpt-5.4-mini --base main --fresh

  assert_success
  assert_output --partial "one.txt"
  assert_output --partial "two.txt"
}

@test "cmd_pr: oversize diff aborts before provider call" {
  local i
  for ((i = 0; i < 200; i++)); do
    printf 'line %03d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n' "$i"
  done > huge.txt
  git add huge.txt
  git commit -q -m "feat: add huge file"

  GIT_AI_MAX_DIFF_BYTES=500 run cmd_pr codex gpt-5.4-mini --base main --fresh

  assert_failure
  assert_output --partial "exceeds limit"
  assert_output --partial "Largest changed files"
  assert_output --partial "huge.txt"
  refute_output --partial "PROVIDER_CALLED"
}

@test "cmd_pr: --fresh rejects --from-sha" {
  run cmd_pr codex gpt-5.4-mini --base main --fresh --from-sha "$FIRST_SHA"

  assert_failure
  assert_output --partial "failed to prepare PR context"
}
