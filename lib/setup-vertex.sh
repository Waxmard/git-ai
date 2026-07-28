#!/bin/bash
# setup-vertex.sh - git-ai setup: Vertex AI project discovery, the GCP project
# picker, and vertex auth-assist. Sourced via lib/setup.sh.

# Best-effort: pick the GCP project fast setup should pin for Vertex AI when
# neither the config nor the environment names one. The gcloud-active project
# is probed first (cheap, the common case — note `gcloud projects list` sorts
# alphabetically, it does NOT lead with the active project); then the account's
# other projects (assumed few; capped) are filtered to those with the Vertex AI
# API enabled. Exactly one match wins outright, several fall back to the first,
# none falls back to the active project. Empty when gcloud is absent or nothing
# resolves — the user can always add/change projects later via the wizard's
# "Change Vertex AI projects" action.
_setup_detect_vertex_project() {
  command -v gcloud >/dev/null 2>&1 || return 0

  local active
  active=$(_gcloud_active_project)
  if [[ -n "$active" ]] && _setup_vertex_api_enabled "$active"; then
    printf '%s\n' "$active"
    return 0
  fi

  # Each enablement probe is a gcloud API round-trip, so cap the sweep — a
  # pathological org account must not hang setup for minutes.
  local p probed=0
  local -a enabled=()
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != "$active" ]] || continue
    [[ $probed -ge 10 ]] && break
    probed=$((probed + 1))
    _setup_vertex_api_enabled "$p" && enabled+=("$p")
  done < <(gcloud projects list --format="value(projectId)" 2>/dev/null)

  if [[ ${#enabled[@]} -gt 0 ]]; then
    printf '%s\n' "${enabled[0]}"
  elif [[ -n "$active" ]]; then
    printf '%s\n' "$active"
  fi
}

# True when PROJECT has the Vertex AI API (aiplatform.googleapis.com) enabled.
_setup_vertex_api_enabled() {
  gcloud services list --enabled --project="$1" \
    --filter="config.name=aiplatform.googleapis.com" \
    --format="value(config.name)" 2>/dev/null | grep -q aiplatform
}

# Name the logins whose project listing failed. An expired, revoked, or
# reauth-required gcloud login errors out the same way an account with zero
# projects returns nothing, so without this an empty picker reads as "you have
# no projects" and the user has no idea a re-auth would fix it.
_setup_warn_gcloud_failures() {
  [[ $# -gt 0 ]] || return 0
  printf 'gcloud could not list projects for: %s\n' "$(_join_comma "$@")" >&2
  printf '  Re-auth with: gcloud auth login --account=<account>\n' >&2
  printf '  (You can still type a project id via the custom row.)\n' >&2
}

# Every GCP project reachable from this machine's gcloud logins, as
# "project<TAB>account" lines (active account's projects first, deduped by
# project id). A bare `gcloud projects list` covers only the ACTIVE account, so
# a user with several logins would otherwise never be offered the projects they
# actually want. Each account is a network round-trip, so the sweep is capped.
_setup_gcloud_projects() {
  command -v gcloud >/dev/null 2>&1 || return 0
  local a p listed seen_accounts=$'\n' seen=$'\n' probed=0 any=0
  local -a failed=()
  while IFS= read -r a; do
    [[ -n "$a" && "$seen_accounts" != *$'\n'"$a"$'\n'* ]] || continue
    seen_accounts+="$a"$'\n'
    [[ $probed -ge 5 ]] && break
    probed=$((probed + 1))
    any=1
    if ! listed=$(gcloud projects list --account="$a" --format="value(projectId)" 2>/dev/null); then
      failed+=("$a")
      continue
    fi
    while IFS= read -r p; do
      [[ -n "$p" && "$seen" != *$'\n'"$p"$'\n'* ]] || continue
      seen+="$p"$'\n'
      printf '%s\t%s\n' "$p" "$a"
    done <<<"$listed"
  done < <(
    gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null
    gcloud auth list --format="value(account)" 2>/dev/null
  )
  if [[ $any -eq 1 ]]; then
    _setup_warn_gcloud_failures ${failed[@]+"${failed[@]}"}
    return 0
  fi
  # No user logins (service-account ADC only) — fall back to whatever the
  # default credential can see, with no account to tag it with.
  while IFS= read -r p; do
    [[ -n "$p" ]] && printf '%s\t\n' "$p"
  done < <(gcloud projects list --format="value(projectId)" 2>/dev/null)
}

# Picker rows ("value|label") for discoverable GCP projects, skipping any id in
# the newline-delimited SEEN set. Rows are account-tagged only when more than
# one login contributed — with a single account the tag is noise. SWEEP is
# pre-fetched _setup_gcloud_projects output; callers pass it so one gcloud
# round-trip serves both the rows and the account lookup below.
_setup_project_rows() {
  local seen="${1:-$'\n'}" sweep="${2:-}"
  local -a pairs=()
  local line p a accounts=$'\n' n=0
  [[ -n "$sweep" ]] || sweep=$(_setup_gcloud_projects)
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pairs+=("$line")
    a="${line#*$'\t'}"
    case "$accounts" in *$'\n'"$a"$'\n'*) ;; *) accounts+="$a"$'\n'; n=$((n + 1)) ;; esac
  done <<<"$sweep"

  for line in ${pairs[@]+"${pairs[@]}"}; do
    p="${line%%$'\t'*}"
    a="${line#*$'\t'}"
    [[ -n "$p" && "$seen" != *$'\n'"$p"$'\n'* ]] || continue
    seen+="$p"$'\n'
    if [[ $n -gt 1 && -n "$a" ]]; then
      printf '%s|%s (%s)\n' "$p" "$p" "$a"
    else
      printf '%s|%s\n' "$p" "$p"
    fi
  done
}

SETUP_CUSTOM_PROJECT_ROW=$'=custom=|— type a project id… —\n'

# The gcloud login whose project listing produced PROJECT, from a pre-fetched
# SWEEP. Empty when the project came from a service-account credential (no
# account to tag) or isn't in the sweep at all (typed by hand).
_setup_account_for_project() {
  local want="$1" sweep="$2" line
  while IFS= read -r line; do
    [[ "${line%%$'\t'*}" == "$want" ]] || continue
    printf '%s' "${line#*$'\t'}"
    return 0
  done <<<"$sweep"
}

# The gcloud login commands run as by default, empty when gcloud is absent or
# no login is active.
_setup_gcloud_active_account() {
  command -v gcloud >/dev/null 2>&1 || return 0
  gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n1
}

# _setup_offer_account_pin CONF SWEEP PROJECT...
# Vertex mints its token from the active gcloud login unless a section names an
# `account`, so a project only a *different* login can see fails at run time
# with nothing in the wizard having hinted at it. _setup_vertex_assist only
# offers `account =` for a provider that isn't ready yet, which this case isn't
# — so offer it here, where the mismatch is actually detectable. No-op when an
# account is already pinned or the picked projects span several logins (no
# single right answer).
_setup_offer_account_pin() {
  local conf="$1" sweep="$2"
  shift 2
  local s p a only="" accounts=$'\n' n=0 active ans
  for s in vertex vertex-anthropic vertex-gemini; do
    [[ -n "$(vertex_resolve "$s" account)" ]] && return 0
  done
  for p in "$@"; do
    a=$(_setup_account_for_project "$p" "$sweep")
    [[ -n "$a" ]] || continue
    case "$accounts" in *$'\n'"$a"$'\n'*) continue ;; esac
    accounts+="$a"$'\n'
    only="$a"
    n=$((n + 1))
  done
  [[ $n -eq 1 ]] || return 0
  active=$(_setup_gcloud_active_account)
  [[ -n "$active" && "$active" != "$only" ]] || return 0

  printf '\nThose projects are visible to %s, but gcloud is active as %s.\n' "$only" "$active"
  read -rp "  Pin account = ${only} for Vertex AI? [Y/n]: " ans || ans=""
  case "$ans" in
    n | N | no | No) printf '  Left unset — Vertex AI will use whichever login is active.\n' ;;
    *)
      _conf_apply "$conf" conf_set_section_setting vertex account "$only" &&
        printf '  Set account = %s\n' "$only"
      ;;
  esac
}

