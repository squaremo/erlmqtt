-module(erlmqtt).

-export([
         open_clean/2,
         open/2, open/3,
         connect/1, disconnect/1,
         close/1,
         subscribe/2, subscribe/3,
         unsubscribe/2, unsubscribe/3,
         publish/3, publish/4,
         publish_sync/4, publish_sync/5,
         recv_message/0, recv_message/1,
         poll_message/0,
         qos_symbol/1,
         is_connect_option/1
        ]).

-include("include/types.hrl").
-include("include/frames.hrl").

-type(address() :: erlmqtt_connection:address()).
-type(connect_option() :: erlmqtt_connection:connect_option()).
-type(connection() :: erlmqtt_connection:connection()).
-type(subscription() :: topic() | {topic(), qos_level()}).
-type(publish_option() :: erlmqtt_connection:publish_option()).

%% Public API for erlmqtt.

%% Create and connect an ephemeral MQTT session, for which the state
%% will be discarded when it is disconnected. This links the
%% connection process to the calling process. Returns the connection.
-spec(open_clean(address(), [connect_option()]) ->
             {ok, connection()} | error()).
open_clean(HostSpec, Options) ->
    ClientId = random_client_id(),
    {ok, Conn} = erlmqtt_connection:start_link(
                   HostSpec, ClientId,
                   [clean_session | Options]),
    ok = erlmqtt_connection:connect(Conn),
    {ok, Conn}.

%% Creates a new MQTT session and returns the client ID, for
%% reconnecting, as well as the connection.
-spec(open(address(), [connect_option()]) ->
             {ok, connection()}).
open(HostSpec, Options) ->
    ClientId = random_client_id(),
    {ok, Conn} = erlmqtt_connection:start_link(
                   HostSpec, ClientId,
                   [{clean_session, false} | Options]),
    ok = erlmqtt_connection:connect(Conn),
    {ok, Conn}.

-spec(open(address(), client_id(), [connect_option()]) ->
             {ok, connection()}).
%% Open a MQTT session identified by the given ClientId.
open(HostSpec, ClientId, Options) ->
    {ok, Conn} = erlmqtt_connection:start_link(
                   HostSpec, ClientId,
                   [{clean_session, false} | Options]),
    ok = erlmqtt_connection:connect(Conn),
    {ok, Conn}.

%% Explicitly disconnect a session from a server without terminating
%% the connection.
-spec(disconnect(connection()) -> ok).
disconnect(Conn) ->    
    erlmqtt_connection:disconnect(Conn).

-spec(connect(connection()) -> ok).
connect(Conn) -> 
    erlmqtt_connection:connect(Conn).

%% Close an MQTT session and terminate the connection.
-spec(close(connection()) -> ok). 
close(C) ->
    erlmqtt_connection:disconnect_and_terminate(C).

%% Subscribe a connection to the given topics. A topic may be a
%% string, a binary, or a tuple of a string or binary with one of the
%% atoms denoting a "quality of service": 'at_most_once',
%% 'at_least_once', 'exactly_once'. A string or binary on its own is
%% the same as `{Topic, at_most_once}`. Returns once the server has
%% replied, with the list of "quality of service" values granted by
%% the server for each subscription.
-spec(subscribe(connection(), [subscription()]) ->
             {ok, [qos_level()]}).
subscribe(Conn, Topics) ->
    Topics1 = [norm_topic(T) || T <- Topics],
    erlmqtt_connection:subscribe(Conn, Topics1).

%% Similar to subscribe/2 but will return `{timeout, Ref}'` if the
%% server does not reply within the given timeout, where the Ref
%% corresponds to the awaited reply.
-spec(subscribe(connection(), [subscription()], timeout()) ->
             {ok, [qos_level()]} | 'timeout').
subscribe(Conn, Topics, Timeout) ->
    Topics1 = [norm_topic(T) || T <- Topics],
    erlmqtt_connection:subscribe(Conn, Topics1, Timeout).

%% Unsubscribe from the given topics, which are each a string or
%% binary. Returns 'ok' once the server has responded.
-spec(unsubscribe(connection(), [topic()]) -> ok).
unsubscribe(Conn, Topics) ->
    erlmqtt_connection:unsubscribe(Conn, Topics).

%% Unsubscribe from the given topics, and return ok or {timeout, Ref}
%% if the operation does not get a reply from the server within
%% Timeout.
-spec(unsubscribe(connection(), [topic()], timeout()) ->
             ok | 'timeout').
