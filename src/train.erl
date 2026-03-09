%%%-------------------------------------------------------------------
%% @doc Individual train controller.
%%
%% Each instance manages one DCC locomotive. It holds the desired
%% state (speed, direction) and communicates with the z21 via
%% z21_connection.
%%
%% Usage:
%%   train_sup:add_train(3).           %% start controlling loco 3
%%   train:set_speed(3, 50).           %% set speed to 50 (0-126)
%%   train:set_direction(3, reverse).  %% reverse direction
%%   train:stop(3).                    %% speed to 0
%%   train:get_state(3).               %% get current state
%% @end
%%%-------------------------------------------------------------------

-module(train).

-behaviour(gen_server).

%% Public API
-export([
    start_link/1,
    set_speed/2,
    set_direction/2,
    stop/1,
    emergency_stop/1,
    get_state/1,
    pid/1
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    address,           %% DCC loco address
    speed = 0,         %% current speed 0-126
    direction = forward %% forward | reverse
}).

%%====================================================================
%% Public API
%%====================================================================

start_link(Address) ->
    %% Register with a unique name based on the address
    Name = via_name(Address),
    gen_server:start_link(Name, ?MODULE, [Address], []).

set_speed(Address, Speed) when Speed >= 0, Speed =< 126 ->
    gen_server:cast(via_name(Address), {set_speed, Speed}).

set_direction(Address, Direction) when Direction =:= forward; Direction =:= reverse ->
    gen_server:cast(via_name(Address), {set_direction, Direction}).

stop(Address) ->
    set_speed(Address, 0).

emergency_stop(Address) ->
    %% Speed 1 is emergency stop in DCC 128 speed step mode
    gen_server:cast(via_name(Address), emergency_stop).

get_state(Address) when is_integer(Address) ->
    gen_server:call(via_name(Address), get_state);
%% Also accept a Pid (used by train_sup:which_trains/0)
get_state(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, get_state).

%% Look up the pid for a train address
pid(Address) ->
    gproc:where({n, l, {train, Address}}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Address]) ->
    %% Subscribe to z21 events so we hear about power changes
    z21_events:subscribe(),

    %% Request current loco state from z21
    z21_connection:get_loco_info(Address),

    logger:notice("Train ~p started", [Address]),
    {ok, #state{address = Address}}.

handle_call(get_state, _From, State) ->
    Info = #{
        address => State#state.address,
        speed => State#state.speed,
        direction => State#state.direction
    },
    {reply, Info, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({set_speed, Speed}, State) ->
    NewState = State#state{speed = Speed},
    send_drive_command(NewState),
    {noreply, NewState};

handle_cast({set_direction, Direction}, State) ->
    NewState = State#state{direction = Direction},
    send_drive_command(NewState),
    {noreply, NewState};

handle_cast(emergency_stop, State) ->
    NewState = State#state{speed = 0},
    %% Speed 1 is emergency stop in DCC 128 speed step mode
    z21_connection:set_loco_drive(State#state.address, 1, State#state.direction),
    {noreply, NewState};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Handle z21 events
handle_info({z21_event, {track_power, off}}, State) ->
    logger:notice("Train ~p: track power off", [State#state.address]),
    {noreply, State#state{speed = 0}};

handle_info({z21_event, {track_power, short_circuit}}, State) ->
    logger:warning("Train ~p: short circuit!", [State#state.address]),
    {noreply, State#state{speed = 0}};

handle_info({z21_event, emergency_stop}, State) ->
    logger:notice("Train ~p: emergency stop", [State#state.address]),
    {noreply, State#state{speed = 0}};

handle_info({z21_event, {loco_info, #{address := Addr} = Info}}, State)
  when Addr =:= State#state.address ->
    %% Update our state from what the z21 reports
    NewState = State#state{
        speed = maps:get(speed, Info, State#state.speed),
        direction = maps:get(direction, Info, State#state.direction)
    },
    {noreply, NewState};

handle_info({z21_event, connection_up}, State) ->
    %% Connection (re)established - re-send our current state
    send_drive_command(State),
    z21_connection:get_loco_info(State#state.address),
    {noreply, State};

handle_info({z21_event, _}, State) ->
    %% Ignore events for other locos or events we don't care about
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    %% Stop the train when the process terminates
    z21_connection:set_loco_drive(State#state.address, 0, State#state.direction),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

send_drive_command(#state{address = Addr, speed = Speed, direction = Dir}) ->
    z21_connection:set_loco_drive(Addr, Speed, Dir).

%% Process registration name for a given loco address.
%% Uses gproc for dynamic name registry.
via_name(Address) ->
    {via, gproc, {n, l, {train, Address}}}.
