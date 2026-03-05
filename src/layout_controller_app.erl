%%%-------------------------------------------------------------------
%% @doc layout_controller public API
%% @end
%%%-------------------------------------------------------------------

-module(layout_controller_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    layout_controller_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
