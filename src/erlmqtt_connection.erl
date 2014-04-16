-module(erlmqtt_connection).

-behaviour(gen_fsm).

%% Public API
-export([start_link/2, start_link/3, start_link/4,
         connect/1,
         publish/3, publish/4,
         subscribe/2, subscribe/3,
         unsubscribe/2, unsubscribe/3,
         disconnect/1,
         disconnect_and_terminate/1]).

%% gen_fsm callbacks
-export([init/1, handle_event/3,
         handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

%% states
-export([unopened/3,
         opened/2, opened/3]).

%% types useful elsewhere
-export_type([
              address/0,
              connect_option/0,
              publish_option/0,
              connection/0
             ]).

-include("include/types.hrl").

-define(RPCS(Tree), {rpcs, Tree}).
-define(REPLAY(Tree), {replay, Tree}).
-define(DEDUP(Tree), {dedup, Tree}).

-type(rpcs() :: ?RPCS(gb_tree())).
-type(replay() :: ?REPLAY(gb_tree())).

-define(SETS, sets).
-type(dedup() :: ?DEDUP(set())).

-type(msg_ref() :: term()).

%% The values given as From to the sync_send_event callbacks.
-type(from() :: {pid(), reference()}).

-record(state, {
          connect_args = undefined :: {
                           address(),
                           client_id(),
                           [connect_packet_option()]
                          },
          clean_session = true :: boolean(),
          socket :: port(),
          parse_fun :: erlmqtt_framing:parse(),
          rpcs = empty_rpcs() :: rpcs(),
          replay = empty_replay() :: replay(),
          dedup = empty_dedup() :: dedup(),
          id_counter = 1 :: pos_integer(),
          receiver :: pid(),
          receiver_monitor :: reference(),
          keep_alive = 0 :: 0..16#ffff,
          timer_ref :: reference()
         }).

-type(connection() :: pid()).

-spec(start_link(address(), client_id()) ->
             {ok, connection()} | error()).
start_link(Address, ClientId) ->
    start_link(Address, ClientId, []).

-spec(start_link(address(), client_id(),
                 [connect_packet_option()]) ->
             {ok, connection()} | error()).
start_link(Address, ClientId, ConnectOpts) ->
    start_link(Address, ClientId, ConnectOpts, self()).

-spec(start_link(address(), client_id(),
                 [connect_packet_option()], pid()) ->
             {ok, connection()} | error()).
start_link(Address, ClientId, ConnectOpts, Receiver) ->
    gen_fsm:start_link(?MODULE,
                       [Address, ClientId, ConnectOpts, Receiver],
                       []).

-spec(connect(connection()) -> ok | error()).
connect(Conn) ->
    gen_fsm:sync_send_event(Conn, connect).

-spec(publish(connection(), topic(), payload()) -> ok).
publish(Conn, Topic, Payload) ->
    publish(Conn, Topic, Payload, []).

-spec(publish(connection(),
              topic(), payload(),
              [publish_option()]) -> ok).
publish(Conn, Topic, Payload, Options) ->
    P0 = #publish{ topic = Topic, payload = Payload },
    Ref = proplists:get_value(ref, Options, none),
    Options1 = proplists:delete(ref, Options),
    P1 = opts(P0, Options1),
    gen_fsm:send_event(Conn, {publish, P1, Ref}).

-spec(subscribe(connection(), [{topic(), qos_level()}], timeout()) ->
             {ok, [qos_level()]} | 'timeout').
subscribe(Conn, Subs, Timeout) ->
    Subscribe = #subscribe{
      dup = false,
      subscriptions = [#subscription{ topic = T, qos = Q }
                       || {T, Q} <- Subs] },
    rpc(Conn, Subscribe, Timeout).

%% Send subscribe and wait indefinitely
-spec(subscribe(connection(), [{topic(), qos_level()}]) ->
             {ok, [qos_level()]}).
subscribe(Conn, Subs) ->
    subscribe(Conn, Subs, infinity).

-spec(unsubscribe(connection(), [topic()], timeout()) ->
             ok | 'timeout').
unsubscribe(Conn, Topics, Timeout) ->
    Unsub = #unsubscribe{ topics = Topics },
    rpc(Conn, Unsub, Timeout).

%% Send ubsubscribe and wait indefinitely
-spec(unsubscribe(connection(), [topic()]) -> ok).
unsubscribe(Conn, Topics) ->
    unsubscribe(Conn, Topics, infinity).

-spec(disconnect(connection()) -> ok).
disconnect(Conn) ->
    gen_fsm:send_event(Conn, disconnect).

-spec(disconnect_and_terminate(connection()) -> ok).
disconnect_and_terminate(Conn) -> 
    disconnect(Conn),
    gen_fsm:sync_send_event(Conn, terminate).

%%% gen_fsm callbacks

init([Address, ClientId, ConnectOpts, Receiver]) ->
    Monitor = monitor(process, Receiver),
    CleanSession = proplists:get_value(clean_session, ConnectOpts, true),
    KeepAlive = proplists:get_value(keep_alive, ConnectOpts, 0),
    {ok, unopened, #state{
           connect_args = {Address, ClientId, ConnectOpts},
           clean_session = CleanSession,
           receiver = Receiver,
           receiver_monitor = Monitor,
           keep_alive = KeepAlive
          }}.

