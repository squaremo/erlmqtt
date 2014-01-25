-module(parse_test).

-include("include/types.hrl").
-include("include/frames.hrl").

-include_lib("eunit/include/eunit.hrl").

parse_incomplete_frame_test_() ->
    [?_test({more, _K} = mqtt_framing:parse(Bin)) ||
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
    {error, _} = mqtt_framing:parse(C).

parse_connect_test() ->
    %% No extra strings
    C = <<1:4, 0:4, 20,
         0, 6, "MQIsdp", 3,
         0, 10:16, %% flags and keepalive
         %% only client id is needed
         0, 6, "foobar", "junk at the end">>,
    {frame, #connect{}, _} = mqtt_framing:parse(C).

parse_reserved_return_code_test() ->
    C = <<32,2,0,45>>,
    {error, {reserved_return_code, 45}} = mqtt_framing:parse(C).

parse_oob_message_id_test() ->
    C = <<64, 2, 0, 0>>,
    {error, {out_of_bounds_message_id, 0}} = mqtt_framing:parse(C).

%% QoS occupies only the lowest two bits of each byte in suback
parse_bad_qoses_test() ->
    C = <<144, 3, 0,1, 100>>,
    {error, {unparsable_as_qos, _}} = mqtt_framing:parse(C).

%% QoS must be 0..2
parse_bad_qoses2_test() ->
    C = <<144, 3, 0,1, 3>>,
    {error, {unparsable_as_qos, _}} = mqtt_framing:parse(C).

%% QoS must be 0|1|2 but is encoded in two bits, which admits 3 as a
%% value.
parse_invalid_qos_test() ->
    C = <<102,2,0,1>>,
    {error, {invalid_qos_value, _}} = mqtt_framing:parse(C).

parse_invalid_sub_qos_test() ->
    C = <<130,8,0,1, 0,3,102,111,111,4>>,
    {error, {unparsable_as_sub, _}} = mqtt_framing:parse(C).

parse_invalid_pubrel_qos_test() ->
    C = <<100, 2, 0,23>>, %% 100 = ?PUBREL + qos_flag(2)
    {error, {invalid_qos_value, _}} = mqtt_framing:parse(C).

parse_qos0_publish_test() ->
    C = <<48,2,0,0>>,
    {frame, #publish{ qos = at_most_once }, _} =
        mqtt_framing:parse(C).
