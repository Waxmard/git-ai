#!/bin/bash
# discovery.sh - live, cached model discovery (sourced via lib/ai-common.sh).

# ---------------------------------------------------------------------------
# Model discovery (live, cached)
# ---------------------------------------------------------------------------
# Model lists are fetched from each provider's own API rather than hardcoded, so
# new models appear without a git-ai release. Results are cached to disk with a
# TTL (network calls are slow; don't hit the API on every commit). Discovery is
# best-effort: providers that can't be listed (the CLIs with no list endpoint,
# or any provider whose creds aren't set yet) yield nothing, and every picker
# falls back to free-text entry. Nothing here gates validation — resolve_model
# accepts any model ID; the provider API is the real validator.

_models_cache_dir() {
  printf '%s/git-ai/models-cache\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# Per-provider cache file. Profile-qualified tokens (vertex-x@profile) get their
# own file so different projects don't clobber each other's catalogs.
_models_cache_path() {
  local safe="${1//[^a-zA-Z0-9._@-]/_}"
  printf '%s/%s.list\n' "$(_models_cache_dir)" "$safe"
}

# discover_models PROVIDER [--refresh]
# Print discovered model IDs (one per line). Serves a fresh on-disk cache when
# present, otherwise fetches, caches, and prints. On a fetch failure, serves a
# stale cache if one exists. Empty output + non-zero return when nothing can be
# discovered, so callers know to rely on free-text entry. TTL in minutes via
# GIT_AI_MODELS_TTL_MIN (default 1440 = 24h); --refresh forces a re-fetch.
discover_models() {
  local provider="$1" refresh="${2:-}"
  local cache ttl="${GIT_AI_MODELS_TTL_MIN:-1440}"
  cache=$(_models_cache_path "$provider")

  if [[ "$refresh" != "--refresh" && -s "$cache" ]]; then
    # `find -mmin +TTL` prints the file only when it is OLDER than TTL minutes;
    # empty output means the cache is still fresh.
    if [[ -z "$(find "$cache" -mmin +"$ttl" 2>/dev/null)" ]]; then
      # $(<file) reads in-shell — this cache-hit path runs once per provider
      # on every picker open, so skip the cat fork+exec.
      printf '%s\n' "$(<"$cache")"
      return 0
    fi
  fi

  # Authed provider API first (reflects the account's real access); fall back to
  # the keyless models.dev catalog when there's no key/CLI list (covers the CLI
  # providers, and any provider whose creds aren't set up).
  local fetched
  fetched=$(_fetch_models "$provider" 2>/dev/null)
  [[ -n "$fetched" ]] || fetched=$(_fetch_models_modelsdev "$provider" 2>/dev/null)
  if [[ -n "$fetched" ]]; then
    mkdir -p "$(_models_cache_dir)" 2>/dev/null || true
    printf '%s\n' "$fetched" >"$cache" 2>/dev/null || true
    printf '%s\n' "$fetched"
    return 0
  fi

  # Fetch failed (offline, no creds, API error) — serve any stale cache.
  [[ -s "$cache" ]] && { printf '%s\n' "$(<"$cache")"; return 0; }
  return 1
}

# models.dev → git-ai family. Prints "MODELS_DEV_KEY<TAB>FAMILY_PREFIX"; the
# prefix narrows the (noisy) catalog to the right family (empty for openai, which
# is matched by a gpt/o-number regex instead). Returns non-zero for unmapped.
_models_dev_key() {
  case ${1%%@*} in
    gemini-api | vertex-gemini)                printf 'google\tgemini\n' ;;
    anthropic-api | claude-code | vertex-anthropic) printf 'anthropic\tclaude\n' ;;
    openai-api | codex)                        printf 'openai\t\n' ;;
    *) return 1 ;;
  esac
}

