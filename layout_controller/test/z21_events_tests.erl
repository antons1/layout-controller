-module(z21_events_tests).

-include_lib("eunit/include/eunit.hrl").

%% All tests run within a setup/teardown that starts and stops z21_events.
z21_events_test_() ->
    {foreach,
     fun setup/0,
     fun teardown/1,
     [
         fun subscribe_receives_events/0,
         fun unsubscribed_process_gets_no_events/0,
         fun multiple_subscribers/0,
         fun duplicate_subscribe_is_ok/0,
         fun unsubscribe_stops_events/0,
         fun subscriber_crash_cleanup/0
     ]}.

setup() ->
    {ok, Pid} = z21_events:start_link(),
    Pid.

teardown(Pid) ->
    unlink(Pid),
    MonRef = monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', MonRef, process, Pid, _} -> ok
    after 5000 -> error(teardown_timeout)
    end.

subscribe_receives_events() ->
    ok = z21_events:subscribe(),
    z21_events:notify({track_power, on}),
    receive
        {z21_event, {track_power, on}} -> ok
    after 1000 ->
        ?assert(false)
    end.

unsubscribed_process_gets_no_events() ->
    %% Don't subscribe, just notify
    z21_events:notify({track_power, off}),
    receive
        {z21_event, _} -> ?assert(false)
    after 100 ->
        ok
    end.

multiple_subscribers() ->
    Self = self(),
    ok = z21_events:subscribe(),
    %% Spawn a second subscriber that forwards events to us
    Pid = spawn_link(fun() ->
        ok = z21_events:subscribe(),
        receive
            {z21_event, Event} -> Self ! {from_other, Event}
        end
    end),
    %% Give the spawned process time to subscribe
    timer:sleep(50),
    z21_events:notify(test_event),
    receive {z21_event, test_event} -> ok
    after 1000 -> ?assert(false) end,
    receive {from_other, test_event} -> ok
    after 1000 -> ?assert(false) end,
    %% Clean up - Pid will have exited after receiving
    _ = Pid,
    ok.

duplicate_subscribe_is_ok() ->
    ok = z21_events:subscribe(),
    ok = z21_events:subscribe(),
    z21_events:notify(dup_test),
    receive {z21_event, dup_test} -> ok
    after 1000 -> ?assert(false) end,
    %% Should only get one copy
    receive {z21_event, dup_test} -> ?assert(false)
    after 100 -> ok end.

unsubscribe_stops_events() ->
    ok = z21_events:subscribe(),
    ok = z21_events:unsubscribe(),
    z21_events:notify(should_not_arrive),
    receive {z21_event, _} -> ?assert(false)
    after 100 -> ok end.

subscriber_crash_cleanup() ->
    Self = self(),
    %% Spawn a process that subscribes then exits
    Pid = spawn(fun() ->
        ok = z21_events:subscribe(),
        Self ! subscribed,
        %% Exit normally
        ok
    end),
    receive subscribed -> ok
    after 1000 -> ?assert(false) end,
    %% Wait for the process to exit and the DOWN monitor to fire
    timer:sleep(100),
    %% Verify the dead process doesn't cause issues when notifying
    z21_events:notify(after_crash),
    %% Subscribe ourselves and verify events still work
    ok = z21_events:subscribe(),
    z21_events:notify(still_works),
    receive {z21_event, still_works} -> ok
    after 1000 -> ?assert(false) end,
    _ = Pid,
    ok.
