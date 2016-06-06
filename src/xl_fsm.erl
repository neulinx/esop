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

-define(RETRY_INTERVAL, 1).
%%%===================================================================
%%% Common types
%%%===================================================================
-export_type([engine/0, fsm/0]).

-type engine() :: 'reuse' | 'standalone'.
-type name() :: term().
-type sign() :: term().  % must not be tuple type.
-type vector() :: {name(), sign()} | (FromRoot :: sign()).
-type limit() :: pos_integer() | 'infinity'.
-type state() :: #{'state_name' => term(),
                   'engine' => engine()}
               | xl_state:state().
-type states() :: states_table() | states_fun().
-type states_table() :: #{From :: vector() => To :: state()}.
-type states_fun() :: fun((From :: name(), sign()) -> To :: state()).
-type rollback() :: 0 | neg_integer() | 'restart' | (Sign :: term()).
-type recovery() :: rollback() |  % restore mode is default.
                    {rollback()} |  % restore
                    {rollback(), Mend :: map()} |  % restore
                    {'restore', rollback(), Mend :: map()} |
                    {'reset', rollback(), Mend :: map()}.
-type fsm() :: #{'state' => state(),
                 'states' => states(),
                 'state_mode' => engine(),
                 'state_pid' => pid(),
                 'engine' => engine(),
                 'step' => non_neg_integer(),
                 'max_steps' => limit(),
                 'recovery' => recovery(),
                 'max_retry' => limit(),
                 'retry_count' => non_neg_integer(),
                 'retry_interval' => non_neg_integer(),
                 'max_pending_size' => limit(),
                 'pending_queue' => list(),
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
%% todo: Add requests to queue when status is failover.
react(Message, Fsm) ->
    try process(Message, Fsm) of
        Output ->
            Output
    catch
        C: E ->
            {ok, Fsm1} = pending(Message, Fsm),
            transfer(Fsm1#{reason => {C, E}}, exception)
    end.

-spec exit(fsm()) -> exit_ret().
exit(Fsm) ->
    Reason = maps:get(reason, Fsm, normal),
    stop_fsm(Fsm, Reason).

%%%===================================================================
%%% Internal functions
%%%===================================================================
%% Sign must not be tuple type. Data in map should be {From, Sign} := To.
%% The first level states may leave out vertex '_root' as Sign := To.
next(#{state := State}, start) ->
    State;
next(#{state := State, states := States}, Sign) ->
    Name = maps:get(state_name, State),
    locate(States, {Name, Sign});
next(#{states := States}, Sign) ->
    locate(States, Sign).

locate(States, Sign) when is_function(States) ->
    States(Sign);
locate(States, Sign) ->
    maps:get(Sign, States).

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

%% First layer, FSM attribute. Atomic type is reserved for internal.
on_command({_, _, Key}, Fsm) when is_atom(Key) ->
    {ok, maps:get(Key, Fsm, undefined), Fsm};
on_command(Command,
           #{state_mode := standalone,
             status := running,
             state_pid := Pid} = Fsm) ->
    Pid ! Command,  % relay message and noreplay for call.
    {ok, Fsm};
on_command(Command, #{status := running} = Fsm) ->
    relay(Command, Fsm);
on_command(Command, #{status := failover} = Fsm) ->
    pending(Command, Fsm);
on_command(_, Fsm) ->
    {ok, unavailable, Fsm}.

on_notify(Info, #{status := failover} = Fsm) ->
    pending(Info, Fsm);
on_notify(Info, #{state_mode := standalone,
                  state_pid := Pid,
                  status := running} = Fsm) ->
    Pid ! Info,
    {ok, Fsm};
on_notify(Notification, #{status := running} = Fsm) ->
    relay(Notification, Fsm);
on_notify(_, Fsm) ->
    {ok, Fsm}.

on_message(xlx_retry, #{status := failover} = Fsm) ->
    retry(Fsm); 
on_message(Info, #{status := failover} = Fsm) ->
    pending(Info, Fsm);
on_message({'EXIT', Pid, {D, S}}, #{state_pid := Pid} = Fsm) ->
    transfer(Fsm#{state := S}, D);
on_message({'EXIT', Pid, Exception}, #{state_pid := Pid} = Fsm) ->
    transfer(Fsm#{reason => Exception}, exception); 
on_message(Message, #{state_mode := standalone,
                      status := running,
                      state_pid := Pid} = Fsm) ->
    Pid ! Message,
    {ok, Fsm};
on_message(Message, #{status := running} = Fsm) ->
    relay(Message, Fsm);
on_message(_, Fsm) ->
    {ok, Fsm}.

pre_transfer(#{steps := Steps, max_steps := MaxSteps} = Fsm, _)
  when Steps >= MaxSteps ->
    pre_transfer(Fsm#{reason => out_of_steps}, exception);
pre_transfer(Fsm, Sign) ->
    try
        {ok, next(Fsm, Sign), Fsm}
    catch
        error: _BadKey when Sign =:= exception ->
            {recover, Fsm};
        error: _BadKey when Sign =:= stop ->
            {stop, normal, Fsm};
        error: _BadKey ->
            transfer(Fsm, exception)
    end.

post_transfer({ok, #{max_pending_size := Max, pending_queue := Gap} = Fsm})
  when Max > 0 andalso length(Gap) > 0 ->
    Self = self(),
    [Self ! Message || Message <- Gap],  % Re-send.
    {ok, Fsm#{pending_queue := []}};
post_transfer(Result) ->
    Result.

transfer(Fsm, Sign) ->
    Step = maps:get(step, Fsm, 0),
    F1 = Fsm#{step => Step + 1},
    post_transfer(transfer(pre_transfer(F1, Sign))).

transfer({recover, Fsm}) ->
    recover(Fsm);
transfer({stop, _, _} = Stop) ->
    Stop;
transfer({ok, NewState, Fsm}) ->
    F1 = archive(Fsm),  % archive successful states only.
    F2 = F1#{state => NewState, state_mode => reuse},
    case engine_mode(F2) of
        standalone ->
            case xl_state:start_link(NewState) of
                {ok, Pid} ->
                    {ok, F2#{state_pid => Pid, state_mode => standalone}};
                {error, {Sign, State}} ->
                    transfer(F2#{state => State}, Sign);
                {error, Exception} ->
                    transfer(F2#{reason => Exception}, exception)
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

%% To slow down the failover progress, retry operation always
%% triggered by message.
recover(#{retry_count := Count, max_retry := Max} = Fsm) when Count >= Max ->
    {stop, max_retry, Fsm#{status => exception}};
recover(#{recovery := _} = Fsm) ->
    Interval = maps:get(retry_interval, Fsm, ?RETRY_INTERVAL),
    Count = maps:get(retry_count, Fsm, 0),
    erlang:send_after(Interval, self(), xlx_retry),
    {ok, Fsm#{status := failover, retry_count => Count + 1}};
recover(Fsm) ->
    {stop, exception, Fsm#{status => exception}}.

retry(#{recovery := Recovery} = Fsm) ->
    try mend(Recovery, Fsm) of
        NewFsm ->
            transfer(NewFsm#{status := running}, start)
    catch
        throw: Stop ->
            Stop;
        _: _ ->
            {stop, fail_to_recover, Fsm#{status := exception}}
    end.

mend({Rollback}, Fsm) ->
    mend({restore, Rollback, #{}}, Fsm);
mend({Rollback, Mend}, Fsm) ->
    mend({restore, Rollback, Mend}, Fsm);
mend({Mode, Rollback, Mend}, Fsm) ->
    NewFsm = failover(Fsm, Rollback, Mode),
    maps:merge(NewFsm, Mend);
mend(Rollback, Fsm) ->
    mend({restore, Rollback, #{}}, Fsm).

failover(#{states := States} = Fsm, restart, _Mode) ->  % From start point.
    Start = locate(States, start),
    Fsm#{state => Start};
failover(Fsm, 0, reset) -> %  Restore.
    reset_state(Fsm);
failover(Fsm, 0, _) ->  % Rewind.
    Fsm;
failover(#{traces := Traces} = Fsm, N, Mode) when N < 0 ->  % Rollback.
    case history(Traces, N) of
        out_of_range ->
            throw({stop, out_of_range, Fsm#{status := exception}});
        History when Mode =:= reset ->
            reset_state(Fsm#{state := History});
        History ->
            Fsm#{state := History}
    end;
failover(#{states := States} = Fsm, Reroute, _Mode) ->  % Reroute.
    State = locate(States, Reroute),  % not bypass, redirect a new state
    Fsm#{state => State}.
    
reset_state(#{state := State, states := States} = Fsm) ->
    Name = maps:get(state_name, State),
    NewState = locate(States, Name),
    Fsm#{state := NewState}.

history(Traces, N) when -N =< length(Traces) ->
    lists:nth(-N, Traces);
history(Traces, N) when is_function(Traces) ->
    Traces(N);  % traces function must return out_of_range only on exception.
history(_, _) ->
    out_of_range.

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
    Trace1 = enqueue(State, Trace, Limit),
    Fsm#{traces => Trace1};
archive(Fsm) ->
    Fsm.

enqueue(_Item, _Queue, 0) ->
    [];
enqueue(Item, Queue, infinity) ->
    [Item | Queue];
enqueue(Item, Queue, Limit) ->
    lists:sublist([Item | Queue], Limit).

pending(_Request, #{max_pending_size := 0} = Fsm) ->
    {ok, Fsm};
pending(Request, #{max_pending_size := Max} = Fsm) ->
    Q = maps:get(pending_queue, Fsm, []),
    Q1 = enqueue(Request, Q, Max),
    {ok, Fsm#{pending_queue => Q1}};
pending(_Request, Fsm) ->
    {ok, Fsm}.

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
            erlang:exit(pi)
    end.

work_fast(_S) ->
    erlang:exit(pi).

%% Set counter 2 as pitfall.
s_react({xlx, _, "error_test"}, #{counter := Count} = S) when Count =:= 2 ->
    error(error_test),
    {ok, exceptin_raised, S};
s_react({xlx, _, "error_test"}, S) ->
    Count = maps:get(counter, S, 0),
    {ok, Count + 1, S#{counter => Count + 1}};
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
    
fsm_reuse_test() ->
    Fsm = create_fsm(),
    Fsm1 = Fsm#{max_pending_size => 5,
             recovery => {0, #{recovery => {reset, 0, #{}}}}},
    %% reuse fsm process, is default.
    fsm_test_cases(Fsm1).
fsm_standalone_test() ->
    Fsm = create_fsm(),
    Fsm1 = Fsm#{recovery => {state2,
                #{recovery => {reset, -1, #{new_data => 1}}}}},
    %% standalone process for each state.
    Fsm2 = Fsm1#{engine => standalone, max_traces => 4},
    fsm_test_cases(Fsm2).

fsm_test_cases(Fsm) ->
    %% Prepare.
    erlang:process_flag(trap_exit, true),
    error_logger:tty(false),
    {ok, Pid} = xl_state:start_link(Fsm),
    %% Basic actions.
    ?assert(state1 =:= xl_state:call(Pid, {get, state})),
    ?assertMatch(#{state_name := state1}, gen_server:call(Pid, state)),
    Pid ! transfer,
    timer:sleep(4),
    ?assert(state2 =:= gen_server:call(Pid, {get, state})),
    ?assert(2 =:=  gen_server:call(Pid, step)),
    %% Failover test.
    ?assert(1 =:= xl_state:call(Pid, "error_test")),
    ?assert(2 =:= xl_state:call(Pid, "error_test")),
    case xl_state:call(Pid, max_pending_size) of
        5 ->
            ?assertMatch(1, xl_state:call(Pid, "error_test"));
        _ ->
            catch xl_state:call(Pid, "error_test", 1)
    end,
    timer:sleep(4),
    %% Worker inside state test.
    gen_server:cast(Pid, {transfer, s4}),
    timer:sleep(4),
    ?assertMatch(state4, xl_state:call(Pid, {get, state})),
    gen_server:cast(Pid, {transfer, s5}),
    timer:sleep(4),
    ?assert(state5 =:= xl_state:call(Pid, {get, state})),
    ?assert(running =:= xl_state:call(Pid, status)),
    gen_server:cast(Pid, {transfer, s3}),
    timer:sleep(4),
    ?assert(state2 =:= xl_state:call(Pid, {get, state})),
    %% Failover test again.
    ?assert(1 =:= xl_state:call(Pid, "error_test")),
    ?assert(2 =:= xl_state:call(Pid, "error_test")),
    catch xl_state:call(Pid, "error_test", 1),
    %% Stop. 
    timer:sleep(4),
    {Sign, Final} = xl_state:stop(Pid),
    #{traces := Trace} = Final,
    case maps:get(max_traces, Final, infinity) of
        infinity ->  % Trace_reuse: 1->*2->*2->2->4->5->3->*2=>2
            ?assertMatch(s1, Sign),
            ?assertMatch(#{step := 12}, Final),
            ?assertMatch(8, length(Trace));
        MaxTrace ->  % Trace_standalone: 1->*2->2->4->5->3->*3->3->1
            ?assertMatch(s1, Sign),
            ?assertMatch(#{step := 11, new_data := 1}, Final),
            ?assertMatch(MaxTrace, length(Trace))
    end.

-endif.
