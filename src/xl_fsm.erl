%%%-------------------------------------------------------------------
%%% @author Gary Hai <gary@XL59.com>
%%% @copyright (C) 2016, Neulinx Collaborations Ltd.
%%% @doc
%%%  Finite State Machine as a normal state object.
%%% @end
%%% Created : 30 Apr 2016 by Gary Hai <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(xl_fsm).

-compile({no_auto_import,[exit/1]}).
%% API
-export([entry/1, react/2, exit/1]).

-ifdef(TEST).
    -include_lib("eunit/include/eunit.hrl").
-endif.

%%%===================================================================
%%% Common types
%%%===================================================================
-export_type([engine/0]).

-type engine() :: 'reuse' | 'standalone'.
-type name() :: term().
-type sign() :: term().
-type vector() :: {name(), sign()}.
-type limit() :: pos_integer() | 'infinity'.
-type state() :: #{'state_name' => term(),
                   'engine' => engine()}
               | xl_state:state().
-type states() :: states_table() | states_fun().
-type states_table() :: #{From :: vector() => To :: state()}.
-type states_fun() :: fun((From :: name(), sign()) -> To :: state()).
-type fsm() :: #{'state' => state(),
                 'states' => states(),
                 'state_mode' => engine(),
                 'state_pid' => pid(),
                 'step' => non_neg_integer(),
                 'max_steps' => limit(),
                 'max_traces' => limit(),
                 'traces' => [state()] | fun((state()) -> any())
                } | xl_state:state().
-type entry_ret() :: xl_state:ok() | xl_state:fail().
-type exit_ret() :: xl_state:output().
-type react_ret() :: xl_state:ok() | xl_state:fail().

%%%===================================================================
%%% API
%%%===================================================================
%%--------------------------------------------------------------------
%% @doc
%% Actions of state.
%% @end
%%--------------------------------------------------------------------
-spec entry(fsm()) -> entry_ret().
entry(Fsm) ->
    erlang:process_flag(trap_exit, true),
    transfer(Fsm, start).

-spec react(Message :: term(), fsm()) -> react_ret().
react(Message, Fsm) ->
    process(Message, Fsm).

-spec exit(fsm()) -> exit_ret().
exit(Fsm) ->
    Reason = maps:get(reason, Fsm, normal),
    stop_fsm(Fsm, Reason).

