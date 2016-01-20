PKG_NAME = sop
SRC = $(wildcard es/*.js)
LIB = $(SRC:es/%.js=foxx/lib/%.js)
MOUNT = /neulinx

lib: $(LIB)
foxx/lib/%.js: es/%.js
	@mkdir -p $(@D)
	babel $< -o $@

install: lib
	foxx-manager install . $(MOUNT)

upgrade: lib
	foxx-manager upgrade . $(MOUNT)

replace: lib
	foxx-manager replace . $(MOUNT)

uninstall:
	foxx-manager uninstall $(MOUNT)

clean:
	@rm foxx/lib/*.js
	@cargo clean

test doc:
	cargo $@

run build:
	cargo $@ --release

docview: doc
	xdg-open target/doc/$(PKG_NAME)/index.html

.PHONY: run test build doc clean docview
