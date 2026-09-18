# Fall back to the SDK bundled with Jaguar.
TOIT ?= $(if $(shell command -v toit),toit,jag toit)

TESTS := $(wildcard tests/*-test.toit)
SOURCES := $(wildcard src/*.toit) $(TESTS) $(wildcard examples/*.toit)

all: test analyze

install-pkgs:
	cd tests && $(TOIT) pkg install
	cd examples && $(TOIT) pkg install

test: install-pkgs
	@set -e; for t in $(TESTS); do echo "== $$t"; $(TOIT) run $$t; done

analyze: install-pkgs
	@set -e; for f in $(SOURCES); do $(TOIT) analyze $$f; done

.PHONY: all install-pkgs test analyze
