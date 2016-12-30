all: compile dialyzer
compile dialyzer clean unlock cover shell:
	./rebar3 $@
reset: clean unlock
	rm -rf _build
test:
	./rebar3 do eunit, cover
.PHONY: all reset test compile dialyzer clean unlock cover shell
