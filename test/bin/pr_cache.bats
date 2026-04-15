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

@test "load_cached_pr: returns failure when no cache exists" {
  run load_cached_pr "$GIT_DIR" "feature/new" "main"
  assert_failure
}

@test "save_cached_pr + load_cached_pr: round-trips content" {
  save_cached_pr "$GIT_DIR" "feature/new" "main" "feat: my pr title"
  run load_cached_pr "$GIT_DIR" "feature/new" "main"
  assert_success
  assert_output "feat: my pr title"
}

@test "pr cache: handles branch names with slashes" {
  save_cached_pr "$GIT_DIR" "feature/deeply/nested" "main" "fix: something"
  run load_cached_pr "$GIT_DIR" "feature/deeply/nested" "main"
  assert_success
  assert_output "fix: something"
}

@test "pr cache: different branches are isolated" {
  save_cached_pr "$GIT_DIR" "feature/a" "main" "feat: branch a"
  save_cached_pr "$GIT_DIR" "feature/b" "main" "feat: branch b"
  run load_cached_pr "$GIT_DIR" "feature/a" "main"
  assert_output "feat: branch a"
  run load_cached_pr "$GIT_DIR" "feature/b" "main"
  assert_output "feat: branch b"
}

@test "pr cache: different base branches are isolated" {
  save_cached_pr "$GIT_DIR" "feature/x" "main" "feat: against main"
  save_cached_pr "$GIT_DIR" "feature/x" "develop" "feat: against develop"
  run load_cached_pr "$GIT_DIR" "feature/x" "main"
  assert_output "feat: against main"
  run load_cached_pr "$GIT_DIR" "feature/x" "develop"
  assert_output "feat: against develop"
}

@test "save_cached_pr: overwrites existing cache" {
  save_cached_pr "$GIT_DIR" "main" "origin/main" "old content"
  save_cached_pr "$GIT_DIR" "main" "origin/main" "new content"
  run load_cached_pr "$GIT_DIR" "main" "origin/main"
  assert_success
  assert_output "new content"
}
