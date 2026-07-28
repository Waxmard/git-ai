#!/bin/bash
# setup-auth.sh - git-ai setup: API-key auth-assist and key validation.
# Sourced via lib/setup.sh; vertex auth-assist lives in setup-vertex.sh.

# _setup_probe_key PROVIDER KEY
# Check KEY against PROVIDER's models endpoint so a typo'd, revoked, or
# wrong-provider key is caught here rather than at the user's first commit.
# Returns 0 accepted, 1 rejected, 2 indeterminate (no curl, offline, unexpected
# status) — the caller saves on 2, since a flaky network must not block setup.
# Body runs in a subshell so the key-file cleanup trap can't outlive the call
# and clobber the wizard's own traps. The key goes in a curl config file rather
# than argv, keeping it out of `ps`.
_setup_probe_key() (
  local provider="$1" key="$2" cfg url code st esc
  [[ -z "${GIT_AI_NO_KEY_PROBE:-}" ]] || return 2
  command -v curl >/dev/null 2>&1 || return 2
  cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || return 2
  trap 'rm -f "$cfg"' EXIT
  # curl's config parser reads \ and " inside a quoted value as escapes, so an
  # unescaped key silently probes a truncated string and reports a false reject.
  esc=${key//\\/\\\\}
  esc=${esc//\"/\\\"}
  case "${provider%%@*}" in
    anthropic-api)
      printf 'header = "x-api-key: %s"\nheader = "anthropic-version: 2023-06-01"\n' "$esc" >"$cfg"
      url="https://api.anthropic.com/v1/models?limit=1"
      ;;
    openai-api)
      printf 'header = "Authorization: Bearer %s"\n' "$esc" >"$cfg"
      url="https://api.openai.com/v1/models"
      ;;
    # Gemini takes the key as a query parameter, so the whole URL lives in the
    # config file too and none of it can be passed on the command line.
    gemini-api)
      printf 'url = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1&key=%s"\n' "$esc" >"$cfg"
      url=""
      ;;
    *) return 2 ;;
  esac

  code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -K "$cfg" ${url:+"$url"})
  st=$?
  [[ $st -eq 0 ]] || return 2
  case "$code" in
    2*) return 0 ;;
    400 | 401 | 403) return 1 ;;
    *) return 2 ;;
  esac
)

# Prompt for, validate, and store PROVIDER's API key. SERVICE is the keychain
# service name and ENVVAR the variable resolve_api_key consults.
_setup_prompt_api_key() {
  local provider="$1" service="$2" envvar="$3" label="$4"
  local key how rc ans

  printf '\n%s needs an API key.\n' "$label"
  read -rsp "  Paste key (blank to skip): " key
  printf '\n'
  if [[ -z "$key" ]]; then
    printf '  Skipped — set %s later or re-run "git-ai setup".\n' "$envvar"
    return 0
  fi

  printf '  Checking key… '
  _setup_probe_key "$provider" "$key"
  case $? in
    0) printf 'accepted.\n' ;;
    1)
      printf '%s rejected it.\n' "$label"
      read -rp '  Save it anyway? [y/N]: ' ans || ans=""
      case "$ans" in
        y | Y | yes | Yes) ;;
        *)
          printf '  Not saved — re-run "git-ai setup" with the right key.\n'
          return 0
          ;;
      esac
      ;;
    *) printf 'could not verify (offline?) — saving it anyway.\n' ;;
  esac

  printf '  Store it: 1) OS keychain  2) shell rc (plaintext)  3) skip saving\n'
  read -rp "  Choice [1]: " how
  case "${how:-1}" in
    1)
      if store_api_key "$service" "$key"; then
        printf '  Saved to your keychain (service: %s).\n' "$service"
      else
        printf '  No keychain backend found. Falling back to shell rc.\n'
        rc=$(persist_key_to_rc "$envvar" "$key") &&
          printf '  Appended export to %s — open a new shell or "source" it.\n' "$rc"
      fi
      ;;
    2)
      rc=$(persist_key_to_rc "$envvar" "$key") &&
        printf '  Appended export to %s (plaintext) — open a new shell or "source" it.\n' "$rc"
      ;;
    *)
      printf '  Not saved — export %s yourself to use this provider.\n' "$envvar"
      ;;
  esac
}

# Help the user authenticate PROVIDER if it isn't ready yet. Key providers get
# an interactive key prompt + storage choice; vertex gets project/region/account
# assist; CLI providers get an install hint. CONF is the options.conf being
# edited (vertex settings are written there).
_setup_ensure_auth() {
  local provider="$1" conf="${2:-$(user_options_path)}"
  local label
  label=$(provider_display_name "$provider")

  if provider_ready "$provider" 2>/dev/null; then
    printf '  %s: already authenticated.\n' "$label"
    case "${provider%%@*}" in
      vertex | vertex-gemini | vertex-anthropic)
        printf '  (To change GCP projects, use "Change Vertex AI projects" in the setup menu.)\n' ;;
    esac
    return 0
  fi

  local meta service envvar
  if meta=$(provider_key_meta "$provider"); then
    read -r service envvar <<<"$meta"
    _setup_prompt_api_key "$provider" "$service" "$envvar" "$label"
  else
    # Non-key providers: point at the right install/auth step.
    case "${provider%%@*}" in
      claude-code)
        printf '  %s: install the CLI — https://claude.ai/code\n' "$label" ;;
      codex)
        printf '  %s: install the CLI — https://github.com/openai/codex\n' "$label" ;;
      # The wizard's `vertex` token lands settings in the shared [vertex] block
      # (one auth/project setup covers both internal vertex providers).
      vertex | vertex-gemini | vertex-anthropic)
        _setup_vertex_assist "$provider" "$conf" ;;
    esac
  fi
  _setup_ready_forget "$provider"
  return 0
}
