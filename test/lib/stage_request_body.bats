#!/usr/bin/env bats
load '../helpers/common'

# The payload rides stdin and lands in a file, so these assert on that file's
# JSON rather than on any argument the helper was called with.
setup() {
  load_bats_libs
  TEST_DIR="$(mktemp -d)"
  export TMPDIR="$TEST_DIR"
  source "${REPO_ROOT}/lib/ai-common.sh"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# stage SHAPE [MODEL] <<< input, then read the staged JSON back through jq-less python.
field() {
  "${GIT_AI_PYTHON:-python3}" -c '
import json, sys
data = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    data = data[int(key)] if key.isdigit() else data.get(key)
print(data)
' "$1" "$2"
}

@test "_stage_request_body: gemini splits the prompt into systemInstruction" {
  local file
  file=$(printf 'the diff' | _stage_request_body gemini "the prompt")
  [ -f "$file" ]
  assert_equal "$(field "$file" systemInstruction.parts.0.text)" "the prompt"
  assert_equal "$(field "$file" contents.0.parts.0.text)" "the diff"
}

@test "_stage_request_body: openai carries the model and both message roles" {
  local file
  file=$(printf 'the diff' | _stage_request_body openai "the prompt" "gpt-test")
  assert_equal "$(field "$file" model)" "gpt-test"
  assert_equal "$(field "$file" messages.0.content)" "the prompt"
  assert_equal "$(field "$file" messages.1.content)" "the diff"
}

@test "_stage_request_body: anthropic sends the model, vertex sends the api version" {
  local direct vertex
  direct=$(printf 'the diff' | _stage_request_body anthropic "the prompt" "claude-test")
  assert_equal "$(field "$direct" model)" "claude-test"
  assert_equal "$(field "$direct" system)" "the prompt"
  assert_equal "$(field "$direct" messages.0.content)" "the diff"

  vertex=$(printf 'the diff' | _stage_request_body vertex-anthropic "the prompt")
  assert_equal "$(field "$vertex" anthropic_version)" "vertex-2023-10-16"
  assert_equal "$(field "$vertex" model)" "None"
}

@test "_stage_request_body: a payload past the argv limit round-trips intact" {
  local file
  file=$(head -c 200000 /dev/zero | tr '\0' 'x' | _stage_request_body gemini "the prompt")
  assert_equal "$(field "$file" contents.0.parts.0.text | wc -c | tr -d ' ')" "200001"
}
