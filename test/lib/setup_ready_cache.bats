#!/usr/bin/env bats
load '../helpers/common'

setup() {
  load_bats_libs
  source "${REPO_ROOT}/lib/ai-common.sh"
  source "${REPO_ROOT}/lib/setup.sh"
  PROBES=0
  provider_ready() {
    PROBES=$((PROBES + 1))
    [[ -n "${READY:-}" ]]
  }
}

cached() {
  case "$_SETUP_READY_CACHE" in
    *$'\n'"$1="*) return 0 ;;
    *) return 1 ;;
  esac
}

@test "_setup_ready_tag: memoizes one probe per provider" {
  _setup_ready_tag codex >/dev/null
  _setup_ready_tag codex >/dev/null
  [ "$PROBES" -eq 1 ]
}

@test "_setup_ready_forget: drops only the forgotten provider, re-probing it" {
  _setup_warm_ready codex gemini-api openai-api
  [ "$PROBES" -eq 3 ]
  _setup_ready_forget gemini-api
  ! cached gemini-api
  cached codex
  cached openai-api
  READY=1
  _setup_ready_tag gemini-api >/dev/null
  [ "$PROBES" -eq 4 ]
  [[ "$_SETUP_READY_CACHE" == *$'\n'"gemini-api=ready"$'\n'* ]]
  [[ "$_SETUP_READY_CACHE" == *$'\n'"codex=setup"$'\n'* ]]
  [[ "$_SETUP_READY_CACHE" == *$'\n'"openai-api=setup"$'\n'* ]]
}

@test "_setup_ready_forget: drops the last entry without corrupting the cache" {
  _setup_warm_ready codex gemini-api
  _setup_ready_forget gemini-api
  ! cached gemini-api
  _setup_ready_tag codex >/dev/null
  [ "$PROBES" -eq 2 ]
  [[ "$_SETUP_READY_CACHE" == *$'\n'"codex=setup"$'\n'* ]]
}

@test "_setup_ready_forget: unknown provider is a no-op" {
  _setup_warm_ready codex
  _setup_ready_forget vertex
  cached codex
  _setup_ready_tag codex >/dev/null
  [ "$PROBES" -eq 1 ]
}
