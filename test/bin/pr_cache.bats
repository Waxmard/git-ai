#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  TEST_REPO="$(make_test_repo)"
  cd "$TEST_REPO"
  GIT_DIR="$(git rev-parse --git-dir)"
  source "${REPO_ROOT}/lib/ai-common.sh"
  source "${REPO_ROOT}/bin/git-ai"
}

teardown() {
  cd /tmp
  rm -rf "$TEST_REPO"
}

cache_dir() { printf '%s/pr-cache/%s' "$GIT_DIR" "$(printf '%s\n%s\n' "$1" "$2" | git hash-object --stdin)"; }

@test "save_cached_pr: forwards output, head sha, and content id to python cache" {
  save_cached_pr "$GIT_DIR" "feature/new" "main" "feat: my pr title" "abc123def456" "content-fingerprint"
  local dir
  dir="$(cache_dir "feature/new" "main")"
  run cat "${dir}/last-output"
  assert_success
  assert_output "feat: my pr title"
  run cat "${dir}/last-head-sha"
  assert_output "abc123def456"
  run cat "${dir}/last-content-id"
  assert_output "content-fingerprint"
  run cat "${dir}/branch-name"
  assert_output "feature/new"
}
