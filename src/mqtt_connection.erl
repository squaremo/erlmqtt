-module(mqtt_connection).

-behaviour(gen_fsm).

%% Public API
-export([start_link/0,
         connect/3, connect/4,
         publish/3, publish/4,
         subscribe/2,
         unsubscribe/2,
         disconnect/1]).

%% gen_fsm callbacks
-export([init/1, handle_event/3,
         handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

%% states
-export([unopened/3, opened/2]).

-include("include/types.hrl").

-record(state, {
          socket = undefined,
          parse_fun = undefined,
          rpcs = gb_trees:empty(),
          id_counter = 1,
          receiver = undefined,
          receiver_monitor = undefined
         }).

-type(error() :: {'error', term()}).

-type(connection() :: pid()).

start_link() ->
    gen_fsm:start_link(?MODULE, [], []).

-spec(connect(connection(), address(), client_id()) -> ok | error()).
connect(Conn, Address, ClientId) ->
    connect(Conn, Address, ClientId, []).

-spec(connect(connection(),
              address(),
              client_id(),
              [connect_option() | {'receiver', pid()}]) -> ok | error()).
connect(Conn, Address, ClientId, ConnectOpts0) ->
    Connect = #connect{ client_id = iolist_to_binary([ClientId]) },
    Receiver = proplists:get_value(receiver, ConnectOpts0, self()),
    ConnectOpts = proplists:delete(receiver, ConnectOpts0),
    Connect1 = opts(Connect, ConnectOpts),
    {Host, Port} = make_address(Address),
    case gen_tcp:connect(Host, Port,
                         [{active, false},
                          binary]) of
        {ok, Sock} ->
            open(Conn, Sock, Receiver, Connect1);
        E = {error, _} -> E
    end.

%% NB this assumes that the calling process controls the socket
open(Conn, Sock, Receiver, ConnectFrame) ->
    ok = gen_tcp:controlling_process(Sock, Conn),
    gen_fsm:sync_send_event(Conn, {open, Sock, Receiver, ConnectFrame}).


-spec(publish(connection(), topic(), payload()) -> ok).
publish(Conn, Topic, Payload) ->
    publish(Conn, Topic, Payload, []).

-spec(publish(connection(),
              topic(), payload(),
              [publish_option()]) ->
             ok).
publish(Conn, Topic, Payload, Options) ->
    P0 = #publish{ topic = Topic, payload = Payload },
    P1 = opts(P0, Options),
    gen_fsm:send_event(Conn, {publish, P1}).

%% NB this also sends a reply `{suback, Qoses}` to the calling process
%% when the server has responded.
-spec(subscribe(connection(), [{topic(), qos_level()}]) -> {ok, reference()}).
subscribe(Conn, Subs) ->
    Subscribe = #subscribe{
      dup = false,
      subscriptions = [#subscription{ topic = T, qos = Q }
                       || {T, Q} <- Subs] },
    rpc(Conn, Subscribe, self()).

-spec(unsubscribe(connection(), [topic()]) -> {ok, reference()}).
unsubscribe(Conn, Topics) ->
    Unsub = #unsubscribe{ topics = Topics },
    rpc(Conn, Unsub, self()).

-spec(disconnect(connection()) -> ok).
disconnect(Conn) ->
    gen_fsm:send_event(Conn, disconnect).

%%% gen_fsm callbacks

init([]) ->
    {ok, unopened, #state{}}.

%% states

%% worth putting specs on these?

unopened({open, Socket, Receiver, Connect}, _From,
         S0 = #state{ socket = undefined }) ->
    Monitor = monitor(process, Receiver),
    S = S0#state{ socket = Socket,
                  receiver_monitor = Monitor,
                  receiver = Receiver },
    write(S, Connect),
    case recv(S) of
        {ok, #connack{ return_code = ok }, Rest, S1} ->
            %% this is a little cheat: we're expecting {tcp, Sock,
            %% Data} packets, and if we have a remainder (somehow)
            %% after the first frame, we need to process that before
            %% asking for more.
            S2 = S1#state{ parse_fun = fun mqtt_framing:parse/1 },
            S3 = case Rest of
                     <<>> ->
                         ask_for_more(S2);
                     More ->
                         self ! {tcp, Socket, More},
                         S2
                 end,
            {reply, ok, opened, S3};
        {ok, #connack{ return_code = Else }, _Rest, S1} ->
            E = {connection_refused, Else},
            {stop, E, {error, E}, S1};
        {ok, Else, _Rest, S1} ->
            E = {unexpected, Else},
            {stop, E, {error, unexpected_frame}, S1};
        {error, Reason} ->
            {stop, Reason, {error, connection_error}, S0}
    end.

opened({publish, P0}, S0 = #state{ id_counter = NextId,
                                   rpcs = RPCS }) ->
    {P1, S1} =
        case P0#publish.qos of
            #qos{ level = L } ->
                Qos = #qos{ level = L,
                            message_id = NextId },
                RPCS1 = gb_trees:insert(NextId, P0, RPCS),
                {P0#publish{ qos = Qos },
                 S0#state{
                   rpcs = RPCS1,
                   id_counter = NextId + 1 }};
            at_most_once ->
                {P0, S0}
        end,
    write(S1, P1),
    {next_state, opened, S1};

opened({rpc, Frame, Ref, From}, S0) ->
    S1 = do_rpc(S0, Frame, Ref, From),
    {next_state, opened, S1};

