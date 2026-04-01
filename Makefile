PREFIX ?= $(HOME)/.local

.PHONY: install uninstall

install:
	@mkdir -p $(PREFIX)/bin $(PREFIX)/lib
	@ln -sf $(CURDIR)/bin/ai-commit-gen $(PREFIX)/bin/ai-commit-gen
	@ln -sf $(CURDIR)/bin/ai-pr-title $(PREFIX)/bin/ai-pr-title
	@ln -sf $(CURDIR)/lib/ai-common.sh $(PREFIX)/lib/ai-common.sh
	@echo "Installed git-ai to $(PREFIX)"

uninstall:
	@rm -f $(PREFIX)/bin/ai-commit-gen
	@rm -f $(PREFIX)/bin/ai-pr-title
	@rm -f $(PREFIX)/lib/ai-common.sh
	@echo "Uninstalled git-ai from $(PREFIX)"
