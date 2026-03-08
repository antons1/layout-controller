-module(mqtt_bridge_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% JSON encoding tests
%%====================================================================

encode_integer_test() ->
    ?assertEqual(<<"42">>, mqtt_bridge:encode_json(42)).

encode_atom_test() ->
    ?assertEqual(<<"\"forward\"">>, mqtt_bridge:encode_json(forward)).

encode_binary_test() ->
    ?assertEqual(<<"\"hello\"">>, mqtt_bridge:encode_json(<<"hello">>)).

encode_empty_list_test() ->
    ?assertEqual(<<"[]">>, mqtt_bridge:encode_json([])).

encode_list_of_integers_test() ->
    ?assertEqual(<<"[1,2,3]">>, mqtt_bridge:encode_json([1, 2, 3])).

encode_empty_map_test() ->
    ?assertEqual(<<"{}">>, mqtt_bridge:encode_json(#{})).

encode_single_field_map_test() ->
    Result = mqtt_bridge:encode_json(#{speed => 50}),
    ?assertEqual(#{<<"speed">> => 50}, json:decode(Result)).

encode_map_roundtrips_through_json_decode_test() ->
    Map = #{address => 3, speed => 50, direction => forward},
    Result = mqtt_bridge:encode_json(Map),
    Decoded = json:decode(Result),
    ?assertEqual(3, maps:get(<<"address">>, Decoded)),
    ?assertEqual(50, maps:get(<<"speed">>, Decoded)),
    ?assertEqual(<<"forward">>, maps:get(<<"direction">>, Decoded)).

encode_nested_list_of_maps_test() ->
    List = [#{address => 3, speed => 50}, #{address => 7, speed => 0}],
    Result = mqtt_bridge:encode_json(List),
    Decoded = json:decode(Result),
    ?assertEqual(2, length(Decoded)),
    [First, Second] = lists:sort(fun(A, B) ->
        maps:get(<<"address">>, A) =< maps:get(<<"address">>, B)
    end, Decoded),
    ?assertEqual(3, maps:get(<<"address">>, First)),
    ?assertEqual(50, maps:get(<<"speed">>, First)),
    ?assertEqual(7, maps:get(<<"address">>, Second)),
    ?assertEqual(0, maps:get(<<"speed">>, Second)).

encode_binary_key_map_test() ->
    Result = mqtt_bridge:encode_json(#{<<"key">> => <<"value">>}),
    ?assertEqual(#{<<"key">> => <<"value">>}, json:decode(Result)).

%%====================================================================
%% Train state encoding tests
%%====================================================================

encode_train_state_full_test() ->
    Info = #{address => 3, speed => 75, direction => reverse},
    Result = mqtt_bridge:encode_train_state(Info),
    Decoded = json:decode(Result),
    ?assertEqual(3, maps:get(<<"address">>, Decoded)),
    ?assertEqual(75, maps:get(<<"speed">>, Decoded)),
    ?assertEqual(<<"reverse">>, maps:get(<<"direction">>, Decoded)).

encode_train_state_defaults_test() ->
    %% Missing speed and direction should default to 0 and forward
    Info = #{address => 5},
    Result = mqtt_bridge:encode_train_state(Info),
    Decoded = json:decode(Result),
    ?assertEqual(5, maps:get(<<"address">>, Decoded)),
    ?assertEqual(0, maps:get(<<"speed">>, Decoded)),
    ?assertEqual(<<"forward">>, maps:get(<<"direction">>, Decoded)).

%%====================================================================
%% JSON decoding tests
%%====================================================================

decode_simple_object_test() ->
    Result = mqtt_bridge:decode_json(<<"{\"action\":\"stop\"}">>),
    ?assertEqual(<<"stop">>, maps:get(<<"action">>, Result)).

decode_object_with_integer_test() ->
    Result = mqtt_bridge:decode_json(<<"{\"action\":\"set_speed\",\"value\":50}">>),
    ?assertEqual(<<"set_speed">>, maps:get(<<"action">>, Result)),
    ?assertEqual(50, maps:get(<<"value">>, Result)).

decode_object_with_string_test() ->
    Result = mqtt_bridge:decode_json(<<"{\"action\":\"set_direction\",\"value\":\"reverse\"}">>),
    ?assertEqual(<<"reverse">>, maps:get(<<"value">>, Result)).

%%====================================================================
%% Topic construction tests
%%====================================================================

train_state_topic_test() ->
    ?assertEqual(<<"layout/trains/3/state">>, mqtt_bridge:train_state_topic(3)).

train_state_topic_large_address_test() ->
    ?assertEqual(<<"layout/trains/9999/state">>, mqtt_bridge:train_state_topic(9999)).
