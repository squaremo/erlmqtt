.PHONY: all dialyse clean

all:
	rebar compile

dialyse: all
	dialyzer ebin/*.beam

clean:
	rebar clean
