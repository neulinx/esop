all: compile
compile dialyzer unlock cover shell:
	./rebar3 $@
reset: clean unlock
	rm -rf _build
devel:
	./rebar3 as devel do compile, dialyzer
test:
	-./rebar3 as devel eunit -c
	./rebar3 as devel cover
clean:
	rm -f test/*.beam
	./rebar3 clean -a
.PHONY: all reset test compile dialyzer clean unlock cover shell
