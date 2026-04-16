PREFIX ?= $(HOME)/.local
BATS := node_modules/.bin/bats
UV ?= uv
export UV_CACHE_DIR := .uv-cache

.PHONY: install uninstall lint test hooks sync py-format py-lint py-type-check py-test py-pre-commit

test: $(BATS)
	@if command -v parallel >/dev/null 2>&1 || command -v rush >/dev/null 2>&1; then \
		$(BATS) --jobs 4 --recursive test/; \
	else \
		$(BATS) --recursive test/; \
	fi

$(BATS):
	npm ci

lint:
	shellcheck -x lib/*.sh
	@for f in bin/* hooks/*; do \
		if head -1 "$$f" | grep -q '^#!.*bash'; then \
			shellcheck -x "$$f"; \
		fi; \
	done

hooks:
	@chmod +x $(CURDIR)/hooks/pre-commit
	@ln -sf $(CURDIR)/hooks/pre-commit $(CURDIR)/.git/hooks/pre-commit
	@echo "Installed pre-commit hook"

install: hooks
	@mkdir -p $(PREFIX)/bin $(PREFIX)/lib
	@ln -sf $(CURDIR)/bin/git-ai $(PREFIX)/bin/git-ai
	@ln -sf $(CURDIR)/bin/aigit $(PREFIX)/bin/aigit
	@ln -sf $(CURDIR)/lib/ai-common.sh $(PREFIX)/lib/ai-common.sh
	@echo "Installed git-ai to $(PREFIX)"

uninstall:
	@rm -f $(PREFIX)/bin/git-ai
	@rm -f $(PREFIX)/bin/aigit
	@rm -f $(PREFIX)/lib/ai-common.sh
	@echo "Uninstalled git-ai from $(PREFIX)"

# Python targets
sync:
	$(UV) sync

py-format:
	$(UV) run ruff check python/ --fix --select F401,I
	$(UV) run ruff format python/

py-lint:
	$(UV) run ruff check python/

py-type-check:
	$(UV) run mypy python/git_ai test/python

py-test:
	$(UV) run pytest

py-pre-commit:
	$(UV) run pre-commit run --all-files
