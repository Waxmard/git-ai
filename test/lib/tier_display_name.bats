#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
}

@test "tier_display_name: haiku" {
  run tier_display_name "haiku"
  assert_success
  assert_output "Haiku"
}

@test "tier_display_name: sonnet" {
  run tier_display_name "sonnet"
  assert_success
  assert_output "Sonnet"
}

@test "tier_display_name: opus" {
  run tier_display_name "opus"
  assert_success
  assert_output "Opus"
}

@test "tier_display_name: flash-lite" {
  run tier_display_name "flash-lite"
  assert_success
  assert_output "Flash Lite"
}

@test "tier_display_name: pro" {
  run tier_display_name "pro"
  assert_success
  assert_output "Pro"
}

@test "tier_display_name: mini" {
  run tier_display_name "mini"
  assert_success
  assert_output "Mini"
}

@test "tier_display_name: standard" {
  run tier_display_name "standard"
  assert_success
  assert_output "Standard"
}

@test "tier_display_name: unknown produces no output" {
  run tier_display_name "unknown"
  assert_success
  assert_output ""
}
