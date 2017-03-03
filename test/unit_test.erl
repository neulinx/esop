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
            {"State behaviors", fun test1/0}],
            %%{"Full coverage test.", fun coverage_test:coverage/0}],
    {timeout, 2, Test}.
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
    {stop, normal, S#{'_sign' => Next}}.

exit(#{'_input' := Input} = S) ->
    S#{'_output' => Input + 1};
exit(State) ->
    State#{'_output' => "Done"}.

subscribe(P) ->
    subscribe(P, self()).

subscribe(P, Pid) ->
    xl:call(P, {subscribe, Pid}).

test1() ->
    S = #{test => 3},
    S1 = xl:create(?MODULE, S),
    {ok, A} = xl:start(S1),
    {ok, world} = gen_server:call(A, hello),
    {ok, 3} = xl:call([A, test], get),
    {ok, Ref} = subscribe(A),
    {stopped, {shutdown, please}} = xl:stop(A, please),
    {exit, #{'_output' := "Done"}} = receive
                                                {Ref, Notify} ->
                                                    Notify
                                            end.

%%-------------------------------------------------------------------
%% get, put, delete, subscribe, unsubscribe, notify
%%-------------------------------------------------------------------
test2() ->
    {ok, Pid} = xl:start(#{'_output' => hello}),
    {ok, running} = xl:call([Pid, '_status'], get),
    {ok, Pid} = xl:call([Pid, '_pid'], get),
    {ok, done} = xl:call([Pid, "a"], {put, a}),
    {ok, a} = xl:call([Pid, "a"], get),
    {ok, done} = xl:call([Pid, "a"], delete),
    {error, undefined} = xl:call([Pid, "a"], get),
    {ok, Ref} = subscribe(Pid),
    xl:notify(Pid, test),
    test = receive
               {Ref, Info} ->
                   Info
           end,
    xl:cast(Pid, {unsubscribe, Ref}),
    xl:notify(Pid, test),
    timeout = receive
                  _ ->
                      ignore_coverage
              after
                  10 ->
                      timeout
              end,
    {ok, Ref1} = subscribe(Pid),
    {ok, done} = xl:call(Pid, {unsubscribe, Ref1}),
    {ok, Subscriber} = xl:start(#{}),
    {ok, Ref2} = subscribe(Pid, Subscriber),
    {ok, Subs} = xl:call([Pid, '_subscribers'], get),
    Subscriber = maps:get(Ref2, Subs),
    {stopped, normal} = xl:stop(Subscriber),
    {ok, #{}} = xl:call([Pid, '_subscribers'], get),
    {ok, Ref3} = subscribe(Pid),
    {stopped, normal} = xl:stop(Pid),
    {exit, #{'_output' := hello}} = receive
                                        {Ref3, Notify} ->
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
    {ok, b1} = xl:call([Pid, "b1"], get),
    {ok, done} = xl:call([Pid, "b1"], delete),
    {error, undefined} = xl:call([Pid, "b1"], get).

%%-------------------------------------------------------------------
%% Hierarchical Data traversal, active attribute version.
%% a1.a2.a3.key = 123
%%-------------------------------------------------------------------
test4() ->
    Entry = fun(#{'_parent' := P} = S) ->
                    {ok, done, S1} = xl:request([reg], {put, {process, P}}, S),
                    {ok, S1}
            end,
    A1 = #{name => a1,
           '_entry' => Entry,
           '_states' => #{"a2" => {refer, [reg, 2]}}},
    A2 = #{name => a2,
 %%        reg => {link, realm, undefined},
           '_states' => #{"a3" => {refer, [reg, 3]},
                          reg => {process, realm}}},
    A3 = #{name => a3,
           '_output' => a3_test,
           "key" => 123},
    F = fun({xlx, From, [], {get, Key}}, State) ->
                Raw = maps:get(Key, State, undefined),
                xl:reply(From, {ok, {raw, Raw}}),
                {noreply, State}
        end,
    Links = #{"a1" => {state, A1},
              2 => {state, A2},
              3 => {state, A3},
              f => {function, F}},
    Realm = #{name => realm, '_states' => Links},
    {ok, R} = xl:start({local, realm}, Realm, []),
    test_path(R),
    {ok, done} = xl:call([R, 2], {put, {function, F}}),
    {ok, {raw, realm}} = xl:call([R, f], {get, name}),
    {ok, {raw, realm}} = xl:call([R, 2], {get, name}),
    {ok, done} = xl:call([R, 2], delete),
    {ok, M1} = subscribe([R, "a1", "a2", "a3"]),
    {stopped, normal} = xl:stop(R),
    {exit, #{'_output' := a3_test}} = receive
                                          {M1, Notify} ->
                                              Notify
                                      end.

%%-------------------------------------------------------------------
%% Simple FSM
%% t1 -> t2 -> t3 -> stop
%%-------------------------------------------------------------------
test5() ->
    Exit = fun exit/1,
    T1 = #{'_id' => t1, '_sign' => t2, '_exit' => Exit},
    T2 = #{'_id' => t2, '_sign' => {t3}, '_exit' => Exit},
    T3 = #{'_id' => t3, '_exit' => Exit},  % '_sign' => stop
    States = #{{<<"start">>} => T1, {t1, t2} => T2, {t3} => T3},
    StartState = #{'_output' => 0, '_sign' => {<<"start">>}},
    Fsm = #{'_state' => StartState,
            '_id' => fsm,
            '_states' => States},
    test5(Fsm),
    F = fun({xlx,_, [Vector], touch}, S) ->
                case maps:find(Vector, States) of
                    {ok, State} ->
                        {data, State, S};
                    error ->
                        {error, undefined, S}
                end
        end,
    Fsm2 = #{'_state' => StartState,
             '_id' => fsm,
             '_states' => {function, F}},
    test5(Fsm2),
    P = #{'_states' => {function, F}},
    Fsm3 = #{'_state' => StartState,
             '_id' => fsm,
             '_states' => {state, P}},
    test5(Fsm3).

test5(Fsm) ->
    {ok, F} = xl:start(Fsm),
    {ok, t1} = xl:call([F, <<>>, '_id'], get),
    {ok, fsm} = xl:call([F, '_id'], get),
    {ok, done} = xl:call([F, <<>>], xl_stop),
    {ok, t2} = xl:call([F, '_state', '_id'], get),
    {ok, done} = xl:call([F, <<>>], xl_stop),
    {ok, t3} = xl:call([F, <<>>, '_id'], get),
    {ok, Ref} = subscribe(F),
    {ok, done} = xl:call([F, <<>>], xl_stop),
    {exit, #{'_output' := 3}} = receive
                                    {Ref, Notify} ->
                                        Notify
                                end.

%%-------------------------------------------------------------------
%% Recovery for active attribute.
%%-------------------------------------------------------------------
test6() ->
    React = fun react/2,
    A = #{name => a, '_react' => React},
    B = #{name => b, '_react' => React, '_recovery' => <<"restart">>},
    Links = #{a => {state, A}, b => {state, B}},
    Actor = #{name => actor, '_states' => Links},
    {ok, Pid} = xl:start(Actor),
    %% ==== default recovery mode, heal on-demand.
    {ok, actor} = xl:call([Pid, name], get),
    {ok, a} = xl:call([Pid, a, name], get),
    xl:cast([Pid, a], crash),
    timer:sleep(5),
    {error, undefined} = xl:call([Pid, a], get_raw),
    {ok, a} = xl:call([Pid, a, name], get),
    %% ==== "restart" recovery mode, heal immediately.
    {ok, b} = xl:call([Pid, b, name], get),
    xl:cast([Pid, b], crash),
    timer:sleep(5),
    {ok, {link, _, _}} = xl:call([Pid, b], get_raw),
    {ok, b} = xl:call([Pid, b, name], get),
    {stopped, normal} = xl:stop(Pid).

%%-------------------------------------------------------------------
%% Recovery for FSM
%% start -> a -> b -> c -> d -> stop
%% a.recovery -> c,
%% b.recovery -> undefined, default is FSM '_recovery'.
%% c.recovery -> -2,
%% d.recovary -> restart 
%%-------------------------------------------------------------------
dump_info() ->
    receive
        stop ->
            ok;
        Info ->
            ?debugVal(Info),
            dump_info()
    end.

test7() ->
    A0 = #{'_id' => a, next => 1, '_recovery' => {c}},
    B0 = #{'_id' => b, next => {c}},
    C0 = #{'_id' => c, next => {2}, '_recovery' => -2},
    D0 = #{'_id' => d, '_recovery' => <<"restart">>},
    A = xl:create(?MODULE, A0),
    B = xl:create(?MODULE, B0),
    C = xl:create(?MODULE, C0),
    D = xl:create(?MODULE, D0),
    States = #{'_state' => #{'_output' => 0, '_sign' => {start}},
               {start} => A,
               {a, 1} => B,
               {c} => C,
               {2} => D},
    React = fun({xlx, _, _, {max_pending_size, Size}}, S) ->
                    {ok, done, S#{'_max_pending_size' => Size}}
            end,
    Fsm = #{'_react' => React,
            '_recovery' => <<"rollback">>,
            '_traces' => [],
            '_max_retry' => 4,
            '_id' => fsm,
            '_states' => States},

    %% ==== subscribe ====
    Dump = spawn(fun dump_info/0),
    %% ==== normal loop ====
    {ok, F} = xl:start(Fsm),
    subscribe(F, Dump),
    {ok, a} = xl:call([F, <<>>, '_id'], get),
    xl:cast([F, <<>>], transfer),
    {ok, b} = xl:call([F, <<>>, '_id'], get),
    xl:cast([F, <<>>], transfer),
    {ok, c} = xl:call([F, <<>>, '_id'], get),
    xl:cast([F, <<>>], transfer),
    {ok, d} = xl:call([F, <<>>, '_id'], get),
    {error, undefined} = xl:call([F, '_retry_count'], get),
    %% Traces = xl:call(F, {get, '_traces'}, [<<".">>]),
    %% ?debugVal(Traces),
    {ok, 4} = xl:call([F, '_step'], get),
    %% stop
    {ok, Ref} = xl:call([F, <<>>], {subscribe, self()}),
    xl:cast([F, <<>>], transfer),
    {exit, Res} = receive
                      {Ref, Notify} ->
                          Notify
                  end,
    #{'_output' := 4, '_id' := d} = Res,
    %% ==== recovery loop ====
    {ok, F1} = xl:start(Fsm#{'_max_pending_size' => 0}),
    subscribe(F1, Dump),
    {ok, a} = xl:call([F1, <<>>, '_id'], get),
    xl:cast([F1, <<>>], crash),  % => c
    {error, timeout} = xl:call([F1, <<>>, '_id'], get, 10),
    {ok, done} = xl:call(F1, {max_pending_size, 100}),
    {ok, c} = xl:call([F1, <<>>, '_id'], get),
    xl:cast([F1, <<>>], transfer),
    {ok, d} = xl:call([F1, <<>>, '_id'], get),
    xl:cast([F1, <<>>], crash),  % => restart
    {ok, a} = xl:call([F1, <<>>, '_id'], get),
    xl:cast([F1, <<>>], transfer),
    {ok, b} = xl:call([F1, <<>>, '_id'], get),
    xl:cast([F1, <<>>], crash),  % => rollback
    {ok, b} = xl:call([F1, <<>>, '_id'], get),
    xl:cast([F1, <<>>], transfer),  % => c
    {ok, c} = xl:call([F1, <<>>, '_id'], get),
    xl:cast([F1, <<>>], crash),  % => rollback -2
    {ok, c} = xl:call([F1, <<>>, '_id'], get),
    {ok, 12} = xl:call([F1, '_step'], get),
    {ok, 4} = xl:call([F1, '_retry_count'], get),
    {ok, Ref1} = xl:call(F1, {subscribe, self()}),
    %% Traces = xl:call(F1, {get, '_traces'}, [<<".">>]),
    %% ?debugVal(Traces),
    xl:cast([F1, <<>>], crash),  % => exceed max retry count
    {exit, Res1} = receive
                       {Ref1, Notify1} ->
                           Notify1
                   end,
    #{'_output' := 3, '_id' := fsm} = Res1.
