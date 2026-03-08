%%%-------------------------------------------------------------------
%% @doc Bridges the layout controller to MQTT.
%%
%% Connects to the MQTT broker as a client, subscribes to command
%% topics, and publishes state updates. Translates between MQTT
%% messages and the internal Erlang API.
%%
%% Topic hierarchy:
%%   layout/track/power/state     - "on" | "off" | "short_circuit"
%%   layout/track/power/cmd       - "on" | "off" | "emergency_stop"
%%   layout/trains/<addr>/state   - JSON: {"speed":N,"direction":"forward"|"reverse"}
%%   layout/trains/<addr>/cmd     - JSON: {"action":"set_speed","value":50}
%%                                        {"action":"set_direction","value":"reverse"}
%%                                        {"action":"stop"}
%%                                        {"action":"emergency_stop"}
%%   layout/trains/cmd            - JSON: {"action":"add","address":3}
%%                                        {"action":"remove","address":3}
%%   layout/trains/list           - JSON: [{"address":3,"speed":50,...}, ...]
%% @end
%%%-------------------------------------------------------------------

-module(mqtt_bridge).

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([encode_json/1, encode_train_state/1, decode_json/1, train_state_topic/1]).
-export([parse_power_command/1, parse_train_command/1, parse_trains_command/1]).
-export([parse_topic/1]).
-endif.

