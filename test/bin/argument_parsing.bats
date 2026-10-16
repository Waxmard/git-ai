#!/usr/bin/env bats
load '../helpers/common'

GIT_AI="${REPO_ROOT}/bin/git-ai"

setup() {
  load_bats_libs
}

@test "git-ai: no arguments exits 1 and prints usage" {
  run "$GIT_AI"
  assert_failure 1
  assert_output --partial "usage: git-ai <commit|pr|setup|providers|models|options>"
}

@test "git-ai setup: routes to the wizard (not unknown command)" {
  local repo xdg stub c
  repo=$(make_test_repo)
  xdg=$(mktemp -d)
  # Block the network/keychain and seed a model cache: the wizard's
  # provider_ready probes and model discovery otherwise hit the real gcloud /
  # curl on this machine — seconds of subprocess time, nondeterministic result.
  stub=$(mktemp -d)
  for c in curl security secret-tool pass kwallet-query gcloud npm; do
    printf '#!/bin/sh\nexit 1\n' >"${stub}/${c}"
    chmod +x "${stub}/${c}"
  done
  mkdir -p "${xdg}/git-ai/models-cache"
  printf 'claude-sonnet-4-6\n' >"${xdg}/git-ai/models-cache/claude-code.list"
  # Numbered fallback: pick provider 1 (claude-code, first in SETUP_PROVIDERS),
  # default model. Isolated config + repo.
  # GIT_AI_NO_SETUP_FAST forces the manual picker (the readiness fast path would
  # otherwise intercept whenever a real provider CLI is present on this machine).
  run bash -c "export PATH=\"$stub:\$PATH\"; cd '$repo' && XDG_CONFIG_HOME='$xdg' GIT_AI_NO_FZF=1 GIT_AI_NO_SETUP_FAST=1 printf '1\n' | XDG_CONFIG_HOME='$xdg' GIT_AI_NO_FZF=1 GIT_AI_NO_SETUP_FAST=1 '$GIT_AI' setup"
  local conf="$xdg/git-ai/options.conf"
  local written=""; [[ -f "$conf" ]] && written=$(cat "$conf")
  rm -rf "$repo" "$xdg" "$stub"
  assert_success
  assert_output --partial "git-ai setup"
  [[ "$written" == *"[claude-code]"* ]]
}

@test "git-ai: unknown subcommand exits 1 and mentions the bad command" {
  run "$GIT_AI" boguscommand
  assert_failure 1
  assert_output --partial "boguscommand"
}

@test "git-ai: tiers command errors with guidance" {
  run "$GIT_AI" tiers
  assert_failure 1
  assert_output --partial "use 'models' instead"
}
