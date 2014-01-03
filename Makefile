.PHONY: all dialyse clean test

all:
	rebar compile

dialyse: all
	dialyzer ebin/*.beam

clean:
	rebar clean

test: all
	rebar eunit
