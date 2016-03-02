PKG_NAME = sop
TARGET = /neulinx
SOURCE = foxx

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

js:
	cd foxx && npm run compile

docview: doc
	xdg-open target/doc/$(PKG_NAME)/index.html

.PHONY: run test build doc clean docview
