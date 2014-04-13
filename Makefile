.PHONY: all dialyse clean test deps

all: deps
	rebar compile

deps:
	rebar get-deps

dialyse: all
	dialyzer ebin/*.beam

clean:
	rebar clean

test: all
	rebar eunit apps=erlmqtt
