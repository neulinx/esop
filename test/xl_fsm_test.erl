%%%-------------------------------------------------------------------
%%% @author Guiqing Hai <gary@XL59.com>
%%% @copyright (C) 2016, Guiqing Hai
%%% @doc
%%%
%%% @end
%%% Created :  7 Jun 2016 by Guiqing Hai <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(xl_fsm_test).
-include_lib("eunit/include/eunit.hrl").

s1_entry(S) ->
    S1 = S#{io => "Hello world!", sign => s2},
    {ok, S1}.

s2_entry(S) ->
    S1 = S#{io => "State 2", sign => s1},
    {ok, S1}.

work_instantly(S) ->
    {stop, done, S}.

    
work_async(S) ->
    receive
        {xlx, {stop, xlx_unload}} ->
            erlang:exit({stop, unloading});
        {xlx, {stop, _Reason}} ->
            erlang:exit({ok, pi});
        _Unknown ->
            work_async(S)
    end.

work_sync(#{actor := Fsm, name := Name} = S) ->
    S0 = xl_state:call(Fsm, {get, state}),
    ?assertMatch({ok, #{name := Name}}, S0),
    {ok, pi, S}.

%% Set counter 2 as pitfall.
s_react({xlx, _, "error_test"}, #{counter := Count}) when Count =:= 2 ->
    error(error_test);
s_react({xlx, _, "error_test"}, S) ->
    Count = maps:get(counter, S, 0),
    {error, Count + 1, S#{counter => Count + 1}};
%% transfer
s_react(transfer, S) ->
    {stop, transfer, S};
s_react({xlx, {transfer, Next}}, S) ->
    {stop, transfer, S#{sign => Next}};
%% state
s_react({xlx, _, {get, "state"}}, S) ->
    {ok, maps:get(name, S), S};
s_react(_, S) ->  % drop unknown message.
    {ok, unhandled, S}.

create_fsm() ->
    S1 = #{name => state1,
           react => fun s_react/2,
           entry => fun s1_entry/1},
    S2 = #{name => state2,
           timeout => 1000,
           react => fun s_react/2,
           entry => fun s2_entry/1},
    S3 = #{name => state3,
           do => fun work_instantly/1,
           react => fun s_react/2,
           entry => fun s1_entry/1},
    S4 = #{name => state4,
           work_mode => async,
           engine => reuse,
           do => fun work_async/1,
           react => fun s_react/2,
           entry => fun s2_entry/1},
    S5 = #{name => state5,
           engine => standalone,
           do => fun work_sync/1,
           react => fun s_react/2,
           entry => fun s2_entry/1},
    States = #{start => S1,
               state1 => S1,
               state2 => S2,
               state3 => S3,
               state4 => S4,
               state5 => S5,
               {state1, s1} => S1,
               {state1, s2} => S2,
               {state1, s3} => S3,
               {state2, s1} => S1,
               {state2, s2} => S2,
               {state2, s4} => S4,
               {state3, s1} => S1,
               {state3, s2} => S2,
               {state3, s4} => S4,
               {state4, s5} => S5,
               {state4, s2} => S2,
               {state4, s3} => S3,
               {state5, s1} => S1,
               {state5, s2} => S2,
               {state5, s3} => S3},
    xl_state:create(xl_fsm, [{states, States}]).
    
