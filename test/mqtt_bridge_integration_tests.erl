-module(mqtt_bridge_integration_tests).

-include_lib("eunit/include/eunit.hrl").

%% Integration tests for mqtt_bridge.
%% Uses meck to mock emqtt so no running Mosquitto broker is needed.
%% Starts gproc, z21_events, z21_connection (with mock UDP), train_sup,
%% and the real mqtt_bridge gen_server.

mqtt_bridge_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
         fun connect_starts_emqtt_and_subscribes/1,
         fun connect_publishes_initial_train_list/1,
         fun mqtt_power_on_sends_track_power_on/1,
         fun mqtt_power_off_sends_track_power_off/1,
         fun mqtt_emergency_stop_sends_emergency_stop/1,
         fun mqtt_set_speed_sends_drive_command/1,
         fun mqtt_set_direction_sends_drive_command/1,
         fun mqtt_stop_sends_speed_zero/1,
         fun mqtt_emergency_stop_train_sends_speed_one/1,
         fun mqtt_add_train_starts_process/1,
         fun mqtt_remove_train_stops_process/1,
         fun mqtt_list_trains_publishes_current/1
     ]}.

setup() ->
    application:ensure_all_started(gproc),

    {ok, EventsPid} = z21_events:start_link(),
    {ok, MockSocket} = gen_udp:open(21105, [binary, {active, false}, {reuseaddr, true}]),
    {ok, ConnPid} = z21_connection:start_link("127.0.0.1"),
    {ok, TrainSupPid} = train_sup:start_link(),

    %% Flush the logon packet
    {ok, {_, _, _}} = gen_udp:recv(MockSocket, 0, 1000),

    setup_emqtt_mock(),

    {ok, BridgePid} = mqtt_bridge:start_link(1883),

    %% Wait for the deferred connect to fire
    meck:wait(emqtt, connect, '_', 2000),
    timer:sleep(50),

    {MockSocket, ConnPid, EventsPid, TrainSupPid, BridgePid}.

teardown({MockSocket, ConnPid, EventsPid, TrainSupPid, BridgePid}) ->
    stop_process(BridgePid),
    stop_process(TrainSupPid),
    drain_udp(MockSocket),
    stop_process(ConnPid),
    gen_udp:close(MockSocket),
    stop_process(EventsPid),
    meck:unload(emqtt),
    application:stop(gproc),
    ok.