# Multi-select GCP projects for vertex providers, from a pre-fetched SWEEP.
# Prints chosen project ids, one per line; empty output means "leave the current
# projects unchanged" (cancel and a confirmed-empty pick alike — a vertex
# provider with no project cannot run, so clearing the list is not offered).
# Unlisted ids go via the explicit custom row, which emits any projects marked
# alongside it and then drops to the free-text prompt — a project the active
# gcloud login can't see is the normal reason to add one, so that path must
# always exist.
_setup_pick_projects() {
  local sweep="${1:-}" line p rows selected want_custom="" st
  [[ -n "$sweep" ]] || sweep=$(_setup_gcloud_projects)
  rows=$(_setup_project_rows $'\n' "$sweep")

  if [[ -n "$rows" ]]; then
    rows+=$'\n'"$SETUP_CUSTOM_PROJECT_ROW"
    selected=$(_setup_multiselect 'vertex projects> ' \
      'Tab marks GCP project(s); Enter confirms; Esc keeps current' \
      '— skip / keep current —' "$rows")
    st=$?
    [[ $st -eq 0 ]] || return 0
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      if [[ "$p" == '=custom=' ]]; then want_custom=1; else printf '%s\n' "$p"; fi
    done <<<"$selected"
    [[ -n "$want_custom" ]] || return 0
  fi

  read -rp "GCP project id(s), comma-separated (blank to keep current): " line || line=""
  [[ -n "$line" ]] || return 0
  while IFS= read -r p; do
    p=$(_trim "$p")
    [[ -n "$p" ]] && printf '%s\n' "$p"
  done < <(printf '%s\n' "${line//,/$'\n'}")
}
# Interactive vertex auth assist: offer ADC login, then prompt for the common
# per-section settings (project required, region/account optional) and write
# them into [PROVIDER] via conf_set_section_setting — for the wizard's `vertex`
# token that is the shared [vertex] block. [vertex-x@profile] profiles and
# service-account credentials= stay manual (see the README).
_setup_vertex_assist() {
  local provider="$1" conf="$2"
  local label account project region input ans
  label=$(provider_display_name "$provider")
  printf '\n%s needs Google Cloud access.\n' "$label"

  # 1. Application Default Credentials (or a per-section account).
  account=$(vertex_resolve "$provider" account)
  if ! _vertex_has_auth "$account"; then
    read -rp '  Run "gcloud auth application-default login" now? [y/N]: ' ans
    case "$ans" in
      y | Y | yes | Yes)
        if command -v gcloud >/dev/null 2>&1; then
          gcloud auth application-default login || printf '  gcloud login failed.\n'
        else
          printf '  gcloud not installed — see https://cloud.google.com/sdk\n'
        fi
        ;;
      *) printf '  Skipped — run it yourself, then re-run setup.\n' ;;
    esac
  fi

  # 2. Project (required). Default-fill from gcloud's active config.
  project=$(vertex_resolve "$provider" project)
  project="${project:-${GOOGLE_VERTEX_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}}"
  if [[ -z "$project" ]]; then
    local default_project
    default_project=$(_gcloud_active_project)
    read -rp "  GCP project${default_project:+ [$default_project]}: " input
    input="${input:-$default_project}"
    if [[ -n "$input" ]]; then
      _conf_apply "$conf" conf_set_section_setting "$provider" project "$input" &&
        printf '  Set project = %s\n' "$input"
    else
      printf '  No project set — vertex requires one to run.\n'
    fi
  fi

  # 3. Region (optional; default us-central1).
  region=$(vertex_resolve "$provider" region)
  if [[ -z "$region" ]]; then
    read -rp '  Vertex region [Enter for us-central1]: ' input
    if [[ -n "$input" ]]; then
      _conf_apply "$conf" conf_set_section_setting "$provider" region "$input" &&
        printf '  Set region = %s\n' "$input"
    fi
  fi

  # 4. Account (optional; pin a specific gcloud login for token minting).
  if [[ -z "$account" ]]; then
    if command -v gcloud >/dev/null 2>&1; then
      local accts
      accts=$(gcloud auth list --format="value(account)" 2>/dev/null)
      [[ -n "$accts" ]] && printf '  Known gcloud accounts:\n%s\n' "$(printf '%s\n' "$accts" | sed 's/^/    /')"
    fi
    read -rp '  Pin a gcloud account? [Enter for default ADC]: ' input
    if [[ -n "$input" ]]; then
      _conf_apply "$conf" conf_set_section_setting "$provider" account "$input" &&
        printf '  Set account = %s\n' "$input"
    fi
  fi
}
