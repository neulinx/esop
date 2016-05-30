all: compile dialyzer
compile dialyzer clean unlock:
	rebar3 $@
reset: clean unlock
	rm -rf _build
test:
	rebar3 eunit --cover
	rebar3 cover

.PHONY: all reset test compile dialyzer clean unlock 