%% states

%% worth putting specs on these?

unopened(connect, _From, S0 = #state{ socket = undefined }) ->
    #state{ connect_args = {Address, ClientId, ConnectOpts} } = S0,
    Connect = #connect{ client_id = iolist_to_binary([ClientId]) },
    Connect1 = opts(Connect, ConnectOpts),
    {Host, Port} = make_address(Address),
    case gen_tcp:connect(Host, Port,
                         [{active, false},
                          binary]) of
        {ok, Socket} ->
            S = S0#state{ socket = Socket },
            open(S, Connect1);
        E = {error, _} ->
            {stop, E, E, S0}
    end;
unopened(terminate, _From, S0 = #state{ socket = undefined }) ->
    {stop, normal, ok, S0}.

%% Helper for connect event
open(S, Connect) ->
    write(S, Connect),
    case recv(S) of
        {ok, #connack{ return_code = ok }, Rest, S1} ->
            %% this is a little cheat: we're expecting {tcp, Sock,
            %% Data} packets, and if we have a remainder (somehow)
            %% after the first frame, we need to process that before
            %% asking for more.
            S2 = S1#state{ parse_fun = fun erlmqtt_framing:parse/1 },
            S3 = case Rest of
                     <<>> ->
                         ask_for_more(S2);
                     More ->
                         #state{ socket = Sock } = S2,
                         self() ! {tcp, Sock, More},
                         S2
                 end,
            S4 = resend_or_reset(S3),
            S5 = maybe_start_timer(S4),
            {reply, ok, opened, S5};
        {ok, #connack{ return_code = Else }, _Rest, S1} ->
            E = {connection_refused, Else},
            {stop, E, {error, E}, S1};
        {ok, Else, _Rest, S1} ->
            E = {unexpected, Else},
            {stop, E, {error, unexpected_frame}, S1};
        {error, Reason} ->
            {stop, Reason, {error, connection_error}, S}
    end.

resend_or_reset(S = #state{ clean_session = true }) ->
    S#state{ rpcs = empty_rpcs(),
             replay = empty_replay() };
resend_or_reset(S = #state{ replay = Replay }) ->
    resend(S#state{ rpcs = empty_rpcs() }, Replay).

-spec(resend(#state{}, replay()) -> #state{}).
resend(S, Replay) ->
    case is_empty_replay(Replay) of
        true ->
            S;
        false ->
            {Frame, Replay1} = next_replay(Replay),
            write(S, dup_of(Frame)),
            resend(S, Replay1)
    end.

maybe_start_timer(S = #state{ keep_alive = 0 }) ->
    S;
maybe_start_timer(S = #state{ socket = Sock }) ->
    Count = bytes_sent(Sock),
    set_timer(S, none, Count).

set_timer(S = #state{ keep_alive = K }, Missed, Count) ->
    Ref = gen_fsm:start_timer(K * 500, {Missed, Count}),
    S#state{ timer_ref = Ref }.

stop_timer(S = #state{ timer_ref = undefined }) ->
    S;
stop_timer(S = #state{ timer_ref = Ref }) ->
    gen_fsm:cancel_timer(Ref),
    S#state{ timer_ref = undefined }.

bytes_sent(Socket) ->
    {ok, [{send_oct, Count}]} = inet:getstat(Socket, [send_oct]),
    Count.

%% For the oft-repeated {next_state, opened, ...}
-define(OPENED(S), {next_state, opened, S}).

%% The sync version, for RPCs
opened({rpc, Frame}, From, S0) ->
    S1 = do_rpc(S0, Frame, From),
    ?OPENED(S1).

%% .. and the async version, for everything else.
opened({timeout, Ref, MissedAndCount},
       S0 = #state{timer_ref = Ref, socket = Sock }) ->
    CountNow = bytes_sent(Sock),
    S1 = case MissedAndCount of
             {once, CountNow} ->
                 ok = write(S0, pingreq),
                 NewCount = bytes_sent(Sock),
                 set_timer(S0, none, NewCount);
             {none, CountNow} ->
                 set_timer(S0, once, CountNow);
             {_, _} ->
                 set_timer(S0, none, CountNow)
         end,
    ?OPENED(S1);

opened({publish, P0, Ref}, S0 = #state{ id_counter = NextId,
                                   replay = Replay }) ->
    S1 = case P0#publish.qos of
             #qos{ level = L } ->
                 Qos = #qos{ level = L,
                             message_id = NextId },
                 Replay1 = record_for_replay(NextId, {P0, Ref}, Replay),
                 P1 = P0#publish{ qos = Qos },
                 write(S0, P1),
                 S0#state{ replay = Replay1,
                           id_counter = NextId + 1 };
             at_most_once ->
                 write(S0, P0),
                 S0
         end,
    ?OPENED(S1);

opened({frame, pingresp}, S0) -> ?OPENED(S0);

%% Receiving publish: messages sent exactly_once must be
%% deduplicated. I do this by keeping a set of message IDs that have
%% already been seen, and removing when the #pubrel{} is sent.  Note
%% that we only have to check for a duplicate if the message is marked
%% as a duplicate and it's exactly_once -- there's no duty to check
%% for duplicates of other messages (although it's possible to do so
%% with a rolling window, say).

opened({frame, Frame = #publish{}}, S0) ->
    #state{ dedup = Dedup, receiver = Receiver } = S0,
    case Frame of
        #publish{ dup = Dup,
                  qos = #qos{
                    message_id = Id,
                    level = exactly_once }} ->
            case Dup andalso is_duplicate(Id, Dedup) of
                true ->
                    ?OPENED(S0);
                false ->
                    S1 = do_ack(S0, Frame),
                    Dedup1 = record_for_dedup(Id, Dedup),
                    Receiver ! {frame, Frame},
                    ?OPENED(S1#state{ dedup = Dedup1 })
            end;
        _ ->
            S1 = do_ack(S0, Frame),
            Receiver ! {frame, Frame},
            ?OPENED(S1)
    end;

%% This is step two of "exactly once" delivery (step one is publish),
%% the first of two acknowledgments.
opened({frame, #pubrec{ message_id = Id }}, S0) ->
    #state{ replay = Replay, receiver = Recv } = S0,
    {#publish{}, Ref} = check_replay(Id, Replay),
    Ack = #pubrel{ message_id = Id },
    maybe_notify_ack(pubrec, Ref, Recv),
    %% NB update: we've passed phase one (publish -> pubrec) of the
    %% delivery, so the replay if any will be phase two (pubrel ->
    %% pubcomp)
    Replay1 = replace_replay(Id, {Ack, Ref}, Replay),
    write(S0, Ack),
    ?OPENED(S0#state{ replay = Replay1 });

%% This is step three of exactly once; we receive it if we send pubrec
%% to acknowledge a publish with QoS = exactly_once. Once we've seen
%% this frame, we no longer have to remember the message for
%% deduplication.
%%
%% These frames might get resent, but the pubcomp must be sent in any
%% case (since that will stop the sender sending pubrel).
opened({frame, #pubrel{ message_id = Id }}, S0) ->
    #state{ dedup = Dedup } = S0,
    Dedup1 = remove_from_dedup(Id, Dedup),
    write(S0, #pubcomp{ message_id = Id }),
    ?OPENED(S0#state{ dedup = Dedup1 });

%% These two ff frames end a "guaranteed delivery" exchange.
opened({frame, #puback{ message_id = Id }}, S0) ->
    #state{ replay = Replay, receiver = Recv } = S0,
    {#publish{}, Ref} = check_replay(Id, Replay),
    maybe_notify_ack(puback, Ref, Recv),
    Replay1 = remove_from_replay(Id, Replay),
    ?OPENED(S0#state{ replay = Replay1 });

opened({frame, #pubcomp{ message_id = Id }}, S0) ->
    #state{ replay = Replay, receiver = Recv } = S0,
    {#pubrel{}, Ref} = check_replay(Id, Replay),
    maybe_notify_ack(pubcomp, Ref, Recv),
    Replay1 = remove_from_replay(Id, Replay),
    ?OPENED(S0#state{ replay = Replay1 });

%% Unaccounted for thus far: #suback, #unsuback
opened({frame, Frame}, S0) ->
    #state{ rpcs = RPC } = S0,
    {Id, Reply} = make_reply(Frame),
    {From, RPC1} = take_rpc(Id, RPC),
    gen_fsm:reply(From, Reply),
    ?OPENED(S0#state{ rpcs = RPC1 });

%% Disconnect from the server and terminate.
opened(disconnect, S0 = #state{ socket = Sock }) ->
    ok = write(S0, disconnect),
    ok = gen_tcp:close(Sock),
    S1 = stop_timer(S0),
    {next_state, unopened, S1#state{ socket = undefined }}.

%% all states

handle_event(Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

handle_sync_event(Event, From, StateName, StateData) ->
    Reply = ok,
    {reply, Reply, StateName, StateData}.

%% Once we've set the socket to {active, once}, and we're not
%% otherwise in a `receive ..`, data will arrive here.
handle_info({tcp, _S, Data}, opened, S0) ->
    S = process_data(Data, S0),
    ?OPENED(S);
handle_info({'DOWN', Ref, process, Pid, Reason}, opened,
            S0 = #state{ receiver_monitor = Ref,
                         receiver = Pid }) ->
    {stop, {receiver_down, Reason}, S0};
handle_info({tcp_closed, Sock}, opened,
           S0 = #state{ socket = Sock }) ->
    {next_state, unconnected, S0#state{ socket = undefined }}.

terminate(Reason, StateName, StateData) ->
    ok.

code_change(OldVsn, StateName, StateData, Extra) ->
    {ok, StateName, StateData}.

%%% Internal functions

-spec(write(#state{ socket :: inet:socket() }, mqtt_frame()) -> ok).
write(#state{ socket = S }, Frame) ->
    ok = gen_tcp:send(S, erlmqtt_framing:serialise(Frame)),
    ok.

%% RPCs

%% Send an RPC frame (one that expects a reply) and return a receipt
rpc(Conn, Frame, Timeout) ->
    gen_fsm:sync_send_event(Conn, {rpc, Frame}, Timeout).

%% Record the fact of an RPC and send the frame with the correct id.
do_rpc(S0, Req, From) ->
    #state{ id_counter = Id,
            rpcs = RPC } = S0,
    RPC1 = record_rpc(Id, From, RPC),
    write(S0, with_id(Id, Req)),
    S0#state{ id_counter = Id + 1, rpcs = RPC1 }.

-spec(empty_rpcs() -> rpcs()).
empty_rpcs() -> ?RPCS(gb_trees:empty()).

-spec(record_rpc(message_id(), from(), rpcs()) ->
             rpcs()).
record_rpc(Id, From, ?RPCS(RPC)) ->
    ?RPCS(gb_trees:insert(Id, From, RPC)).

-spec(take_rpc(message_id(), rpcs()) -> {from(), rpcs()}).
take_rpc(Id, ?RPCS(RPC)) ->
    From = gb_trees:get(Id, RPC),
    RPC1 = gb_trees:delete(Id, RPC),
    {From, ?RPCS(RPC1)}.

-spec(empty_replay() -> replay()).
empty_replay() ->
    ?REPLAY(gb_trees:empty()).

-spec(is_empty_replay(replay()) -> boolean()).
is_empty_replay(?REPLAY(Replay)) -> gb_trees:is_empty(Replay).

-spec(check_replay(message_id(), replay()) -> {mqtt_frame(), msg_ref()}).
check_replay(Id, ?REPLAY(Replay)) ->
    gb_trees:get(Id, Replay).

-spec(record_for_replay(message_id(),
                        {mqtt_frame(), msg_ref()},
                        replay()) ->
             replay()).
record_for_replay(Id, Frame, ?REPLAY(Replay)) ->
    ?REPLAY(gb_trees:insert(Id, Frame, Replay)).

-spec(remove_from_replay(message_id(), replay()) ->
             replay()).
remove_from_replay(Id, ?REPLAY(Replay)) ->
    ?REPLAY(gb_trees:delete(Id, Replay)).

-spec(replace_replay(message_id(),
                     {mqtt_frame(), msg_ref()},
                     replay()) ->
             replay()).
replace_replay(Id, Frame, ?REPLAY(Replay)) ->
    ?REPLAY(gb_trees:update(Id, Frame, Replay)).

-spec(next_replay(replay()) -> {mqtt_frame(), replay()}).
next_replay(?REPLAY(Replay)) ->
    {_Id, {Frame, _Ref}, Replay1} = gb_trees:take_smallest(Replay),
    {Frame, ?REPLAY(Replay1)}.

-spec(empty_dedup() -> dedup()).
empty_dedup() -> ?DEDUP(?SETS:new()).

-spec(is_duplicate(message_id(), dedup()) -> boolean()).
is_duplicate(Id, ?DEDUP(Set)) ->
    ?SETS:is_element(Id, Set).

-spec(record_for_dedup(message_id(), dedup()) -> dedup()).
record_for_dedup(Id, ?DEDUP(Set)) ->
    ?DEDUP(?SETS:add_element(Id, Set)).

-spec(remove_from_dedup(message_id(), dedup()) -> dedup()).
remove_from_dedup(Id, ?DEDUP(Set)) ->
    ?DEDUP(?SETS:del_element(Id, Set)).

with_id(Id, S = #subscribe{})   -> S#subscribe{ message_id = Id };
with_id(Id, U = #unsubscribe{}) -> U#unsubscribe{ message_id = Id }.

dup_of(F = #publish{}) ->
    F#publish{ dup = true };
dup_of(F = #subscribe{}) ->
    F#subscribe{ dup = true };
dup_of(F = #pubrel{}) ->
    F#pubrel{ dup = true }.

make_reply(#suback{ message_id = Id, qoses = QoSes }) ->
    {Id, {ok, QoSes}};
make_reply(#unsuback{ message_id = Id }) ->
    {Id, ok}.

%% Send an acknowledgment.
do_ack(S, #publish{ qos = QoS }) ->
    case QoS of
        at_most_once ->
            S;
        #qos{ level = at_least_once,
              message_id = Id } ->
            Ack = #puback{ message_id = Id },
            write(S, Ack),
            S;
        #qos{ level = exactly_once,
              message_id = Id } ->
            Ack = #pubrec{ message_id = Id },
            write(S, Ack),
            S
    end.

%% Tell the receiver about an acknowledgment, if the publish was given
%% a reference.
maybe_notify_ack(_Kind, none, _Recv) ->
    ok;
maybe_notify_ack(Kind, Ref, Recv) ->
    Recv ! {Kind, Ref}.

%% `recv` is used to synchronously get another frame from the
%% socket. Once the connection is open, there's no need to do this,
%% since it will effectively receive frames in a loop anyway.
-spec(recv(#state{}) -> {ok, mqtt_frame(), binary(), #state{}}
                      | {error, term()}).
recv(State) ->
    parse_frame(<<>>, State, fun erlmqtt_framing:parse/1).

parse_frame(<<>>, S, P) ->
    wait_for_more(S, P);
parse_frame(Buf, S0, Parse) ->
    case Parse(Buf) of
        {frame, F, Rest} ->
            {ok, F, Rest, S0};
        {more, K} ->
            wait_for_more(S0, K);
        Err = {error, _} ->
            Err
    end.

wait_for_more(S = #state{ socket = Sock }, K) ->
    inet:setopts(Sock, [{active, once}]),
    receive
        {tcp, Sock, D} -> parse_frame(D, S, K);
        {tcp_closed, Sock} -> {error, unexpected_socket_close};
        {tcp_error, Sock, Reason} -> {error, {socket_error, Reason}}
    end.

ask_for_more(S = #state{ socket = Sock }) ->
    inet:setopts(Sock, [{active, once}]),
    S.

%% Whenever data comes in, parse out a frame and do something with
%% it. Since we can (and often will) end up on a frame boundary, no
%% remainder means get some more and start again.
process_data(<<>>, S) ->
    ask_for_more(S);
process_data(Data, S = #state{ socket = Sock,
                               parse_fun = Parse }) ->
    case Parse(Data) of
        {more, K} ->
            inet:setopts(Sock, [{active, once}]),
            S#state{ parse_fun = K };
        {frame, F, Rest} ->
            S1 = S#state{ parse_fun = fun erlmqtt_framing:parse/1 },
            selfsend_frame(F),
            process_data(Rest, S1)
            %% ERROR CASES
    end.

selfsend_frame(Frame) ->
    ok = gen_fsm:send_event(self(), {frame, Frame}).

%% API helpers

%% Create a frame given the options (fields, effectively) as an alist
opts(F, []) ->
    F;
opts(F, [Opt |Rest]) ->
    opts(opt(F, Opt), Rest).

opt(C = #connect{}, Opt) ->
    connect_opt(C, Opt);
opt(P = #publish{}, Opt) ->
    publish_opt(P, Opt).

%% I make clean_session apart from the other options, because it is
%% implied in the public API by the procedure used, rather than given
%% as an option.
-type(connect_packet_option() ::
      connect_option()
    | {clean_session, boolean()}
    | clean_session).

-type(connect_option() ::
      {username, binary() | iolist()}
    | {password, binary() | iolist()}
    | {will, topic(), payload(), qos_level(), boolean()}
    | {will, topic(), payload()}
    | {keep_alive, 0..16#ffff }).

-spec(connect_opt(#connect{}, connect_packet_option()) ->
             #connect{}).
connect_opt(C, {client_id, Id}) ->
    C#connect{ client_id = iolist_to_binary([Id]) };
connect_opt(C, {username, User}) ->
    C#connect{ username = iolist_to_binary([User])};
connect_opt(C, {password, Pass}) ->
    C#connect{ password = iolist_to_binary(Pass)};
connect_opt(C, {will, Topic, Payload, QoS, Retain}) ->
    C#connect{ will = #will{ topic = Topic,
                             message = Payload,
                             qos = QoS,
                             retain = Retain } };
connect_opt(C, {will, Topic, Payload}) ->
    C#connect{ will = #will{ topic = Topic,
                             message = Payload,
                             qos = at_most_once } };
connect_opt(C, clean_session) ->
    C#connect{ clean_session = true };
connect_opt(C, {clean_session, B}) ->
    C#connect{ clean_session = B };
connect_opt(C, {keep_alive, K}) ->
    C#connect{ keep_alive = K }.

-type(publish_option() ::
        {ref, msg_ref()}
      | retain
      | {retain, boolean()}
      | {qos, qos_level()}
      | qos_level()).

-spec(publish_opt(#publish{}, publish_option()) -> #publish{}).
publish_opt(P, {ref, _}) ->
    P;
publish_opt(P, retain) ->
    P#publish{ retain = true };
publish_opt(P, {retain, Flag}) when is_boolean(Flag) ->
    P#publish{ retain = Flag };
publish_opt(P, {qos, Qos}) ->
    P#publish{ qos = Qos };
publish_opt(P, at_most_once) ->
    publish_opt(P, {qos, at_most_once});
publish_opt(P, at_least_once) ->
    publish_opt(P, {qos, #qos{ level = at_least_once}});
publish_opt(P, exactly_once) ->
    publish_opt(P, {qos, #qos{ level = exactly_once}}).


-type(address() ::
        {host(), inet:port_number()}
      | host()).

-type(host() :: inet:ip_address() | inet:hostname()).

-spec(make_address(address()) -> {host(), inet:port_number()}).
make_address(Whole = {_Host, _Port}) ->
    Whole;
make_address(Host) ->
    {Host, 1883}.
