%%%-------------------------------------------------------------------
%% @doc layout_controller top level supervisor.
%%
%% Supervision tree:
%%   layout_controller_sup (one_for_one)
%%     ├── z21_events       (gen_server - event pub/sub)
%%     ├── z21_connection    (gen_server - UDP connection to z21)
%%     └── train_sup         (supervisor - one train gen_server per loco)
%%
%% one_for_one: each child restarts independently. When z21_connection
%% restarts, it notifies via z21_events so trains can re-send their state.
%% @end
%%%-------------------------------------------------------------------

-module(layout_controller_sup).

-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    Z21Ip = application:get_env(layout_controller, z21_ip, "192.168.0.111"),

    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },

    ChildSpecs = [
        #{
            id => z21_events,
            start => {z21_events, start_link, []},
            restart => permanent,
            type => worker
        },
        #{
            id => z21_connection,
            start => {z21_connection, start_link, [Z21Ip]},
            restart => permanent,
            type => worker
        },
        #{
            id => train_sup,
            start => {train_sup, start_link, []},
            restart => permanent,
            type => supervisor
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
