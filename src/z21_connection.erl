%%%-------------------------------------------------------------------
%% @doc Z21 connection manager.
%%
%% Manages the UDP connection to a Roco z21 command station.
%% Handles:
%%   - Opening and maintaining the UDP socket
%%   - Periodic keep-alive (z21 drops clients after ~60s of silence)
%%   - Sending commands to the z21
%%   - Receiving and dispatching broadcast messages
%%
%% Other processes send commands through this server:
%%   z21_connection:send(Packet).
%%   z21_connection:track_power_on().
%% @end
%%%-------------------------------------------------------------------

-module(z21_connection).

-behaviour(gen_server).

%% Public API
-export([
    start_link/1,
    send/1,
    track_power_on/0,
    track_power_off/0,
    emergency_stop/0,
    get_serial_number/0,
    get_loco_info/1,
    set_loco_drive/3
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(KEEPALIVE_INTERVAL, 30000).  %% 30 seconds

-record(state, {
    socket,          %% UDP socket
    z21_ip,          %% z21 IP address (tuple)
    z21_port,        %% z21 UDP port
    subscribers      %% list of {Pid, MonitorRef} subscribed to broadcasts
}).

%%====================================================================
%% Public API
%%====================================================================

%% Start with z21 IP address as a string, e.g. "192.168.0.111"
start_link(Z21Ip) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [Z21Ip], []).

%% Send a raw encoded packet to the z21.
%% Silently drops the message if the connection process is down.
send(Packet) ->
    try
        gen_server:cast(?SERVER, {send, Packet})
    catch
        exit:{noproc, _} -> ok
    end.

track_power_on() ->
    send(z21_protocol:encode_track_power_on()).

track_power_off() ->
    send(z21_protocol:encode_track_power_off()).

emergency_stop() ->
    send(z21_protocol:encode_emergency_stop()).

get_serial_number() ->
    send(z21_protocol:encode_get_serial_number()).

get_loco_info(Address) ->
    send(z21_protocol:encode_get_loco_info(Address)).

set_loco_drive(Address, Speed, Direction) ->
    send(z21_protocol:encode_set_loco_drive(Address, Speed, Direction)).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Z21Ip]) ->
    {ok, IpTuple} = inet:parse_address(Z21Ip),
    Z21Port = 21105,

    %% Open a UDP socket - we bind to any available port
    {ok, Socket} = gen_udp:open(0, [binary, {active, true}]),

    State = #state{
        socket = Socket,
        z21_ip = IpTuple,
        z21_port = Z21Port,
        subscribers = []
    },

    %% Send logon (subscribe to broadcasts)
    send_to_z21(State, z21_protocol:encode_logon()),

    %% Start keep-alive timer
    erlang:send_after(?KEEPALIVE_INTERVAL, self(), keepalive),

    logger:notice("z21_connection started, connecting to ~s:~p", [Z21Ip, Z21Port]),

    %% Notify subscribers that the connection is (re)established
    z21_events:notify(connection_up),

    {ok, State}.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

%% Send a packet to z21
handle_cast({send, Packet}, State) ->
    send_to_z21(State, Packet),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Incoming UDP data from z21
handle_info({udp, _Socket, _Ip, _Port, Data}, State) ->
    Messages = z21_protocol:decode(Data),
    lists:foreach(fun(Msg) ->
        handle_z21_message(Msg, State)
    end, Messages),
    {noreply, State};

%% Keep-alive timer
handle_info(keepalive, State) ->
    send_to_z21(State, z21_protocol:encode_logon()),
    erlang:send_after(?KEEPALIVE_INTERVAL, self(), keepalive),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{socket = Socket} = State) ->
    %% Send logoff before closing
    send_to_z21(State, z21_protocol:encode_logoff()),
    gen_udp:close(Socket),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

send_to_z21(#state{socket = Socket, z21_ip = Ip, z21_port = Port}, Packet) ->
    gen_udp:send(Socket, Ip, Port, Packet).

handle_z21_message({track_power, Status}, _State) ->
    logger:notice("Track power: ~p", [Status]),
    %% Notify all train processes about power changes
    z21_events:notify({track_power, Status});

handle_z21_message({loco_info, Info}, _State) ->
    z21_events:notify({loco_info, Info});

handle_z21_message(emergency_stop, _State) ->
    logger:warning("Emergency stop received!"),
    z21_events:notify(emergency_stop);

handle_z21_message({system_state, Info}, _State) ->
    logger:notice("System state: ~p", [Info]),
    z21_events:notify({system_state, Info});

handle_z21_message({serial_number, Serial}, _State) ->
    logger:notice("Z21 serial number: ~p", [Serial]);

handle_z21_message(_Other, _State) ->
    ok.
