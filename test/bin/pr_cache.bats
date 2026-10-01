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

@test "pr cache: no output file when nothing saved" {
  run cat "$(cache_dir "feature/new" "main")/last-output"
  assert_failure
}

@test "save_cached_pr: round-trips content" {
  save_cached_pr "$GIT_DIR" "feature/new" "main" "feat: my pr title"
  run cat "$(cache_dir "feature/new" "main")/last-output"
  assert_success
  assert_output "feat: my pr title"
}

@test "pr cache: handles branch names with slashes" {
  save_cached_pr "$GIT_DIR" "feature/deeply/nested" "main" "fix: something"
  run cat "$(cache_dir "feature/deeply/nested" "main")/last-output"
  assert_success
  assert_output "fix: something"
}

@test "pr cache: different branches are isolated" {
  save_cached_pr "$GIT_DIR" "feature/a" "main" "feat: branch a"
  save_cached_pr "$GIT_DIR" "feature/b" "main" "feat: branch b"
  run cat "$(cache_dir "feature/a" "main")/last-output"
  assert_output "feat: branch a"
  run cat "$(cache_dir "feature/b" "main")/last-output"
  assert_output "feat: branch b"
}

@test "pr cache: different base branches are isolated" {
  save_cached_pr "$GIT_DIR" "feature/x" "main" "feat: against main"
  save_cached_pr "$GIT_DIR" "feature/x" "develop" "feat: against develop"
  run cat "$(cache_dir "feature/x" "main")/last-output"
  assert_output "feat: against main"
  run cat "$(cache_dir "feature/x" "develop")/last-output"
  assert_output "feat: against develop"
}

@test "save_cached_pr: overwrites existing cache" {
  save_cached_pr "$GIT_DIR" "main" "origin/main" "old content"
  save_cached_pr "$GIT_DIR" "main" "origin/main" "new content"
  run cat "$(cache_dir "main" "origin/main")/last-output"
  assert_success
  assert_output "new content"
}

@test "pr cache: no sha file when nothing saved" {
  run cat "$(cache_dir "feature/new" "main")/last-head-sha"
  assert_failure
}

@test "save_cached_pr: no sha file for cache saved without sha" {
  save_cached_pr "$GIT_DIR" "feature/new" "main" "some output"
  run cat "$(cache_dir "feature/new" "main")/last-head-sha"
  assert_failure
}

@test "save_cached_pr: round-trips sha" {
  save_cached_pr "$GIT_DIR" "feature/new" "main" "some output" "abc123def456"
  run cat "$(cache_dir "feature/new" "main")/last-head-sha"
  assert_success
  assert_output "abc123def456"
}

@test "save_cached_pr: sha isolated per branch" {
  save_cached_pr "$GIT_DIR" "feature/a" "main" "output a" "sha-for-a"
  save_cached_pr "$GIT_DIR" "feature/b" "main" "output b" "sha-for-b"
  run cat "$(cache_dir "feature/a" "main")/last-head-sha"
  assert_output "sha-for-a"
  run cat "$(cache_dir "feature/b" "main")/last-head-sha"
  assert_output "sha-for-b"
}

@test "save_cached_pr: sha isolated per base branch" {
  save_cached_pr "$GIT_DIR" "feature/x" "main" "output main" "sha-main"
  save_cached_pr "$GIT_DIR" "feature/x" "develop" "output develop" "sha-develop"
  run cat "$(cache_dir "feature/x" "main")/last-head-sha"
  assert_output "sha-main"
  run cat "$(cache_dir "feature/x" "develop")/last-head-sha"
  assert_output "sha-develop"
}

@test "save_cached_pr: overwrites existing sha" {
  save_cached_pr "$GIT_DIR" "feature/new" "main" "output" "old-sha"
  save_cached_pr "$GIT_DIR" "feature/new" "main" "output" "new-sha"
  run cat "$(cache_dir "feature/new" "main")/last-head-sha"
  assert_output "new-sha"
}

@test "save_cached_pr: round-trips content id" {
  save_cached_pr "$GIT_DIR" "feature/new" "main" "output" "abc123" "content-fingerprint"
  run cat "$(cache_dir "feature/new" "main")/last-content-id"
  assert_success
  assert_output "content-fingerprint"
}

@test "save_cached_pr: records the branch name for pruning" {
  save_cached_pr "$GIT_DIR" "feature/new" "main" "output"
  run cat "$(cache_dir "feature/new" "main")/branch-name"
  assert_output "feature/new"
}
