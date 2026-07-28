# Changelog

## [6.6.1](https://github.com/Waxmard/git-ai/compare/v6.6.0...v6.6.1) (2026-07-28)


### Bug Fixes

* prevent stray markers and turn limits from corrupting generated text ([#109](https://github.com/Waxmard/git-ai/issues/109)) ([3792254](https://github.com/Waxmard/git-ai/commit/37922548c573cbd780e7ce4957f30a4467057122))

## [6.6.0](https://github.com/Waxmard/git-ai/compare/v6.5.2...v6.6.0) (2026-07-28)


### Features

* setup wizard validates API keys and guards vertex account mismatches ([#106](https://github.com/Waxmard/git-ai/issues/106)) ([7b0a267](https://github.com/Waxmard/git-ai/commit/7b0a2670808d1ec8416b07df184a05d89f733b27))


### Bug Fixes

* classify pinned values correctly in generated PRs ([#104](https://github.com/Waxmard/git-ai/issues/104)) ([ba438f2](https://github.com/Waxmard/git-ai/commit/ba438f2ebcb6893ea37c491dc4de53973ded06e8))
* refresh provider readiness after inline auth setup ([7b0a267](https://github.com/Waxmard/git-ai/commit/7b0a2670808d1ec8416b07df184a05d89f733b27))

## [6.5.2](https://github.com/Waxmard/git-ai/compare/v6.5.1...v6.5.2) (2026-07-01)


### Miscellaneous Chores

* **ci:** bump anthropics/claude-code-action ([f02a550](https://github.com/Waxmard/git-ai/commit/f02a5501e4b4c26c2edbfd953940281a53116e8a))
* **config:** update anthropic sonnet to version 5 ([#97](https://github.com/Waxmard/git-ai/issues/97)) ([41e5b56](https://github.com/Waxmard/git-ai/commit/41e5b5661b62fe995bd2354b7bec9fa315f09744))

## [6.5.1](https://github.com/Waxmard/git-ai/compare/v6.5.0...v6.5.1) (2026-06-29)


### Bug Fixes

* strip whitespace from commit message before empty check ([f407e81](https://github.com/Waxmard/git-ai/commit/f407e818449342a1d48b004cb057d7715a4833d3))

## [6.5.0](https://github.com/Waxmard/git-ai/compare/v6.4.0...v6.5.0) (2026-06-26)


### Features

* install git-ai via pip with full Bash CLI bundled ([#89](https://github.com/Waxmard/git-ai/issues/89)) ([7ec9668](https://github.com/Waxmard/git-ai/commit/7ec96685a4a35082a538f30f43b042986742dadb))
* open editor directly after generating a commit message ([#88](https://github.com/Waxmard/git-ai/issues/88)) ([20f4e51](https://github.com/Waxmard/git-ai/commit/20f4e51a4cd71caaf6f529f29c2d12ce1c91df30))

## [6.4.0](https://github.com/Waxmard/git-ai/compare/v6.3.0...v6.4.0) (2026-06-17)


### Features

* support repo-local commit/PR conventions via `.git-ai-instructions` ([#81](https://github.com/Waxmard/git-ai/issues/81)) ([cc24335](https://github.com/Waxmard/git-ai/commit/cc243357edcb1679f4eea39862b8666181cf0e5c))


### Bug Fixes

* surface lockfile bumps in PR diff stat for dependency-only branches ([#83](https://github.com/Waxmard/git-ai/issues/83)) ([f974da3](https://github.com/Waxmard/git-ai/commit/f974da37b618912fb7f32f591fccc43e5d5b9a5a))


### Miscellaneous Chores

* add MIT license ([128f198](https://github.com/Waxmard/git-ai/commit/128f198253ced68d254929bac56985a98584dfea))

## [6.3.0](https://github.com/Waxmard/git-ai/compare/v6.2.2...v6.3.0) (2026-06-11)


### Features

* add interactive setup wizard with live model discovery and provider auth ([#73](https://github.com/Waxmard/git-ai/issues/73)) ([32d42b6](https://github.com/Waxmard/git-ai/commit/32d42b63c1b9530dbee909bfa1703e6f9cf0b0fd))
* smarter PR base detection and single-commit fast path ([#79](https://github.com/Waxmard/git-ai/issues/79)) ([cc6311f](https://github.com/Waxmard/git-ai/commit/cc6311f3663b20668c7ea932aca6fa4dd784a99c))


### Bug Fixes

* avoid exporting API keys to env and write config atomically ([04370fb](https://github.com/Waxmard/git-ai/commit/04370fbce9d08a07f1fc8bc13b96fc4a0fe773dd))
* harden key-file cleanup and config edge-case handling ([157bbb9](https://github.com/Waxmard/git-ai/commit/157bbb992b2325ffe3eae6619e4d589c039560a7))
* improve commit and PR output to be reader-focused and concise ([e86626d](https://github.com/Waxmard/git-ai/commit/e86626d725a78db47e8e7822893fec409fe4fc91))
* suppress fork warning on detached HEAD in base_warnings ([9a3dd8a](https://github.com/Waxmard/git-ai/commit/9a3dd8afa03301dd147c0714554d522dfbb84372))
* tighten feat/style/branch-context classification rules in commit prompt ([1159a68](https://github.com/Waxmard/git-ai/commit/1159a68b9de13937cf94e31b4b68d912ea1a243f))


### Documentation

* condense setup wizard and discovery sections in agent/user guides ([5a5e9ec](https://github.com/Waxmard/git-ai/commit/5a5e9ecd2b16e9614d18b50879cab1eb34a02095))


### Build System

* add changelog-sections to release-please config ([9bee42f](https://github.com/Waxmard/git-ai/commit/9bee42ff4ee016ada72036297ae1d927dacf3e49))

## [6.2.2](https://github.com/Waxmard/git-ai/compare/v6.2.1...v6.2.2) (2026-06-04)


### Bug Fixes

* add type-selection precedence and role-based classification rules to PR prompts ([f096966](https://github.com/Waxmard/git-ai/commit/f0969664e8b01450971fd680755fa549945b7725))

## [6.2.1](https://github.com/Waxmard/git-ai/compare/v6.2.0...v6.2.1) (2026-06-03)


### Bug Fixes

* sharpen commit prefix rules for restructuring and config-file changes ([#65](https://github.com/Waxmard/git-ai/issues/65)) ([eaaeac8](https://github.com/Waxmard/git-ai/commit/eaaeac88c35c59c30510ce9fca549a7db201fceb))

## [6.2.0](https://github.com/Waxmard/git-ai/compare/v6.1.0...v6.2.0) (2026-06-01)


### Features

* branch-aware commit prefixes and intra-branch churn folding in PR drafts ([#58](https://github.com/Waxmard/git-ai/issues/58)) ([0de98fb](https://github.com/Waxmard/git-ai/commit/0de98fbb957c06563edb6a4c9be80d01c32948c9))
* Vertex multi-profile layered config, docs generation pipeline, and security CI ([#57](https://github.com/Waxmard/git-ai/issues/57)) ([aa4a001](https://github.com/Waxmard/git-ai/commit/aa4a0016f9c68f9d70948c9077735b54698a5594))


### Bug Fixes

* guard path traversal in docs include and catch OSError in pr-repo CLI ([a1861fc](https://github.com/Waxmard/git-ai/commit/a1861fca8eaf8f3c01bc447eb996d54c800b464c))

## [6.1.0](https://github.com/Waxmard/git-ai/compare/v6.0.1...v6.1.0) (2026-05-28)


### Features

* replace interactive PR diff output with markdown summary ([#55](https://github.com/Waxmard/git-ai/issues/55)) ([bb80127](https://github.com/Waxmard/git-ai/commit/bb80127bf6a442c7e7546e054622ab8e6c20df92))

## [6.0.1](https://github.com/Waxmard/git-ai/compare/v6.0.0...v6.0.1) (2026-05-14)


### Bug Fixes

* migrate pre-commit hooks to lefthook and fix strip_fences backtick bug ([#53](https://github.com/Waxmard/git-ai/issues/53)) ([3fd955e](https://github.com/Waxmard/git-ai/commit/3fd955ef014766b8d32349863f630f9b32b3d6b0))

## [6.0.0](https://github.com/Waxmard/git-ai/compare/v5.0.0...v6.0.0) (2026-05-09)


### ⚠ BREAKING CHANGES

* auto-load ignore patterns in diff helpers ([#49](https://github.com/Waxmard/git-ai/issues/49))

### Features

* auto-load ignore patterns in diff helpers ([#49](https://github.com/Waxmard/git-ai/issues/49)) ([df02e64](https://github.com/Waxmard/git-ai/commit/df02e64eef71c3b563a68c2dd9bd71ada8b4c1a8))

## [5.0.0](https://github.com/Waxmard/git-ai/compare/v4.1.4...v5.0.0) (2026-04-29)


### ⚠ BREAKING CHANGES

* diff ignore rules, size guard, and vertex provider split ([#44](https://github.com/Waxmard/git-ai/issues/44))

### Features

* diff ignore rules, size guard, and vertex provider split ([#44](https://github.com/Waxmard/git-ai/issues/44)) ([35dac3b](https://github.com/Waxmard/git-ai/commit/35dac3b7877298addd22dc2d01ef9f29c5854bac))

## [4.1.4](https://github.com/Waxmard/git-ai/compare/v4.1.3...v4.1.4) (2026-04-22)


### Bug Fixes

* update npm publish workflow to Node 24 ([af7dbee](https://github.com/Waxmard/git-ai/commit/af7dbee5a96e3ca94bd1f98995c2dffd02301f55))

## [4.1.3](https://github.com/Waxmard/git-ai/compare/v4.1.2...v4.1.3) (2026-04-22)


### Bug Fixes

* adjust npm publish workflow ([1e29a96](https://github.com/Waxmard/git-ai/commit/1e29a96030d9791ad37477e984e3d58ec71b9435))

## [4.1.2](https://github.com/Waxmard/git-ai/compare/v4.1.1...v4.1.2) (2026-04-22)


### Bug Fixes

* include merge commits in commit logs and update npm publish to Node 22 ([#37](https://github.com/Waxmard/git-ai/issues/37)) ([dce6e9a](https://github.com/Waxmard/git-ai/commit/dce6e9a3038ccaebc1659d8b49b2dbdaa8ccecd7))

## [4.1.1](https://github.com/Waxmard/git-ai/compare/v4.1.0...v4.1.1) (2026-04-22)


### Bug Fixes

* include merge commits in commit logs and update npm publish to Node 22 ([#37](https://github.com/Waxmard/git-ai/issues/37)) ([dce6e9a](https://github.com/Waxmard/git-ai/commit/dce6e9a3038ccaebc1659d8b49b2dbdaa8ccecd7))

## [4.1.0](https://github.com/Waxmard/git-ai/compare/v4.0.0...v4.1.0) (2026-04-22)


### Features

* improve PR draft generation with incremental regeneration support ([#34](https://github.com/Waxmard/git-ai/issues/34)) ([839008a](https://github.com/Waxmard/git-ai/commit/839008a2f31cfbc9ec2d765513ed65b38632fcdb))

## [4.0.0](https://github.com/Waxmard/git-ai/compare/v3.1.1...v4.0.0) (2026-04-21)


### ⚠ BREAKING CHANGES

* introduce user-configurable provider/model selection and enhanced PR rendering ([#32](https://github.com/Waxmard/git-ai/issues/32))

### Features

* introduce user-configurable provider/model selection and enhanced PR rendering ([#32](https://github.com/Waxmard/git-ai/issues/32)) ([3620d3c](https://github.com/Waxmard/git-ai/commit/3620d3c143bbfbe4e2a95613bbbb5fc407695603))

## [3.1.1](https://github.com/Waxmard/git-ai/compare/v3.1.0...v3.1.1) (2026-04-16)


### Bug Fixes

* add README metadata and sync lock version ([cfc4da9](https://github.com/Waxmard/git-ai/commit/cfc4da96f972a1e226b0a72f80423558e7c5dbbc))

## [3.1.0](https://github.com/Waxmard/git-ai/compare/v3.0.0...v3.1.0) (2026-04-16)


### Features

* add Python-backed generators and incremental PR draft caching ([#27](https://github.com/Waxmard/git-ai/issues/27)) ([75887ee](https://github.com/Waxmard/git-ai/commit/75887ee3ccb451680b91d36356217219c0be35f7))

## [3.0.0](https://github.com/Waxmard/git-ai/compare/v2.0.0...v3.0.0) (2026-04-15)


### ⚠ BREAKING CHANGES

* add model tier selection for LLM providers ([#7](https://github.com/Waxmard/git-ai/issues/7))

### Features

* add adaptive provider defaults and persist last provider selection ([#5](https://github.com/Waxmard/git-ai/issues/5)) ([bc6c80b](https://github.com/Waxmard/git-ai/commit/bc6c80bfa1a5290f99b3dc1118800c89ba6c5b8e))
* add git-ai CLI tools for LLM-powered commit and PR title generation ([36a655f](https://github.com/Waxmard/git-ai/commit/36a655f0ed6ae1f6145d9bba580cbe558019d898))
* add model tier selection for LLM providers ([#7](https://github.com/Waxmard/git-ai/issues/7)) ([4f0d4c7](https://github.com/Waxmard/git-ai/commit/4f0d4c7c094cd8559d67374c65596793c4a175b9))
* add release context to generated prompts ([#14](https://github.com/Waxmard/git-ai/issues/14)) ([73fc310](https://github.com/Waxmard/git-ai/commit/73fc310200896ed9861a99ec74ebb3abf2e74e28))
* **auth:** expand provider auth fallbacks and default to gemini ([#12](https://github.com/Waxmard/git-ai/issues/12)) ([69eee1a](https://github.com/Waxmard/git-ai/commit/69eee1a7daba067954a02de55fad6efea52ff88a))
* reuse saved commit messages when the staged diff is unchanged ([#17](https://github.com/Waxmard/git-ai/issues/17)) ([352f2d4](https://github.com/Waxmard/git-ai/commit/352f2d4dddb6fda28515625dd825bcd4f711a895))
* two-pass PR generation with grouped sections and --no-test-plan flag ([#10](https://github.com/Waxmard/git-ai/issues/10)) ([a44cef4](https://github.com/Waxmard/git-ai/commit/a44cef479b27fe6af08ca7b582993081a11dcb8e))
* unify git-ai workflows, cache PR drafts by branch/base, and clarify semver guidance ([#19](https://github.com/Waxmard/git-ai/issues/19)) ([82f68a8](https://github.com/Waxmard/git-ai/commit/82f68a889eb46414fa6fc304c86d20f1d5b507dd))

## [2.0.0](https://github.com/Waxmard/git-ai/compare/git-ai-v1.4.0...git-ai-v2.0.0) (2026-04-15)


### ⚠ BREAKING CHANGES

* add model tier selection for LLM providers ([#7](https://github.com/Waxmard/git-ai/issues/7))

### Features

* add adaptive provider defaults and persist last provider selection ([#5](https://github.com/Waxmard/git-ai/issues/5)) ([bc6c80b](https://github.com/Waxmard/git-ai/commit/bc6c80bfa1a5290f99b3dc1118800c89ba6c5b8e))
* add git-ai CLI tools for LLM-powered commit and PR title generation ([36a655f](https://github.com/Waxmard/git-ai/commit/36a655f0ed6ae1f6145d9bba580cbe558019d898))
* add model tier selection for LLM providers ([#7](https://github.com/Waxmard/git-ai/issues/7)) ([4f0d4c7](https://github.com/Waxmard/git-ai/commit/4f0d4c7c094cd8559d67374c65596793c4a175b9))
* add release context to generated prompts ([#14](https://github.com/Waxmard/git-ai/issues/14)) ([73fc310](https://github.com/Waxmard/git-ai/commit/73fc310200896ed9861a99ec74ebb3abf2e74e28))
* **auth:** expand provider auth fallbacks and default to gemini ([#12](https://github.com/Waxmard/git-ai/issues/12)) ([69eee1a](https://github.com/Waxmard/git-ai/commit/69eee1a7daba067954a02de55fad6efea52ff88a))
* reuse saved commit messages when the staged diff is unchanged ([#17](https://github.com/Waxmard/git-ai/issues/17)) ([352f2d4](https://github.com/Waxmard/git-ai/commit/352f2d4dddb6fda28515625dd825bcd4f711a895))
* two-pass PR generation with grouped sections and --no-test-plan flag ([#10](https://github.com/Waxmard/git-ai/issues/10)) ([a44cef4](https://github.com/Waxmard/git-ai/commit/a44cef479b27fe6af08ca7b582993081a11dcb8e))
* unify git-ai workflows, cache PR drafts by branch/base, and clarify semver guidance ([#19](https://github.com/Waxmard/git-ai/issues/19)) ([82f68a8](https://github.com/Waxmard/git-ai/commit/82f68a889eb46414fa6fc304c86d20f1d5b507dd))

## [1.4.0](https://github.com/Waxmard/git-ai/compare/v1.3.0...v1.4.0) (2026-04-13)


### Features

* reuse saved commit messages when the staged diff is unchanged ([#17](https://github.com/Waxmard/git-ai/issues/17)) ([352f2d4](https://github.com/Waxmard/git-ai/commit/352f2d4dddb6fda28515625dd825bcd4f711a895))

## [1.3.0](https://github.com/Waxmard/git-ai/compare/v1.2.0...v1.3.0) (2026-04-08)


### Features

* add release context to generated prompts ([#14](https://github.com/Waxmard/git-ai/issues/14)) ([73fc310](https://github.com/Waxmard/git-ai/commit/73fc310200896ed9861a99ec74ebb3abf2e74e28))

## [1.2.0](https://github.com/Waxmard/git-ai/compare/v1.1.0...v1.2.0) (2026-04-08)


### Features

* **auth:** expand provider auth fallbacks and default to gemini ([#12](https://github.com/Waxmard/git-ai/issues/12)) ([69eee1a](https://github.com/Waxmard/git-ai/commit/69eee1a7daba067954a02de55fad6efea52ff88a))

## [1.1.0](https://github.com/Waxmard/git-ai/compare/v1.0.0...v1.1.0) (2026-04-07)


### Features

* two-pass PR generation with grouped sections and --no-test-plan flag ([#10](https://github.com/Waxmard/git-ai/issues/10)) ([a44cef4](https://github.com/Waxmard/git-ai/commit/a44cef479b27fe6af08ca7b582993081a11dcb8e))

## [1.0.0](https://github.com/Waxmard/git-ai/compare/v0.1.2...v1.0.0) (2026-04-03)


### ⚠ BREAKING CHANGES

* add model tier selection for LLM providers ([#7](https://github.com/Waxmard/git-ai/issues/7))

### Features

* add model tier selection for LLM providers ([#7](https://github.com/Waxmard/git-ai/issues/7)) ([4f0d4c7](https://github.com/Waxmard/git-ai/commit/4f0d4c7c094cd8559d67374c65596793c4a175b9))

## [0.1.2](https://github.com/Waxmard/git-ai/compare/v0.1.1...v0.1.2) (2026-04-03)


### Features

* add adaptive provider defaults and persist last provider selection ([#5](https://github.com/Waxmard/git-ai/issues/5)) ([bc6c80b](https://github.com/Waxmard/git-ai/commit/bc6c80bfa1a5290f99b3dc1118800c89ba6c5b8e))

## [0.1.1](https://github.com/Waxmard/git-ai/compare/v0.1.0...v0.1.1) (2026-04-01)


### Features

* add git-ai CLI tools for LLM-powered commit and PR title generation ([36a655f](https://github.com/Waxmard/git-ai/commit/36a655f0ed6ae1f6145d9bba580cbe558019d898))