unsubscribe(Conn, Topics, Timeout) ->
    erlmqtt_connection:unsubscribe(Conn, Topics, Timeout).

%% publish a message with the default quality of service and options.
-spec(publish(connection(), topic(), payload()) -> ok).
publish(Conn, Topic, Payload) ->
    publish(Conn, Topic, Payload, []).

-spec(publish(connection(), topic(), payload(),
              qos_level() | [publish_option()]) -> ok).
%% publish a message with the given quality of service.
publish(Conn, Topic, Payload, QoS) when is_atom(QoS) ->
    erlmqtt_connection:publish(Conn, Topic, Payload, [QoS]);
%% publish a message with the options given, possibly including
%% quality of service.
publish(Conn, Topic, Payload, Options) ->
    erlmqtt_connection:publish(Conn, Topic, Payload, Options).

%% Publish a message and wait for the acknowledgment to come back, or
%% a timeout. The QoS level may be given in the `Options`, or as the
%% `Options`.
-spec(publish_sync(connection(), topic(), payload(),
                   qos_level() | [publish_option()],
                   timeout()) ->
             ok).
publish_sync(Conn, Topic, Payload, QoS, Timeout)
  when is_atom(QoS) ->
    publish_sync(Conn, Topic, Payload, [QoS], Timeout);
publish_sync(Conn, Topic, Payload, Options, Timeout) ->
    case qos_option(Options) of
        at_most_once ->
            publish(Conn, Topic, Payload, Options);
        QoS ->
            Ref = publish_ref(Conn, Topic, Payload, Options),
            Ack = ack_for(QoS),
            receive {Ack, Ref} ->
                    ok
            after Timeout ->
                    timeout
            end
    end.


%% Publish a message and wait for the acknowledgment to come back.
-spec(publish_sync(connection(), topic(), payload(),
                   qos_level() | [publish_option()]) ->
             ok).
publish_sync(Conn, Topic, Payload, Options) ->
    publish_sync(Conn, Topic, Payload, Options, infinity).


%% Wait for a message sent to the calling process, which is assumed to
%% have been registered as the consumer for a connection. Return
%% the topic and payload of the message as {Topic, Payload}.
-spec(recv_message() -> {binary(), binary()}).
recv_message() ->
    recv_message(infinity).

%% Wait for a message and return {Topic, Payload}, or time out after
%% Timeout, in which case return 'timeout'.
-spec(recv_message(timeout()) -> {binary(), binary()} | 'timeout').
recv_message(Timeout) ->
    receive {frame, #publish{topic = T, payload = P}} ->
            {T, P}
    after Timeout ->
            timeout
    end.

-spec(poll_message() -> {binary(), binary()} | 'none').
poll_message() ->
    case recv_message(0) of
        timeout      -> none;
        Msg = {_, _} -> Msg
    end.

%% -- helpers for command-line

-spec(qos_symbol(0..2) -> qos_level()).
qos_symbol(0) -> at_most_once;
qos_symbol(1) -> at_least_once;
qos_symbol(2) -> exactly_once.

-spec(is_connect_option({atom(), term()}) -> boolean()).
is_connect_option({username, _})   -> true; 
is_connect_option({password, _})   -> true;
is_connect_option({keep_alive, _}) -> true;
is_connect_option({client_id, _})  -> true;
is_connect_option(_)               -> false.

%% ---- internal helpers

qos_option([at_most_once | _])  -> at_most_once;
qos_option([at_least_once | _]) -> at_least_once;
qos_option([exactly_once | _])  -> exactly_once;
qos_option([{qos, QoS} | _])    -> QoS;
qos_option([_Else | Rest])      -> qos_option(Rest);
qos_option([])                  -> at_most_once.

publish_ref(Conn, Topic, Payload, Options) ->
    Ref = make_ref(),
    publish(Conn, Topic, Payload, [{ref, Ref} | Options]),
    Ref.

ack_for(at_least_once) -> puback;
ack_for(exactly_once)  -> pubrec.

%% Not very UUIDy, but probably good enough for now.
random_client_id() ->
    list_to_binary(
      [crypto:rand_uniform(33, 126) || _ <- lists:seq(1, 23)]).

norm_topic(Topic = {_T, _Q}) ->
    Topic;
norm_topic(Topic) when is_binary(Topic); is_list(Topic) ->
    {Topic, at_most_once}.
