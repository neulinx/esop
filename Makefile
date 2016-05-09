all: compile

compile:
	rebar3 compile
clean:
	rebar3 clean
	rm -f test/*.beam
test:
	rebar3 eunit
	rebar3 cover
