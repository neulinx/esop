%%%-------------------------------------------------------------------
%%% @author HaiGuiqing <gary@XL59.com>
%%% @copyright (C) 2016, HaiGuiqing
%%% @doc
%%%
%%% @end
%%% Created : 19 Oct 2016 by HaiGuiqing <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(xl_state_test).

-include_lib("eunit/include/eunit.hrl").

%%%-------------------------------------------------------------------
%%% General control.
%%%-------------------------------------------------------------------
unit_test_() ->
    error_logger:tty(false),
    {timeout, 1, [{"Basic access and subscribe", fun test1/0},
                  {"Data traversal", fun test2/0}
                 ]}.

%%%-------------------------------------------------------------------
%% get, put, delete, subscribe, unsubscribe, notify
%%%-------------------------------------------------------------------
test1() ->
    {ok, Pid} = xl_state:start(#{'_io' => hello}),
    {ok, running} = xl_state:call(Pid, {get, '_status'}),
    {ok, Pid} = xl_state:call(Pid, {get, '_pid'}),
    {error, forbidden} = xl_state:call(Pid, {put, a, 1}),
    ok = xl_state:call(Pid, {put, "a", a}),
    {ok, a} = xl_state:call(Pid, {get, "a"}),
    {error, forbidden} = xl_state:call(Pid, {delete, a}),
    ok = xl_state:call(Pid, {delete, "a"}),
    {error, not_found} = xl_state:call(Pid, {get, "a"}),
    {ok, Ref} = xl_state:subscribe(Pid),
    xl_state:notify(Pid, test),
    {Ref, test} = receive
                      Info ->
                          Info
                  end,
    xl_state:unsubscribe(Pid, Ref),
    xl_state:notify(Pid, test),
    timeout = receive
                  Info1 ->
                      Info1
              after
                  10 ->
                      timeout
              end,
    {ok, Ref1} = xl_state:subscribe(Pid),
    xl_state:stop(Pid),
    {Ref1, {stop, {stopped, hello}}} = receive
                                           Notify ->
                                               Notify
                                       end.

%%%-------------------------------------------------------------------
%% Hierarchical Data traversal
%% a1.a2.a3.key = 123
%%%-------------------------------------------------------------------
test2() ->
    D4 = #{"key" => 123},
    D3 = #{"a3" => D4},
    D2 = #{"a2" => D3},
    D1 = #{"a1" => D2},
    {ok, Pid} = xl_state:start(D1),
    {ok, 123} = xl_state:call(Pid, get, ["a1", "a2", "a3", "key"]),
    {ok, D4} = xl_state:call(Pid, get, ["a1", "a2", "a3"]),
    ok = xl_state:call(Pid, {put, 456}, ["a1", "a2", "a3", "key"]),
    {ok, 456} = xl_state:call(Pid, get, ["a1", "a2", "a3", "key"]),
    ok = xl_state:call(Pid, {put, 789}, ["a1", "a2", "key2"]),
    {ok, 789} = xl_state:call(Pid, get, ["a1", "a2", "key2"]),
    ok = xl_state:call(Pid, delete, ["a1", "a2", "key2"]),
    {error, not_found} = xl_state:call(Pid, get, ["a1", "a2", "key2"]),
    ok = xl_state:call(Pid, {put, b1}, ["b1"]),
    {ok, b1} = xl_state:call(Pid, {get, "b1"}),
    {ok, b1} = xl_state:call(Pid, get, ["b1"]),
    ok = xl_state:call(Pid, delete, ["b1"]),
    {error, not_found} = xl_state:call(Pid, get, ["b1"]),
    xl_state:stop(Pid).
