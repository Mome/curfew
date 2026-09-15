PREFIX     ?= $(HOME)/.local
BINDIR     ?= $(PREFIX)/bin
CONFIGDIR  ?= $(HOME)/.config/curfew

SCRIPT := $(CURDIR)/curfew

.PHONY: install uninstall purge

install:
	mkdir -p $(BINDIR)
	ln -sf $(SCRIPT) $(BINDIR)/curfew

uninstall:
	rm -f $(BINDIR)/curfew

purge: uninstall
	rm -rf $(CONFIGDIR)
