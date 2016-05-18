%%%-------------------------------------------------------------------
%%% @author Gary Hai <gary@XL59.com>
%%% @copyright (C) 2013, Gary Hai
%%% @doc
%%%
%%% @end
%%% Created : 20 Jul 2013 by Gary Hai <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(test).
%-export([s1_entry/1]).
-include_lib("eunit/include/eunit.hrl").

s1_entry(S) ->
    S1 = S#{output => "Hello world!", sign => s2},
    {ok, S1}.
s2_entry(S) ->
    S1 = S#{output => "State 2", sign => s1},
    {ok, S1}.
    
work_now(S) ->
    {stop, done, S#{output => pi}}.
    
work_slowly(_S) ->
    receive
        {'$xl_notify', {stop, _Reason}} ->
            exit(pi)
    end.

work_fast(_S) ->
    exit(pi).

s_react(transfer, S) ->
    {stop, transfer, S};
s_react({'$xl_command', _, {get, state}}, S) ->
    {ok, maps:get(state_name, S), S};
s_react({'$xl_notify', {transfer, Next}}, S) ->
    {stop, transfer, S#{sign => Next}};
s_react(_, S) ->  % drop unknown message.
    {ok, S}.


simple_state_test() ->
    S = #{entry => fun s1_entry/1},
    {ok, Pid} = xl_state:start(S),
    Res = gen_server:call(Pid, test),
    ?assert(Res =:= unknown),
    {'EXIT', {Sign, Final}} = (catch gen_server:stop(Pid)),
    ?assertMatch(#{output := "Hello world!"}, Final),
    ?assert(Sign =:= s2).

create_fsm() -> 
    S1 = #{state_name => state1,
           react => fun s_react/2,
           entry => fun s1_entry/1},
    S2 = #{state_name => state2,
           react => fun s_react/2,
           entry => fun s2_entry/1},
    S3 = #{state_name => state3,
           work_mode => block,
           do => fun work_now/1,
           react => fun s_react/2,
           entry => fun s1_entry/1},
    S4 = #{state_name => state4,
           engine => reuse,
           do => fun work_slowly/1,
           react => fun s_react/2,
           entry => fun s2_entry/1},
    S5 = #{state_name => state5,
           do => fun work_fast/1,
           react => fun s_react/2,
           entry => fun s2_entry/1},
    States = #{{'$root', start} => S1,
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
    xl_fsm:create([{states, States}]).
    
fsm_reuse_test() ->
    Fsm = create_fsm(),
    %% reuse fsm process, is default.
    fsm_test_cases(Fsm).
fsm_standalone_test() ->
    Fsm = create_fsm(),
    %% standalone process for each state.
    Fsm1 = Fsm#{engine => standalone, max_trace => 3},
    fsm_test_cases(Fsm1).

fsm_test_cases(Fsm) ->
    erlang:process_flag(trap_exit, true),
    {ok, Pid} = xl_state:start_link(Fsm),
    ?assert(state1 =:= xl_state:invoke(Pid, {get, state})),
    Pid ! transfer,
    timer:sleep(10),
    ?assert(state2 =:= gen_server:call(Pid, {get, state})),
    gen_server:cast(Pid, {transfer, s4}),
    timer:sleep(10),
    ?assert(state4 =:= xl_state:invoke(Pid, {get, state})),
    gen_server:cast(Pid, {transfer, s5}),
    timer:sleep(10),
    ?assert(state5 =:= xl_state:invoke(Pid, {get, state})),
    gen_server:cast(Pid, {transfer, s3}),
    timer:sleep(10),
    ?assert(state2 =:= xl_state:invoke(Pid, {get, state})),
    {s1, Final} = xl_state:deactivate(Pid),
    ?assertMatch(#{step := 6, status := stopped}, Final),
    #{trace := Trace, step := Step} = Final,
    case maps:get(max_trace, Final, infinity) of
        infinity ->
            ?assert(Step - 1 =:= length(Trace));
        MaxTrace ->
            ?assert(MaxTrace =:= length(Trace))
        end.
%    xl_state:deactivate(Pid).