# Keyless model list from the public models.dev catalog (no auth). The whole
# api.json is cached once (it covers every provider); per-call we extract the
# mapped provider's models and filter to text-generation ids.
_fetch_models_modelsdev() {
  local provider="$1" meta mdkey fam cache_json ttl tmp
  meta=$(_models_dev_key "$provider") || return 1
  IFS=$'\t' read -r mdkey fam <<<"$meta"
  cache_json="$(_models_cache_dir)/_modelsdev.json"
  ttl="${GIT_AI_MODELS_TTL_MIN:-1440}"

  if [[ ! -s "$cache_json" || -n "$(find "$cache_json" -mmin +"$ttl" 2>/dev/null)" ]]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/git-ai-md.XXXXXX") || return 1
    if curl -sf "https://models.dev/api.json" -o "$tmp"; then
      mkdir -p "$(_models_cache_dir)" 2>/dev/null || true
      mv "$tmp" "$cache_json" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi
  [[ -s "$cache_json" ]] || return 1

  GIT_AI_MDKEY="$mdkey" GIT_AI_FAM="$fam" GIT_AI_CACHE="$cache_json" python3 -c '
import json, os, re
SKIP = ("embedding", "-tts", "tts", "-image", "image", "-audio", "audio",
        "-live", "computer-use", "native-audio", "-guard", "gemma")
d = json.load(open(os.environ["GIT_AI_CACHE"]))
fam = os.environ["GIT_AI_FAM"]
out = []
for mid in d.get(os.environ["GIT_AI_MDKEY"], {}).get("models", {}):
    low = mid.lower()
    if any(s in low for s in SKIP):
        continue
    if fam:
        if not low.startswith(fam):
            continue
    elif not re.match(r"^(gpt|o[0-9])", low):
        continue
    out.append(mid)
for m in sorted(set(out), reverse=True):
    print(m)
' 2>/dev/null
}

# Dispatch a provider to its fetch helper. The CLIs have no list endpoint, so
# they borrow the matching API's catalog when a key is configured.
_fetch_models() {
  case ${1%%@*} in
    gemini-api)       _fetch_models_gemini_api ;;
    vertex-gemini)    _fetch_models_vertex "$1" google ;;
    vertex-anthropic) _fetch_models_vertex "$1" anthropic ;;
    anthropic-api)    _fetch_models_anthropic_api ;;
    openai-api)       _fetch_models_openai_api ;;
    claude-code)      _fetch_models_anthropic_api ;;
    codex)            _fetch_models_openai_api ;;
    *) return 1 ;;
  esac
}

# Gemini (AI Studio) — GET /v1beta/models, filtered to generateContent models.
# The API key goes in the URL, so the whole URL lives in the curl config file
# rather than argv (keeps the key out of `ps`).
_fetch_models_gemini_api() {
  local key cfg resp st
  key=$(resolve_gemini_api_key) && [[ -n "$key" ]] || return 1
  cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || return 1
  trap 'rm -f "$cfg"' EXIT # safety net: an interrupt mid-curl must not leak the key file
  printf 'url = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000&key=%s"\n' "$key" >"$cfg"
  resp=$(curl -sf -K "$cfg")
  st=$?
  rm -f "$cfg"
  [[ $st -eq 0 ]] || return 1
  GIT_AI_JSON="$resp" python3 -c '
import json, os
for m in json.loads(os.environ["GIT_AI_JSON"]).get("models", []):
    if "generateContent" in m.get("supportedGenerationMethods", []):
        name = m.get("baseModelId") or m.get("name", "").split("/")[-1]
        if name:
            print(name)
' 2>/dev/null
}

# Anthropic — GET /v1/models (newest-first). Key in a header via curl config.
_fetch_models_anthropic_api() {
  local key cfg resp st
  key=$(resolve_api_key anthropic-api-key ANTHROPIC_API_KEY) && [[ -n "$key" ]] || return 1
  cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || return 1
  trap 'rm -f "$cfg"' EXIT # safety net: an interrupt mid-curl must not leak the key file
  printf 'header = "x-api-key: %s"\n' "$key" >"$cfg"
  resp=$(curl -sf -K "$cfg" -H "anthropic-version: 2023-06-01" \
    "https://api.anthropic.com/v1/models?limit=1000")
  st=$?
  rm -f "$cfg"
  [[ $st -eq 0 ]] || return 1
  GIT_AI_JSON="$resp" python3 -c '
import json, os
for m in json.loads(os.environ["GIT_AI_JSON"]).get("data", []):
    i = m.get("id")
    if i:
        print(i)
' 2>/dev/null
}

