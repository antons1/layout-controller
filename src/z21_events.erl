%%%-------------------------------------------------------------------
%% @doc Simple event pub/sub for z21 broadcasts.
%%
%% Processes can subscribe to z21 events (track power, loco info, etc.)
%% and will receive messages in the form: {z21_event, Event}.
%%
%% Usage:
%%   z21_events:subscribe().
%%   receive {z21_event, {track_power, on}} -> ... end.
%% @end
%%%-------------------------------------------------------------------

-module(z21_events).

-behaviour(gen_server).

-export([start_link/0, subscribe/0, unsubscribe/0, notify/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).

-record(state, {
    subscribers = #{} :: #{pid() => reference()}
}).

%%====================================================================
%% Public API
%%====================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Subscribe the calling process to z21 events
subscribe() ->
    gen_server:call(?SERVER, {subscribe, self()}).

%% Unsubscribe the calling process
unsubscribe() ->
    gen_server:call(?SERVER, {unsubscribe, self()}).

%% Send an event to all subscribers (called by z21_connection)
notify(Event) ->
    gen_server:cast(?SERVER, {notify, Event}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    {ok, #state{}}.

handle_call({subscribe, Pid}, _From, #state{subscribers = Subs} = State) ->
    case maps:is_key(Pid, Subs) of
        true ->
            {reply, ok, State};
        false ->
            MonRef = monitor(process, Pid),
            {reply, ok, State#state{subscribers = Subs#{Pid => MonRef}}}
    end;

handle_call({unsubscribe, Pid}, _From, #state{subscribers = Subs} = State) ->
    case maps:take(Pid, Subs) of
        {MonRef, NewSubs} ->
            demonitor(MonRef, [flush]),
            {reply, ok, State#state{subscribers = NewSubs}};
        error ->
            {reply, ok, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({notify, Event}, #state{subscribers = Subs} = State) ->
    maps:foreach(fun(Pid, _Ref) ->
        Pid ! {z21_event, Event}
    end, Subs),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Clean up when a subscriber process dies
handle_info({'DOWN', _MonRef, process, Pid, _Reason}, #state{subscribers = Subs} = State) ->
    {noreply, State#state{subscribers = maps:remove(Pid, Subs)}};

handle_info(_Info, State) ->
    {noreply, State}.
