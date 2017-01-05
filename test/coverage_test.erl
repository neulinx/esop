%%%-------------------------------------------------------------------
%%% @author HaiGuiqing <gary@XL59.com>
%%% @copyright (C) 2016, HaiGuiqing
%%% @doc
%%%
%%% @end
%%% Created : 25 Dec 2016 by HaiGuiqing <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(coverage_test).

-export([create/1, coverage/0]).

-include_lib("eunit/include/eunit.hrl").

create(Data) ->
    Data#{test => yes}.

coverage() ->
    {ok, P1} = xl:start_link(undefined, #{<<"_timeout">> => 1000}, []),
    {stopped, normal} = xl:stop(P1),

    xl:start_link({local, p2}, #{}, []),
    {stopped, normal} = xl:stop(p2),

    {ok, P3} = xl:start(undefined, #{}, []),
    {stopped, normal} = xl:stop(P3),

    #{test := yes} = xl:create(?MODULE),
    S1 = xl:create(xyz, [{a, 1}]),
    1 = maps:get(a, S1),
    {ok, P4} = xl:start(S1),
    Tag = make_ref(),
    P4 ! {xlx, {self(), Tag}, {subscribe, self()}},
    R1 = receive
             {Tag, {ok, R}} ->
                 R
         end,
    ok = gen_server:cast(P4, timeout),
    {status,runnable} = process_info(P4, status),
    {ok, 1} = xl:call(P4, {get, a}),
    {status,waiting} = process_info(P4, status),
    ok = gen_server:cast(P4, {xl_stop, {shutdown, test}}),
    receive
        {R1, _} ->
            ok
    end,

    F1 = fun(xl_wakeup, #{parent := Parent} = S) ->
                 Parent ! xl_wakeup,
                 {ok, S};
            (_, S) ->
                 {ok, unhandled, S}
         end,
    {ok, P5} = xl:start(#{parent => self(),
                          '_react' => F1,
                          '_status' => running}),
    receive
        xl_wakeup ->
            ok
    end,
    {stopped, normal} = xl:stop(P5),

    F2 = fun(S) -> {ok, S, 1} end,

    {ok, P6} = xl:start(#{'_entry' => F2, b => 2}),
    timer:sleep(5),
    {ok, 2} = xl:call(P6, {get, b}),
    {stopped, normal} = xl:stop(P6),

    F3 = fun(S) -> {stop, normal, S} end,
    {error, normal} = xl:start(#{'_entry' => F3}),

    {error, {{preload_failure, undefined}, _}} =
        xl:start(#{<<"_preload">> => [a]}),

    {ok, P7} = xl:start(#{}),
    L1 = #{'_state' => {process, P7}},
    {ok, P8} = xl:start(#{'_states' => L1,
                          <<"_preload">> => ['_state']}),
    {ok, R2} = xl:subscribe([P8, <<".">>]),
    {ok, done} = gen_server:call(P7, {xl_stop, normal}),
    receive
        {R2, _} ->
            ok
    end,

    M1 = #{'_entry' => F2, '_state' => {data, {[], start}}},
    {error, normal} = xl:start(M1),

    M2 = #{'_states' => {state, #{}}, '_state' => {data, {[], start}}},
    {error,{shutdown,incurable}} = xl:start(M2),

    {ok, P9} = xl:start(#{}),
    {ok, R3} = xl:subscribe(P9),
    ok = gen_server:cast(P9, xl_stop),
    receive
        {R3, _} ->
            ok
    end,

    F4 = fun({xl_stop, _}, S) ->
                 {ok, S};
            (_, S) ->
                 {ok, unhandled, S}
         end,
    {ok, P10} = xl:start(#{'_react' => F4}),
    {ok, R4} = xl:subscribe(P10),
    ok = gen_server:cast(P10, {xl_stop, normal}),
    receive
        {R4, _} ->
            ok
    end,

    F5 = fun({xl_stop, _}, S) ->
                 {ok, done, S};
            (xl_hibernate, S) ->
                 {ok, done, S};
            (test, S) ->
                 {stop, S};
            (test2, S) ->
                 {stop, normal, stop, S};
            ({test, Pid}, S) ->
                 Pid ! ok,
                 {ok, done, S};

            (_, S) ->
                 {ok, unhandled, S}
         end,

    {ok, P11} = xl:start(#{'_react' => F5}),
    {ok, R5} = xl:subscribe(P11),
    ok = gen_server:cast(P11, {xl_stop, normal}),
    receive
        {R5, _} ->
            ok
    end,

    {ok, P12} = xl:start(#{'_react' => F5}),
    ok = gen_server:cast(P12, xl_hibernate),
    {stopped, normal} = xl:stop(P12),

    {ok, P13} = xl:start(#{'_react' => F5}),
    {ok, R6} = xl:subscribe(P13),
    ok = gen_server:cast(P13, test),
    receive
        {R6, _} ->
            ok
    end,

    {ok, P14} = xl:start(#{'_react' => F5, <<"_hibernate">> => 10}),
    {error, unknown} = gen_server:call(P14, hello),
    ok = gen_server:cast(P14, {xl_leave, test}),
    ok = gen_server:cast(P14, {test, self()}),
    receive
        ok ->
            ok
    end,
    {ok, R7} = xl:subscribe(P14),
    ok = gen_server:cast(P14, test2),
    receive
        {R7, _} ->
            ok
    end,

    M3 = #{'_states' => #{},
           name => m3,
           <<"_aftermath">> => <<"halt">>,
           '_state' => #{}},
    {ok, P15} = xl:start(M3),
    ok = xl:cast([P15, '_state'], xl_stop),
    {ok, m3} = xl:call(P15, {get, name}),
    {error, undefined} = xl:call(P15, {get, '_state'}),
    {stopped, normal} = xl:stop(P15),

    M4 = #{'_states' => #{},
           name => m4,
           '_state' => #{'_sign' => halt}},
    {ok, P16} = xl:start(M4),
    ok = xl:cast([P16, '_state'], xl_stop),
    {ok, m4} = xl:call(P16, {get, name}),
    {ok, halt} = xl:call(P16, {get, '_status'}),
    {stopped, normal} = xl:stop(P16),

    M5 = #{'_states' => #{{start} => #{'_sign' => start}},
           <<"_max_steps">> => 2,
           <<"_aftermath">> => <<"halt">>,
           '_state' => {[], start}},
    {ok, P17} = xl:start(M5),
    {ok, done} = xl:call(P17, xl_stop),
    {ok, 2} = xl:call([P17, <<".">>], {get, '_step'}),
    {ok, done} = xl:call(P17, xl_stop),
    {ok, 3} = xl:call(P17, {get, '_step'}),
    {ok, halt} = xl:call(P17, {get, '_status'}),
    {stopped, normal} = xl:stop(P17),


    F18 = fun({log, Trace}, Fsm) ->
                  Logs = maps:get(logs, Fsm, []),
                  {ok, done, Fsm#{logs => [Trace | Logs]}};
             ({backtrack, Back}, #{logs := Logs} = Fsm) ->
                  History = lists:nth(-Back, Logs),
                  {ok, History, Fsm}
          end,
    S18 = #{'_sign' => exception},
    M18 = #{'_states' => #{{start} => S18, '_traces' => {function, F18}},
            <<"_recovery">> => -2,
            '_state' => {[], start}},
    {ok, P18} = xl:start(M18),
    {ok, done} = xl:call(P18, xl_stop),
    {ok, [S18, {[],start}]} = xl:call([P18, <<".">>], {get, logs}),
    {ok, done} = xl:call(P18, xl_stop),
    {ok, exception} = xl:call(P18, {get, '_sign'}),
    {ok, 2} = xl:call([P18, <<".">>], {get, '_retry_count'}),
    {ok, 5} = xl:call([P18, <<".">>], {get, '_step'}),
    {stopped, normal} = xl:stop(P18),

    F19 = fun({xlx, _, [], {xl_trace, Log}}, Fsm) ->
                  F18(Log, Fsm);
             (_, Fsm) ->
                  {ok, unhandled, Fsm}
          end,
    S19 = #{'_react' => F19, name => s19},
    M19 = #{'_states' => #{'_traces' => {state, S19},
                           {start} => #{'_sign' => exception}},
            <<"_recovery">> => -2,
            <<"_timeout">> => 1000,
            '_state' => {[], start}},
    {ok, P19} = xl:start(M19),
    {ok, done} = xl:call(P19, xl_stop),
    {ok, running} = xl:call(P19, {get, '_status'}),
    {ok, 1} = xl:call([P19, <<".">>], {get, '_retry_count'}),
    {ok, 3} = xl:call([P19, <<".">>], {get, '_step'}),
    {ok, done} = xl:call(P19, xl_stop),
    {ok, 2} = xl:call([P19, <<".">>], {get, '_retry_count'}),
    {ok, running} = xl:call(P19, {get, '_status'}),
    {ok, 5} = xl:call([P19, <<".">>], {get, '_step'}),
    {stopped, normal} = xl:stop(P19),

    M20 = #{<<"_recovery">> => <<"rollback">>,
            '_states' => #{{start} => #{'_sign' => exception}},
            '_traces' => [],
            <<"_max_traces">> => 0,
            '_state' => {[], start}},
    {ok, P20} = xl:start(M20),
    {ok, R20} = xl:subscribe([P20, <<".">>]),
    {ok, done} = xl:call(P20, xl_stop),
    receive
        {R20, _} ->
            ok
    end,

    F21 = fun(#{'_parent' := Fsm, '_input' := 1} = State) ->
                  Fsm ! {xl_leave, {2, {start}}},
                  State#{'_report' := false};
             (#{'_parent' := Fsm, '_input' := 2} = State) ->
                  Fsm ! {xl_leave, {3, exception}},
                  State#{'_report' := false};
             (#{'_parent' := Fsm, '_input' := 3} = State) ->
                  Fsm ! {xl_leave, {4, {exception}}},
                  State#{'_report' := false};
             (#{'_parent' := Fsm, '_input' := 4} = State) ->
                  Fsm ! {xl_leave, #{'_sign' => {exception}}},
                  State#{'_report' := false}
          end,
    S21 = #{'_exit' => F21},
    M21 = #{<<"_recovery">> => <<"rollback">>,
            '_states' => #{{start} => S21},
            '_traces' => [],
            '_state' => {1, start}},
    {ok, P21} = xl:start(M21),
    {ok, done} = xl:call(P21, xl_stop),
    {ok, 2} = xl:call(P21, {get, '_input'}),
    {ok, done} = xl:call(P21, xl_stop),
    {ok, 1} = xl:call([P21, <<".">>], {get, '_retry_count'}),
    {ok, done} = xl:call(P21, xl_stop),
    {ok, 2} = xl:call([P21, <<".">>], {get, '_retry_count'}),
    {stopped, normal} = xl:stop(P21),
    M22 = M21#{'_state' => {3, start}},
    {ok, P22} = xl:start(M22),
    {ok, done} = xl:call(P22, xl_stop),
    {ok, 3} = xl:call(P22, {get, '_input'}),
    {stopped, normal} = xl:stop(P22),
    M23 = M21#{'_state' => {4, start}},
    {ok, P23} = xl:start(M23),
    {ok, done} = xl:call(P23, xl_stop),
    {ok, 4} = xl:call(P23, {get, '_input'}),
    {stopped, normal} = xl:stop(P23),

    S24 = #{a => #{b => c}, x => 1},
    {ok, P24} = xl:start(S24),
    {ok, c} = xl:call([P24, a, b], get),
    {error, badarg} =  xl:call([P24, a, b, c], get),
    {error, badarg} =  xl:call([P24, a, x, b], get),
    {stopped, normal} = xl:stop(P24),

    F25 = fun(State) -> State#{'_status' := exception} end,
    S25 = #{'_exit' => F25},
    {ok, P25} = xl:start(S25),
    {stopped, normal} = xl:stop(P25),

    S26 = spawn(fun() -> ok end),
    M26 = #{'_state' => {link, S26, undefined}},
    {ok, P26} = xl:start(M26),
    {stopped, normal} = xl:stop(P26),

    F27 = fun() ->
                  receive
                      stop ->
                          stop
                  end
          end,
    S27 = spawn(F27),
    M27 = #{'_state' => {link, S27, undefined},
            <<"_timeout">> => 1},
    {ok, P27} = xl:start(M27),
    {stopped, normal} = xl:stop(P27),

    S28 = #{'_parent' => P27, '_report' => true},
    {ok, P28} = xl:start(S28),
    {stopped, normal} = xl:stop(P28),

    S29 = #{'_parent' => self(),
            <<"_report">> => <<"all">>,
            '_report' => true},
    {ok, P29} = xl:start(S29),
    {ok, Y29} = xl:stop(P29),
    true = maps:get('_report', Y29),

    S30 = S29#{<<"_report">> => [a, b],
               a => 1, b => 2,
               '_report' => true},
    {ok, P30} = xl:start(S30),
    {ok, Y30} = xl:stop(P30),
    #{a := 1, b := 2} = Y30,

    F31 = fun(State) ->
                  Pid = self(),
                  Pid ! {'EXIT', 1, 2},
                  Pid ! {'DOWN', 1, 2, 3, 4},
                  State
          end,
    S31 = S30#{'_exit' => F31, '_of_fsm' => true},
    {ok, P31} = xl:start(S31),
    {ok, #{a := 1}} = xl:stop(P31),

    {ok, P32} = xl:start(#{}),
    {stopped, shutdown} = xl:stop(P32, shutdown),

    {ok, P33} = xl:start(S29),
    {ok, #{'_reason' := {shutdown, ok}}} = xl:stop(P33, {shutdown, ok}),

    L34 = #{test => {state, {#{'_input' => 0}, unit_test}},
            abc => {state, {#{'_input' => 2}, <<"unit_test">>}}},
    {ok, P34} = xl:start(#{'_states' => L34}),
    {ok, 0} = xl:call([P34, test, '_input'], get),
    {ok, 2} = xl:call([P34, abc, '_input'], get),
    {stopped, normal} = xl:stop(P34),

    F35 = fun(S) -> {ok, S#{xyz := abc}} end,
    L35 = #{test => {state, {#{xyz => 1}, #{'_entry' => F35}}}},
    {ok, P35} = xl:start(#{'_states' => L35}),
    {ok, abc} = xl:call([P35, test, xyz], get),
    {stopped, normal} = xl:stop(P35),

    L36 = #{test => {state, {#{}, "err"}}},
    {ok, P36} = xl:start(#{'_states' => L36}),
    {error, unknown} = xl:call(P36, {get, test}),
    {stopped, normal} = xl:stop(P36),

    S37 = #{a => 1, b => 2},
    {ok, P37} = xl:start(S37),
    L38 = #{x => {ref, P37, a}},
    {ok, P38} = xl:start(#{'_states' => L38}),
    {ok, 1} = xl:call(P38, {get, x}),
    {stopped, normal} = xl:stop(P38),
    {stopped, normal} = xl:stop(P37),

    F39 = fun({xl_touch, Key}, State) ->
                  {ok, Key, State}
          end,
    L39 = #{x => {ref, register, y},
            y => {ref, s37, b},
            z => {ref, ss, c},
            a => {a, b, c},
            s37 => {data, S37},
            register => {function, F39}},
    {ok, P39} = xl:start(#{'_states' => L39}),
    {ok, y} = xl:call(P39, {get, x}),
    {ok, 2} = xl:call(P39, {get, y}),
    {error, undefined} = xl:call(P39, {get, z}),
    {error, badarg} = xl:call(P39, {get, a}),
    {stopped, normal} = xl:stop(P39),

    F40 = fun({get, Key}, S) ->
                  {ok, {f40, Key}, S}
          end,
    S40 = #{2 => a,
            1 => {link, test, test},
            {1} => test,
            y => {function, F40}},
    {ok, P40} = xl:start(S40),
    {ok, {f40, y}} = xl:call(P40, {get, y}),
    {ok, #{2 := a}} = xl:call(P40, get),
    {stopped, normal} = xl:stop(P40),

    S41 = #{'_parent' => self(), <<"_report">> => false, '_report' => true},
    {ok, P41} = xl:start(S41),
    {ok, #{}} = xl:stop(P41),
    S42 = S41#{<<"_report">> := []},
    {ok, P42} = xl:start(S42),
    {ok, #{}} = xl:stop(P42).
