-module(mqtt_framing).

-ifdef(TEST).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([parse/1, serialise/1]).

-export_type([return_code/0,
              parse_result/0,
              message_type/0,
              message_id/0,
              qos/0,
              mqtt_frame/0,
              client_id/0]).


-define(Top1, 128).
-define(Lower7, 127).

-define(CONNECT, 1).
-define(CONNACK, 2).
-define(PUBLISH, 3).
-define(PUBACK, 4).
-define(PUBREC, 5).
-define(PUBREL, 6).
-define(PUBCOMP, 7).
-define(SUBSCRIBE, 8).
-define(SUBACK, 9).
-define(UNSUBSCRIBE, 10).
-define(UNSUBACK, 11).
-define(PINGREQ, 12).
-define(PINGRESP, 13).
-define(DISCONNECT, 14).

-define(set(Record, Field), fun(R, V) -> R#Record{ Field = V } end).
-define(undefined(ExprIn, IfUndefined, IfDefined),
        case ExprIn of
            undefined -> IfUndefined;
            _         -> IfDefined
        end).

-include("include/frames.hrl").


-type(mqtt_frame() ::
        #connect{}
      | #connack{}
      | #publish{}
      | #puback{}
      | #pubrec{}
      | #pubrel{}
      | #pubcomp{}).

-type(qos() :: 0 | 1 | 2).
-type(message_type() ::
      ?CONNECT
    | ?CONNACK
    | ?PUBLISH
    | ?PUBACK
    | ?PUBREC
    | ?PUBREL
    | ?PUBCOMP
    | ?SUBSCRIBE
    | ?SUBACK
    | ?UNSUBSCRIBE
    | ?UNSUBACK
    | ?PINGREQ
    | ?PINGRESP
    | ?DISCONNECT).

-type(return_code() :: 'ok'
                     | 'wrong_version'
                     | 'bad_id'
                     | 'server_unavailable'
                     | 'bad_auth'
                     | 'not_authorised').

%% This isn't quite adequate: client IDs are supposed to be between 1
%% and 23 characters long; however, Erlang's type notation doesn't let
%% me express that easily.
-type(client_id() :: <<_:8, _:_*8>>).

-type(message_id() :: 1..16#ffff).

%% MQTT frames come in three parts: firstly, a fixed header, which is
%% two to five bytes with some flags, a number denoting the command,
%% and the (encoded) remaining length; then, a variable header which
%% is various serial values depending on the command; then, the
%% payload, which is simply bytes.
%%
%% We'll simply split the frame up into these sections and wrap a
%% record around it representing the command.

%% We'll take the chance that almost all of the time we'll want the
%% whole frame at once, even if we end up discarding it.

%% Fixed header.
%% bit     |7  6  5  4   |3        |2    1    |0
%% byte 1  |Message Type |DUP flag |QoS level |RETAIN
%% byte 2  |Remaining Length

%% Frame parsing is to be done as a trampoline: it starts with the
%% function `start/1`, which returns either `{frame, Frame, Rest}`,
%% indicating that a frame has been parsed and parsing should begin
%% again with `start(Rest)`; or, `{more, K}` which indicates that a
%% frame was not able to be parsed, and parsing should start again
%% with `K` when there are more bytes available.

-type(parse_result() :: {frame, mqtt_frame(), binary()}
                      | {error, term()}
                      | {more, parse()}).
-type(parse() :: fun((binary()) -> parse_result())).

-spec(parse(binary()) -> parse_result()).
parse(Bin) ->
    try start(Bin)
    catch
        throw:A -> {error, A}
    end.

-spec(start(binary()) -> parse_result()).
start(<<MessageType:4, Dup:1, QoS:2, Retain:1, Len1:8,
       Rest/binary>>) ->
    %% Invalid values?
    parse_from_length(MessageType,
                      #fixed{ dup = flag(Dup),
                              qos = QoS,
                              retain = flag(Retain)},
                      Len1, 1, 0, Rest);
%% Not enough to even get the first bit of the header. This might
%% happen if a frame is split across packets. We don't expect to split
%% across more than two packets.
start(Bin1) ->
    {more, fun(Bin2) -> start(<<Bin1/binary, Bin2/binary>>) end}.


parse_from_length(Type, Fixed, LenByte, Multiplier0, Value0, Bin) ->
    Length = Value0 + (LenByte band ?Lower7) * Multiplier0,
    case LenByte band ?Top1 of
        ?Top1 ->
            Multiplier = Multiplier0 * 128,
            case Bin of
                <<NextLenByte:8, Rest/binary>> ->
                    parse_from_length(Type, Fixed, NextLenByte, Multiplier,
                                      Length, Rest);
                <<>> ->
                    %% Assumes we get at least one more byte ..
                    {more, fun(<<NextLenByte:8, Rest/binary>>) ->
                                   parse_from_length(Type, Fixed,
                                                     NextLenByte,
                                                     Multiplier,
                                                     Length, Rest)
                           end}
            end;
        0 -> % No continuation bit
            parse_variable_header(Type, Fixed, Length, Bin)
    end.

%% Each message type has its own idea of what the variable header
%% contains.  We may as well read until we have the entire frame first
%% though.
parse_variable_header(Type, Fixed = #fixed{}, Length, Bin) ->
    case Bin of
        <<FrameRest:Length/binary, Rest/binary>> ->
            case parse_message_type(Type, Fixed, FrameRest) of
                Err = {error, _} ->
                    Err;
                {ok, Frame} ->
                    {frame, Frame, Rest}
            end;
        NotEnough ->
            parse_more_header(Type, Fixed, Length, Length,
                              [], NotEnough)
    end.

parse_more_header(Type, Fixed, Length, Needed, FragmentsRev, Bin) ->
    Got = size(Bin),
    if Got < Needed ->
            {more, fun(NextBin) ->
                           parse_more_header(Type, Fixed, Length,
                                             Needed - Got,
                                             [Bin | FragmentsRev], NextBin)
                   end};
       true ->
            Fragments = lists:reverse([Bin | FragmentsRev]),
            parse_variable_header(Type, Fixed, Length,
                                  list_to_binary(Fragments))
    end.

parse_message_type(?CONNECT, Fixed,
                   %% Protocol name, Protocol version
                   <<0, 6, "MQIsdp", 3,
                    %% Flaaaags
                    UsernameFlag:1, PasswordFlag:1, WillRetain:1,
                    WillQos:2, WillFlag:1, CleanSession:1, _:1,
                    KeepAlive:16,
                    %% The content depends on the flags
                    Payload/binary>>) ->
    {ClientId, Rest} = parse_string(Payload),
    if size(ClientId) > 23 ->
            {error, identifier_rejected};
       true ->
            C = #connect{ fixed = Fixed,
                          will = undefined,
                          clean_session = flag(CleanSession),
                          keep_alive = KeepAlive,
                          client_id = ClientId },
            S1 = case WillFlag of
                     0 ->
                         {ok, C, Rest};
                     1 ->
                         {Topic, Rest1} = parse_string(Rest),
                         {Message, Rest2} = parse_string(Rest1),
                         {ok, C#connect{ will = #will{
                                           topic = Topic,
                                           message = Message,
                                           qos = WillQos,
                                           retain = flag(WillRetain)
                                          }
                                        }, Rest2}
                 end,
            S2 = maybe_s(S1, UsernameFlag, ?set(connect, username)),
            S3 = maybe_s(S2, PasswordFlag, ?set(connect, password)),
            case S3 of
                {ok, Connect, <<>>} -> {ok, Connect};
                {ok, _, _} -> {error, malformed_frame};
                Err = {error, _} -> Err
            end
    end;

