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

%%====================================================================
%% Power command parsing tests
%%====================================================================

parse_power_on_test() ->
    ?assertEqual({ok, power_on}, mqtt_bridge:parse_power_command(<<"on">>)).

parse_power_off_test() ->
    ?assertEqual({ok, power_off}, mqtt_bridge:parse_power_command(<<"off">>)).

parse_power_emergency_stop_test() ->
    ?assertEqual({ok, emergency_stop}, mqtt_bridge:parse_power_command(<<"emergency_stop">>)).

parse_power_unknown_test() ->
    ?assertEqual({error, unknown}, mqtt_bridge:parse_power_command(<<"bogus">>)).

%%====================================================================
%% Train management command parsing tests
%%====================================================================

parse_trains_add_test() ->
    ?assertEqual({ok, {add, 3}},
        mqtt_bridge:parse_trains_command(<<"{\"action\":\"add\",\"address\":3}">>)).

parse_trains_remove_test() ->
    ?assertEqual({ok, {remove, 7}},
        mqtt_bridge:parse_trains_command(<<"{\"action\":\"remove\",\"address\":7}">>)).

parse_trains_list_test() ->
    ?assertEqual({ok, list},
        mqtt_bridge:parse_trains_command(<<"{\"action\":\"list\"}">>)).

parse_trains_unknown_action_test() ->
    ?assertEqual({error, unknown},
        mqtt_bridge:parse_trains_command(<<"{\"action\":\"fly\"}">>)).

parse_trains_add_non_integer_address_test() ->
    ?assertEqual({error, unknown},
        mqtt_bridge:parse_trains_command(<<"{\"action\":\"add\",\"address\":\"three\"}">>)).

%%====================================================================
%% Per-train command parsing tests
%%====================================================================

parse_train_set_speed_test() ->
    ?assertEqual({ok, {set_speed, 50}},
        mqtt_bridge:parse_train_command(<<"{\"action\":\"set_speed\",\"value\":50}">>)).

parse_train_set_speed_zero_test() ->
    ?assertEqual({ok, {set_speed, 0}},
        mqtt_bridge:parse_train_command(<<"{\"action\":\"set_speed\",\"value\":0}">>)).

parse_train_set_speed_max_test() ->
    ?assertEqual({ok, {set_speed, 126}},
        mqtt_bridge:parse_train_command(<<"{\"action\":\"set_speed\",\"value\":126}">>)).

parse_train_set_speed_too_high_test() ->
    ?assertEqual({error, unknown},
        mqtt_bridge:parse_train_command(<<"{\"action\":\"set_speed\",\"value\":127}">>)).

parse_train_set_speed_negative_test() ->
    ?assertEqual({error, unknown},
        mqtt_bridge:parse_train_command(<<"{\"action\":\"set_speed\",\"value\":-1}">>)).

parse_train_set_direction_forward_test() ->
    ?assertEqual({ok, {set_direction, forward}},
        mqtt_bridge:parse_train_command(<<"{\"action\":\"set_direction\",\"value\":\"forward\"}">>)).

parse_train_set_direction_reverse_test() ->
    ?assertEqual({ok, {set_direction, reverse}},
        mqtt_bridge:parse_train_command(<<"{\"action\":\"set_direction\",\"value\":\"reverse\"}">>)).

parse_train_set_direction_invalid_test() ->
    ?assertEqual({error, unknown},
        mqtt_bridge:parse_train_command(<<"{\"action\":\"set_direction\",\"value\":\"sideways\"}">>)).

parse_train_stop_test() ->
    ?assertEqual({ok, stop},
        mqtt_bridge:parse_train_command(<<"{\"action\":\"stop\"}">>)).

parse_train_emergency_stop_test() ->
    ?assertEqual({ok, emergency_stop},
        mqtt_bridge:parse_train_command(<<"{\"action\":\"emergency_stop\"}">>)).

parse_train_unknown_action_test() ->
    ?assertEqual({error, unknown},
        mqtt_bridge:parse_train_command(<<"{\"action\":\"explode\"}">>)).

%%====================================================================
%% Topic parsing tests
%%====================================================================

parse_topic_train_cmd_test() ->
    ?assertEqual({train_cmd, 3}, mqtt_bridge:parse_topic(<<"layout/trains/3/cmd">>)).

parse_topic_train_cmd_large_address_test() ->
    ?assertEqual({train_cmd, 9999}, mqtt_bridge:parse_topic(<<"layout/trains/9999/cmd">>)).

parse_topic_train_state_not_cmd_test() ->
    ?assertEqual(unknown, mqtt_bridge:parse_topic(<<"layout/trains/3/state">>)).

parse_topic_invalid_address_test() ->
    ?assertEqual(unknown, mqtt_bridge:parse_topic(<<"layout/trains/abc/cmd">>)).

parse_topic_unrelated_test() ->
    ?assertEqual(unknown, mqtt_bridge:parse_topic(<<"some/other/topic">>)).