setup_emqtt_mock() ->
    meck:new(emqtt, [non_strict]),
    FakeClient = spawn_link(fun() -> fake_client_loop() end),
    meck:expect(emqtt, start_link, fun(_Opts) -> {ok, FakeClient} end),
    meck:expect(emqtt, connect, fun(_Client) -> {ok, #{}} end),
    meck:expect(emqtt, subscribe, fun(_Client, _Topics) -> {ok, #{}, [1, 1, 1]} end),
    meck:expect(emqtt, publish, fun(_Client, _Topic, _Payload, _Opts) -> ok end),
    meck:expect(emqtt, disconnect, fun(_Client) -> ok end),
    ok.

fake_client_loop() ->
    receive stop -> ok end.

stop_process(Pid) ->
    unlink(Pid),
    MonRef = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', MonRef, process, Pid, _} -> ok
    after 5000 -> error(teardown_timeout) end.

drain_udp(Socket) ->
    case gen_udp:recv(Socket, 0, 0) of
        {ok, _} -> drain_udp(Socket);
        {error, timeout} -> ok
    end.

recv_packet(MockSocket) ->
    case gen_udp:recv(MockSocket, 0, 1000) of
        {ok, {_Ip, _Port, Data}} -> {ok, Data};
        {error, timeout} -> timeout
    end.

flush_packets(MockSocket) ->
    case gen_udp:recv(MockSocket, 0, 100) of
        {ok, _} -> flush_packets(MockSocket);
        {error, timeout} -> ok
    end.

%% Simulate an inbound MQTT message arriving at the bridge
send_mqtt_message(BridgePid, Topic, Payload) ->
    BridgePid ! {publish, #{topic => Topic, payload => Payload}},
    timer:sleep(50).

%% Find all emqtt:publish calls for a given topic in meck history
find_publish_calls(Topic) ->
    [{T, Payload, Opts}
     || {_Pid, {emqtt, publish, [_Client, T, Payload, Opts]}, ok}
        <- meck:history(emqtt),
        T =:= Topic].

%%====================================================================
%% Connection lifecycle tests
%%====================================================================

connect_starts_emqtt_and_subscribes({_MockSocket, _ConnPid, _EventsPid, _TrainSupPid, _BridgePid}) ->
    fun() ->
        ?assertEqual(1, meck:num_calls(emqtt, start_link, '_')),
        ?assertEqual(1, meck:num_calls(emqtt, connect, '_')),
        ?assertEqual(1, meck:num_calls(emqtt, subscribe, '_'))
    end.

connect_publishes_initial_train_list({_MockSocket, _ConnPid, _EventsPid, _TrainSupPid, _BridgePid}) ->
    fun() ->
        Calls = find_publish_calls(<<"layout/trains/list">>),
        ?assertMatch([{_, <<"[]">>, _}], Calls)
    end.

%%====================================================================
%% Inbound MQTT power command tests
%%====================================================================

mqtt_power_on_sends_track_power_on({MockSocket, _ConnPid, _EventsPid, _TrainSupPid, BridgePid}) ->
    fun() ->
        flush_packets(MockSocket),
        send_mqtt_message(BridgePid, <<"layout/track/power/cmd">>, <<"on">>),
        {ok, Packet} = recv_packet(MockSocket),
        ?assertEqual(z21_protocol:encode_track_power_on(), Packet)
    end.

mqtt_power_off_sends_track_power_off({MockSocket, _ConnPid, _EventsPid, _TrainSupPid, BridgePid}) ->
    fun() ->
        flush_packets(MockSocket),
        send_mqtt_message(BridgePid, <<"layout/track/power/cmd">>, <<"off">>),
        {ok, Packet} = recv_packet(MockSocket),
        ?assertEqual(z21_protocol:encode_track_power_off(), Packet)
    end.

mqtt_emergency_stop_sends_emergency_stop({MockSocket, _ConnPid, _EventsPid, _TrainSupPid, BridgePid}) ->
    fun() ->
        flush_packets(MockSocket),
        send_mqtt_message(BridgePid, <<"layout/track/power/cmd">>, <<"emergency_stop">>),
        {ok, Packet} = recv_packet(MockSocket),
        ?assertEqual(z21_protocol:encode_emergency_stop(), Packet)
    end.

%%====================================================================
%% Inbound MQTT train command tests
%%====================================================================

mqtt_set_speed_sends_drive_command({MockSocket, _ConnPid, _EventsPid, _TrainSupPid, BridgePid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        flush_packets(MockSocket),
        send_mqtt_message(BridgePid, <<"layout/trains/3/cmd">>,
                          <<"{\"action\":\"set_speed\",\"value\":50}">>),
        {ok, Packet} = recv_packet(MockSocket),
        ?assertEqual(z21_protocol:encode_set_loco_drive(3, 50, forward), Packet)
    end.

mqtt_set_direction_sends_drive_command({MockSocket, _ConnPid, _EventsPid, _TrainSupPid, BridgePid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        flush_packets(MockSocket),
        send_mqtt_message(BridgePid, <<"layout/trains/3/cmd">>,
                          <<"{\"action\":\"set_direction\",\"value\":\"reverse\"}">>),
        {ok, Packet} = recv_packet(MockSocket),
        ?assertEqual(z21_protocol:encode_set_loco_drive(3, 0, reverse), Packet)
    end.

mqtt_stop_sends_speed_zero({MockSocket, _ConnPid, _EventsPid, _TrainSupPid, BridgePid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        train:set_speed(3, 50),
        flush_packets(MockSocket),
        send_mqtt_message(BridgePid, <<"layout/trains/3/cmd">>,
                          <<"{\"action\":\"stop\"}">>),
        {ok, Packet} = recv_packet(MockSocket),
        ?assertEqual(z21_protocol:encode_set_loco_drive(3, 0, forward), Packet)
    end.

mqtt_emergency_stop_train_sends_speed_one({MockSocket, _ConnPid, _EventsPid, _TrainSupPid, BridgePid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        flush_packets(MockSocket),
        send_mqtt_message(BridgePid, <<"layout/trains/3/cmd">>,
                          <<"{\"action\":\"emergency_stop\"}">>),
        {ok, Packet} = recv_packet(MockSocket),
        ?assertEqual(z21_protocol:encode_set_loco_drive(3, 1, forward), Packet)
    end.

%%====================================================================
%% Inbound MQTT trains management tests
%%====================================================================

mqtt_add_train_starts_process({_MockSocket, _ConnPid, _EventsPid, _TrainSupPid, BridgePid}) ->
    fun() ->
        meck:reset(emqtt),
        send_mqtt_message(BridgePid, <<"layout/trains/cmd">>,
                          <<"{\"action\":\"add\",\"address\":5}">>),
        ?assertNotEqual(undefined, train:pid(5)),
        %% Should republish train list with the new train
        Calls = find_publish_calls(<<"layout/trains/list">>),
        ?assertMatch([{_, _, _}], Calls),
        [{_, Payload, _}] = Calls,
        Decoded = json:decode(Payload),
        Addresses = lists:sort([maps:get(<<"address">>, T) || T <- Decoded]),
        ?assertEqual([5], Addresses)
    end.

mqtt_remove_train_stops_process({_MockSocket, _ConnPid, _EventsPid, _TrainSupPid, BridgePid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(5),
        timer:sleep(50),
        meck:reset(emqtt),
        send_mqtt_message(BridgePid, <<"layout/trains/cmd">>,
                          <<"{\"action\":\"remove\",\"address\":5}">>),
        ?assertEqual(undefined, train:pid(5)),
        %% Should republish train list without the removed train
        Calls = find_publish_calls(<<"layout/trains/list">>),
        ?assertMatch([{_, <<"[]">>, _}], Calls)
    end.

mqtt_list_trains_publishes_current({_MockSocket, _ConnPid, _EventsPid, _TrainSupPid, BridgePid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        {ok, _} = train_sup:add_train(7),
        timer:sleep(50),
        meck:reset(emqtt),
        send_mqtt_message(BridgePid, <<"layout/trains/cmd">>,
                          <<"{\"action\":\"list\"}">>),
        Calls = find_publish_calls(<<"layout/trains/list">>),
        ?assertMatch([{_, _, _}], Calls),
        [{_, Payload, _}] = Calls,
        Decoded = json:decode(Payload),
        Addresses = lists:sort([maps:get(<<"address">>, T) || T <- Decoded]),
        ?assertEqual([3, 7], Addresses)
    end.
