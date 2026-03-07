-module(z21_protocol_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Encoding tests
%%====================================================================

encode_logon_test() ->
    %% Logon sets broadcast flags 0x00000101
    Packet = z21_protocol:encode_logon(),
    %% 8 bytes: 2 len + 2 header(0x50) + 4 flags
    ?assertEqual(8, byte_size(Packet)),
    <<8:16/little, 16#50:16/little, 16#101:32/little>> = Packet.

encode_logoff_test() ->
    Packet = z21_protocol:encode_logoff(),
    ?assertEqual(<<4:16/little, 16#30:16/little>>, Packet).

encode_get_serial_number_test() ->
    Packet = z21_protocol:encode_get_serial_number(),
    ?assertEqual(<<4:16/little, 16#10:16/little>>, Packet).

encode_track_power_on_test() ->
    Packet = z21_protocol:encode_track_power_on(),
    %% X-Bus: header 0x0040, X-Header 0x21, DB0 0x81, XOR 0xA0
    ?assertEqual(<<7:16/little, 16#40:16/little, 16#21, 16#81, 16#A0>>, Packet).

encode_track_power_off_test() ->
    Packet = z21_protocol:encode_track_power_off(),
    ?assertEqual(<<7:16/little, 16#40:16/little, 16#21, 16#80, 16#A1>>, Packet).

encode_emergency_stop_test() ->
    Packet = z21_protocol:encode_emergency_stop(),
    %% X-Header 0x80, no DBs, XOR = 0x80
    ?assertEqual(<<6:16/little, 16#40:16/little, 16#80, 16#80>>, Packet).

encode_get_loco_info_short_address_test() ->
    %% Address 3 (short addressing: AddrHigh=0x00, AddrLow=0x03)
    Packet = z21_protocol:encode_get_loco_info(3),
    XHeader = 16#E3,
    DB0 = 16#F0,
    DB1 = 16#00,
    DB2 = 16#03,
    Xor = XHeader bxor DB0 bxor DB1 bxor DB2,
    Expected = <<9:16/little, 16#40:16/little, XHeader, DB0, DB1, DB2, Xor>>,
    ?assertEqual(Expected, Packet).

encode_get_loco_info_long_address_test() ->
    %% Address 1000 (long addressing: AddrHigh=0xC3, AddrLow=0xE8)
    Packet = z21_protocol:encode_get_loco_info(1000),
    XHeader = 16#E3,
    DB0 = 16#F0,
    DB1 = 16#C3,
    DB2 = 16#E8,
    Xor = XHeader bxor DB0 bxor DB1 bxor DB2,
    Expected = <<9:16/little, 16#40:16/little, XHeader, DB0, DB1, DB2, Xor>>,
    ?assertEqual(Expected, Packet).

encode_set_loco_drive_forward_test() ->
    Packet = z21_protocol:encode_set_loco_drive(3, 50, forward),
    XHeader = 16#E4,
    DB0 = 16#13,
    DB1 = 16#00,
    DB2 = 16#03,
    DB3 = (1 bsl 7) bor 50,  %% forward bit + speed
    Xor = XHeader bxor DB0 bxor DB1 bxor DB2 bxor DB3,
    Expected = <<10:16/little, 16#40:16/little, XHeader, DB0, DB1, DB2, DB3, Xor>>,
    ?assertEqual(Expected, Packet).

encode_set_loco_drive_reverse_test() ->
    Packet = z21_protocol:encode_set_loco_drive(3, 50, reverse),
    XHeader = 16#E4,
    DB0 = 16#13,
    DB1 = 16#00,
    DB2 = 16#03,
    DB3 = 50,  %% no forward bit
    Xor = XHeader bxor DB0 bxor DB1 bxor DB2 bxor DB3,
    Expected = <<10:16/little, 16#40:16/little, XHeader, DB0, DB1, DB2, DB3, Xor>>,
    ?assertEqual(Expected, Packet).

encode_set_loco_drive_stop_test() ->
    Packet = z21_protocol:encode_set_loco_drive(3, 0, forward),
    XHeader = 16#E4,
    DB0 = 16#13,
    DB1 = 16#00,
    DB2 = 16#03,
    DB3 = 16#80,  %% forward + speed 0
    Xor = XHeader bxor DB0 bxor DB1 bxor DB2 bxor DB3,
    Expected = <<10:16/little, 16#40:16/little, XHeader, DB0, DB1, DB2, DB3, Xor>>,
    ?assertEqual(Expected, Packet).

%%====================================================================
%% Decoding tests
%%====================================================================

decode_serial_number_test() ->
    Packet = <<8:16/little, 16#10:16/little, 42:32/little>>,
    ?assertEqual([{serial_number, 42}], z21_protocol:decode(Packet)).

decode_track_power_off_test() ->
    %% X-Bus: 0x61, 0x00, XOR=0x61
    Packet = <<7:16/little, 16#40:16/little, 16#61, 16#00, 16#61>>,
    ?assertEqual([{track_power, off}], z21_protocol:decode(Packet)).

decode_track_power_on_test() ->
    Packet = <<7:16/little, 16#40:16/little, 16#61, 16#01, 16#60>>,
    ?assertEqual([{track_power, on}], z21_protocol:decode(Packet)).

decode_track_power_programming_test() ->
    Packet = <<7:16/little, 16#40:16/little, 16#61, 16#02, 16#63>>,
    ?assertEqual([{track_power, programming}], z21_protocol:decode(Packet)).

decode_track_power_short_circuit_test() ->
    Packet = <<7:16/little, 16#40:16/little, 16#61, 16#08, 16#69>>,
    ?assertEqual([{track_power, short_circuit}], z21_protocol:decode(Packet)).

decode_emergency_stop_test() ->
    Packet = <<6:16/little, 16#40:16/little, 16#81, 16#00>>,
    ?assertEqual([emergency_stop], z21_protocol:decode(Packet)).

decode_loco_info_test() ->
    %% Loco address 3, forward, speed 50
    %% Real Z21 loco info: EF, AddrH, AddrL, SpeedSteps, SpeedDir, DB4, DB5, [DB6..], XOR
    %% decode_x_payload needs at least 7 bytes after XOR strip
    AddrHigh = 16#00,
    AddrLow = 16#03,
    SpeedSteps = 16#04,
    SpeedDir = (1 bsl 7) bor 50,
    DB4 = 16#00,
    DB5 = 16#00,
    DB6 = 16#00,
    XHeader = 16#EF,
    Xor = XHeader bxor AddrHigh bxor AddrLow bxor SpeedSteps bxor SpeedDir bxor DB4 bxor DB5 bxor DB6,
    Packet = <<12:16/little, 16#40:16/little, XHeader, AddrHigh, AddrLow,
               SpeedSteps, SpeedDir, DB4, DB5, DB6, Xor>>,
    ?assertEqual([{loco_info, #{address => 3, speed => 50, direction => forward}}],
                 z21_protocol:decode(Packet)).

decode_loco_info_reverse_test() ->
    AddrHigh = 16#00,
    AddrLow = 16#03,
    SpeedSteps = 16#04,
    SpeedDir = 50,  %% no forward bit = reverse
    DB4 = 16#00,
    DB5 = 16#00,
    DB6 = 16#00,
    XHeader = 16#EF,
    Xor = XHeader bxor AddrHigh bxor AddrLow bxor SpeedSteps bxor SpeedDir bxor DB4 bxor DB5 bxor DB6,
    Packet = <<12:16/little, 16#40:16/little, XHeader, AddrHigh, AddrLow,
               SpeedSteps, SpeedDir, DB4, DB5, DB6, Xor>>,
    ?assertEqual([{loco_info, #{address => 3, speed => 50, direction => reverse}}],
                 z21_protocol:decode(Packet)).

decode_loco_info_long_address_test() ->
    %% Loco address 1000 (0xC3, 0xE8)
    AddrHigh = 16#C3,
    AddrLow = 16#E8,
    SpeedSteps = 16#04,
    SpeedDir = (1 bsl 7) bor 10,
    DB4 = 16#00,
    DB5 = 16#00,
    DB6 = 16#00,
    XHeader = 16#EF,
    Xor = XHeader bxor AddrHigh bxor AddrLow bxor SpeedSteps bxor SpeedDir bxor DB4 bxor DB5 bxor DB6,
    Packet = <<12:16/little, 16#40:16/little, XHeader, AddrHigh, AddrLow,
               SpeedSteps, SpeedDir, DB4, DB5, DB6, Xor>>,
    ?assertEqual([{loco_info, #{address => 1000, speed => 10, direction => forward}}],
                 z21_protocol:decode(Packet)).

decode_system_state_test() ->
    MainCurrent = 500,
    ProgCurrent = 0,
    FilteredCurrent = 480,
    Temperature = 35,
    SupplyVoltage = 18000,  %% 18.0V
    VCCVoltage = 5100,      %% 5.1V
    CentralState = 0,
    CentralStateEx = 0,
    Packet = <<20:16/little, 16#84:16/little,
               MainCurrent:16/little-signed,
               ProgCurrent:16/little-signed,
               FilteredCurrent:16/little-signed,
               Temperature:16/little-signed,
               SupplyVoltage:16/little,
               VCCVoltage:16/little,
               CentralState:8,
               CentralStateEx:8,
               0:8, 0:8>>,
    [{system_state, Info}] = z21_protocol:decode(Packet),
    ?assertEqual(500, maps:get(main_current, Info)),
    ?assert(abs(maps:get(supply_voltage, Info) - 18.0) < 0.01),
    ?assert(abs(maps:get(vcc_voltage, Info) - 5.1) < 0.01),
    ?assertEqual([], maps:get(flags, Info)).

decode_system_state_with_flags_test() ->
    %% emergency_stop (0x01) + short_circuit (0x04)
    CentralState = 16#05,
    Packet = <<20:16/little, 16#84:16/little,
               0:16/little-signed, 0:16/little-signed,
               0:16/little-signed, 0:16/little-signed,
               0:16/little, 0:16/little,
               CentralState:8, 0:8, 0:8, 0:8>>,
    [{system_state, Info}] = z21_protocol:decode(Packet),
    Flags = maps:get(flags, Info),
    ?assert(lists:member(emergency_stop, Flags)),
    ?assert(lists:member(short_circuit, Flags)).

%%====================================================================
%% Roundtrip and edge case tests
%%====================================================================

decode_multiple_packets_test() ->
    %% Two packets concatenated (as z21 can send)
    P1 = <<7:16/little, 16#40:16/little, 16#61, 16#01, 16#60>>,
    P2 = <<8:16/little, 16#10:16/little, 99:32/little>>,
    Combined = <<P1/binary, P2/binary>>,
    ?assertEqual([{track_power, on}, {serial_number, 99}],
                 z21_protocol:decode(Combined)).

decode_incomplete_packet_test() ->
    %% Incomplete packet should be silently ignored
    ?assertEqual([], z21_protocol:decode(<<7:16/little, 16#40:16/little, 16#61>>)).

decode_empty_test() ->
    ?assertEqual([], z21_protocol:decode(<<>>)).

encode_broadcast_flags_test() ->
    Packet = z21_protocol:encode_set_broadcast_flags(16#00010001),
    ?assertEqual(<<8:16/little, 16#50:16/little, 16#00010001:32/little>>, Packet).

address_boundary_127_test() ->
    %% Address 127 should use short addressing
    Packet = z21_protocol:encode_get_loco_info(127),
    <<_:16/little, 16#40:16/little, 16#E3, 16#F0, AddrHigh, AddrLow, _Xor>> = Packet,
    ?assertEqual(16#00, AddrHigh),
    ?assertEqual(127, AddrLow).

address_boundary_128_test() ->
    %% Address 128 should use long addressing
    Packet = z21_protocol:encode_get_loco_info(128),
    <<_:16/little, 16#40:16/little, 16#E3, 16#F0, AddrHigh, _AddrLow, _Xor>> = Packet,
    ?assertEqual(16#C0, AddrHigh band 16#C0).
