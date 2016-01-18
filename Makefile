SRC = $(wildcard src/*.js)
LIB = $(SRC:src/%.js=lib/%.js)
MOUNT = /neulinx

lib: $(LIB)
lib/%.js: src/%.js
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
	@rm lib/*.js
