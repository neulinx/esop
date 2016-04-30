all: compile

compile:
	rebar3 compile
clean:
	rebar3 clean
	rm -f test/*.beam
test: all
	rebar3 eunit
	rebar3 cover

docs:
	rebar3 skip_deps=true doc
