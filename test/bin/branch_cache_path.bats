#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
  source "${REPO_ROOT}/bin/git-ai"
}

@test "branch_cache_path: constructs correct path" {
  expected_key=$(printf '%s\n%s\n' "main" "main" | git hash-object --stdin)
  run branch_cache_path "/repo/.git" "main" "main"
  assert_success
  assert_output "/repo/.git/pr-cache/${expected_key}/last-output"
}

@test "branch_cache_path: different branches produce different paths" {
  run branch_cache_path "/repo/.git" "feature/my-branch" "main"
  path_a="$output"
  run branch_cache_path "/repo/.git" "other-branch" "main"
  path_b="$output"
  [ "$path_a" != "$path_b" ]
}

@test "branch_cache_path: different base branches produce different paths" {
  run branch_cache_path "/some/path/.git" "feature/scope/detail" "main"
  path_a="$output"
  run branch_cache_path "/some/path/.git" "feature/scope/detail" "develop"
  path_b="$output"
  [ "$path_a" != "$path_b" ]
}
