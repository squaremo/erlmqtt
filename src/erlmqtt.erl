-module(erlmqtt).

-export([
         open_clean/2,
         open/2, open/3,
         subscribe/2, subscribe/3,
         unsubscribe/2, unsubscribe/3,
         disconnect/1,
         publish/3, publish/4,
         recv_message/0, recv_message/1
        ]).

-include("include/types.hrl").
-include("include/frames.hrl").

%% Public API for erlmqtt.

%% Create and connect an ephemeral MQTT session, for which the state
%% will be discarded when it is disconnected. This links the
%% connection process to the calling process. Returns the connection.
open_clean(HostSpec, Options) ->
    ClientId = random_client_id(),
    {ok, Conn} = erlmqtt_connection:start_link(
                   HostSpec, ClientId,
                   [clean_session | Options]),
    ok = erlmqtt_connection:connect(Conn),
    {ok, Conn}.

%% Creates a new MQTT session and returns the client ID, for
%% reconnecting, as well as the connection.
open(HostSpec, Options) ->
    ClientId = random_client_id(),
    {ok, Conn} = erlmqtt_connection:start_link(
                   HostSpec, ClientId,
                   [{clean_session, false} | Options]),
    ok = erlmqtt_connection:connect(Conn),
    {ok, Conn}.

%% Open a MQTT session identified by the given ClientId.
open(HostSpec, ClientId, Options) ->
    {ok, Conn} = erlmqtt_connection:start_link(
                   HostSpec, ClientId,
                   [{clean_session, false} | Options]),
    ok = erlmqtt_connectiojn:connect(Conn),
    {ok, Conn}.

%% Subscribe a connection to the given topics. A topic may be a
%% string, a binary, or a tuple of a string or binary with one of the
%% atoms denoting a "quality of service": 'at_most_once',
%% 'at_least_once', 'exactly_once'. A string or binary on its own is
%% the same as `{Topic, at_most_once}`. Returns once the server has
%% replied, with the list of "quality of service" values granted by
%% the server for each subscription.
subscribe(Conn, Topics) ->
    Topics1 = [norm_topic(T) || T <- Topics],
    {ok, Ref} = erlmqtt_connection:subscribe(Conn, Topics1),
    receive {Ref, {suback, Granted}} ->
            {ok, Granted}
    end.

%% Similar to subscribe/2 but will return `{timeout, Ref}'` if the
%% server does not reply within the given timeout, where the Ref
%% corresponds to the awaited reply.
subscribe(Conn, Topics, Timeout) ->    
    Topics1 = [norm_topic(T) || T <- Topics],
    {ok, Ref} = erlmqtt_connection:subscribe(Conn, Topics1),
    receive {Ref, {suback, Reply}} ->
            {ok, Reply}
    after Timeout ->
            {timeout, Ref}
    end.

%% Unsubscribe from the given topics, which are each a string or
%% binary. Returns 'ok' once the server has responded.
unsubscribe(Conn, Topics) ->
    {ok, Ref} = erlmqtt_connection:unsubscribe(Conn, Topics),
    receive {Ref, unsuback} ->
            ok
    end.

%% Unsubscribe from the given topics, and return ok or {timeout, Ref}
%% if the operation does not get a reply from the server within
%% Timeout.
unsubscribe(Conn, Topics, Timeout) ->
    {ok, Ref} = erlmqtt_connection:unsubscribe(Conn, Topics),
    receive {Ref, unsuback} ->
            ok
    after Timeout ->
            {timeout, Ref}
    end.

%% Explicitly disconnect a session from a server.
disconnect(Conn) ->    
    erlmqtt_connection:disconnect(Conn).

%% publish a message with the default quality of service and options.
publish(Conn, Topic, Payload) ->
    publish(Conn, Topic, Payload, []).

%% publish a message with the given quality of service.
publish(Conn, Topic, Payload, QoS) when is_atom(QoS) ->
    erlmqtt_connection:publish(Conn, Topic, Payload, [QoS]);
%% publish a message with the options given, possibly including
%% quality of service.
publish(Conn, Topic, Payload, Options) ->
    erlmqtt_connection:publish(Conn, Topic, Payload, Options).

%% Wait for a message sent to the calling process, which is assumed to
%% have been registered as the consumer for a connection. Return
%% the topic and payload of the message as {Topic, Payload}.
recv_message() ->
    receive {frame, #publish{topic = T, payload = P}} ->
            {T, P}
    end.

%% Wait for a message and return {Topic, Payload}, or time out after
%% Timeout, in which case return 'timeout'.
recv_message(Timeout) ->
    receive {frame, #publish{topic = T, payload = P}} ->
            {T, P}
    after Timeout ->
            timeout
    end.

%% ---- helpers

%% Not very UUIDy, but probably good enough for now.
random_client_id() ->
    [crypto:rand_uniform(33, 126) || _ <- lists:seq(1, 23)].

norm_topic(Topic = {_T, _Q}) ->
    Topic;
norm_topic(Topic) when is_binary(Topic); is_list(Topic) ->
    {Topic, at_most_once}.
