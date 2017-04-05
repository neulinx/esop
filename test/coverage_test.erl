%%%-------------------------------------------------------------------
%%% @author HaiGuiqing <gary@XL59.com>
%%% @copyright (C) 2016, HaiGuiqing
%%% @doc
%%%
%%% @end
%%% Created : 25 Dec 2016 by HaiGuiqing <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(coverage_test).

-export([create/1, coverage/0, isolate/0]).

-include_lib("eunit/include/eunit.hrl").

create(Data) ->
    Data#{test => yes}.

react({xlx, _, [], xl_enter}, S) ->
    {ok, done, S};
react(_, S) ->
    {ok, unhandled, S}.

coverage() ->
    {ok, P1} = xl:start_link(undefined, #{'_timeout' => 1000}, []),
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
    {status, runnable} = process_info(P4, status),
    {ok, 1} = xl:call([P4, a], get),
    {status, waiting} = process_info(P4, status),
    ok = gen_server:cast(P4, {xl_stop, {shutdown, test}}),
    receive
        {R1, _} ->
            ok
    end,

    F1 = fun(xl_wakeup, #{parent := Parent} = S) ->
                 Parent ! xl_wakeup,
                 {ok, S}
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
    {ok, 2} = xl:call([P6, b], get),
    {stopped, normal} = xl:stop(P6),

    %%~~ init_state()
    {ok, P6_1} = xl:start(#{'_state' => stop}),
    {stopped, noproc} = xl:stop(P6_1),
    {ok, P6_2} = xl:start(#{'_entry' => F2, '_state' => stop}),
    {stopped, noproc} = xl:stop(P6_2),
    
    F3 = fun(S) -> {stop, normal, S} end,
    {error, normal} = xl:start(#{'_entry' => F3}),

    {ok, P6_3} = xl:start(#{'_preload' => [a]}),
    {stopped, noproc} = xl:stop(P6_3),

    {ok, P7} = xl:start(#{'_react' => fun react/2}),
    {ok, #{'_pid' := P7, '_status' := running}} = xl:call(P7, get_raw),
    L1 = #{'_state' => {process, P7}},
    {ok, P8} = xl:start(#{'_states' => L1,
                          '_preload' => ['_state']}),
    {ok, R2} = xl:call(P8, {subscribe, self()}),
    P7 ! xl_stop,
    receive
        {R2, _} ->
            ok
    end,

    M2 = #{'_states' => {state, #{}},
           '_recovery' => undefined,
           '_state' => {data, #{'_sign' => start}}},
    {ok, P8_1} = xl:start(M2),
    {stopped, {shutdown,exception}} = xl:stop(P8_1),


    {ok, P9} = xl:start(#{}),
    {ok, R3} = xl:call(P9, {subscribe, self()}),
    %%~~ invoke(xl_fsm_stop
    ok = gen_server:cast(P9, xl_fsm_stop),
    receive
        {R3, _} ->
            ok
    end,

    F4 = fun({xl_stop, _}, S) -> {stop, S} end,
    {ok, P10} = xl:start(#{'_react' => F4}),
    {ok, R4} = xl:call(P10, {subscribe, self()}),
    ok = gen_server:cast(P10, {xl_stop, normal}),
    receive
        {R4, _} ->
            ok
    end,

    F5 = fun({xl_stop, _}, S) ->
                 {stop, normal, S};
            (xl_hibernate, S) ->
                 {ok, S, hibernate};
            (test, S) ->
                 {stop, S};
            (test2, S) ->
                 {stop, normal, stop, S};
            ({xlx, _, _, hello}, S) ->
                 {reply, world, S};
            ({test, Pid}, S) ->
                 Pid ! ok,
                 {ok, done, S}
         end,

    {ok, P11} = xl:start(#{'_react' => F5}),
    {ok, R5} = xl:call(P11, {subscribe, self()}),
    %%~~ _stop()
    {error, timeout} = xl:stop(P11, normal, 0),
    receive
        {R5, _} ->
            ok
    end,

    {ok, P12} = xl:start(#{'_react' => F5}),
    ok = gen_server:cast(P12, xl_hibernate),
    {stopped, normal} = xl:stop(P12),

    {ok, P13} = xl:start(#{'_react' => F5}),
    world = xl:call(P13, hello),
    {ok, R6} = xl:call(P13, {subscribe, self()}),
    ok = gen_server:cast(P13, test),
    receive
        {R6, _} ->
            ok
    end,

    {ok, P14} = xl:start(#{'_react' => F5, '_hibernate' => 10}),
    {error, unknown} = gen_server:call(P14, noop),
    ok = gen_server:cast(P14, {xl_leave, undefined, test}),
    ok = gen_server:cast(P14, {test, self()}),
    receive
        ok ->
            ok
    end,
    {ok, R7} = xl:call(P14, {subscribe, self()}),
    ok = gen_server:cast(P14, test2),
    receive
        {R7, _} ->
            ok
    end,

    M3 = #{'_states' => #{},
           name => m3,
           '_aftermath' => <<"halt">>,
           '_state' => #{}},
    {ok, P15} = xl:start(M3),
    ok = xl:cast([P15, '_state'], xl_stop),
    {ok, m3} = xl:call([P15, name], get),
    {ok, #{}} = xl:call([P15, '_state'], get),
    {stopped, normal} = xl:stop(P15),

    M4 = #{'_states' => #{},
           name => m4,
           '_state' => #{'_sign' => halt}},
    {ok, P16} = xl:start(M4),
    ok = xl:cast([P16, '_state'], xl_stop),
    {ok, m4} = xl:call([P16, name], get),
    {ok, halt} = xl:call([P16, '_status'], get),
    {stopped, normal} = xl:stop(P16),

    M5 = #{'_states' => #{{start} => #{'_sign' => start}},
           '_max_steps' => 2,
           '_aftermath' => <<"halt">>,
           '_state' => {start}},
    {ok, P17} = xl:start(M5),
    {ok, done} = xl:call([P17, <<>>], xl_stop),
    {ok, 2} = xl:call([P17, '_step'], get),
    {ok, done} = xl:call([P17, <<>>], xl_stop),
    {ok, 3} = xl:call([P17, '_step'], get),
    {ok, halt} = xl:call([P17, '_status'], get),
    {stopped, normal} = xl:stop(P17),
    
    F18 = fun({log, Trace}, Fsm) ->
                  Logs = maps:get(logs, Fsm, []),
                  {ok, done, Fsm#{logs => [Trace | Logs]}};
             ({backtrack, Back}, #{logs := Logs} = Fsm) ->
                  History = lists:nth(-Back, Logs),
                  {ok, History, Fsm}
          end,
    F19 = fun({xlx, _, [], {xl_trace, Log}}, Fsm) ->
                  F18(Log, Fsm)
          end,
    S18 = #{'_sign' => {exception}, '_payload' => undefined},
    M18 = #{'_states' => #{{start} => S18, '_traces' => {function, F19}},
            '_recovery' => -2,
            '_state' => #{'_sign' => {start}}},
    {ok, P18} = xl:start(M18),
    {ok, done} = xl:call([P18, <<>>], xl_stop),
    {ok, [S18, #{'_sign' := {start}}]} = xl:call([P18, logs], get),
    {ok, done} = xl:call([P18, <<>>], xl_stop),
    {ok, {exception}} = xl:call([P18, '_sign'], get),
    {ok, 2} = xl:call([P18, '_retry_count'], get),
    {ok, 4} = xl:call([P18, '_step'], get),
    {stopped, normal} = xl:stop(P18),

    S19 = #{'_react' => F19, name => s19},
    M19 = #{'_states' => #{'_traces' => {state, S19},
                           {start} => #{'_sign' => {exception}}},
            '_recovery' => -2,
            '_timeout' => 1000,
            '_state' => {start}},
    {ok, P19} = xl:start(M19),
    {ok, running} = xl:call([P19, '_status'], get),
    {ok, done} = xl:call([P19, <<>>], xl_stop),
    {ok, failover} = xl:call([P19, '_status'], get),
    {ok, 1} = xl:call([P19, '_retry_count'], get),
    timer:sleep(1),
    {ok, 3} = xl:call([P19, '_step'], get),
    {ok, done} = xl:call([P19, <<>>], xl_stop),
    {ok, 2} = xl:call([P19, '_retry_count'], get),
    {ok, running} = xl:call([P19, <<>>, '_status'], get),
    {ok, 5} = xl:call([P19, '_step'], get),
    {stopped, normal} = xl:stop(P19),

    M20 = #{'_recovery' => <<"rollback">>,
            '_states' => #{{start} => #{'_sign' => exception}},
            '_traces' => [],
            '_max_traces' => 0,
            '_state' => #{'_sign' => {start}}},
    {ok, P20} = xl:start(M20),
    {ok, R20} = xl:call(P20, {subscribe, self()}),
    {ok, done} = xl:call([P20, <<>>], xl_stop),
    receive
        {R20, _} ->
            ok
    end,

    F21 = fun(#{'_parent' := {_, Fsm}, '_payload' := 1} = State) ->
                  Fsm ! {xl_leave, undefined,
                         #{'_payload' => 2, '_sign' => start}},
                  State#{'_report' := false};
             (#{'_parent' := {_, Fsm}, '_payload' := 2} = State) ->
                  Fsm ! {xl_leave, undefined,
                         #{'_payload' => 3, '_sign' => exception}},
                  State#{'_report' := false};
             (#{'_parent' := {_, Fsm}, '_payload' := 3} = State) ->
                  Fsm ! {xl_leave, undefined,
                         #{'_payload' => 4, '_sign' => exception}},
                  State#{'_report' := false};
             (#{'_parent' := {_, Fsm}, '_payload' := 4} = State) ->
                  Fsm ! {xl_leave, undefined, #{'_sign' => {exception}}},
                  State#{'_report' := false}
          end,
    S21 = #{'_exit' => F21},
    M21 = #{'_recovery' => <<"rollback">>,
            '_states' => #{{start} => S21},
            '_traces' => [],
            '_state' => #{'_payload' => 1, '_sign' => start}},
    {ok, P21} = xl:start(M21),
    {ok, done} = xl:call([P21, <<>>], xl_stop),
    {ok, 2} = xl:call([P21, <<>>, '_payload'], get),
    {ok, done} = xl:call([P21, <<>>], xl_stop),
    timer:sleep(1),
    {ok, 1} = xl:call([P21, '_retry_count'], get),
    {ok, done} = xl:call([P21, <<>>], xl_stop),
    {ok, 2} = xl:call([P21, '_retry_count'], get),
    {stopped, normal} = xl:stop(P21),
    M22 = M21#{'_state' => #{'_payload' => 3, '_sign' => start}},
    {ok, P22} = xl:start(M22),
    {ok, done} = xl:call([P22, <<>>], xl_stop),
    {ok, 3} = xl:call([P22, <<>>, '_payload'], get),
    {stopped, normal} = xl:stop(P22),
    M23 = M21#{'_state' => #{'_payload' => 4, '_sign' => start}},
    {ok, P23} = xl:start(M23),
    {ok, done} = xl:call([P23, <<>>], xl_stop),
    {ok, 4} = xl:call([P23, <<>>, '_payload'], get),
    {stopped, normal} = xl:stop(P23),

    S24 = #{a => #{b => c}, x => 1},
    {ok, P24} = xl:start(S24),
    {ok, c} = xl:call([P24, a, b], get),
    {error, undefined} =  xl:call([P24, a, b, c], get),
    {error, undefined} =  xl:call([P24, a, x, b], get),
    {stopped, normal} = xl:stop(P24),

    F25 = fun(State) -> State#{'_status' := exception} end,
    S25 = #{'_exit' => F25},
    {ok, P25} = xl:start(S25),
    {stopped, normal} = xl:stop(P25),

    M26 = #{state => {state, #{'_react' => fun react/2}},
            '_state' => {refer, [state]}},
    {ok, P26} = xl:start(M26),
    {stopped, normal} = xl:stop(P26),

    F27 = fun() ->
                  receive
                      {xlx, From, [], xl_enter} ->
                          xl:reply(From, {ok, done})
                  end
          end,
    S27 = spawn(F27),
    M27 = #{'_state' => {link, S27, undefined},
            '_timeout' => 1},
    {ok, P27} = xl:start(M27),
    {stopped, _} = xl:stop(P27),

    S28 = #{'_parent' => {link, P27, undefined}, '_report' => true},
    {ok, P28} = xl:start(S28),
    {stopped, normal} = xl:stop(P28),

    S29 = #{'_parent' => {process, self()},
            '_report_items' => <<"all">>,
            '_report' => true},
    {ok, P29} = xl:start(S29),
    {ok, Y29} = xl:stop(P29),
    true = maps:get('_report', Y29),

    S30 = S29#{'_report_items' => [a, b],
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
    {error, unknown} = xl:call([P36, test], get),
    {stopped, normal} = xl:stop(P36),

    S37 = #{a => 1, b => 2, c => #{d => 3}},
    {ok, P37} = xl:start(S37),
    L38 = #{x => {refer, {P37, [a]}}},
    {ok, P38} = xl:start(#{'_states' => L38}),
    {ok, 1} = xl:call([P38, x], get),
    {stopped, normal} = xl:stop(P38),
    {stopped, normal} = xl:stop(P37),

    F39 = fun({xlx, _, [Key], touch}, State) ->
                  {ok, Key, State}  % Data not cache in Key.
          end,
    L39 = #{x => {refer, [register, y]},
            y => {refer, [s37, b]},
            z => {refer, [ss, c]},
            e => {refer, [s37, c, e]},
            a => {a, b, c},
            b => {a, b},
            s37 => {data, S37},
            register => {function, F39}},
    {ok, P39} = xl:start(#{'_states' => L39, d => {refer, [s37, c, d]}}),
    {ok, y} = xl:call([P39, x], get),
    {error, undefined} = xl:call([P39, x], get_raw),
    {ok, 2} = xl:call([P39, y], get),
    {ok, 2} = xl:call([P39, y], get_raw),
    {error, undefined} = xl:call([P39, z], get),
    {ok, {a, b, c}} = xl:call([P39, a], get),
    {a, b} = xl:call([P39, b], get),
    {ok, 3} = xl:call([P39, d], get),
    {error, undefined} = xl:call([P39, e], get),
    {stopped, normal} = xl:stop(P39),

    F40 = fun({xlx, _, [], {get, Key}}, S) ->
                  {ok, {f40, Key}, S}
          end,
    S40 = #{2 => a,
            1 => {link, test, test},
            {1} => test,
            y => {function, F40}},
    {ok, P40} = xl:start(S40),
    {ok, {f40, z}} = xl:call([P40, y], {get, z}),
    {ok, #{2 := a}} = xl:call(P40, get),
    {stopped, normal} = xl:stop(P40),

    S41 = #{'_parent' => {process, self()},
            '_report_items' => false, '_report' => true},
    {ok, P41} = xl:start(S41),
    {ok, #{}} = xl:stop(P41),
    S42 = S41#{'_report_items' := []},
    {ok, P42} = xl:start(S42),
    {ok, #{}} = xl:stop(P42),
    
    {ok, P43} = xl:start(#{'_status' => running}),
    {stopped, normal} = xl:stop(P43),
    
    F44 = fun({xlx, _, Path, bb}, S) ->
                     xl:request(Path ++ [b], get, S);
             ({xlx, _, _Path, cc}, S) ->
                     xl:request([c], get, S);
             ({xlx, _, Path, dd}, S) ->
                     xl:request(Path ++ [b], get, S#{'_timeout' => 0})
          end,
    L44 = #{a => {state, #{b => 2}}},
    S44 = #{'_react' => F44, '_states' => L44, c => 3},
    {ok, P44} = xl:start(S44),
    {ok, 2} = xl:call([P44, a], bb),
    {ok, 3} = xl:call(P44, cc),
    {error, timeout} = xl:call([P44, a], dd),
    {stopped, normal} = xl:stop(P44),
    
    %%~~ default_react(), _bond
    {ok, P45} = xl:start(#{}),
    F46 = fun(xl_enter, #{'_parent' := {process, Parent}} = S) ->
                  link(Parent),
                  {ok, S};
             (xl_enter, #{'_parent' := {link, Parent, _}} = S) ->
                  link(Parent),
                  {ok, S};
             ({xlx, _, _, {bind, Pid}}, S) ->
                  link(Pid),
                  {ok, done, S#{'_parent' => {link, Pid, undefined}}};
             ({xlx, _, _, {bind, normal, Pid}}, S) ->
                  link(Pid),
                  {ok, done,
                   S#{'_parent' => {process, Pid}, '_bond' => normal}}
          end,
    {ok, P46} = xl:start(#{'_parent' => {process, P45},
                           '_react' => F46,
                           '_bond' => standalone}),
    {ok, R46} = xl:call(P46, {subscribe, self()}),
    {stopped, normal} = xl:stop(P45),
    receive
        {R46, _} ->
            ignore_coverage
    after
        10 ->
            continue
    end,
    {ok, P47} = xl:start(#{}),
    {ok, done} = xl:call(P46, {bind, P47}, 10),
    {stopped, normal} = xl:stop(P47),
    receive
        {R46, _} ->
            ignore_coverage
    after
        10 ->
            continue
    end,
    {ok, P471} = xl:start(#{}),
    {ok, done} = xl:call(P46, {bind, normal, P471}, 10),
    {stopped, normal} = xl:stop(P471),
    receive
        {R46, {exit, _}} ->
            reach_here
    end,
    {ok, P472} = xl:start(#{}),
    {ok, P461} = xl:start(#{'_parent' => {link, P472, undefined},
                           '_react' => F46, '_bond' => normal}),
    {ok, R461} = xl:call(P461, {subscribe, self()}),
    {stopped, normal} = xl:stop(P472),
    receive
        {R461, {exit, _}} ->
            reach_here
    end,

    S48 = #{a => 1, b => #{c => 2}},
    {ok, P48} = xl:start(S48),
    F49 = fun({xlx,undefined,[p2],touch}, S) ->
                  {refer, [p1, a], S};
             (_M, S) ->
                  {error, undefined, S}
          end,
    {ok, P49} = xl:start(#{'_states' => {function, F49},
                           p1 => {link, P48, undefined},
                           aa => {refer, {P48, [a]}},
                           bb => {refer, {P48, [b, c]}},
                           cc => {refer, {P48, [b, d]}},
                           dd => {refer, P48}}),
    {data, 1} = xl:call([P48, a], touch),
    {data, 1} = xl:call([P49, aa], touch),
    {ok, 1} = xl:call([P49, aa], get),
    {ok, 2} = xl:call([P49, bb], get),
    {error, undefined} = xl:call([P49, cc], get),
    {ok, 2} = xl:call([P49, dd, b, c], get),
    {ok, 2} = xl:call([P49, p1, b, c], get),
    {ok, 1} = xl:call([P49, p2], get),
    {stopped, normal} = xl:stop(P48),
    {ok, 1} = xl:call([P49, aa], get),
    {stopped, normal} = xl:stop(P49),

    S50 = #{d => 2, b => #{c => 3}},
    {ok, P50} = xl:start(S48),
    {ok, done} = xl:call(P50, {patch, S50}),
    {ok, 2} = xl:call([P50, d], get),
    {ok, 3} = xl:call([P50, b, c], get_raw),
    {ok, 1} = xl:call([P50, a], get),
    L51 = #{x => {redirect, []},
            y => {redirect, [b, c]},
            z => {redirect, {P50, [b]}},
            p => {redirect, P50}},
    S51 = S50#{'_states' => L51},
    {ok, P51} = xl:start(S51),
    {ok, 2} = xl:call([P51, x, d], get),
    {ok, 3} = xl:call([P51, y], get),
    {ok, 3} = xl:call([P51, z, c], get),
    {ok, 3} = xl:call([P51, p, b, c], get),
    {ok, done} = xl:call(P51, {patch, S48}),
    {ok, 2} = xl:call([P51, x, d], get),
    {ok, 2} = xl:call([P51, y], get),
    {ok, 3} = xl:call([P51, z, c], get),
    {ok, 1} = xl:call([P51, a], get),
    {ok, done} = xl:call([P51, x, b], {patch, #{c => 4, e => 6}}),
    {ok, done} = xl:call([P51, z], {patch, #{c => 5, e => 7}}),
    {ok, 4} = xl:call([P51, b, c], get),
    {ok, 6} = xl:call([P51, b, e], get),
    {ok, 5} = xl:call([P50, b, c], get),
    {ok, 7} = xl:call([P50, b, e], get),
    %% ?debugVal(xl:call(P51, get_raw)),
    %% ?debugVal(xl:call(P50, get_raw)),
    {process, P50} = xl:call(P51, P50, touch, 10),
    {stopped, normal} = xl:stop(P50),
    {stopped, normal} = xl:stop(P51),

    %%~~ init_fsm(), fsm_start()
    S52 = #{a => #{b => 1, '_sign' => c},
            d => #{b => 2, '_sign' => e},
            '_states' => #{{c} => {refer, [d]}, {e} => {test, unknown}},
            '_state' => {redirect, [a]}},
    {ok, P52} = xl:start(S52),
    {ok, 1} = xl:call([P52, <<>>, b], get),
    {ok, done} = xl:call([P52, <<>>], xl_stop),
    {ok, 2} = xl:call([P52, <<>>, b], get),
    {ok, done} = xl:call([P52, <<>>], xl_stop),
    timer:sleep(1),
    {stopped, noproc} = xl:stop(P52),
    {ok, P52_1} = xl:start(#{'_state' => {redirect, [unknown]}}),
    {stopped, noproc} = xl:stop(P52_1),
    
    %%~~ start_fsm(), transfer_2()
    L53 = #{{a} => #{'_sign' => b},
            {b} => 1,
            {c} => {state, #{}},
            '_state' => {a}},
    {ok, P53} = xl:start(#{'_max_retry' => 2,
                           '_states' => L53,
                           '_recovery' => {c}}),
    {ok, R53} = xl:call(P53, {subscribe, self()}),
    {ok, done} = xl:call([P53, <<>>], xl_stop),
    receive
        {R53, {transition, #{'_sign' := b}}} ->
            b
    end,
    receive
        {R53, {transition, {c}}} ->
            c
    end,
    receive
        {R53, {exit, #{'_sign' := {escape}}}} ->
            stopped
    end,
    
    %%~~ deliver()
    F54 = fun({xlx, From, [Key], test}, S) ->
                  xl:deliver([Key], {From, test}, S)
          end,
    F541 = fun({From, test}, S) ->
                   xl:reply(From, {ok, passed}),
                   {ok, S}
           end,
    S54 = #{x => {function, F541}, y => #{}, '_react' => F54},
    {ok, P54} = xl:start(S54),
    {ok, passed} = xl:call([P54, x], test),
    {error, undefined} = xl:call([P54, a], test),
    {error, badarg} = xl:call([P54, y], test),
    {stopped, normal} = xl:stop(P54),
    
    %%~~ stop_fsm()
    F55 = fun({xlx, _, [], xl_enter}, S) ->
                  {ok, done, S};
             ({xl_fsm_stop, _}, S) ->
                  {ok, timer:sleep(100), S};
             (_, S) ->
                  {ok, unhandled, S}
          end,
    L55 = #{'_state' => {state, #{'_react' => F55}}},
    S55 = #{'_timeout' => 5, '_states' => L55},
    {ok, P55} = xl:start(S55),
    {ok, R55} = xl:call(P55, {subscribe, self()}),
    P55 ! xl_stop,
    receive
        {R55, {exit, #{'_sign' := {abort}}}} ->
            abort
    end,
    S56 = #{'_state' => {function, fun react/2}},
    {ok, P56} = xl:start(S56),
    {ok, R56} = xl:call(P56, {subscribe, self()}),
    P56 ! xl_stop,
    receive
        {R56, {exit, #{'_sign' := {stop}}}} ->
            stop
    end,
    
    %%~~ fsm_start()
    F57 = fun(_, S) -> {ok, unhandled, S} end,
    S57 = #{'_state' => F57},
    {ok, P57} = xl:start(S57),
    {stopped, noproc} = xl:stop(P57).

isolate() ->
    ignore_coverage.
