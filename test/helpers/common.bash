#!/usr/bin/env bash
# Shared test helpers — load via: load '../helpers/common'

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

load_bats_libs() {
  load "${REPO_ROOT}/node_modules/bats-support/load"
  load "${REPO_ROOT}/node_modules/bats-assert/load"
}

# Create a temp git repo, print its path.
make_test_repo() {
  local repo
  repo="$(mktemp -d)"
  git -C "$repo" init -q
  git -C "$repo" config user.email "test@test.com"
  git -C "$repo" config user.name "Test"
  # Need at least one commit so git rev-parse --git-dir works reliably
  git -C "$repo" commit -q --allow-empty -m "init"
  printf '%s' "$repo"
}
