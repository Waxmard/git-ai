#!/usr/bin/env bats
load '../helpers/common'

GIT_AI="${REPO_ROOT}/bin/git-ai"

setup() {
  load_bats_libs
}

@test "git-ai: no arguments exits 1" {
  run "$GIT_AI"
  assert_failure 1
}

@test "git-ai: no arguments prints usage" {
  run "$GIT_AI"
  assert_output --partial "usage:"
}

@test "git-ai: usage mentions models" {
  run "$GIT_AI"
  assert_output --partial "models"
}

@test "git-ai: unknown subcommand exits 1" {
  run "$GIT_AI" boguscommand
  assert_failure 1
}

@test "git-ai: unknown subcommand mentions the bad command" {
  run "$GIT_AI" boguscommand
  assert_output --partial "boguscommand"
}

@test "git-ai: tiers command errors with guidance" {
  run "$GIT_AI" tiers
  assert_failure 1
  assert_output --partial "use 'models' instead"
}
