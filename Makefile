SRC = $(wildcard src/*.js)
LIB = $(SRC:src/%.js=lib/%.js)
MOUNT = /neulinx
OPTIONS = --presets es2015

lib: $(LIB)
lib/%.js: src/%.js
	mkdir -p $(@D)
	babel $(OPTIONS) $< -o $@

install: lib
	foxx-manager install . $(MOUNT)

upgrade: lib
	foxx-manager upgrade . $(MOUNT)

replace: lib
	foxx-manager replace . $(MOUNT)

uninstall:
	foxx-manager uninstall $(MOUNT)
