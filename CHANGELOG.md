# Changelog

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
