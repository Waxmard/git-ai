PREFIX ?= $(HOME)/.local

.PHONY: install uninstall lint

lint:
	shellcheck -x lib/*.sh
	@for f in bin/*; do \
		if head -1 "$$f" | grep -q '^#!.*bash'; then \
			shellcheck -x "$$f"; \
		fi; \
	done

install:
	@mkdir -p $(PREFIX)/bin $(PREFIX)/lib
	@ln -sf $(CURDIR)/bin/ai-commit-gen $(PREFIX)/bin/ai-commit-gen
	@ln -sf $(CURDIR)/bin/ai-pr-title $(PREFIX)/bin/ai-pr-title
	@ln -sf $(CURDIR)/bin/ai-provider-menu $(PREFIX)/bin/ai-provider-menu
	@ln -sf $(CURDIR)/lib/ai-common.sh $(PREFIX)/lib/ai-common.sh
	@echo "Installed git-ai to $(PREFIX)"

uninstall:
	@rm -f $(PREFIX)/bin/ai-commit-gen
	@rm -f $(PREFIX)/bin/ai-pr-title
	@rm -f $(PREFIX)/bin/ai-provider-menu
	@rm -f $(PREFIX)/lib/ai-common.sh
	@echo "Uninstalled git-ai from $(PREFIX)"
