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

@test "git-ai: usage mentions options" {
  run "$GIT_AI"
  assert_output --partial "options"
}

@test "git-ai options: commit emits pipe-delimited lines" {
  local repo xdg stub c
  repo=$(make_test_repo)
  xdg=$(mktemp -d)
  # No static catalog: seed a discovered cache and block the network so the
  # spawned process lists deterministically offline.
  stub=$(mktemp -d)
  for c in curl security secret-tool pass kwallet-query gcloud; do
    printf '#!/bin/sh\nexit 1\n' >"${stub}/${c}"
    chmod +x "${stub}/${c}"
  done
  mkdir -p "${xdg}/git-ai/models-cache"
  printf 'gemini-3.1-pro-preview\n' >"${xdg}/git-ai/models-cache/vertex-gemini.list"
  run bash -c "export PATH=\"$stub:\$PATH\"; cd '$repo'; XDG_CONFIG_HOME='$xdg' '$GIT_AI' options commit"
  rm -rf "$repo" "$xdg" "$stub"
  assert_success
  assert_output --partial "vertex-gemini:"
  assert_output --partial " · Vertex AI"
}

@test "git-ai: usage mentions setup" {
  run "$GIT_AI"
  assert_output --partial "setup"
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

@test "git-ai setup: no providers selected exits cleanly" {
  local xdg stub c
  xdg=$(mktemp -d)
  # Stub out the wizard's provider_ready probes (real gcloud/keychain hits).
  stub=$(mktemp -d)
  for c in curl security secret-tool pass kwallet-query gcloud npm; do
    printf '#!/bin/sh\nexit 1\n' >"${stub}/${c}"
    chmod +x "${stub}/${c}"
  done
  run bash -c "export PATH=\"$stub:\$PATH\"; XDG_CONFIG_HOME='$xdg' GIT_AI_NO_FZF=1 GIT_AI_NO_SETUP_FAST=1 printf '\n' | XDG_CONFIG_HOME='$xdg' GIT_AI_NO_FZF=1 GIT_AI_NO_SETUP_FAST=1 '$GIT_AI' setup"
  rm -rf "$xdg" "$stub"
  # Backing out is a normal "not now" — the wizard also auto-launches on the
  # first commit, where dying here would fail the commit.
  assert_success
  assert_output --partial "No providers selected — nothing written."
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