fsm_test() ->
    Fsm = create_fsm(),
    %% standalone process for each state.
    Fsm1 = Fsm#{max_traces => 4,
                max_steps => 30,
                recovery =>
                    {state2, #{recovery => {reset, -1, #{new_data => 1}}}}},
    fsm_test_cases(Fsm1).

fsm_recovery_test() ->
    Fsm = create_fsm(),
    Fsm1 = Fsm#{max_pending_size => 5,
                max_steps => 30,
                recovery => {0, #{recovery => {reset, 0, #{}}}}},
    fsm_test_cases(Fsm1#{engine => reuse}).

fsm_test_cases(Fsm) ->
    %% Prepare.
    erlang:process_flag(trap_exit, true),
    error_logger:tty(false),
    {ok, Pid} = xl_state:start_link(Fsm),
    %% Subscribe
    {ok, Mref} = xl_state:call(Pid, subscribe),
    %% Basic actions.
    ?assertMatch({ok, state1}, xl_state:call(Pid, {get, "state"})),
    ?assertMatch({ok, #{name := state1}}, gen_server:call(Pid, {get, state})),
    Pid ! transfer,
    timer:sleep(10),
    ?assert({ok, state2} =:= gen_server:call(Pid, {get, "state"})),
    ?assert({ok, 2} =:=  gen_server:call(Pid, {get, step})),
    %% Failover test.
    ?assert({error, 1} =:= xl_state:call(Pid, "error_test")),
    ?assert({error, 2} =:= xl_state:call(Pid, "error_test")),
    catch xl_state:call(Pid, "error_test", 0),
    {_, SelfHeal} = xl_state:call(Pid, {get, max_pending_size}),
    case xl_state:call(Pid, {get, "state"}, 20) of
        {ok, state2} ->
            ?assertMatch(5, SelfHeal);
        {error, timeout} ->
            ?assertMatch(not_found, SelfHeal)
    end,
    timer:sleep(10),
    %% Worker inside state test.
    gen_server:cast(Pid, {transfer, s4}),
    timer:sleep(10),
    ?assertMatch({ok, state4}, xl_state:call(Pid, {get, "state"})),
    %% unload and resume
    {unloaded, FsmData} = xl_state:unload(Pid),
    ?assertMatch(#{status := running}, FsmData),
    %% Subscribe notification
    receive
        {Mref, unload} ->
            ok
    end,
    %% Link output.
    receive
        {'EXIT', Pid, {unloaded, F}} ->
            ?assert(F =:= FsmData)
    end,
    {ok, NewPid} = xl_state:start_link(FsmData),
    fsm_test_resume(NewPid).

fsm_test_resume(Pid) ->
    ?assertMatch({ok, state4}, xl_state:call(Pid, {get, "state"})),
    gen_server:cast(Pid, {transfer, s5}),
    timer:sleep(10),
    ?assertMatch({ok, state5}, xl_state:call(Pid, {get, "state"})),
    ?assert({ok, running} =:= xl_state:call(Pid, {get, status})),
    gen_server:cast(Pid, {transfer, s3}),
    timer:sleep(10),
    ?assertMatch({ok, state2}, xl_state:call(Pid, {get, "state"})),
    %% Failover test again.
    ?assert({error, 1} =:= xl_state:call(Pid, "error_test")),
    ?assert({error, 2} =:= xl_state:call(Pid, "error_test")),
    catch xl_state:call(Pid, "error_test", 0),
    %% Stop. 
    timer:sleep(10),
    {Sign, Final} = xl_state:stop(Pid),
    #{traces := Trace} = Final,
    case maps:get(max_traces, Final, infinity) of
        %% recovery_test:  1->2*->(retry)2*->2->4(#)4->5->3->*2->(reset)2 =>2
        infinity ->
            ?assertMatch(s1, Sign),
            ?assertMatch(#{step := 10}, Final),
            ?assertMatch(7, length(Trace));
        %% fsm_test: 1->2*->(bypass)2->2->4(#)4->5->3->2*->(reset -1)3->3 =>2
        MaxTrace ->
            ?assertMatch(s1, Sign),
            ?assertMatch(#{step := 11, new_data := 1}, Final),
            ?assertMatch(MaxTrace, length(Trace))
    end.

%%----------------------------------------------------------------------
%% Benchmark for message delivery and process exit throw.
loop(_Pid, 0) ->
    ok;
loop(Pid, Count) ->
    Pid ! {self(), test},
    receive
        got_it ->
            NewPid = spawn(fun by_message/0);
        {'EXIT', Pid, got_it} ->
            NewPid = spawn_link(fun by_exit/0)
    end,
    loop(NewPid, Count - 1).


by_message() ->
    receive
        {Pid, test} ->
            Pid ! got_it
    end.

by_exit() ->
    receive
        {_, test} ->
            erlang:exit(got_it)
    end.

benchmark(Count) ->
    erlang:process_flag(trap_exit, true),
    P1 = spawn(fun by_message/0),
    P2 = spawn_link(fun by_exit/0),
    ?debugTime("Messages delivery", loop(P1, Count)),
    ?debugTime("Process throw", loop(P2, Count)).

benchmark_test() ->
    benchmark(100000).
