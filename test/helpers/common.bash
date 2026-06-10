#!/usr/bin/env bash
# Shared test helpers — load via: load '../helpers/common'

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"

# The stock bats-support/bats-assert loaders source 15 files through 15
# $(dirname ...) command substitutions — ~30 forks per test. Concatenate them
# once per bats run (BATS_RUN_TMPDIR) and source the single bundle instead.
# The src files only define functions, so glob order doesn't matter.
load_bats_libs() {
  local bundle="${BATS_RUN_TMPDIR:-${TMPDIR:-/tmp}}/git-ai-bats-libs.bash"
  if [[ ! -s "$bundle" ]]; then
    local tmp
    tmp="$(mktemp "${bundle}.XXXXXX")"
    cat "${REPO_ROOT}/node_modules/bats-support/src/"*.bash \
        "${REPO_ROOT}/node_modules/bats-assert/src/"*.bash >"$tmp"
    mv "$tmp" "$bundle"  # same-dir rename: atomic, parallel-safe
  fi
  source "$bundle"
}

# Create a temp git repo, print its path.
# git init + an empty commit cost ~50ms per call on macOS, so the first call
# builds a template repo (shared across the whole bats run via BATS_RUN_TMPDIR)
# and every call copies its .git instead (~half the cost). `--template=` skips
# the sample-hooks copy; GIT_CONFIG_GLOBAL/SYSTEM=/dev/null keeps the
# developer's real gitconfig out of the template.
make_test_repo() {
  local repo tpl="${BATS_RUN_TMPDIR:-${TMPDIR:-/tmp}}/git-ai-test-repo-template"
  if [[ ! -d "${tpl}/.git" ]]; then
    local build
    build="$(mktemp -d)"
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      git -C "$build" init -q --template=
    # Append the identity directly to .git/config instead of two `git config`
    # subprocesses — persists for later commits the same as `git config` would.
    printf '[user]\n\temail = test@test.com\n\tname = Test\n' >>"$build/.git/config"
    # Need at least one commit so git rev-parse --git-dir works reliably
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      git -C "$build" commit -q --allow-empty -m "init"
    # Parallel tests race to publish the template. If another test won, the
    # winner's template is valid — only fall back to our build when no
    # template materialized at all.
    mv "$build" "$tpl" 2>/dev/null || true
    [[ -d "${tpl}/.git" ]] || tpl="$build"
  fi
  repo="$(mktemp -d)"
  cp -R "${tpl}/.git" "${repo}/.git"
  printf '%s' "$repo"
}
