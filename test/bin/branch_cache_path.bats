#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
  source "${REPO_ROOT}/bin/git-ai"
}

@test "branch_cache_path: constructs correct path" {
  run branch_cache_path "/repo/.git" "main"
  assert_success
  assert_output "/repo/.git/pr-cache/main/last-output"
}

@test "branch_cache_path: handles branch with slashes" {
  run branch_cache_path "/repo/.git" "feature/my-branch"
  assert_success
  assert_output "/repo/.git/pr-cache/feature/my-branch/last-output"
}

@test "branch_cache_path: handles deeply nested branch name" {
  run branch_cache_path "/some/path/.git" "feature/scope/detail"
  assert_success
  assert_output "/some/path/.git/pr-cache/feature/scope/detail/last-output"
}
