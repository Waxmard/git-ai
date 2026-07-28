## Suites

- **BATS** — `test/bin/`, `test/lib/`, run via `make test` or `npm test` (`.github/workflows/test.yml`).
- **pytest** — `test/python/`, run via `make py-test` or `uv run pytest` (`.github/workflows/python.yml`).

Shell helpers now live across `lib/{auth,discovery,config,provider}.sh` but load through the `lib/ai-common.sh` umbrella — tests source only the umbrella. The wizard libs (`lib/setup.sh` / `lib/setup-edit.sh` / `lib/setup-auth.sh` / `lib/setup-vertex.sh` / `lib/setup-shadow.sh`) are exercised by sourcing `bin/git-ai`. Tests that touch provider APIs stub `curl` / `gcloud` / `security` / the provider CLIs on `PATH`; discovery tests run against seeded caches with the network blocked.

## Intentionally not covered

These require live external processes, so they are excluded on purpose — not accidentally missed:

- `run_provider()` and its API helpers (`_run_anthropic_api`, `_run_openai_api`) — need real LLM calls or an HTTP mock server
- `cmd_commit()` / `cmd_pr()` end-to-end — depend on `run_provider` and real git state with staged changes
- `resolve_gemini_bin()` / `resolve_gemini_api_key()` — platform-specific (Keychain, nvm paths, etc.)
- `_gemini_has_adc()` — requires mocking `gcloud`

No coverage threshold is enforced, precisely because that exclusion list is deliberate. When adding a helper function, add a corresponding `.bats` file in `test/lib/` or `test/bin/`, or a `test_*.py` file in `test/python/`.