-record(state, {
    mqtt_client :: pid(),
    mqtt_port :: inet:port_number()
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
    z21_events:subscribe(),
    case connect_mqtt(MqttPort) of
        {ok, Client} ->
            subscribe_to_commands(Client),
            publish_train_list(Client),
            logger:notice("mqtt_bridge connected to broker on port ~p", [MqttPort]),
            {ok, #state{mqtt_client = Client, mqtt_port = MqttPort}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% MQTT messages from the broker
handle_info({publish, #{topic := Topic, payload := Payload}}, State) ->
    handle_mqtt_message(Topic, Payload, State),
    {noreply, State};

%% Z21 events — publish to MQTT
handle_info({z21_event, {track_power, Status}}, #state{mqtt_client = Client} = State) ->
    StatusBin = atom_to_binary(Status),
    publish(Client, <<"layout/track/power/state">>, StatusBin, [{retain, true}]),
    {noreply, State};

handle_info({z21_event, emergency_stop}, #state{mqtt_client = Client} = State) ->
    publish(Client, <<"layout/track/power/state">>, <<"emergency_stop">>, [{retain, true}]),
    {noreply, State};

handle_info({z21_event, {loco_info, #{address := Addr} = Info}}, #state{mqtt_client = Client} = State) ->
    Topic = train_state_topic(Addr),
    Payload = encode_train_state(Info),
    publish(Client, Topic, Payload, [{retain, true}]),
    {noreply, State};

handle_info({z21_event, connection_up}, #state{mqtt_client = Client} = State) ->
    publish_train_list(Client),
    {noreply, State};

handle_info({z21_event, _}, State) ->
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{mqtt_client = Client}) when is_pid(Client) ->
    emqtt:disconnect(Client),
    ok;
terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% MQTT connection
%%====================================================================

connect_mqtt(MqttPort) ->
    {ok, Client} = emqtt:start_link(#{
        host => "127.0.0.1",
        port => MqttPort,
        clientid => <<"layout_controller">>,
        clean_start => true
    }),
    case emqtt:connect(Client) of
        {ok, _Props} -> {ok, Client};
        {error, _} = Err -> Err
    end.

subscribe_to_commands(Client) ->
    Topics = [
        {<<"layout/track/power/cmd">>, 1},
        {<<"layout/trains/cmd">>, 1},
        {<<"layout/trains/+/cmd">>, 1}
    ],
    emqtt:subscribe(Client, [{Topic, Qos} || {Topic, Qos} <- Topics]).

%%====================================================================
%% Inbound MQTT command handling
%%====================================================================

handle_mqtt_message(<<"layout/track/power/cmd">>, Payload, _State) ->
    case parse_power_command(Payload) of
        {ok, Cmd} -> execute_power_command(Cmd);
        {error, unknown} ->
            logger:warning("mqtt_bridge: unknown power command: ~s", [Payload])
    end;

handle_mqtt_message(<<"layout/trains/cmd">>, Payload, #state{mqtt_client = Client}) ->
    case parse_trains_command(Payload) of
        {ok, {add, Addr}} ->
            case train_sup:add_train(Addr) of
                {ok, _Pid} -> publish_train_list(Client);
                {error, Reason} ->
                    logger:warning("mqtt_bridge: failed to add train ~p: ~p", [Addr, Reason])
            end;
        {ok, {remove, Addr}} ->
            train_sup:remove_train(Addr),
            publish_train_list(Client);
        {ok, list} ->
            publish_train_list(Client);
        {error, unknown} ->
            logger:warning("mqtt_bridge: unknown trains command: ~s", [Payload])
    end;

handle_mqtt_message(Topic, Payload, _State) ->
    case parse_topic(Topic) of
        {train_cmd, Addr} ->
            case parse_train_command(Payload) of
                {ok, Cmd} -> execute_train_command(Addr, Cmd);
                {error, unknown} ->
                    logger:warning("mqtt_bridge: unknown train command for ~p: ~s", [Addr, Payload])
            end;
        unknown ->
            logger:debug("mqtt_bridge: unhandled topic: ~s", [Topic])
    end.

%%====================================================================
%% Command parsing (pure functions)
%%====================================================================

parse_power_command(<<"on">>) -> {ok, power_on};
parse_power_command(<<"off">>) -> {ok, power_off};
parse_power_command(<<"emergency_stop">>) -> {ok, emergency_stop};
parse_power_command(_) -> {error, unknown}.

parse_trains_command(Payload) ->
    case decode_json(Payload) of
        #{<<"action">> := <<"add">>, <<"address">> := Addr} when is_integer(Addr) ->
            {ok, {add, Addr}};
        #{<<"action">> := <<"remove">>, <<"address">> := Addr} when is_integer(Addr) ->
            {ok, {remove, Addr}};
        #{<<"action">> := <<"list">>} ->
            {ok, list};
        _ ->
            {error, unknown}
    end.

parse_train_command(Payload) ->
    case decode_json(Payload) of
        #{<<"action">> := <<"set_speed">>, <<"value">> := Speed}
          when is_integer(Speed), Speed >= 0, Speed =< 126 ->
            {ok, {set_speed, Speed}};
        #{<<"action">> := <<"set_direction">>, <<"value">> := <<"forward">>} ->
            {ok, {set_direction, forward}};
        #{<<"action">> := <<"set_direction">>, <<"value">> := <<"reverse">>} ->
            {ok, {set_direction, reverse}};
        #{<<"action">> := <<"stop">>} ->
            {ok, stop};
        #{<<"action">> := <<"emergency_stop">>} ->
            {ok, emergency_stop};
        _ ->
            {error, unknown}
    end.

parse_topic(<<"layout/trains/", Rest/binary>>) ->
    case binary:split(Rest, <<"/">>) of
        [AddrBin, <<"cmd">>] ->
            case catch binary_to_integer(AddrBin) of
                Addr when is_integer(Addr) -> {train_cmd, Addr};
                _ -> unknown
            end;
        _ -> unknown
    end;
parse_topic(_) -> unknown.

%%====================================================================
%% Command execution
%%====================================================================

execute_power_command(power_on) -> z21_connection:track_power_on();
execute_power_command(power_off) -> z21_connection:track_power_off();
execute_power_command(emergency_stop) -> z21_connection:emergency_stop().

execute_train_command(Addr, {set_speed, Speed}) -> train:set_speed(Addr, Speed);
execute_train_command(Addr, {set_direction, Dir}) -> train:set_direction(Addr, Dir);
execute_train_command(Addr, stop) -> train:stop(Addr);
execute_train_command(Addr, emergency_stop) -> train:emergency_stop(Addr).

%%====================================================================
%% Outbound MQTT publishing
%%====================================================================

publish(Client, Topic, Payload, Opts) ->
    Retain = proplists:get_value(retain, Opts, false),
    emqtt:publish(Client, Topic, Payload, [{qos, 1}, {retain, Retain}]).

publish_train_list(Client) ->
    Trains = train_sup:which_trains(),
    Payload = encode_json(Trains),
    publish(Client, <<"layout/trains/list">>, Payload, [{retain, true}]).

train_state_topic(Addr) ->
    <<"layout/trains/", (integer_to_binary(Addr))/binary, "/state">>.

%%====================================================================
%% JSON encoding/decoding (minimal, no dependency)
%%====================================================================

encode_train_state(#{address := Addr} = Info) ->
    Speed = maps:get(speed, Info, 0),
    Dir = maps:get(direction, Info, forward),
    encode_json(#{address => Addr, speed => Speed, direction => Dir}).

encode_json(Map) when is_map(Map) ->
    Fields = maps:fold(fun(K, V, Acc) ->
        [encode_json_field(K, V) | Acc]
    end, [], Map),
    <<"{", (join_binary(Fields, <<",">>))/binary, "}">>;
encode_json(List) when is_list(List) ->
    Items = [encode_json(Item) || Item <- List],
    <<"[", (join_binary(Items, <<",">>))/binary, "]">>;
encode_json(Atom) when is_atom(Atom) ->
    <<"\"", (atom_to_binary(Atom))/binary, "\"">>;
encode_json(Int) when is_integer(Int) ->
    integer_to_binary(Int);
encode_json(Bin) when is_binary(Bin) ->
    <<"\"", Bin/binary, "\"">>.

encode_json_field(K, V) ->
    Key = if
        is_atom(K) -> atom_to_binary(K);
        is_binary(K) -> K
    end,
    <<"\"", Key/binary, "\":", (encode_json(V))/binary>>.

decode_json(Bin) ->
    %% Minimal JSON object decoder — handles flat objects with string,
    %% integer, and boolean values. Sufficient for our command protocol.
    json:decode(Bin).

join_binary([], _Sep) -> <<>>;
join_binary([H], _Sep) -> H;
join_binary([H | T], Sep) ->
    lists:foldl(fun(Item, Acc) ->
        <<Acc/binary, Sep/binary, Item/binary>>
    end, H, T).
