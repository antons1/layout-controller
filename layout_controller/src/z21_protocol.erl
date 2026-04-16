%%%-------------------------------------------------------------------
%% @doc Z21 LAN protocol encoding and decoding.
%%
%% The z21 communicates over UDP port 21105 using a binary protocol.
%% Each packet has the structure:
%%   - 2 bytes: total length (little-endian, includes these 2 bytes)
%%   - 2 bytes: header (little-endian)
%%   - N bytes: data
%%
%% X-Bus commands (header 0x0040) have additional structure in data:
%%   - 1 byte: X-Header
%%   - N bytes: DB0..DBn
%%   - 1 byte: XOR checksum of X-Header and all DB bytes
%% @end
%%%-------------------------------------------------------------------

-module(z21_protocol).

-export([
    %% Encoding
    encode_logon/0,
    encode_logoff/0,
    encode_set_broadcast_flags/1,
    encode_get_serial_number/0,
    encode_track_power_on/0,
    encode_track_power_off/0,
    encode_emergency_stop/0,
    encode_get_loco_info/1,
    encode_set_loco_drive/3,

    %% Decoding
    decode/1
]).

-define(Z21_PORT, 21105).

%% LAN headers
-define(LAN_GET_SERIAL_NUMBER,   16#10).
-define(LAN_LOGOFF,              16#30).
-define(LAN_X,                   16#40).
-define(LAN_SET_BROADCASTFLAGS,  16#50).
-define(LAN_GET_BROADCASTFLAGS,  16#51).
-define(LAN_SYSTEMSTATE_DATACHANGED, 16#84).
-define(LAN_GET_HWINFO,         16#1A).

%%====================================================================
%% Encoding
%%====================================================================

%% Subscribe to broadcasts - this also serves as the initial "logon"
encode_logon() ->
    %% Bit 0: general status (track power, short circuit, etc.)
    %% Bit 8: changes to loco info on subscribed locos
    Flags = 16#00000101,
    encode_set_broadcast_flags(Flags).

encode_logoff() ->
    encode_packet(?LAN_LOGOFF, <<>>).

encode_set_broadcast_flags(Flags) ->
    encode_packet(?LAN_SET_BROADCASTFLAGS, <<Flags:32/little>>).

encode_get_serial_number() ->
    encode_packet(?LAN_GET_SERIAL_NUMBER, <<>>).

%% LAN_X_SET_TRACK_POWER_ON
encode_track_power_on() ->
    encode_x_packet(16#21, [16#81]).

%% LAN_X_SET_TRACK_POWER_OFF
encode_track_power_off() ->
    encode_x_packet(16#21, [16#80]).

%% LAN_X_BC_STOP_ALL (emergency stop all locos)
encode_emergency_stop() ->
    encode_x_packet(16#80, []).

%% LAN_X_GET_LOCO_INFO - request current state of a loco
%% Address is the DCC address (1-9999)
encode_get_loco_info(Address) ->
    {AddrHigh, AddrLow} = encode_loco_address(Address),
    encode_x_packet(16#E3, [16#F0, AddrHigh, AddrLow]).

%% LAN_X_SET_LOCO_DRIVE - set speed and direction
%% Address: DCC loco address (1-9999)
%% Speed: 0-126 (0 = stop, 1 = emergency stop, 2-126 = speed)
%% Direction: forward | reverse
encode_set_loco_drive(Address, Speed, Direction) ->
    {AddrHigh, AddrLow} = encode_loco_address(Address),
    DirBit = case Direction of
        forward -> 1;
        reverse -> 0
    end,
    %% 0x13 = 128 speed steps mode
    SpeedByte = (DirBit bsl 7) bor (Speed band 16#7F),
    encode_x_packet(16#E4, [16#13, AddrHigh, AddrLow, SpeedByte]).

%%====================================================================
%% Decoding
%%====================================================================

%% Decode one or more z21 packets from binary data.
%% Returns a list of decoded messages.
decode(Binary) ->
    decode_packets(Binary, []).

decode_packets(<<>>, Acc) ->
    lists:reverse(Acc);
decode_packets(<<Len:16/little, _/binary>> = Data, Acc) when byte_size(Data) >= Len ->
    <<Packet:Len/binary, Rest/binary>> = Data,
    <<_Len:16/little, Header:16/little, Payload/binary>> = Packet,
    Msg = decode_packet(Header, Payload),
    decode_packets(Rest, [Msg | Acc]);
decode_packets(_Incomplete, Acc) ->
    lists:reverse(Acc).

%% Serial number response
decode_packet(?LAN_GET_SERIAL_NUMBER, <<Serial:32/little>>) ->
    {serial_number, Serial};

%% X-Bus messages
decode_packet(?LAN_X, Payload) ->
    decode_x_packet(Payload);

%% System state
decode_packet(?LAN_SYSTEMSTATE_DATACHANGED, <<
    MainCurrent:16/little-signed,
    _ProgCurrent:16/little-signed,
    _FilteredMainCurrent:16/little-signed,
    _Temperature:16/little-signed,
    SupplyVoltage:16/little,
    VCCVoltage:16/little,
    CentralState:8,
    _CentralStateEx:8,
    _Reserved1:8,
    _Reserved2:8
>>) ->
    Flags = decode_central_state(CentralState),
    {system_state, #{
        main_current => MainCurrent,
        supply_voltage => SupplyVoltage / 1000.0,
        vcc_voltage => VCCVoltage / 1000.0,
        flags => Flags
    }};

%% Broadcast flags response
decode_packet(?LAN_GET_BROADCASTFLAGS, <<Flags:32/little>>) ->
    {broadcast_flags, Flags};

%% Unknown
decode_packet(Header, Payload) ->
    {unknown, Header, Payload}.

%% X-Bus packet decoding
decode_x_packet(XData) ->
    %% Strip the XOR checksum (last byte)
    PayloadSize = byte_size(XData) - 1,
    <<Payload:PayloadSize/binary, _Xor:8>> = XData,
    decode_x_payload(Payload).

%% Track power off broadcast
decode_x_payload(<<16#61, 16#00>>) ->
    {track_power, off};

%% Track power on broadcast
decode_x_payload(<<16#61, 16#01>>) ->
    {track_power, on};

%% Programming mode
decode_x_payload(<<16#61, 16#02>>) ->
    {track_power, programming};

%% Short circuit
decode_x_payload(<<16#61, 16#08>>) ->
    {track_power, short_circuit};

%% Emergency stop
decode_x_payload(<<16#81, 16#00>>) ->
    emergency_stop;

%% Loco info response
decode_x_payload(<<16#EF, AddrHigh:8, AddrLow:8, _SpeedSteps:8,
                   SpeedDir:8, _DB4:8, _DB5:8, _Rest/binary>>) ->
    Address = decode_loco_address(AddrHigh, AddrLow),
    Direction = case SpeedDir band 16#80 of
        16#80 -> forward;
        0 -> reverse
    end,
    Speed = SpeedDir band 16#7F,
    {loco_info, #{
        address => Address,
        speed => Speed,
        direction => Direction
    }};

%% BC stopped (all locos emergency stopped)
decode_x_payload(<<16#81>>) ->
    emergency_stop;

%% Unknown X-Bus message
decode_x_payload(Payload) ->
    {unknown_x, Payload}.

%%====================================================================
%% Internal helpers
%%====================================================================

%% Encode a basic z21 packet (length + header + data)
encode_packet(Header, Data) ->
    Len = 4 + byte_size(Data),
    <<Len:16/little, Header:16/little, Data/binary>>.

%% Encode an X-Bus packet with XOR checksum
encode_x_packet(XHeader, DBs) ->
    Xor = lists:foldl(fun(B, Acc) -> Acc bxor B end, XHeader, DBs),
    Data = list_to_binary([XHeader | DBs] ++ [Xor]),
    encode_packet(?LAN_X, Data).

%% Encode DCC loco address into high/low bytes
%% Addresses 1-127 use short addressing, 128+ use long addressing
encode_loco_address(Address) when Address =< 127 ->
    {16#00, Address};
encode_loco_address(Address) ->
    {16#C0 bor (Address bsr 8), Address band 16#FF}.

%% Decode DCC loco address from high/low bytes
decode_loco_address(AddrHigh, AddrLow) when AddrHigh band 16#C0 =:= 16#C0 ->
    ((AddrHigh band 16#3F) bsl 8) bor AddrLow;
decode_loco_address(_AddrHigh, AddrLow) ->
    AddrLow.

%% Decode central state flags byte
decode_central_state(State) ->
    Flags = [],
    F1 = if State band 16#01 =/= 0 -> [emergency_stop | Flags]; true -> Flags end,
    F2 = if State band 16#02 =/= 0 -> [track_voltage_off | F1]; true -> F1 end,
    F3 = if State band 16#04 =/= 0 -> [short_circuit | F2]; true -> F2 end,
    F4 = if State band 16#08 =/= 0 -> [programming_mode | F3]; true -> F3 end,
    F4.
