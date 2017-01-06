%%%-------------------------------------------------------------------
%%% @author HaiGuiqing <gary@XL59.com>
%%% @copyright (C) 2016, HaiGuiqing
%%% @doc
%%%
%%% @end
%%% Created : 19 Oct 2016 by HaiGuiqing <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(unit_test).

-compile({no_auto_import,[exit/1]}).

-export([entry/1, react/2, exit/1]).

-include_lib("eunit/include/eunit.hrl").

%%-------------------------------------------------------------------
%% General control.
%%-------------------------------------------------------------------
unit_test_() ->
    error_logger:tty(false),
    Test = [{"Recovery for FSM", fun test7/0},
            {"Recovery for active attribute", fun test6/0},
            {"Simple FSM", fun test5/0},
            {"Active attribute", fun test4/0},
            {"Data traversal", fun test3/0},
            {"Basic access and subscribe", fun test2/0},
            {"State behaviors", fun test1/0},
            {"Full coverage test.", fun coverage_test:coverage/0}],
    {timeout, 5, Test}.
%%    {timeout, 2, []}.

%%-------------------------------------------------------------------
%% Behaviours
%%-------------------------------------------------------------------
entry(State) ->
    {ok, State#{hello => world}}.

react({xlx, _From, [], hello}, State) ->
    Response = maps:get(hello, State),
    {ok, Response, State};
react({xlx, _, _, crash}, _S) ->
    error(crash);
react({xlx, _, _, transfer}, S) ->
    Next = maps:get(next, S, stop),
    {stop, normal, S#{'_sign' => Next}};
react(_, State) ->
    {ok, unhandled, State}.

exit(#{'_input' := Input} = S) ->
    S#{'_output' => Input + 1};
exit(State) ->
    State#{'_output' => "Done"}.

test1() ->
    S = #{test => 3},
    S1 = xl:create(?MODULE, S),
    {ok, A} = xl:start(S1),
    {ok, world} = xl:call(A, hello),
    {ok, 3} = gen_server:call(A, {get, test}),
    {ok, Ref} = xl:subscribe(A),
    {stopped, {shutdown, please}} = xl:stop(A, please),
    {Ref, {exit, #{'_output' := "Done"}}} = receive
                                                Notify ->
                                                    Notify
                                            end.

%%-------------------------------------------------------------------
%% get, put, delete, subscribe, unsubscribe, notify
%%-------------------------------------------------------------------
test2() ->
    {ok, Pid} = xl:start(#{'_output' => hello}),
    {ok, running} = xl:call(Pid, {get, '_status'}),
    {ok, Pid} = xl:call(Pid, {get, '_pid'}),
    {error, forbidden} = xl:call(Pid, {put, a, 1}),
    {ok, done} = xl:call(Pid, {put, "a", a}),
    {ok, a} = xl:call(Pid, {get, "a"}),
    {error, forbidden} = xl:call(Pid, {delete, a}),
    {ok, done} = xl:call(Pid, {delete, "a"}),
    {error, undefined} = xl:call(Pid, {get, "a"}),
    {ok, Ref} = xl:subscribe(Pid),
    xl:notify(Pid, test),
    {Ref, test} = receive
                      Info ->
                          Info
                  end,
    xl:unsubscribe(Pid, Ref),
    xl:notify(Pid, test),
    timeout = receive
                  Info1 ->
                      Info1
              after
                  10 ->
                      timeout
              end,
    {ok, Ref1} = xl:subscribe(Pid),
    {ok, done} = xl:call(Pid, {unsubscribe, Ref1}),
    {ok, Subscriber} = xl:start(#{}),
    {ok, Ref2} = xl:subscribe(Pid, Subscriber),
    {ok, Subs} = xl:call(Pid, {get, '_subscribers'}),
    Subscriber = maps:get(Ref2, Subs),
    {stopped, normal} = xl:stop(Subscriber),
    {ok, #{}} = xl:call(Pid, {get, '_subscribers'}),
    {ok, Ref3} = xl:subscribe(Pid),
    {stopped, normal} = xl:stop(Pid),
    {Ref3, {exit, #{'_output' := hello}}} = receive
                                                Notify ->
                                                    Notify
                                            end.

%%-------------------------------------------------------------------
%% Hierarchical Data traversal
%% a1.a2.a3.key = 123
%%-------------------------------------------------------------------
test3() ->
    D4 = #{"key" => 123},
    D3 = #{"a3" => D4},
    D2 = #{"a2" => D3},
    D1 = #{"a1" => D2},
    {ok, Pid} = xl:start(D1),
    test_path(Pid),
    {stopped, normal} = xl:stop(Pid).

test_path(Pid) ->
    {ok, 123} = xl:call([Pid, "a1", "a2", "a3", "key"], get, 10),
    {ok, #{"key" := 123}} = xl:call([Pid, "a1", "a2", "a3"], get),
    {ok, done} = xl:call([Pid, "a1", "a2", "a3", "key"], {put, 456}),
    {ok, 456} = xl:call([Pid, "a1", "a2", "a3", "key"], get),
    {ok, done} = xl:call([Pid, "a1", "a2", "key2"], {put, 789}),
    {ok, 789} = xl:call([Pid, "a1", "a2", "key2"], get),
    {ok, done} = xl:call([Pid, "a1", "a2", "key2"], delete),
    {error, undefined} = xl:call([Pid, "a1", "a2", "key2"], get),
    {ok, done} = xl:call([Pid, "b1"], {put, b1}),
    {ok, b1} = xl:call(Pid, {get, "b1"}),
    {ok, b1} = xl:call([Pid, "b1"], get),
    {ok, done} = xl:call([Pid, "b1"], delete),
    {error, undefined} = xl:call([Pid, "b1"], get).

%%-------------------------------------------------------------------
%% Hierarchical Data traversal, active attribute version.
%% a1.a2.a3.key = 123
%%-------------------------------------------------------------------
test4() ->
    Entry = fun(#{'_parent' := P} = S) ->
                    {ok, done, S1} = xl:put(reg, {process, P}, S),
                    {ok, S1}
            end,
    A1 = #{name => a1,
           '_entry' => Entry,
           '_states' => #{"a2" => {ref, reg, 2}}},
    A2 = #{name => a2,
 %%        reg => {link, realm, undefined},
           '_states' => #{"a3" => {ref, reg, 3},
                          reg => {process, realm}}},
    A3 = #{name => a3,
           '_output' => a3_test,
           "key" => 123},
    F = fun({xlx, From, [], {get, Key}}, State) ->
                Raw = maps:get(Key, State, undefined),
                xl:reply(From, {ok, {raw, Raw}}),
                {ok, State}
        end,
    Links = #{"a1" => {state, A1},
              2 => {state, A2},
              3 => {state, A3},
              f => {function, F}},
    Realm = #{name => realm, '_states' => Links},
    {ok, R} = xl:start({local, realm}, Realm, []),
    test_path(R),
    {ok, done} = xl:call(R, {put, 2, {function, F}}),
    {ok, {raw, realm}} = xl:call([R, f], {get, name}),
    {ok, {raw, realm}} = xl:call([R, 2], {get, name}),
    {ok, done} = xl:call(R, {delete, 2}),
    {ok, M1} = xl:subscribe([R, "a1", "a2", "a3"]),
    {stopped, normal} = xl:stop(R),
    {M1, {exit, #{'_output' := a3_test}}} = receive
                                                Notify ->
                                                    Notify
                                            end.

%%-------------------------------------------------------------------
%% Simple FSM
%% t1 -> t2 -> t3 -> stop
%%-------------------------------------------------------------------
test5() ->
    Exit = fun exit/1,
    T1 = #{<<"_name">> => t1, '_sign' => t2, '_exit' => Exit},
    T2 = #{<<"_name">> => t2, '_sign' => t3, '_exit' => Exit},
    T3 = #{<<"_name">> => t3, '_exit' => Exit},  % '_sign' => stop
    States = #{{<<"start">>} => T1, {t1, t2} => T2, {t3} => T3},
    StartState = #{<<"input">> => 0, <<"sign">> => [<<"start">>]},
    Fsm = #{<<"_state">> => StartState,
            <<"_name">> => fsm,
            '_states' => States},
    test5(Fsm),
    F = fun(Vector, S) ->
                case maps:find(Vector, States) of
                    {ok, State} ->
                        {data, State, S};
                    error when is_tuple(Vector) ->
                        {_, Global} = Vector,
                        {data, maps:get({Global}, States), S};
                    error ->
                        {error, undefined, S}
                end
        end,
    Fsm2 = #{<<"_state">> => StartState,
             <<"_name">> => fsm,
             '_states' => {function, F}},
    test5(Fsm2),
    P = #{'_states' => {function, F}},
    Fsm3 = #{<<"_state">> => StartState,
             <<"_name">> => fsm,
             '_states' => {state, P}},
    test5(Fsm3).


test5(Fsm) ->
    {ok, F} = xl:start(Fsm),
    {ok, t1} = xl:call(F, {get, <<"_name">>}),
    {ok, fsm} = xl:call([F, <<".">>], {get, <<"_name">>}),
    {ok, done} = xl:call(F, xl_stop),
    {ok, t2} = xl:call(F, {get, <<"_name">>}),
    {ok, done} = xl:call(F, xl_stop),
    {ok, t3} = xl:call(F, {get, <<"_name">>}),
    {ok, Ref} = xl:subscribe(F),
    {ok, done} = xl:call(F, xl_stop),
    {Ref, {exit, #{'_output' := 3}}} = receive
                                           Notify ->
                                               Notify
                                       end.

%%-------------------------------------------------------------------
%% Recovery for active attribute.
%%-------------------------------------------------------------------
test6() ->
    React = fun react/2,
    A = #{name => a, '_react' => React},
    B = #{name => b, '_react' => React, <<"_recovery">> => <<"restart">>},
    Links = #{a => {state, A}, b => {state, B}},
    Actor = #{name => actor, '_states' => Links},
    {ok, Pid} = xl:start(Actor),
    %% ==== default recovery mode, heal on-demand.
    {ok, actor} = xl:call(Pid, {get, name}),
    {ok, a} = xl:call([Pid, a, name], get),
    xl:cast([Pid, a], crash),
    timer:sleep(5),
    {error, undefined} = xl:call(Pid, {get, a, raw}),
    {ok, a} = xl:call([Pid, a, name], get),
    %% ==== "restart" recovery mode, heal immediately.
    {ok, b} = xl:call([Pid, b, name], get),
    xl:cast([Pid, b], crash),
    timer:sleep(5),
    {ok, {link, _, _}} = xl:call(Pid, {get, b, raw}),
    {ok, b} = xl:call([Pid, b, name], get),
    {stopped, normal} = xl:stop(Pid).

%%-------------------------------------------------------------------
%% Recovery for FSM
%% start -> a -> b -> c -> d -> stop
%% a.recovery -> c,
%% b.recovery -> undefined, default is FSM <<"_recovery">>.
%% c.recovery -> -2,
%% d.recovary -> restart 
%%-------------------------------------------------------------------
%% dump_info() ->
%%     receive
%%         stop ->
%%             ok;
%%         Info ->
%%             ?debugVal(Info),
%%             dump_info()
%%     end.

test7() ->
    A0 = #{<<"_name">> => a, next => 1, <<"_recovery">> => {c}},
    B0 = #{<<"_name">> => b, next => c},
    C0 = #{<<"_name">> => c, next => {2}, <<"_recovery">> => -2},
    D0 = #{<<"_name">> => d, <<"_recovery">> => <<"restart">>},
    A = xl:create(?MODULE, A0),
    B = xl:create(?MODULE, B0),
    C = xl:create(?MODULE, C0),
    D = xl:create(?MODULE, D0),
    States = #{'_state' => {data, {0, start}},
               {start} => A,
               {a, 1} => B,
               {c} => C,
               {2} => D},
    Fsm = #{<<"_recovery">> => <<"rollback">>,
            '_traces' => [],
            <<"_max_retry">> => 4,
            <<"_name">> => fsm,
            '_states' => States},

    %% ==== subscribe ====
    %% Dump = spawn(fun dump_info/0),
    %% ==== normal loop ====
    {ok, F} = xl:start(Fsm),
    %% xl:subscribe([F, <<".">>], Dump),
    {ok, a} = xl:call(F, {get, <<"_name">>}),
    xl:cast(F, transfer),
    {ok, b} = xl:call(F, {get, <<"_name">>}),
    xl:cast(F, transfer),
    {ok, c} = xl:call(F, {get, <<"_name">>}),
    xl:cast(F, transfer),
    {ok, d} = xl:call(F, {get, <<"_name">>}),
    {error, undefined} = xl:call([F, <<".">>], {get, '_retry_count'}),
    %% Traces = xl:call(F, {get, '_traces'}, [<<".">>]),
    %% ?debugVal(Traces),
    {ok, 4} = xl:call([F, <<".">>], {get, '_step'}),
    %% stop
    {ok, Ref} = xl:subscribe(F),
    xl:cast(F, transfer),
    {Ref, {exit, Res}} = receive
                             Notify ->
                                 Notify
                         end,
    #{'_output' := 4, <<"_name">> := d} = Res,
    %% ==== recovery loop ====
    {ok, F1} = xl:start(Fsm#{<<"_max_pending_size">> => 0}),
    %% xl:subscribe([F1, <<".">>], Dump),
    {ok, a} = xl:call(F1, {get, <<"_name">>}),
    xl:cast(F1, crash),  % => c
    {error, timeout} = xl:call(F1, {get, <<"_name">>}, 10),
    {ok, c} = xl:call(F1, {get, <<"_name">>}),
    xl:cast(F1, transfer),
    {ok, d} = xl:call(F1, {get, <<"_name">>}),
    {ok, done} = xl:call([F1, <<".">>], {put, <<"_max_pending_size">>, 100}),
    xl:cast(F1, crash),  % => restart
    {ok, a} = xl:call(F1, {get, <<"_name">>}),
    xl:cast(F1, transfer),
    {ok, b} = xl:call(F1, {get, <<"_name">>}),
    xl:cast(F1, crash),  % => rollback
    {ok, b} = xl:call(F1, {get, <<"_name">>}),
    xl:cast(F1, transfer),  % => c
    {ok, c} = xl:call(F1, {get, <<"_name">>}),
    xl:cast(F1, crash),  % => rollback -2
    {ok, c} = xl:call(F1, {get, <<"_name">>}),
    {ok, 12} = xl:call([F1, <<".">>], {get, '_step'}),
    {ok, 4} = xl:call([F1, <<".">>], {get, '_retry_count'}),
    {ok, Ref1} = xl:subscribe([F1, <<".">>]),
    %% Traces = xl:call(F1, {get, '_traces'}, [<<".">>]),
    %% ?debugVal(Traces),
    xl:cast(F1, crash),  % => exceed max retry count
    {Ref1, {exit, Res1}} = receive
                               Notify1 ->
                                   Notify1
                           end,
    #{'_output' := 3, <<"_name">> := fsm} = Res1.
