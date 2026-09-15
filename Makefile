PREFIX      ?= $(HOME)/.local
BINDIR      ?= $(PREFIX)/bin
CONFIGDIR   ?= $(HOME)/.config/curfew
BASHCOMPDIR ?= $(PREFIX)/share/bash-completion/completions
FISHCOMPDIR ?= $(HOME)/.config/fish/completions

SCRIPT := $(CURDIR)/curfew
BASH_COMPLETION_SCRIPT := $(CURDIR)/completions/curfew.bash
FISH_COMPLETION_SCRIPT := $(CURDIR)/completions/curfew.fish

.PHONY: install uninstall purge test

install:
	mkdir -p $(BINDIR)
	ln -sf $(SCRIPT) $(BINDIR)/curfew
	mkdir -p $(BASHCOMPDIR)
	ln -sf $(BASH_COMPLETION_SCRIPT) $(BASHCOMPDIR)/curfew
	mkdir -p $(FISHCOMPDIR)
	ln -sf $(FISH_COMPLETION_SCRIPT) $(FISHCOMPDIR)/curfew.fish

uninstall:
	rm -f $(BINDIR)/curfew
	rm -f $(BASHCOMPDIR)/curfew
	rm -f $(FISHCOMPDIR)/curfew.fish

purge: uninstall
	rm -rf $(CONFIGDIR)

test:
	bash tests/test_completion.bash
	bash tests/test_completion_fish.sh
	bash tests/test_apply.bash
