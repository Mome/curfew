PREFIX      ?= $(HOME)/.local
BINDIR      ?= $(PREFIX)/bin
CONFIGDIR   ?= $(HOME)/.config/curfew
BASHCOMPDIR ?= $(PREFIX)/share/bash-completion/completions

SCRIPT := $(CURDIR)/curfew
BASH_COMPLETION_SCRIPT := $(CURDIR)/completions/curfew.bash

.PHONY: install uninstall purge test

install:
	mkdir -p $(BINDIR)
	ln -sf $(SCRIPT) $(BINDIR)/curfew
	mkdir -p $(BASHCOMPDIR)
	ln -sf $(BASH_COMPLETION_SCRIPT) $(BASHCOMPDIR)/curfew

uninstall:
	rm -f $(BINDIR)/curfew
	rm -f $(BASHCOMPDIR)/curfew

purge: uninstall
	rm -rf $(CONFIGDIR)

test:
	bash tests/test_completion.bash
