-module(mqtt_connection).

-behaviour(gen_fsm).

%% Public API
-export([start_link/0, connect/4]).

%% gen_fsm callbacks
-export([init/1, handle_event/3,
         handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

%% states
-export([unopened/3]).

-include("include/types.hrl").

-record(state, {
          socket = undefined,
          frame_buf = <<>>
         }).

-type(connection() :: pid()).

start_link() ->
    gen_fsm:start_link(?MODULE, [], []).

-spec(connect(connection(),
              address(),
              client_id(),
              [connect_option()]) -> ok).
connect(Conn, Address, ClientId, ConnectOpts) ->
    Connect = #connect{ client_id = iolist_to_binary([ClientId]) },
    Connect1 = opts(Connect, ConnectOpts),
    {Host, Port} = make_address(Address),
    {ok, Sock} = gen_tcp:connect(Host, Port,
                                 [{active, false},
                                  binary]),
    open(Conn, Sock, Connect1).

%% NB this assumes that the calling process controls the socket
open(Conn, Sock, ConnectFrame) ->
    ok = gen_tcp:controlling_process(Sock, Conn),
    gen_fsm:sync_send_event(Conn, {open, Sock, ConnectFrame}).

%%% gen_fsm callbacks

init([]) ->
    {ok, unopened, #state{}}.

%% states

%% worth putting specs on these?

unopened({open, Socket, Connect}, From,
         S0 = #state{ socket = undefined }) ->
    S = S0#state{ socket = Socket },
    write(S, Connect),
    case recv(S) of
        {ok, #connack{ return_code = ok }, S1} ->
            {reply, ok, opened, S1};
        {ok, #connack{ return_code = Else }, S1} ->
            protocol_error(Else, S1);
        {ok, Else, S1} ->
            protocol_error({unexpected, Else}, S1);
        {error, Reason} ->
            frame_error(Reason, S)
    end.

%% all states

handle_event(Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

handle_sync_event(Event, From, StateName, StateData) ->
    Reply = ok,
    {reply, Reply, StateName, StateData}.

handle_info(Info, StateName, StateData) ->
    {next_state, StateName, StateData}.

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

-spec(recv(#state{}) -> {ok, mqtt_frame(), #state{}}
                      | {error, term()}).
recv(State = #state{ frame_buf = Buf }) ->
    parse_frame(Buf, State, fun mqtt_framing:parse/1).

parse_frame(<<>>, S, P) ->
    ask_for_more(S, P);
parse_frame(Buf, S0 = #state{ socket = Sock }, Parse) ->
    case Parse(Buf) of
        {frame, F, Rest} ->
            {ok, F, S0#state{ frame_buf = Rest }};
        {more, K} ->
            ask_for_more(S0, K);
        {error, R} ->
            frame_error(self(), R)
    end.

ask_for_more(S = #state{ socket = Sock }, K) ->
    inet:setopts(Sock, [{active, once}]),
    receive
        {tcp, Sock, D} -> parse_frame(D, S, K);
        {tcp_closed, Sock} -> unexpected_closed(self());
        {tcp_error, Sock, Reason} -> socket_error(self(), Reason)
    end.

%% FIXME TODO ETC
unexpected_closed(Conn) ->
    {error, closed}.

socket_error(Conn, Reason) ->
    {error, Reason}.

frame_error(Conn, Reason) ->
    {error, Reason}.

protocol_error(Reason, State) ->
    {error, Reason, State}.

%% Create a frame given the options (fields, effectively) as an alist
opts(F, []) ->
    F;
opts(F, [Opt |Rest]) ->
    opts(opt(F, Opt), Rest).

opt(C = #connect{}, Opt) ->
    connect_opt(C, Opt).

-type(connect_option() ::
      {client_id, client_id()}
    | {username, binary() | iolist()}
    | {password, binary() | iolist()}).

-spec(connect_opt(#connect{}, connect_option()) -> #connect{}).
connect_opt(C = #connect{}, {client_id, Id}) ->
    C#connect{ client_id = iolist_to_binary([Id]) };
connect_opt(C = #connect{}, {username, User}) ->
    C#connect{ username = iolist_to_binary([User])};
connect_opt(C = #connect{}, {password, Pass}) ->
    C#connect{ password = iolist_to_binary(Pass)}.

-type(address() ::
        {host(), inet:port_number()}
      | host()).

-type(host() :: inet:ip_address() | inet:hostname()).

-spec(make_address(address()) -> {host(), inet:port_number()}).
make_address(Whole = {Host, Port}) ->
    Whole;
make_address(Host) ->
    {Host, 1883}.