parse_message_type(?CONNACK, Fixed, <<_Reserved:8, Return:8>>) ->
    {ok, #connack{ fixed = Fixed,
                   return_code = byte_to_return_code(Return) }};

parse_message_type(?PUBLISH, Fixed, <<TopicLen:16, Topic:TopicLen/binary,
                                     MsgId:16,
                                     Payload/binary>>) ->
    {ok, #publish{ fixed = Fixed, topic = Topic, message_id = MsgId,
                   payload = Payload }};

parse_message_type(?PUBACK, Fixed, <<MessageId:16>>) ->
    {ok, #puback{ fixed = Fixed, message_id = MessageId }};
parse_message_type(?PUBREC, Fixed, <<MessageId:16>>) ->
    {ok, #pubrec{ fixed = Fixed, message_id = MessageId }};
parse_message_type(?PUBREL, Fixed, <<MessageId:16>>) ->
    {ok, #pubrel{ fixed = Fixed, message_id = MessageId }};
parse_message_type(?PUBCOMP, Fixed, <<MessageId:16>>) ->
    {ok, #pubcomp{ fixed = Fixed, message_id = MessageId }};

parse_message_type(_, _, _) ->
    {error, unrecognised}.

parse_string(<<Length:16, String:Length/binary, Rest/binary>>) ->
    {String, Rest};
parse_string(_Bin) ->
    {error, malformed_frame}.

maybe_s(Err = {error, _}, _, _) ->
    Err;
maybe_s({ok, Frame, Bin}, 0, _Setter) ->
    {ok, Frame, Bin};
maybe_s({ok, Frame, Bin}, 1, Setter) ->
    case parse_string(Bin) of
        Error = {error, _} ->
            Error;
        {String, Rest} ->
            {ok, Setter(Frame, String), Rest}
    end.

flag(0) -> false;
flag(1) -> true.

-spec(byte_to_return_code(byte()) -> return_code()). 
byte_to_return_code(0) -> ok;
byte_to_return_code(1) -> wrong_version;
byte_to_return_code(2) -> bad_id;
byte_to_return_code(3) -> server_unavailable;
byte_to_return_code(4) -> bad_auth;
byte_to_return_code(5) -> not_authorised;
byte_to_return_code(Else) -> throw({reserved_return_code, Else}).

-spec(return_code_to_byte(return_code()) -> byte()).
return_code_to_byte(ok) -> 0;
return_code_to_byte(wrong_version) -> 1;
return_code_to_byte(bad_id) -> 2;
return_code_to_byte(server_unavailable) -> 3;
return_code_to_byte(bad_auth) -> 4;
return_code_to_byte(not_authorised) -> 5;
return_code_to_byte(Else) -> throw({unknown_return_code, Else}).


%% --- serialise

-spec(serialise(mqtt_frame()) -> iolist() | binary()).

serialise(#connect{ fixed = Fixed,
                    clean_session = Clean,
                    will = Will,
                    username = Username,
                    password = Password,
                    client_id = ClientId,
                    keep_alive = KeepAlive }) ->
    FixedByte = fixed_byte(?CONNECT, Fixed),

    WillQos = ?undefined(Will, 0, Will#will.qos),
    WillRetain = ?undefined(Will, false, Will#will.retain),
    WillTopic = ?undefined(Will, undefined, Will#will.topic),
    WillMsg = ?undefined(Will, undefined, Will#will.message),

    Flags = flag_bit(Clean, 1) +
        defined_bit(Will, 2) + %% assume will if topic given
        (WillQos bsl 3) +
        flag_bit(WillRetain, 5) +
        string_bit(Password, 6) +
        string_bit(Username, 7),

    %% Done in reverse order so no lists:reverse needed.
    Strings = << <<(size(Str)):16, Str/binary>> ||
                  Str <- [ClientId, WillTopic, WillMsg,
                          Username, Password], is_binary(Str)>>,
    {LenEncoded, LenSize} = encode_length(12 + size(Strings)),
    [<<FixedByte:8,
      LenEncoded:LenSize, %% remaining length
      6:16, "MQIsdp", 3:8, %% protocol name and version
      Flags:8,
      KeepAlive:16>>,
     Strings];

serialise(#connack{ fixed = Fixed, return_code = ReturnCode }) ->
    FixedByte = fixed_byte(?CONNACK, Fixed),
    <<FixedByte:8,
     2:8, %% always 2
     0:8, %% reserved
     (return_code_to_byte(ReturnCode)):8>>;

serialise(#publish{ fixed = Fixed,
                    topic = Topic,
                    message_id = MessageId,
                    payload = Payload }) ->
    FixedByte = fixed_byte(?PUBLISH, Fixed),
    TopicSize = size(Topic),
    {Num, Bits} = encode_length(2 + TopicSize + %% topic len + bytes
                                2 + %% 16-bit message id
                                size(Payload)),
    [<<FixedByte:8, Num:Bits,
      TopicSize:16, Topic/binary,
      MessageId:16>>, Payload];

serialise(#puback{ fixed = Fixed, message_id = MsgId }) ->
    <<(fixed_byte(?PUBACK, Fixed)):8, 2:8, MsgId:16>>;
serialise(#pubrec{ fixed = Fixed, message_id = MsgId }) ->
    <<(fixed_byte(?PUBREC, Fixed)):8, 2:8, MsgId:16>>;
serialise(#pubrel{ fixed = Fixed, message_id = MsgId }) ->
    <<(fixed_byte(?PUBREL, Fixed)):8, 2:8, MsgId:16>>;
serialise(#pubcomp{ fixed = Fixed, message_id = MsgId }) ->
    <<(fixed_byte(?PUBCOMP, Fixed)):8, 2:8, MsgId:16>>;

serialise(Else) ->
    throw({unserialisable, Else}).

-type(frame_length() :: 0..268435455).
-type(length_num() :: 0..16#ffffffff).
-type(length_bits() :: 8 | 16 | 24 | 32).

-spec(encode_length(frame_length()) ->
             {length_num(), length_bits()}).
encode_length(L) when L < 16#80 ->
    {L, 8};
encode_length(L) ->
    encode_length(L, 0, 0).

encode_length(0, Bits, Sum) ->
    {Sum, Bits};
encode_length(L, Bits, Sum) ->
    Mod128 = L band 16#7f,
    X = L bsr 7,
    Digit = case X of
                0 -> Mod128;
                _ -> Mod128 bor 16#80
            end,
    encode_length(X, Bits + 8, (Sum bsl 8) + Digit).

fixed_byte(Type, #fixed{ dup = Dup,
                         qos = Qos,
                         retain = Retain }) ->
    (Type bsl 4) +
    flag_bit(Dup, 3) +
    (Qos bsl 1) +
    flag_bit(Retain, 0).

flag_bit(false, _)  -> 0;
flag_bit(true, Bit) -> 1 bsl Bit.

string_bit(undefined, _) -> 0;
string_bit(Str, Bit) when is_binary(Str) -> 1 bsl Bit.

defined_bit(undefined, _) -> 0;
defined_bit(_, Bit) -> 1 bsl Bit.

%% ---------- properties

-ifdef(TEST).
-include("include/module_tests.hrl").

encode_length_boundary_test_() ->
    [?_test(?assertEqual({Num, Bits}, encode_length(Len))) ||
        {Len, Num, Bits} <- [{0, 0, 8},
                             {127, 127, 8},
                             {128, 16#8001, 16},
                             {16383, 16#ff7f, 16},
                             {16384, 16#808001, 24},
                             {2097151, 16#ffff7f, 24},
                             {2097152, 16#80808001, 32},
                             {268435455, 16#ffffff7f, 32}]].

prop_return_code() ->
    ?FORALL(Code, mqtt_framing:return_code(),
            begin
                B = return_code_to_byte(Code),
                C = byte_to_return_code(B),
                Code =:= C
            end).

%% NB #connect has a special case because it's difficult to express
%% the type for client ID (a string between 1 and 23 bytes long).
prop_roundtrip_frame() ->
    ?FORALL(Frame, mqtt_frame(),
            ?IMPLIES(case Frame of
                         #connect{ client_id = ClientId } ->
                             size(ClientId) < 24;
                         _ -> true
                     end,
                     begin
                         Ser = iolist_to_binary(serialise(Frame)),
                         {frame, F, <<>>} = start(Ser),
                         F =:= Frame
                     end)).

-endif.
