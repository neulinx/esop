compile:
	rebar3 compile
all: compile test
	rebar3 dialyzer
clean:
	rebar3 clean
reset: clean
	rebar3 unlock
	rm -rf _build
test:
	rebar3 eunit --cover
	rebar3 cover

.PHONY: test
