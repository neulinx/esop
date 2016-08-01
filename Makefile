all: compile dialyzer
compile dialyzer clean unlock cover:
	./rebar3 $@
reset: clean unlock
	rm -rf _build
test:
	./rebar3 do eunit -c, cover
.PHONY: all reset test compile dialyzer clean unlock cover
