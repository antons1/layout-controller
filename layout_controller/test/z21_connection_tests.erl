-module(z21_connection_tests).

-include_lib("eunit/include/eunit.hrl").

%% Tests use a local UDP socket to simulate the Z21 command station.
%% z21_connection sends to our socket, and we can send responses back.

z21_connection_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
         fun sends_logon_on_start/1,
         fun track_power_on_sends_correct_packet/1,
         fun track_power_off_sends_correct_packet/1,
         fun emergency_stop_sends_correct_packet/1,
         fun get_serial_number_sends_correct_packet/1,
         fun get_loco_info_sends_correct_packet/1,
         fun set_loco_drive_sends_correct_packet/1,
         fun incoming_track_power_dispatched_to_events/1,
         fun incoming_loco_info_dispatched_to_events/1
     ]}.

setup() ->
    %% Start z21_events first (z21_connection depends on it for dispatching)
    {ok, EventsPid} = z21_events:start_link(),

    %% Open a UDP socket on port 21105 to act as the mock Z21.
    %% Use {active, false} so any process can call gen_udp:recv.
    {ok, MockSocket} = gen_udp:open(21105, [binary, {active, false}, {reuseaddr, true}]),

    %% Start z21_connection pointing at localhost
    {ok, ConnPid} = z21_connection:start_link("127.0.0.1"),

    {MockSocket, ConnPid, EventsPid}.

teardown({MockSocket, ConnPid, EventsPid}) ->
    unlink(ConnPid),
    MonRef1 = monitor(process, ConnPid),
    exit(ConnPid, shutdown),
    receive {'DOWN', MonRef1, process, ConnPid, _} -> ok
    after 5000 -> error(teardown_timeout) end,

    gen_udp:close(MockSocket),

    unlink(EventsPid),
    MonRef2 = monitor(process, EventsPid),
    exit(EventsPid, shutdown),
    receive {'DOWN', MonRef2, process, EventsPid, _} -> ok
    after 5000 -> error(teardown_timeout) end.

%% Helper: receive the next UDP packet sent to our mock socket
recv_packet(MockSocket, Timeout) ->
    case gen_udp:recv(MockSocket, 0, Timeout) of
        {ok, {_Ip, _Port, Data}} -> {ok, Data};
        {error, timeout} -> timeout
    end.

%% Helper: receive a packet and also return the sender port
recv_packet_with_port(MockSocket, Timeout) ->
    case gen_udp:recv(MockSocket, 0, Timeout) of
        {ok, {_Ip, Port, Data}} -> {ok, Port, Data};
        {error, timeout} -> timeout
    end.

%% Helper: flush the logon packet that z21_connection sends on start
flush_logon(MockSocket) ->
    {ok, _} = recv_packet(MockSocket, 1000),
    ok.

%% Helper: send a packet from our mock Z21 back to z21_connection
send_from_z21(MockSocket, ClientPort, Packet) ->
    gen_udp:send(MockSocket, {127, 0, 0, 1}, ClientPort, Packet).

%%====================================================================
%% Tests
%%====================================================================

sends_logon_on_start({MockSocket, _ConnPid, _EventsPid}) ->
    fun() ->
        {ok, Packet} = recv_packet(MockSocket, 1000),
        <<8:16/little, 16#50:16/little, _Flags:32/little>> = Packet
    end.

track_power_on_sends_correct_packet({MockSocket, _ConnPid, _EventsPid}) ->
    fun() ->
        flush_logon(MockSocket),
        z21_connection:track_power_on(),
        {ok, Packet} = recv_packet(MockSocket, 1000),
        ?assertEqual(z21_protocol:encode_track_power_on(), Packet)
    end.

track_power_off_sends_correct_packet({MockSocket, _ConnPid, _EventsPid}) ->
    fun() ->
        flush_logon(MockSocket),
        z21_connection:track_power_off(),
        {ok, Packet} = recv_packet(MockSocket, 1000),
        ?assertEqual(z21_protocol:encode_track_power_off(), Packet)
    end.

emergency_stop_sends_correct_packet({MockSocket, _ConnPid, _EventsPid}) ->
    fun() ->
        flush_logon(MockSocket),
        z21_connection:emergency_stop(),
        {ok, Packet} = recv_packet(MockSocket, 1000),
        ?assertEqual(z21_protocol:encode_emergency_stop(), Packet)
    end.

get_serial_number_sends_correct_packet({MockSocket, _ConnPid, _EventsPid}) ->
    fun() ->
        flush_logon(MockSocket),
        z21_connection:get_serial_number(),
        {ok, Packet} = recv_packet(MockSocket, 1000),
        ?assertEqual(z21_protocol:encode_get_serial_number(), Packet)
    end.

get_loco_info_sends_correct_packet({MockSocket, _ConnPid, _EventsPid}) ->
    fun() ->
        flush_logon(MockSocket),
        z21_connection:get_loco_info(3),
        {ok, Packet} = recv_packet(MockSocket, 1000),
        ?assertEqual(z21_protocol:encode_get_loco_info(3), Packet)
    end.

set_loco_drive_sends_correct_packet({MockSocket, _ConnPid, _EventsPid}) ->
    fun() ->
        flush_logon(MockSocket),
        z21_connection:set_loco_drive(3, 50, forward),
        {ok, Packet} = recv_packet(MockSocket, 1000),
        ?assertEqual(z21_protocol:encode_set_loco_drive(3, 50, forward), Packet)
    end.

incoming_track_power_dispatched_to_events({MockSocket, _ConnPid, _EventsPid}) ->
    fun() ->
        %% Get client port from the logon packet
        {ok, ClientPort, _Data} = recv_packet_with_port(MockSocket, 1000),

        %% Subscribe to events
        ok = z21_events:subscribe(),

        %% Send a track_power_on response from the mock Z21
        PowerOnPacket = <<7:16/little, 16#40:16/little, 16#61, 16#01, 16#60>>,
        send_from_z21(MockSocket, ClientPort, PowerOnPacket),

        receive
            {z21_event, {track_power, on}} -> ok
        after 1000 ->
            ?assert(false)
        end
    end.

incoming_loco_info_dispatched_to_events({MockSocket, _ConnPid, _EventsPid}) ->
    fun() ->
        {ok, ClientPort, _Data} = recv_packet_with_port(MockSocket, 1000),
        ok = z21_events:subscribe(),

        %% Build a loco info response for address 3, speed 50, forward
        XHeader = 16#EF,
        AddrHigh = 16#00,
        AddrLow = 16#03,
        SpeedSteps = 16#04,
        SpeedDir = (1 bsl 7) bor 50,
        DB4 = 16#00,
        DB5 = 16#00,
        DB6 = 16#00,
        Xor = XHeader bxor AddrHigh bxor AddrLow bxor SpeedSteps bxor SpeedDir bxor DB4 bxor DB5 bxor DB6,
        LocoPacket = <<12:16/little, 16#40:16/little, XHeader, AddrHigh, AddrLow,
                       SpeedSteps, SpeedDir, DB4, DB5, DB6, Xor>>,
        send_from_z21(MockSocket, ClientPort, LocoPacket),

        receive
            {z21_event, {loco_info, #{address := 3, speed := 50, direction := forward}}} -> ok
        after 1000 ->
            ?assert(false)
        end
    end.
