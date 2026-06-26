PREFIX ?= $(HOME)/.local
BATS := node_modules/.bin/bats
UV ?= uv
export UV_CACHE_DIR := .uv-cache

# Parallel BATS jobs: default to the machine's core count (GNU parallel/rush required).
BATS_JOBS ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

.PHONY: install uninstall lint line-limit test hooks sync py-format py-lint py-type-check py-test docs-build docs-check prompts-build prompts-check

# --no-parallelize-within-files: per-test GNU-parallel dispatch costs more than
# it buys for this suite (measured ~16s vs ~10s wall) — file-level fan-out only.
test: $(BATS)
	@if command -v parallel >/dev/null 2>&1 || command -v rush >/dev/null 2>&1; then \
		$(BATS) --jobs $(BATS_JOBS) --no-parallelize-within-files --recursive test/; \
	else \
		$(BATS) --recursive test/; \
	fi

$(BATS):
	npm ci

lint:
	shellcheck -x lib/*.sh
	@for f in bin/*; do \
		if head -1 "$$f" | grep -q '^#!.*bash'; then \
			shellcheck -x "$$f"; \
		fi; \
	done

# Fail if any hand-written source file exceeds the per-file line cap (default
# 800; override with GIT_AI_LINE_LIMIT). Keeps modules small enough to read.
line-limit:
	@bash scripts/check-line-limit.sh

hooks:
	@command -v lefthook >/dev/null 2>&1 || { echo "lefthook not installed (run 'mise install' or 'brew install lefthook')"; exit 1; }
	@lefthook install
	@echo "Installed git hooks via lefthook"

install: hooks
	@mkdir -p $(PREFIX)/bin $(PREFIX)/lib
	@ln -sf $(CURDIR)/bin/git-ai $(PREFIX)/bin/git-ai
	@ln -sf $(CURDIR)/bin/aigit $(PREFIX)/bin/aigit
	@for f in $(CURDIR)/lib/*.sh; do ln -sf "$$f" $(PREFIX)/lib/$$(basename "$$f"); done
	@echo "Installed git-ai to $(PREFIX)"
	@resolved=$$(command -v git-ai 2>/dev/null); \
	npmdupe=""; \
	if command -v npm >/dev/null 2>&1 && [ -d "$$(npm root -g 2>/dev/null)/waxmard-git-ai" ]; then \
		npmdupe=1; \
	fi; \
	if [ -n "$$resolved" ] && [ "$$resolved" != "$(PREFIX)/bin/git-ai" ]; then \
		echo ""; \
		echo "WARNING: another git-ai shadows this install on your PATH:"; \
		echo "  PATH resolves:  $$resolved"; \
		echo "  just installed: $(PREFIX)/bin/git-ai"; \
		echo "  Remove the other (e.g. npm rm -g waxmard-git-ai) or put $(PREFIX)/bin first on PATH."; \
		echo "  Then open a new shell, or refresh the command cache in this one:"; \
		echo "    bash:  hash -r"; \
		echo "    zsh:   rehash"; \
	elif [ -n "$$npmdupe" ]; then \
		echo ""; \
		echo "WARNING: a waxmard-git-ai npm global is also installed (npm root -g)."; \
		echo "  This symlink wins on PATH here, but the npm copy may shadow git-ai in other shells."; \
		echo "  Remove it with: npm rm -g waxmard-git-ai"; \
	else \
		echo "  If your shell still runs an old git-ai, open a new shell or refresh its command cache:"; \
		echo "    bash:  hash -r"; \
		echo "    zsh:   rehash"; \
	fi

uninstall:
	@rm -f $(PREFIX)/bin/git-ai
	@rm -f $(PREFIX)/bin/aigit
	@rm -f $(PREFIX)/lib/*.sh
	@echo "Uninstalled git-ai from $(PREFIX)"

# Python targets
sync:
	$(UV) sync

py-format:
	$(UV) run ruff check python/ test/python --fix --select F401,I
	$(UV) run ruff format python/ test/python

py-lint:
	$(UV) run ruff check python/ test/python

py-type-check:
	$(UV) run mypy python/git_ai test/python

py-test:
	$(UV) run pytest

# Docs (generated from docs/src/ — stdlib python3, no deps)
docs-build:
	python3 scripts/build_docs.py --write

docs-check:
	python3 scripts/build_docs.py --check

# LLM prompts (generated from prompts/src/ — stdlib python3, no deps)
prompts-build:
	python3 scripts/build_prompts.py --write

prompts-check:
	python3 scripts/build_prompts.py --check
