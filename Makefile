PKG_NAME = sop
SRC = $(wildcard es/*.js)
LIB = $(SRC:es/%.js=foxx/lib/%.js)
TARGET = /neulinx
SOURCE = foxx

lib: $(LIB)
foxx/lib/%.js: es/%.js
	@mkdir -p $(@D)
	babel $< -o $@

install: lib
	foxx-manager install $(SOURCE) $(TARGET)

upgrade: lib
	foxx-manager upgrade $(SOURCE) $(TARGET)

replace: lib
	foxx-manager replace $(SOURCE) $(TARGET)

uninstall:
	foxx-manager uninstall $(TARGET)

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
