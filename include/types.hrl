-ifndef(types_hrl).
-define(types_hrl, true).

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

-include("frames.hrl").

%% Represents records that are ready to be serialised. In some cases,
%% records may be constructed with fields left undefined; these must
%% be further constrained here.
-type(mqtt_frame() ::
        #connect{}
      | #connack{}
      | #publish{}
      | #puback{}
      | #pubrec{}
      | #pubrel{}
      | #pubcomp{}
      | #subscribe{ message_id :: message_id() }
      | #suback{}
      | #unsubscribe{ message_id :: message_id() }
      | #unsuback{}
      | 'pingreq'
      | 'pingresp'
      | 'disconnect').

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

-type(error() :: {'error', term()}).

-type(qos_level() :: 'at_least_once'
                   | 'at_most_once'
                   | 'exactly_once').

-type(return_code() :: 'ok'
                     | 'wrong_version'
                     | 'bad_id'
                     | 'server_unavailable'
                     | 'bad_auth'
                     | 'not_authorised').

-type(topic() :: iolist() | binary()).
-type(payload() :: iolist() | binary()).

%% This isn't quite adequate: client IDs are supposed to be between 1
%% and 23 characters long; however, Erlang's type notation doesn't let
%% me express that easily.
-type(client_id() :: <<_:8, _:_*8>>).

-type(message_id() :: 1..16#ffff).

-endif.
