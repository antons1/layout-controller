%%%-------------------------------------------------------------------
%% @doc layout_controller top level supervisor.
%%
%% Supervision tree:
%%   layout_controller_sup (rest_for_one)
%%     ├── z21_events       (gen_server - event pub/sub)
%%     ├── z21_connection    (gen_server - UDP connection to z21)
%%     ├── train_sup         (supervisor - one train gen_server per loco)
%%     ├── mqtt_broker       (gen_server - manages mosquitto process)
%%     └── mqtt_bridge       (gen_server - MQTT client bridging to controller)
%%
%% rest_for_one: if a child crashes, all children started after it
%% are restarted too. This ensures mqtt_bridge restarts if mqtt_broker
%% crashes. train_sup is placed before MQTT children so that MQTT
%% failures do not cascade to running trains.
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
    MqttPort = application:get_env(layout_controller, mqtt_port, 1883),

    SupFlags = #{
        strategy => rest_for_one,
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
        },
        #{
            id => mqtt_broker,
            start => {mqtt_broker, start_link, [MqttPort]},
            restart => permanent,
            type => worker
        },
        #{
            id => mqtt_bridge,
            start => {mqtt_bridge, start_link, [MqttPort]},
            restart => permanent,
            type => worker
        }
    ],
    {ok, {SupFlags, ChildSpecs}}.
