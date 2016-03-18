PKG_NAME = sop
TARGET = /neulinx
SOURCE = foxx

js:
	cd foxx && npm run compile

install:
	foxx-manager install $(SOURCE) $(TARGET)

upgrade:
	foxx-manager upgrade $(SOURCE) $(TARGET)

replace:
	foxx-manager replace $(SOURCE) $(TARGET)

uninstall:
	foxx-manager uninstall $(TARGET)

clean:
	@rm foxx/lib/*.js
	@cargo clean

test doc:
	cargo $@

release:
	cd foxx && npm run release
	cargo build --release

docview: doc
	xdg-open target/doc/$(PKG_NAME)/index.html

.PHONY: run test build doc clean docview js release