opened({frame, Frame = #publish{}}, S0) ->
    %% TODO deal with QoS
    #state{ receiver = Receiver } = S0,
    Receiver ! {frame, Frame},
    {next_state, opened, S0};

%% This is step one of "exactly once" delivery
opened({frame, #pubrec{ message_id = Id }}, S0) ->
    #state{ rpcs = RPC } = S0,
    #publish{} = gb_trees:get(Id, RPC),
    Ack = #pubrel{ message_id = Id },
    RPC1 = gb_trees:update(Id, Ack, RPC),
    write(S0, Ack),
    {next_state, opened, S0#state{ rpcs = RPC1 }};

%% These frames end a "guaranteed delivery" exchange.
opened({frame, #puback{ message_id = Id }}, S0) ->
    #state{ rpcs = RPC } = S0,
    #publish{} = gb_trees:get(Id, RPC),
    RPC1 = gb_trees:delete(Id, RPC),
    {next_state, opened, S0#state{ rpcs = RPC1 }};
opened({frame, #pubcomp{ message_id = Id }}, S0) ->
    #state{ rpcs = RPC } = S0,
    #pubrel{} = gb_trees:get(Id, RPC),
    RPC1 = gb_trees:delete(Id, RPC),
    {next_state, opened, S0#state{ rpcs = RPC1 }};

%% Remaining: #suback, #unsuback
opened({frame, Frame}, S0) ->
    #state{ rpcs = RPC0 } = S0,
    {Id, Reply} = make_reply(Frame),
    {Ref, From} = gb_trees:get(Id, RPC0),
    RPC1 = gb_trees:delete(Id, RPC0),
    From ! {Ref, Reply},
    {next_state, opened, S0#state{ rpcs = RPC1 }};

opened(disconnect, S0 = #state{ socket = Sock }) ->
    ok = write(S0, disconnect),
    ok = gen_tcp:close(Sock),
    {next_state, closed, S0#state{ socket = undefined }}.


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
    {next_state, opened, S};
handle_info({'DOWN', Ref, process, Pid, Reason}, opened,
            S0 = #state{ receiver_monitor = Ref,
                         receiver = Pid }) ->
    {stop, {receiver_down, Reason}, S0}.

terminate(Reason, StateName, StatData) ->
    ok.

code_change(OldVsn, StateName, StateData, Extra) ->
    {ok, StateName, StateData}.

%%% Internal functions

-spec(write(#state{ socket :: inet:socket() }, mqtt_frame()) ->
             ok).
write(#state{ socket = S }, Frame) ->
    ok = gen_tcp:send(S, mqtt_framing:serialise(Frame)),
    ok.

%% Send an RPC frame (one that expects a reply) and return a receipt
rpc(Conn, Frame, From) ->
    Ref = make_ref(),
    gen_fsm:send_event(Conn, {rpc, Frame, Ref, From}),
    {ok, Ref}.

%% Record the fact of an RPC and send the frame with the correct id.
do_rpc(S0, Req, Ref, From) ->
    #state{ id_counter = Id,
            rpcs = RPC0 } = S0,
    RPC1 = gb_trees:insert(Id, {Ref, From}, RPC0),
    write(S0, with_id(Id, Req)),
    S0#state{ id_counter = Id + 1, rpcs = RPC1 }.

with_id(Id, S = #subscribe{})   -> S#subscribe{ message_id = Id };
with_id(Id, U = #unsubscribe{}) -> U#unsubscribe{ message_id = Id }.

make_reply(#suback{ message_id = Id, qoses = QoSes }) ->
    {Id, {suback, QoSes}};
make_reply(#unsuback{ message_id = Id }) ->
    {Id, unusback}.

%% `recv` is used to synchronously get another frame from the
%% socket. Once the connection is open, there's no need to do this,
%% since it will effectively receive frames in a loop anyway.
-spec(recv(#state{}) -> {ok, mqtt_frame(), binary(), #state{}}
                      | {error, term()}).
recv(State) ->
    parse_frame(<<>>, State, fun mqtt_framing:parse/1).

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
            S1 = S#state{ parse_fun = fun mqtt_framing:parse/1 },
            selfsend_frame(F),
            process_data(Rest, S1)
            %% ERROR CASES
    end.

selfsend_frame(Frame) ->
    ok = gen_fsm:send_event(self(), {frame, Frame}).

%% Create a frame given the options (fields, effectively) as an alist
opts(F, []) ->
    F;
opts(F, [Opt |Rest]) ->
    opts(opt(F, Opt), Rest).

opt(C = #connect{}, Opt) ->
    connect_opt(C, Opt);
opt(P = #publish{}, Opt) ->
    publish_opt(P, Opt).

-type(connect_option() ::
      {client_id, client_id()}
    | {username, binary() | iolist()}
    | {password, binary() | iolist()}
    | {will, topic(), payload(), qos_level(), boolean()}
    | {will, topic(), payload()}).

-spec(connect_opt(#connect{}, connect_option()) -> #connect{}).
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
                             qos = at_most_once } }.

-type(publish_option() ::
        'dup'
      | {'dup', boolean()}
      | retain
      | {retain, boolean()}
      | {qos, qos_level()}
      | qos_level()).

-spec(publish_opt(#publish{}, publish_option()) -> #publish{}).
publish_opt(P, dup) ->
    P#publish{ dup = true };
publish_opt(P, {dup, Flag}) when is_boolean(Flag) ->
    P#publish{ dup = Flag };
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
