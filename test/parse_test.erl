-module(parse_test).

-include("include/frames.hrl").

-include_lib("eunit/include/eunit.hrl").

parse_incomplete_frame_test_() ->
    [?_test({more, _K} = mqtt_framing:start(Bin)) ||
        Bin <- [<<>>,
                <<6:4, 1:1, 1:2>>,
                <<1:4, 1:1, 1:2, 1:1>>,
                <<14:4, 1:1, 1:1, 1:2, 1:1, 255>>,
                <<14:4, 1:1, 1:1, 1:2, 1:1, 128, 128, 128>>,
                <<12:4, 4:4, 127, "not enough">>]].

parse_incomplete_connect_test() ->
    %% mid-string
    C = <<1:4, 0:4, 16,
          0, 6, "MQIsdp", 3,
          0, 10:16,
          0, 10, "fo", "junk at the end">>,
    {error, _} = mqtt_framing:start(C).

parse_connect_test() ->
    %% No extra strings
    C = <<1:4, 0:4, 20,
         0, 6, "MQIsdp", 3,
         0, 10:16, %% flags and keepalive
         %% only client id is needed
         0, 6, "foobar", "junk at the end">>,
    {frame, #connect{}, _} = mqtt_framing:start(C).
