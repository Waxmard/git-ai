PREFIX ?= $(HOME)/.local
BATS := node_modules/.bin/bats

.PHONY: install uninstall lint test hooks

test: $(BATS)
	$(BATS) --recursive test/

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
