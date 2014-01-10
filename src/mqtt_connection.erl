-module(mqtt_connection).

-behaviour(gen_fsm).

%% Public API
-export([start_link/0, connect/4, open/3]).

%% gen_fsm callbacks
-export([init/1, handle_event/3,
         handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

%% states
-export([unopened/3]).

-type(connection_state() :: 'unopened').

-include("include/types.hrl").

-record(state, {
          socket = undefined,
          frame_buf = <<>>
         }).

start_link() ->
    gen_fsm:start_link(?MODULE, [], []).

connect(Conn, Host, Port, ConnectFrame) ->
    {ok, Sock} = gen_tcp:connect(Host, Port,
                                 [{active, false},
                                  binary]),
    open(Conn, Sock, ConnectFrame).

%% NB this assumes that the calling process controls the socket
open(Conn, Sock, ConnectFrame) ->
    ok = gen_tcp:controlling_process(Sock, Conn),
    gen_fsm:sync_send_event(Conn, {open, Sock, ConnectFrame}).


%%% gen_fsm callbacks

init([]) ->
    {ok, unopened, #state{}}.

%% states

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

write(#state{ socket = S }, Frame) ->
    ok = gen_tcp:send(S, mqtt_framing:serialise(Frame)),
    ok.

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