# OpenAI — GET /v1/models returns every model (embeddings, tts, …), so filter to
# chat-capable ids heuristically (gpt* / o<digit>*, minus known non-chat kinds).
_fetch_models_openai_api() {
  local key cfg resp st
  key=$(resolve_api_key openai-api-key OPENAI_API_KEY) && [[ -n "$key" ]] || return 1
  cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || return 1
  trap 'rm -f "$cfg"' EXIT # safety net: an interrupt mid-curl must not leak the key file
  printf 'header = "Authorization: Bearer %s"\n' "$key" >"$cfg"
  resp=$(curl -sf -K "$cfg" "https://api.openai.com/v1/models")
  st=$?
  rm -f "$cfg"
  [[ $st -eq 0 ]] || return 1
  GIT_AI_JSON="$resp" python3 -c '
import json, os, re
NON_CHAT = ("embedding", "tts", "whisper", "audio", "image", "realtime",
            "dall-e", "moderation", "transcribe", "search", "similarity", "edit")
ids = [m.get("id", "") for m in json.loads(os.environ["GIT_AI_JSON"]).get("data", [])]
keep = [i for i in ids
        if re.match(r"^(gpt|o[0-9])", i) and not any(x in i for x in NON_CHAT)]
for i in sorted(set(keep), reverse=True):
    print(i)
' 2>/dev/null
}

# Vertex AI — GET {region}-aiplatform.../publishers/{google|anthropic}/models
# (Model Garden catalog). The model id is the last path segment of each
# publisherModels[].name, filtered to the family and to text-generation models
# (the catalog also lists embedding / image / tts / audio variants). User ADC
# requires a quota project (X-Goog-User-Project) or the API 403s; pageSize maxes
# at 300, and the catalog is paged. We walk up to a few pages.
_fetch_models_vertex() {
  local provider="$1" publisher="$2"
  local account region project token host cfg

  account=$(vertex_resolve "$provider" account)
  region=$(vertex_resolve "$provider" region)
  region="${region:-us-central1}"
  token=$(_vertex_access_token "$account") && [[ -n "$token" ]] || return 1

  # Quota project for the aiplatform API: the provider's own project, else the
  # gcloud default, else the first shared [vertex] projects entry. Any project
  # the caller can bill works — it does not affect the (global) catalog.
  project=$(vertex_resolve "$provider" project)
  [[ -n "$project" ]] || project=$(_gcloud_active_project)
  if [[ -z "$project" ]]; then
    local projlist
    projlist=$(vertex_config_value "vertex" projects)
    project=$(printf '%s' "$projlist" | tr ', ' '\n' | awk 'NF{print;exit}')
  fi
  [[ -n "$project" ]] || return 1

  [[ "$region" == "global" ]] && host="aiplatform.googleapis.com" \
                              || host="${region}-aiplatform.googleapis.com"
  cfg=$(mktemp "${TMPDIR:-/tmp}/git-ai-curl.XXXXXX") || return 1
  trap 'rm -f "$cfg"' EXIT # safety net: an interrupt mid-curl must not leak the key file
  printf 'header = "Authorization: Bearer %s"\nheader = "X-Goog-User-Project: %s"\n' \
    "$token" "$project" >"$cfg"

  local page_token="" url resp st page=0 names="" parsed
  while ((page < 5)); do
    url="https://${host}/v1beta1/publishers/${publisher}/models?pageSize=300"
    [[ -n "$page_token" ]] && url+="&pageToken=${page_token}"
    resp=$(curl -sf -K "$cfg" "$url")
    st=$?
    [[ $st -eq 0 ]] || break
    parsed=$(GIT_AI_PUB="$publisher" GIT_AI_JSON="$resp" python3 -c '
import json, os
prefix = "gemini" if os.environ["GIT_AI_PUB"] == "google" else "claude"
# Skip non-text variants the catalog mixes in.
SKIP = ("embedding", "-tts", "-image", "-audio", "-live", "computer-use",
        "native-audio", "-guard")
d = json.loads(os.environ["GIT_AI_JSON"])
# First line is the next page token (may be empty), then one model id per line.
print(d.get("nextPageToken", ""))
for m in d.get("publisherModels", []):
    name = m.get("name", "").split("/")[-1]
    if name.startswith(prefix) and not any(s in name for s in SKIP):
        print(name)
' 2>/dev/null) || break
    page_token=$(printf '%s\n' "$parsed" | head -n1)
    names+=$(printf '%s\n' "$parsed" | tail -n +2)$'\n'
    page=$((page + 1))
    [[ -n "$page_token" ]] || break
  done
  rm -f "$cfg"

  # De-dup, drop blanks, preserve order.
  printf '%s' "$names" | awk 'NF && !seen[$0]++'
}

