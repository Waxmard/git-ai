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
  local repo xdg
  repo=$(make_test_repo)
  xdg=$(mktemp -d)
  run bash -c "cd '$repo' && XDG_CONFIG_HOME='$xdg' '$GIT_AI' options commit"
  rm -rf "$repo" "$xdg"
  assert_success
  assert_output --partial "vertex-gemini:"
  assert_output --partial " · Vertex AI (Gemini)"
}

@test "git-ai: usage mentions setup" {
  run "$GIT_AI"
  assert_output --partial "setup"
}

@test "git-ai setup: routes to the wizard (not unknown command)" {
  local repo xdg
  repo=$(make_test_repo)
  xdg=$(mktemp -d)
  # Numbered fallback: pick provider 1, default model. Isolated config + repo.
  run bash -c "cd '$repo' && XDG_CONFIG_HOME='$xdg' GIT_AI_NO_FZF=1 printf '1\n' | XDG_CONFIG_HOME='$xdg' GIT_AI_NO_FZF=1 '$GIT_AI' setup"
  local conf="$xdg/git-ai/options.conf"
  local written=""; [[ -f "$conf" ]] && written=$(cat "$conf")
  rm -rf "$repo" "$xdg"
  assert_success
  assert_output --partial "git-ai setup"
  [[ "$written" == *"[gemini-api]"* ]]
}

@test "git-ai setup: no providers selected exits 1" {
  local xdg
  xdg=$(mktemp -d)
  run bash -c "XDG_CONFIG_HOME='$xdg' GIT_AI_NO_FZF=1 printf '\n' | XDG_CONFIG_HOME='$xdg' GIT_AI_NO_FZF=1 '$GIT_AI' setup"
  rm -rf "$xdg"
  assert_failure 1
  assert_output --partial "No providers selected"
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
