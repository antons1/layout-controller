%%%-------------------------------------------------------------------
%% @doc Supervisor for individual train processes.
%%
%% Uses simple_one_for_one strategy - a template-based supervisor
%% where all children are the same type (train gen_servers) but
%% started dynamically with different arguments.
%%
%% Usage:
%%   train_sup:add_train(3).        %% start controlling loco address 3
%%   train_sup:remove_train(3).     %% stop controlling loco address 3
%%   train_sup:which_trains().      %% list active trains
%% @end
%%%-------------------------------------------------------------------

-module(train_sup).

-behaviour(supervisor).

-export([start_link/0, add_train/1, remove_train/1, which_trains/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% Dynamically add a train with the given DCC address
add_train(Address) ->
    supervisor:start_child(?SERVER, [Address]).

%% Remove a train by its DCC address
remove_train(Address) ->
    case train:pid(Address) of
        undefined ->
            {error, not_found};
        Pid ->
            supervisor:terminate_child(?SERVER, Pid)
    end.

%% List all active train addresses
which_trains() ->
    Children = supervisor:which_children(?SERVER),
    [train:get_state(Pid) || {_Id, Pid, _Type, _Modules} <- Children, is_pid(Pid)].

init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 10,
        period => 5
    },

    %% Template child spec - Address is passed via add_train/1
    ChildSpec = #{
        id => train,
        start => {train, start_link, []},   %% add_train(Addr) appends [Addr]
        restart => transient,                %% restart only if crash (not normal exit)
        type => worker
    },

    {ok, {SupFlags, [ChildSpec]}}.
