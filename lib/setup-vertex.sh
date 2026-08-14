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

# ---------------------------------------------------------------------------
# Vertex config shape. The wizard pins models PER PROJECT, in
# [vertex-<family>@<project>] sections, so two GCP projects can run different
# models. The older shared shape — base [vertex-gemini]/[vertex-anthropic]
# sections multiplied across a [vertex] `projects =` list — still parses (see
# parse_user_options); _setup_vertex_normalize converts it in place the first
# time a vertex edit actually writes.
# ---------------------------------------------------------------------------

# _setup_section_lines CONF SECTION models|settings
# The model IDs (or the key=value settings) written inside a literal [SECTION].
# Literal is the point: parse_user_options expands base vertex sections across
# the projects list, and normalization needs what the base section itself holds.
_setup_section_lines() {
  local conf="$1" target="$2" kind="$3" line trimmed section=""
  [[ -r "$conf" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed=$(_trim "${line%%#*}")
    [[ -n "$trimmed" ]] || continue
    if [[ "$trimmed" =~ ^\[([^][]+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    [[ "$section" == "$target" ]] || continue
    case "$kind" in
      settings) [[ "$trimmed" == *=* ]] && printf '%s\n' "$trimmed" ;;
      *) [[ "$trimmed" != *=* ]] && printf '%s\n' "$trimmed" ;;
    esac
  done <"$conf"
  return 0
}

# True when CONF's literal [SECTION] contains a whole-line comment. Unlike
# _setup_section_lines (which strips comments before it looks at a line), this
# reads the raw line — the point is to detect the comment, not discard it.
_setup_section_has_comment() {
  local conf="$1" target="$2" line trimmed section=""
  [[ -r "$conf" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed=$(_trim "$line")
    if [[ "$trimmed" =~ ^\[([^][]+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    [[ "$section" == "$target" ]] || continue
    [[ "$trimmed" == \#* ]] && return 0
  done <"$conf"
  return 1
}

# True when CONF holds a literal [NAME] provider section.
_setup_conf_has_section() {
  local conf="$1" name="$2" s
  [[ -r "$conf" ]] || return 1
  while IFS= read -r s; do
    [[ "$s" == "$name" ]] && return 0
  done < <(conf_section_providers <"$conf")
  return 1
}

# Split a project list into one id per line. The wizard joins with ", ", but the
# legacy `projects =` key takes commas OR spaces — parse_user_options splits on
# both, so every reader of that key has to as well.
_setup_split_projects() {
  local p
  while IFS= read -r p; do
    p=$(_trim "$p")
    [[ -n "$p" ]] && printf '%s\n' "$p"
  done < <(printf '%s\n' "$1" | tr ', ' '\n')
}

# The GCP projects vertex is configured for, as a comma list: the per-project
# sections plus whatever the legacy `projects =` / `project =` keys still name.
# Both, not either — a config can carry an explicit profile *and* a shared list
# that expands the base sections across other projects, and a project named only
# by the key is just as configured as one with a section.
_setup_current_vertex_projects() {
  local conf="${1:-$(user_options_path)}" p s legacy=""
  local seen=$'\n'
  local -a all=()
  while IFS= read -r p; do
    [[ -n "$p" && "$seen" != *$'\n'"$p"$'\n'* ]] || continue
    seen+="$p"$'\n'
    all+=("$p")
  done < <(vertex_section_projects "$conf")

  legacy=$(vertex_config_value vertex projects)
  if [[ -z "$legacy" ]]; then
    # Each base section can carry its own singular `project =`, and they need not
    # agree. Taking only the first drops the other's project — and, once the fold
    # finds no target for its models, the section and its pins with it.
    local -a singles=()
    for s in vertex vertex-anthropic vertex-gemini; do
      p=$(vertex_resolve "$s" project)
      [[ -n "$p" ]] && singles+=("$p")
    done
    [[ ${#singles[@]} -gt 0 ]] && legacy=$(_join_comma "${singles[@]}")
  fi
  while IFS= read -r p; do
    [[ "$seen" != *$'\n'"$p"$'\n'* ]] || continue
    seen+="$p"$'\n'
    all+=("$p")
  done < <(_setup_split_projects "$legacy")

  [[ ${#all[@]} -gt 0 ]] && _join_comma "${all[@]}"
}

# "<project><TAB><suffix>" for each [vertex-<family>@<suffix>] section holding an
# explicit `project =` that differs from its suffix. Only the section's own key
# counts, never one inherited from a base section: an alias is a deliberate
# second name for a project, and the fold's whole point is that inherited base
# keys stop applying to profiles. A project already addressed by some alias must
# be folded THERE, or it gets a second, id-named section alongside — the same
# duplicate _setup_vertex_add_project declines to write. Suffixes that name a
# project outright are skipped: that section is the project's own address, and
# rerouting its pins to an alias would strand them.
_setup_vertex_alias_map() {
  local conf="$1" s suffix explicit suffixes=$'\n'
  while IFS= read -r s; do suffixes+="$s"$'\n'; done < <(vertex_section_projects "$conf")
  while IFS= read -r s; do
    case "$s" in vertex-gemini@* | vertex-anthropic@*) ;; *) continue ;; esac
    suffix="${s#*@}"
    explicit=$(vertex_config_value "$s" project)
    [[ -n "$explicit" && "$explicit" != "$suffix" ]] || continue
    [[ "$suffixes" == *$'\n'"$explicit"$'\n'* ]] && continue
    printf '%s\t%s\n' "$explicit" "$suffix"
  done < <(conf_section_providers <"$conf")
  return 0
}

# The address PROJECT's pins belong under per MAP, else PROJECT itself.
_setup_vertex_canonical() {
  local map="$1" want="$2" line
  while IFS= read -r line; do
    [[ "${line%%$'\t'*}" == "$want" ]] || continue
    printf '%s' "${line#*$'\t'}"
    return 0
  done <<<"$map"
  printf '%s' "$want"
}

# Every id whose pins belong at SUFFIX per MAP: SUFFIX itself, plus each project
# that canonicalizes to it. parse_user_options keys a base section's expanded
# pins under the project id the expansion used, never the alias they now live
# at, so reading only "<base>@SUFFIX" drops them — and the loss guard misses it
# whenever the same model is also pinned elsewhere.
_setup_vertex_sources() {
  local map="$1" suffix="$2" project alias
  printf '%s\n' "$suffix"
  while IFS=$'\t' read -r project alias; do
    [[ "$alias" == "$suffix" && -n "$project" && "$project" != "$suffix" ]] &&
      printf '%s\n' "$project"
  done <<<"$map"
  return 0
}

# Copy the `project =` a section's sibling family carries onto SECTION. The
# wizard treats both families as one entry, so a model added to the other family
# lands in a section with no override — but vertex_resolve never consults the
# sibling, so that family would call the bare suffix while its twin calls the
# real project. Only for sections the wizard just created: retargeting one the
# user already had is the silent repoint the fold takes pains to avoid.
_setup_vertex_mirror_alias() {
  local conf="$1" section="$2" suffix sibling other
  case "$section" in
    vertex-gemini@*) sibling="vertex-anthropic@${section#*@}" ;;
    vertex-anthropic@*) sibling="vertex-gemini@${section#*@}" ;;
    *) return 0 ;;
  esac
  suffix="${section#*@}"
  _setup_conf_has_section "$conf" "$section" || return 0
  [[ -n "$(vertex_config_value "$section" project)" ]] && return 0
  other=$(vertex_config_value "$sibling" project)
  [[ -n "$other" && "$other" != "$suffix" ]] || return 0
  _conf_apply "$conf" conf_set_section_setting "$section" project "$other"
}

# "<section><TAB><project>" for each [vertex-<family>@<suffix>] section with no
# `project =` of its own that inherits one differing from its suffix. Deleting
# the base key is what the fold is for — a base project= applies to every
# profile at once, which is exactly what per-project pinning replaces — but it
# does change where those profiles run, so the caller names them rather than
# retargeting them in silence. Snapshot before the first write.
_setup_vertex_inherited_projects() {
  local conf="$1" s resolved
  while IFS= read -r s; do
    case "$s" in vertex-gemini@* | vertex-anthropic@*) ;; *) continue ;; esac
    [[ -n "$(vertex_config_value "$s" project)" ]] && continue
    resolved=$(vertex_resolve "$s" project)
    [[ -n "$resolved" && "$resolved" != "${s#*@}" ]] || continue
    printf '%s\t%s\n' "$s" "$resolved"
  done < <(conf_section_providers <"$conf")
  return 0
}

# Every model id pinned under any vertex section of CONF, sorted and deduped.
_setup_vertex_model_ids() {
  local conf="$1" s
  {
    while IFS= read -r s; do
      case "$s" in vertex-gemini* | vertex-anthropic*) ;; *) continue ;; esac
      _setup_section_lines "$conf" "$s" models
    done < <(conf_section_providers <"$conf")
  } | LC_ALL=C sort -u
}

# Fold a shared-shape vertex config down to per-project sections, restoring the
# file untouched if any pinned model would go missing. The fold only ever moves
# pins between sections, so a dropped id means a section was removed before its
# models were copied out — silent, unrecoverable data loss without this guard.
_setup_vertex_normalize() {
  local conf="$1" backup rc=0 m
  [[ -r "$conf" ]] || return 0
  backup=$(mktemp "$(dirname "$conf")/git-ai-conf.XXXXXX") || return 1
  cp "$conf" "$backup" || { rm -f "$backup"; return 1; }

  local -a lost=()
  if _setup_vertex_fold "$conf"; then
    while IFS= read -r m; do [[ -n "$m" ]] && lost+=("$m"); done \
      < <(LC_ALL=C comm -23 <(_setup_vertex_model_ids "$backup") <(_setup_vertex_model_ids "$conf"))
  else
    rc=1
  fi

  if [[ $rc -ne 0 || ${#lost[@]} -gt 0 ]]; then
    mv "$backup" "$conf"
    [[ ${#lost[@]} -gt 0 ]] && printf 'Vertex AI config left as-is: pinning per project would have dropped %s.\n' \
      "$(_join_comma "${lost[@]}")" >&2
    return 1
  fi
  rm -f "$backup"
  return 0
}

# Convert a shared-shape vertex config to per-project sections: every model a
# base section expands into [<base>@<project>] is written there for real, then
# the base sections and the project keys that drove the expansion are dropped.
# Expansion-equivalent by construction. Returns without touching the file once
# nothing is left to fold, or when no project is named anywhere — a base-only
# config takes its project from the environment at run time and must keep
# working. Explicit profiles are folded INTO, not skipped: a config can mix the
# two shapes, and leaving a base model expanding across a project that also has
# its own section is what makes a per-project unpin silently fail.
_setup_vertex_fold() {
  local conf="$1" base p m s src moved="" shared alias_map inherited
  [[ -r "$conf" ]] || return 0
  shared=$(vertex_config_value vertex projects)
  alias_map=$(_setup_vertex_alias_map "$conf")
  inherited=$(_setup_vertex_inherited_projects "$conf")

  local -a projects=()
  local seen_project=$'\n'
  while IFS= read -r p; do
    p=$(_setup_vertex_canonical "$alias_map" "$p")
    [[ -n "$p" && "$seen_project" != *$'\n'"$p"$'\n'* ]] || continue
    seen_project+="$p"$'\n'
    projects+=("$p")
  done < <(_setup_split_projects "$(_setup_current_vertex_projects "$conf")")
  [[ ${#projects[@]} -gt 0 ]] || return 0

  # Already folded: no base section still holds models, and no project key is
  # left to override a profile's own project.
  local pending=""
  for base in vertex-gemini vertex-anthropic; do
    [[ -n "$(_setup_section_lines "$conf" "$base" models)" ]] && pending=1
  done
  for s in vertex vertex-gemini vertex-anthropic; do
    [[ -n "$(vertex_config_value "$s" projects)$(vertex_config_value "$s" project)" ]] && pending=1
  done
  [[ -n "$pending" ]] || return 0

  # What the config resolves to right now is, for each (family, project) pair,
  # exactly the post-fold pin set — base expansion and explicit section unioned
  # and deduped in file order. Snapshot it before the first write, since every
  # write changes what the next read would report.
  local parsed
  parsed=$(parse_user_options)

  for base in vertex-gemini vertex-anthropic; do
    local -a base_models=()
    while IFS= read -r m; do [[ -n "$m" ]] && base_models+=("$m"); done \
      < <(_setup_section_lines "$conf" "$base" models)

    # Only a shared `projects =` list expands a base section, so without one the
    # base models are still under the bare name in `parsed` and would fold into
    # nothing. They belong to the single project the section's own `project =`
    # resolves to; with no project named either they are resolved from the
    # environment at run time, and the section has to stay as it is.
    local literal=""
    if [[ ${#base_models[@]} -gt 0 && -z "$shared" ]]; then
      literal=$(vertex_config_value "$base" project)
      [[ -n "$literal" ]] || literal=$(vertex_config_value vertex project)
      [[ -n "$literal" ]] || continue
      literal=$(_setup_vertex_canonical "$alias_map" "$literal")
    fi
    [[ ${#base_models[@]} -gt 0 ]] && moved=1

    for p in "${projects[@]}"; do
      local -a models=()
      local seen=$'\n'
      while IFS= read -r m; do
        [[ -n "$m" && "$seen" != *$'\n'"$m"$'\n'* ]] || continue
        seen+="$m"$'\n'
        models+=("$m")
      done < <(
        while IFS= read -r src; do
          printf '%s\n' "$parsed" | awk -F: -v k="${base}@${src}" '$1 == k { print $2 }'
        done < <(_setup_vertex_sources "$alias_map" "$p")
        [[ "$p" == "$literal" ]] && printf '%s\n' ${base_models[@]+"${base_models[@]}"}
      )
      local existed=""
      _setup_conf_has_section "$conf" "${base}@${p}" && existed=1
      _setup_upsert_section_models "$conf" "${base}@${p}" ${models[@]+"${models[@]}"} || return 1
      if [[ -z "$existed" ]]; then
        _setup_vertex_mirror_alias "$conf" "${base}@${p}" || return 1
      fi
    done
    _setup_conf_has_section "$conf" "$base" || continue
    # A base section carrying settings or comments keeps the header (settings
    # for its profiles to inherit, comments because they're the user's words,
    # not the expansion's); conf_set_section_models already keeps both and
    # drops only the model lines. A section with neither has nothing left to
    # say once its models are gone — and project=/projects= do not count, since
    # the sweep below strips them and would leave a bare header behind.
    local kept=""
    while IFS= read -r s; do
      case "$(_trim "${s%%=*}")" in project | projects) continue ;; esac
      kept=1
    done < <(_setup_section_lines "$conf" "$base" settings)
    if [[ -n "$kept" ]] || _setup_section_has_comment "$conf" "$base"; then
      _conf_apply "$conf" conf_set_section_models "$base"
    else
      _conf_apply "$conf" conf_remove_section "$base"
    fi || return 1
  done
  # A projects list with no base section at all still names configured projects.
  for p in "${projects[@]}"; do
    _setup_conf_has_section "$conf" "vertex-gemini@${p}" ||
      _setup_conf_has_section "$conf" "vertex-anthropic@${p}" ||
      _conf_apply "$conf" conf_add_section "vertex-gemini@${p}" || return 1
  done

  local section was
  while IFS=$'\t' read -r section was; do
    [[ -n "$section" ]] || continue
    printf '[%s] no longer inherits project = %s; it now targets %s.\n' \
      "$section" "$was" "${section#*@}" >&2
    printf '  Add project = %s to that section to keep the old target.\n' "$was" >&2
  done <<<"$inherited"

  # project=/projects= are what the expansion consumed. Leaving them behind would
  # override every profile's own project — vertex_resolve prefers a base
  # section's key over the profile name.
  for s in vertex vertex-gemini vertex-anthropic; do
    _conf_apply "$conf" conf_remove_section_setting "$s" projects || return 1
    _conf_apply "$conf" conf_remove_section_setting "$s" project || return 1
  done
  [[ -n "$moved" ]] &&
    printf 'Vertex AI models are now pinned per project (%s).\n' "$(_join_comma "${projects[@]}")"
  return 0
}

# _setup_vertex_resolved_project CONF PROFILE
# The actual GCP project PROFILE targets: an explicit `project =` override in
# either family's [vertex-<x>@PROFILE] section, else the profile name itself
# (vertex_resolve's own fallback). A profile's address (the @suffix used in
# section headers) and the GCP project it runs against are two different things
# once a hand-written override is in play — conflating them is what let
# re-picking the real project id create a duplicate profile alongside an
# existing alias instead of recognizing it as the same project.
_setup_vertex_resolved_project() {
  local conf="$1" profile="$2" v
  v=$(vertex_resolve "vertex-gemini@${profile}" project)
  [[ "$v" == "$profile" ]] && v=$(vertex_resolve "vertex-anthropic@${profile}" project)
  printf '%s' "$v"
}

# Record PROJECT by giving it its own sections. Sections ARE the record of a
# configured project, so one with nothing pinned still gets an empty pair. A
# project that an existing profile already targets under an alias (its section
# suffix differs from the real id via `project =`) is recognized as already
# configured rather than duplicated under a second, id-named profile.
# Returns 2 — not 0 — for that case: callers pin models on what they treat as
# newly added suffixes, so "already configured" reported as success is what
# recreates the duplicate the guard above just declined to write.
# The three writers below normalize first, and nothing else does: a wizard action
# the user backs out of must leave the file untouched. They abort when the fold
# refuses — an edit written over a config still in the shared shape is the very
# thing the fold exists to prevent (base models keep expanding, so a scoped
# unpin silently does nothing), and reporting it as done would hide that.
_setup_vertex_add_project() {
  local conf="$1" project="$2" p
  _setup_vertex_normalize "$conf" || return 1
  while IFS= read -r p; do
    [[ "$(_setup_vertex_resolved_project "$conf" "$p")" == "$project" ]] && return 2
  done < <(vertex_section_projects "$conf")
  _setup_conf_has_section "$conf" "vertex-gemini@${project}" && return 2
  _setup_conf_has_section "$conf" "vertex-anthropic@${project}" && return 2
  _conf_apply "$conf" conf_add_section "vertex-gemini@${project}" &&
    _conf_apply "$conf" conf_add_section "vertex-anthropic@${project}"
}

_setup_vertex_drop_project() {
  local conf="$1" project="$2"
  _setup_vertex_normalize "$conf" || return 1
  _conf_apply "$conf" conf_remove_section "vertex-gemini@${project}" &&
    _conf_apply "$conf" conf_remove_section "vertex-anthropic@${project}"
}

# _setup_write_vertex_models CONF SCOPE [MODEL...]
# Write MODELS as SCOPE's pins — `vertex@<project>` for one project, `vertex`
# for every configured project at once (falling back to the base sections when
# none is configured). Each model is routed to its family's section by id, which
# is how the wizard's single "Vertex AI" hides the gemini/anthropic split.
_setup_write_vertex_models() {
  local conf="$1" scope="$2" m p
  shift 2
  local -a anth=() gem=() targets=()
  for m in "$@"; do
    case "$(_setup_provider_for_model vertex "$m")" in
      vertex-anthropic) anth+=("$m") ;;
      *) gem+=("$m") ;;
    esac
  done
  case "$scope" in
    *@*)
      # Pinning one project only means something once the base sections have
      # been folded down — otherwise their models still apply to every project.
      _setup_vertex_normalize "$conf" || return 1
      targets=("@${scope#*@}")
      ;;
    *)
      while IFS= read -r p; do [[ -n "$p" ]] && targets+=("@${p}"); done \
        < <(vertex_section_projects "$conf")
      [[ ${#targets[@]} -gt 0 ]] || targets=("")
      ;;
  esac
  local fam had
  for p in "${targets[@]}"; do
    had=""
    for fam in vertex-anthropic vertex-gemini; do
      _setup_conf_has_section "$conf" "${fam}${p}" && had+=" ${fam}"
    done
    _setup_upsert_section_models "$conf" "vertex-anthropic${p}" ${anth[@]+"${anth[@]}"} &&
      _setup_upsert_section_models "$conf" "vertex-gemini${p}" ${gem[@]+"${gem[@]}"} || return 1
    for fam in vertex-anthropic vertex-gemini; do
      case "$had" in *" ${fam}"*) continue ;; esac
      _setup_vertex_mirror_alias "$conf" "${fam}${p}" || return 1
    done
  done
}

# Which projects a Vertex AI model edit writes to. One project (or none — a
# base-only config) has nothing to choose, so the scope is the whole provider;
# several offer "all projects" as a bulk write alongside each project's own pins.
_setup_pick_vertex_scope() {
  local conf="$1" p menu pins
  local -a projects=()
  while IFS= read -r p; do projects+=("$p"); done \
    < <(_setup_split_projects "$(_setup_current_vertex_projects "$conf")")
  [[ ${#projects[@]} -gt 1 ]] || { printf 'vertex\n'; return 0; }

  menu=$'vertex\tAll projects — one set of models everywhere\n'
  for p in "${projects[@]}"; do
    pins=$(_setup_existing_models "vertex@${p}" | paste -sd, - | sed 's/,/, /g')
    menu+="vertex@${p}"$'\t'"${p} — ${pins:-no models pinned}"$'\n'
  done
  _setup_select 'Models for> ' "$menu"
}

# Interactive vertex auth assist: offer ADC login, then prompt for what vertex
# needs — a project (which becomes its own [vertex-<family>@<project>] sections)
# plus optional region/account written into the shared [vertex] block.
# Service-account credentials= stays manual (see the README).
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
  project=$(_setup_current_vertex_projects "$conf")
  project="${project:-${GOOGLE_VERTEX_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}}"
  if [[ -z "$project" ]]; then
    local default_project
    default_project=$(_gcloud_active_project)
    read -rp "  GCP project${default_project:+ [$default_project]}: " input
    input="${input:-$default_project}"
    if [[ -n "$input" ]]; then
      # Recorded as the shared key, then normalized — that is the one path that
      # also folds any models already pinned on the base sections into the new
      # project's own sections (a bare add_project would strand them).
      _conf_apply "$conf" conf_set_section_setting vertex projects "$input" &&
        _setup_vertex_normalize "$conf" &&
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
