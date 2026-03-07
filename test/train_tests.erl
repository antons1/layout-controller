-module(train_tests).

-include_lib("eunit/include/eunit.hrl").

%% Integration tests for train and train_sup.
%% Starts gproc, z21_events, z21_connection (with mock UDP), and train_sup.

train_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
         fun add_and_get_train_state/1,
         fun set_speed_sends_drive_command/1,
         fun set_direction_sends_drive_command/1,
         fun stop_sets_speed_zero/1,
         fun emergency_stop_sends_speed_one/1,
         fun which_trains_lists_active/1,
         fun remove_train_stops_it/1,
         fun train_requests_loco_info_on_start/1,
         fun train_reacts_to_power_off/1,
         fun train_reacts_to_emergency_stop/1,
         fun train_updates_from_loco_info/1,
         fun train_resends_state_on_connection_up/1
     ]}.

setup() ->
    %% Start gproc (needed for train process registry)
    application:ensure_all_started(gproc),

    {ok, EventsPid} = z21_events:start_link(),
    {ok, MockSocket} = gen_udp:open(21105, [binary, {active, false}, {reuseaddr, true}]),
    {ok, ConnPid} = z21_connection:start_link("127.0.0.1"),
    {ok, TrainSupPid} = train_sup:start_link(),

    %% Flush the logon packet
    {ok, {_, _, _}} = gen_udp:recv(MockSocket, 0, 1000),

    {MockSocket, ConnPid, EventsPid, TrainSupPid}.

teardown({MockSocket, ConnPid, EventsPid, TrainSupPid}) ->
    %% Stop train_sup first (trains send stop commands on terminate)
    stop_process(TrainSupPid),
    %% Drain any packets the trains sent during shutdown
    drain_udp(MockSocket),
    stop_process(ConnPid),
    gen_udp:close(MockSocket),
    stop_process(EventsPid),
    application:stop(gproc),
    ok.

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

%% Helper: receive and return the next packet from mock socket
recv_packet(MockSocket) ->
    case gen_udp:recv(MockSocket, 0, 1000) of
        {ok, {_Ip, _Port, Data}} -> {ok, Data};
        {error, timeout} -> timeout
    end.

%% Helper: flush any pending UDP packets (e.g. get_loco_info on train start)
flush_packets(MockSocket) ->
    case gen_udp:recv(MockSocket, 0, 100) of
        {ok, _} -> flush_packets(MockSocket);
        {error, timeout} -> ok
    end.

%%====================================================================
%% Tests
%%====================================================================

add_and_get_train_state({_MockSocket, _ConnPid, _EventsPid, _TrainSupPid}) ->
    fun() ->
        {ok, _Pid} = train_sup:add_train(3),
        State = train:get_state(3),
        ?assertEqual(3, maps:get(address, State)),
        ?assertEqual(0, maps:get(speed, State)),
        ?assertEqual(forward, maps:get(direction, State))
    end.

set_speed_sends_drive_command({MockSocket, _ConnPid, _EventsPid, _TrainSupPid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        flush_packets(MockSocket),
        train:set_speed(3, 50),
        {ok, Packet} = recv_packet(MockSocket),
        ?assertEqual(z21_protocol:encode_set_loco_drive(3, 50, forward), Packet)
    end.

set_direction_sends_drive_command({MockSocket, _ConnPid, _EventsPid, _TrainSupPid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        flush_packets(MockSocket),
        train:set_direction(3, reverse),
        {ok, Packet} = recv_packet(MockSocket),
        ?assertEqual(z21_protocol:encode_set_loco_drive(3, 0, reverse), Packet)
    end.

stop_sets_speed_zero({MockSocket, _ConnPid, _EventsPid, _TrainSupPid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        flush_packets(MockSocket),
        %% First set a non-zero speed
        train:set_speed(3, 50),
        _ = recv_packet(MockSocket),
        %% Now stop
        train:stop(3),
        {ok, Packet} = recv_packet(MockSocket),
        ?assertEqual(z21_protocol:encode_set_loco_drive(3, 0, forward), Packet)
    end.

emergency_stop_sends_speed_one({MockSocket, _ConnPid, _EventsPid, _TrainSupPid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        flush_packets(MockSocket),
        train:emergency_stop(3),
        {ok, Packet} = recv_packet(MockSocket),
        %% Speed 1 = emergency stop in 128 speed step mode
        ?assertEqual(z21_protocol:encode_set_loco_drive(3, 1, forward), Packet)
    end.

which_trains_lists_active({_MockSocket, _ConnPid, _EventsPid, _TrainSupPid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        {ok, _} = train_sup:add_train(7),
        Trains = train_sup:which_trains(),
        Addresses = lists:sort([maps:get(address, T) || T <- Trains]),
        ?assertEqual([3, 7], Addresses)
    end.

remove_train_stops_it({_MockSocket, _ConnPid, _EventsPid, _TrainSupPid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        ?assertNotEqual(undefined, train:pid(3)),
        ok = train_sup:remove_train(3),
        ?assertEqual(undefined, train:pid(3)),
        ?assertEqual({error, not_found}, train_sup:remove_train(3))
    end.

train_requests_loco_info_on_start({MockSocket, _ConnPid, _EventsPid, _TrainSupPid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        {ok, Packet} = recv_packet(MockSocket),
        ?assertEqual(z21_protocol:encode_get_loco_info(3), Packet)
    end.

train_reacts_to_power_off({_MockSocket, _ConnPid, _EventsPid, _TrainSupPid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        %% Set some speed first
        train:set_speed(3, 50),
        timer:sleep(50),
        %% Simulate track power off event
        z21_events:notify({track_power, off}),
        timer:sleep(50),
        State = train:get_state(3),
        ?assertEqual(0, maps:get(speed, State))
    end.

train_reacts_to_emergency_stop({_MockSocket, _ConnPid, _EventsPid, _TrainSupPid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        train:set_speed(3, 50),
        timer:sleep(50),
        z21_events:notify(emergency_stop),
        timer:sleep(50),
        State = train:get_state(3),
        ?assertEqual(0, maps:get(speed, State))
    end.

train_updates_from_loco_info({_MockSocket, _ConnPid, _EventsPid, _TrainSupPid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        %% Simulate a loco info event from the Z21
        z21_events:notify({loco_info, #{address => 3, speed => 75, direction => reverse}}),
        timer:sleep(50),
        State = train:get_state(3),
        ?assertEqual(75, maps:get(speed, State)),
        ?assertEqual(reverse, maps:get(direction, State))
    end.

train_resends_state_on_connection_up({MockSocket, _ConnPid, _EventsPid, _TrainSupPid}) ->
    fun() ->
        {ok, _} = train_sup:add_train(3),
        flush_packets(MockSocket),
        %% Set speed so the train has non-default state
        train:set_speed(3, 75),
        _ = recv_packet(MockSocket),
        train:set_direction(3, reverse),
        _ = recv_packet(MockSocket),
        %% Simulate connection restart
        z21_events:notify(connection_up),
        timer:sleep(50),
        %% Train should re-send its drive command and request loco info
        {ok, DrivePacket} = recv_packet(MockSocket),
        ?assertEqual(z21_protocol:encode_set_loco_drive(3, 75, reverse), DrivePacket),
        {ok, InfoPacket} = recv_packet(MockSocket),
        ?assertEqual(z21_protocol:encode_get_loco_info(3), InfoPacket)
    end.
