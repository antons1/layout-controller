%%%-------------------------------------------------------------------
%% @doc Manages an embedded Mosquitto MQTT broker process.
%%
%% Starts Mosquitto as an Erlang port. If the Mosquitto process dies,
%% this gen_server crashes and the supervisor restarts it (which
%% restarts Mosquitto).
%%
%% To switch to an external broker, remove this module from the
%% supervision tree and point mqtt_bridge at the external host:port.
%% @end
%%%-------------------------------------------------------------------

-module(mqtt_broker).

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    port :: port(),
    os_pid :: integer() | undefined,
    mqtt_port :: inet:port_number(),
    config_file :: string() | undefined
}).

%%====================================================================
%% Public API
%%====================================================================

start_link(MqttPort) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [MqttPort], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([MqttPort]) ->
    process_flag(trap_exit, true),
    case start_mosquitto(MqttPort) of
        {ok, Port, ConfigFile} ->
            OsPid = get_os_pid(Port),
            logger:notice("mqtt_broker started mosquitto on port ~p", [MqttPort]),
            {ok, #state{port = Port, os_pid = OsPid, mqtt_port = MqttPort,
                        config_file = ConfigFile}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Port, {exit_status, Status}}, #state{port = Port} = State) ->
    logger:error("mqtt_broker: mosquitto exited with status ~p", [Status]),
    {stop, {mosquitto_exit, Status}, State#state{port = undefined}};

handle_info({Port, {data, Data}}, #state{port = Port} = State) ->
    logger:info("mosquitto: ~s", [Data]),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{port = Port, os_pid = OsPid}) when is_port(Port) ->
    port_close(Port),
    kill_os_process(OsPid),
    ok;
terminate(_Reason, #state{os_pid = OsPid}) ->
    kill_os_process(OsPid),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

start_mosquitto(MqttPort) ->
    MosquittoCmd = os:find_executable("mosquitto"),
    case MosquittoCmd of
        false ->
            logger:error("mqtt_broker: mosquitto not found in PATH"),
            {error, mosquitto_not_found};
        Path ->
            ConfigFile = write_config(MqttPort),
            PortArgs = [
                {args, ["-c", ConfigFile, "-v"]},
                exit_status,
                use_stdio,
                stderr_to_stdout,
                {line, 1024}
            ],
            Port = open_port({spawn_executable, Path}, PortArgs),
            {ok, Port, ConfigFile}
    end.

get_os_pid(Port) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, Pid} -> Pid;
        undefined -> undefined
    end.

kill_os_process(undefined) -> ok;
kill_os_process(OsPid) ->
    os:cmd("kill " ++ integer_to_list(OsPid)),
    ok.


write_config(MqttPort) ->
    ConfigContent = io_lib:format(
        "listener ~p 127.0.0.1~n"
        "allow_anonymous true~n"
        "persistence false~n",
        [MqttPort]),
    ConfigFile = filename:join(
        filename:basedir(user_cache, "layout_controller"),
        "mosquitto.conf"),
    ok = filelib:ensure_dir(ConfigFile),
    ok = file:write_file(ConfigFile, ConfigContent),
    ConfigFile.