%%%===================================================================
%%% Internal functions
%%%===================================================================
next(#{state := State}, start) ->
    State;
next(#{state := State, states := States}, Sign) ->
    Name = maps:get(state_name, State),
    next(States, Name, Sign);
next(#{states := States}, Sign) ->
    next(States, '_root', Sign).

next(States, From, Sign) when is_function(States) ->
    States(From, Sign);
next(States, From, Sign) ->
    maps:get({From, Sign}, States).

process({xlx, _, _} = Command, Fsm) ->
    on_command(Command, Fsm);
process({xlx, _} = Notification, Fsm) ->
    on_notify(Notification, Fsm);
process(Message, Fsm) ->
    on_message(Message, Fsm).

relay(Message, #{state := State, status := running} = Fsm) ->
    relay(Message, State, Fsm);
relay({xlx, _, _}, Fsm) ->
    {ok, not_ready, Fsm};
relay(_, Fsm) ->
    {ok, Fsm}.


relay(Message, #{react := React} = State, Fsm) ->
    case React(Message, State) of
        {ok, R, S} ->
            {ok, R, Fsm#{state := S}};
        {ok, S} ->
            {ok, Fsm#{state := S}};
        {stop, Reason, S} ->
            {Sign, S1} = xl_state:leave(S, Reason),
            transfer(Fsm#{state := S1}, Sign);
        {stop, Reason, Reply, S} ->
            {Sign, S1} = xl_state:leave(S, Reason),
            case transfer(Fsm#{state := S1}, Sign) of
                {ok, NewFsm} ->
                    {ok, Reply, NewFsm};
                {stop, R, NewFsm} ->
                    {stop, R, Reply, NewFsm}
            end
    end;
relay(_, _, Fsm) ->
    {ok, Fsm}.

on_command({_, _, stop}, Fsm) ->
    {Reply, Fsm1} = stop_fsm(Fsm, command),
    {stop, command, Reply, Fsm1};
on_command({_, _, {stop, Reason}}, Fsm) ->
    {Reply, Fsm1} = stop_fsm(Fsm, Reason),
    {stop, Reason, Reply, Fsm1};
%% First layer, FSM attribute. Atomic type is reserved for internal.
on_command({_, _, Key}, Fsm) when is_atom(Key) ->
    {ok, maps:get(Key, Fsm, undefined), Fsm};
on_command({_, _, Command},
           #{state_mode := standalone,
             status := running,
             state_pid := Pid
            } = Fsm) ->
    Timeout = maps:get(timeout, Fsm, infinity),
    Result = xl_state:call(Pid, Command, Timeout),
    {ok, Result, Fsm};  % notice: timeout exception
on_command(Command, #{status := running} = Fsm) ->
    relay(Command, Fsm);
on_command(_, Fsm) ->
    {ok, unknown, Fsm}.

on_notify({_, Info}, #{state_mode := standalone, state_pid := Pid} = Fsm) ->
    ok = gen_server:cast(Pid, Info),
    {ok, Fsm};
on_notify(Notification, #{status := running} = Fsm) ->
    relay(Notification, Fsm);
on_notify(_, Fsm) ->
    {ok, Fsm}.

on_message({'EXIT', Pid, {D, S}}, #{state_pid := Pid} = Fsm) ->
    transfer(Fsm#{state := S}, D); 
on_message(Message, #{state_mode := standalone, state_pid := Pid} = Fsm) ->
    Pid ! Message,
    {ok, Fsm};
on_message(Message, #{status := running} = Fsm) ->
    relay(Message, Fsm);
on_message(_, Fsm) ->
    {ok, Fsm}.

transfer(Fsm, Sign) ->
    Step = maps:get(step, Fsm, 0),
    F1 = Fsm#{step => Step + 1},
    post_transfer(pre_transfer(F1, Sign)).

pre_transfer(#{steps := Steps, max_steps := MaxSteps} = Fsm, _)
  when Steps >= MaxSteps ->
    pre_transfer(Fsm#{reason => out_of_steps}, exception);
pre_transfer(Fsm, Sign) ->
    try
        {ok, next(Fsm, Sign), Fsm}
    catch
        error: _BadKey when Sign =:= exception ->
            {stop, no_such_state, Fsm};
        error: _BadKey when Sign =:= stop ->
            {stop, normal, Fsm};
        error: _BadKey ->
            transfer(Fsm, exception)
    end.

post_transfer({stop, _, _} = Stop) ->
    Stop;
post_transfer({ok, NewState, Fsm}) ->
    F1 = archive(Fsm),
    F2 = F1#{state => NewState, state_mode => reuse},
    case engine_mode(F2) of
        standalone ->
            case xl_state:start_link(NewState) of
                {ok, Pid} ->
                    {ok, F2#{state_pid => Pid, state_mode => standalone}};
                {error, {Sign, State}} ->
                    transfer(F2#{state => State}, Sign)
            end;
        _Reuse ->
            case xl_state:enter(NewState) of
                {ok, State} ->
                    {ok, F2#{state => State}};
                {Sign, ErrState} ->
                    transfer(F2#{state => ErrState}, Sign)
            end
    end.
    
engine_mode(#{state := #{engine := Mode}}) ->
    Mode;
engine_mode(#{engine := Mode}) ->
    Mode;
engine_mode(_) ->
    reuse.

stop_fsm(#{status := running} = Fsm, Reason) ->
    case stop_1(Fsm, Reason) of
        {Sign, #{status := running} = Fsm1} ->
            {Sign, Fsm1#{status := stopped}};
        Result ->
            Result
    end;
stop_fsm(#{status := exception} = Fsm, _) ->
    {exception, Fsm};
stop_fsm(#{sign := Sign} = Fsm, _) ->
    {Sign, Fsm};
stop_fsm(Fsm, _) ->
    {stopped, Fsm}.

stop_1(#{state_mode := standalone, state_pid := Pid} = Fsm, Reason) ->
    case is_process_alive(Pid) of
        true->
            Timeout = maps:get(timeout, Fsm, infinity),
            case catch xl_state:stop(Pid, Reason, Timeout) of
                {'EXIT', timeout} ->
                    {timeout, Fsm#{status := exception}};
                {Sign, FinalState} ->
                    {Sign, Fsm#{state => FinalState, sign => Sign}}
            end;
        false ->
            {stopped, Fsm}
    end;
stop_1(#{state := State} = Fsm, Reason) ->
    {Sign, FinalState} = xl_state:leave(State, Reason),
    {Sign, Fsm#{state => FinalState, sign => Sign}};
stop_1(Fsm, _) ->
    {stopped, Fsm}.

archive(#{traces := Trace} = Fsm) when is_function(Trace) ->
    Trace(Fsm);
archive(#{state := State} = Fsm)  ->
    Trace = maps:get(traces, Fsm, []),
    Limit = maps:get(max_traces, Fsm, infinity),
    NewTrace = [State | Trace],
    if
        length(NewTrace) > Limit ->
            Fsm#{traces => lists:droplast(NewTrace)};
        true ->
            Fsm#{traces => NewTrace}
    end;
archive(Fsm) ->
    Fsm.

%%%===================================================================
%%% Unit test
%%%===================================================================
-ifdef(TEST).

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
        {xlx, {stop, _Reason}} ->
            exit(pi)
    end.

work_fast(_S) ->
    exit(pi).

s_react(transfer, S) ->
    {stop, transfer, S};
s_react({xlx, _, {get, state}}, S) ->
    {ok, maps:get(state_name, S), S};
s_react({xlx, {transfer, Next}}, S) ->
    {stop, transfer, S#{sign => Next}};
s_react(_, S) ->  % drop unknown message.
    {ok, S}.

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
    States = #{{'_root', start} => S1,
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
    
fsm_reuse_test() ->
    Fsm = create_fsm(),
    %% reuse fsm process, is default.
    fsm_test_cases(Fsm).
fsm_standalone_test() ->
    Fsm = create_fsm(),
    %% standalone process for each state.
    Fsm1 = Fsm#{engine => standalone, max_traces => 3},
    fsm_test_cases(Fsm1).

fsm_test_cases(Fsm) ->
    erlang:process_flag(trap_exit, true),
    {ok, Pid} = xl_state:start_link(Fsm),
    ?assert(state1 =:= xl_state:call(Pid, {get, state})),
    ?assertMatch(#{state_name := state1}, gen_server:call(Pid, state)),
    Pid ! transfer,
    timer:sleep(10),
    ?assert(state2 =:= gen_server:call(Pid, {get, state})),
    ?assert(2 =:=  gen_server:call(Pid, step)),
    gen_server:cast(Pid, {transfer, s4}),
    timer:sleep(10),
    ?assert(state4 =:= xl_state:call(Pid, {get, state})),
    gen_server:cast(Pid, {transfer, s5}),
    timer:sleep(10),
    ?assert(state5 =:= xl_state:call(Pid, {get, state})),
    ?assert(running =:= xl_state:call(Pid, status)),
    gen_server:cast(Pid, {transfer, s3}),
    timer:sleep(10),
    ?assert(state2 =:= xl_state:call(Pid, {get, state})),
    {s1, Final} = xl_state:stop(Pid),
    ?assertMatch(#{step := 6, status := stopped}, Final),
    #{traces := Trace, step := Step} = Final,
    case maps:get(max_traces, Final, infinity) of
        infinity ->
            ?assert(Step - 1 =:= length(Trace));
        MaxTrace ->
            ?assert(MaxTrace =:= length(Trace))
        end.

-endif.
