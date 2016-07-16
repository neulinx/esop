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
-export([do/1, react/2, exit/1]).

-ifdef(TEST).
    -include_lib("eunit/include/eunit.hrl").
-endif.

-define(RETRY_INTERVAL, 5).
-define(DFL_TIMEOUT, 4500).
-define(MAX_TRACES, 1000).

%%--------------------------------------------------------------------
%% Common types
%%--------------------------------------------------------------------
-export_type([fsm/0]).

-type name() :: term().
-type sign() :: term().  % must not be tuple type.
-type vector() :: {name(), sign()} | (FromRoot :: sign()).
-type limit() :: pos_integer() | 'infinity'.
-type state() :: #{'name' := term()}  % mandatory
               | xl_state:state().
-type states() :: states_table() | states_fun().
-type states_table() :: #{From :: vector() => To :: state()}.
-type states_fun() :: fun((From :: name(), sign()) -> To :: state()).
-type rollback() :: 0 | neg_integer() | 'restart' | (Sign :: term()).
%% imo, bad design. Low level design should avoid decision.
-type recovery() :: rollback() |  % restore mode is default.
                    {rollback()} |  % restore
                    {rollback(), Mend :: map()} |  % restore
                    {'restore', rollback(), Mend :: map()} |
                    {'reset', rollback(), Mend :: map()}.
-type fsm() :: #{'state' => state(),
                 'states' := states(),
                 'state_pid' => pid(),
                 'actor' => pid() | atom(),
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
-type do_ret() :: xl_state:ok() | xl_state:fail().
-type exit_ret() :: xl_state:output().
-type react_ret() :: xl_state:ok() | xl_state:fail().

%%--------------------------------------------------------------------
%% @doc
%% Actions of state.
%% @end
%%--------------------------------------------------------------------
-spec do(fsm()) -> do_ret().
do(Fsm) ->
    erlang:process_flag(trap_exit, true),
    transfer(Fsm, start).

-spec react(Message :: term(), fsm()) -> react_ret().
react(Message, Fsm) ->
    process(Message, Fsm).

-spec exit(fsm()) -> exit_ret().
exit(Fsm) ->
    Reason = maps:get(reason, Fsm, normal),
    stop_fsm(Fsm, Reason).

%%--------------------------------------------------------------------
%% There is a graph structure in states set.
%%
%% Sign must not be tuple type. Data in map should be {From, Sign} := To.
%% The first level states may leave out vertex '_root' as Sign := To.
%%--------------------------------------------------------------------
next(#{state := State}, start) ->
    State;
next(#{state := State, states := States}, Sign) ->
    Name = maps:get(name, State),
    locate(States, {Name, Sign});
next(#{states := States}, Sign) ->
    locate(States, Sign).

locate(States, Sign) when is_function(States) ->
    States(Sign);
locate(States, Sign) ->
    maps:get(Sign, States).


%%--------------------------------------------------------------------
%% Divide messages into three types of handlers.
%%--------------------------------------------------------------------
process({xlx, _, _} = Command, Fsm) ->
    on_command(Command, Fsm);
process({xlx, _} = Notification, Fsm) ->
    on_notify(Notification, Fsm);
process(Message, Fsm) ->
    on_message(Message, Fsm).

%% First layer, FSM attribute. Atomic type is reserved for internal.
on_command({_, _, Key}, Fsm) when is_atom(Key) ->
    {ok, maps:find(Key, Fsm), Fsm};
on_command(Command, #{status := running, state_pid := Pid} = Fsm) ->
    Pid ! Command,  % relay message and noreply for call.
    {ok, Fsm};
on_command(Command, #{status := failover} = Fsm) ->
    pending(Command, Fsm);
on_command(_Command, Fsm) ->
    {ok, {error, unhandled}, Fsm}.

%% Queue the notification received in failover status.
on_notify(Info, #{status := failover} = Fsm) ->
    pending(Info, Fsm);
%% Unload command cause FSM stop and thow current FSM data dehydrated.
on_notify({_, {stop, xlx_unload}},
          #{state_pid := Pid, status := running} = Fsm) ->
    Timeout = maps:get(timeout, Fsm, ?DFL_TIMEOUT),
    case xl_state:unload(Pid, Timeout) of
        {unloaded, State} ->
            {ok, Fsm#{state => State}};
        NotReady ->
            {stop, {error, NotReady}, Fsm}
    end;
on_notify(Info, #{state_pid := Pid,
                  status := running} = Fsm) ->
    Pid ! Info,
    {ok, Fsm};
on_notify(_, Fsm) ->
    {ok, {error, unhandled}, Fsm}.

on_message(xlx_retry, #{status := failover} = Fsm) ->
    retry(Fsm); 
on_message(Info, #{status := failover} = Fsm) ->
    pending(Info, Fsm);
on_message({'EXIT', Pid, {D, S}}, #{state_pid := Pid} = Fsm) ->
    transfer(Fsm#{state := S}, D);
on_message({'EXIT', Pid, Exception}, #{state_pid := Pid} = Fsm) ->
    transfer(Fsm#{reason => Exception}, exception);
%% Unknown EXIT signal. Stop FSM for OTP principles.
on_message({'EXIT', _, _} = Kill, Fsm) ->
    {stop, Kill, Fsm};
on_message(Message, #{status := running,
                      state_pid := Pid} = Fsm) ->
    Pid ! Message,
    {ok, Fsm};
on_message(_, Fsm) ->
    {ok, {error, unhandled}, Fsm}.

%%--------------------------------------------------------------------
%% Main part of FSM logic, state changing.
%%--------------------------------------------------------------------
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
    F2 = F1#{state => NewState},  % Keep the initial state in Fsm.
    Actor = maps:get(actor, F2, self()),
    case xl_state:start_link(NewState#{actor => Actor}) of
        {ok, Pid} ->
            {ok, F2#{state_pid => Pid}};
        {error, {Sign, State}} ->
            transfer(F2#{state => State}, Sign);
        {error, Exception} ->  % For unhandled exceptions.
            transfer(F2#{reason => Exception}, exception)
    end.

%%--------------------------------------------------------------------
%% Failover and recovery.
%%-------------------------------------------------------------------- 
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
    Name = maps:get(name, State),
    NewState = locate(States, Name),
    Fsm#{state := NewState}.

%% Do not enqueue the message which crashed the state process.
pending(_Request, #{max_pending_size := 0} = Fsm) ->
    {ok, Fsm};
pending(Request, #{max_pending_size := Max} = Fsm) ->
    Q = maps:get(pending_queue, Fsm, []),
    Q1 = enqueue(Request, Q, Max),
    {ok, Fsm#{pending_queue => Q1}};
pending(_Request, Fsm) ->
    {ok, Fsm}.

%%--------------------------------------------------------------------
%% Operations of trace log for state transitions.
%%--------------------------------------------------------------------
history(Traces, N) when -N =< length(Traces) ->
    lists:nth(-N, Traces);
history(Traces, N) when is_function(Traces) ->
    Traces(N);  % traces function must return out_of_range only on exception.
history(_, _) ->
    out_of_range.

archive(#{traces := Trace} = Fsm) when is_function(Trace) ->
    Trace(Fsm);
archive(#{state := State} = Fsm)  ->
    Trace = maps:get(traces, Fsm, []),
    Limit = maps:get(max_traces, Fsm, ?MAX_TRACES),
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

%%--------------------------------------------------------------------
%% Stop FSM and throw output.
%%--------------------------------------------------------------------

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

stop_1(#{state_pid := Pid} = Fsm, Reason) ->
    case is_process_alive(Pid) of
        true->
            Timeout = maps:get(timeout, Fsm, ?DFL_TIMEOUT),
            try xl_state:stop(Pid, Reason, Timeout) of
                {Sign, FinalState} ->
                    {Sign, Fsm#{state => FinalState, sign => Sign}}
            catch
                _: Error ->  % should be exit: timeout
                    erlang:exit(Pid, kill),  % Mention case of trap exit.
                    {Error, Fsm#{status := exception}}
            end;
        false ->
            {stopped, Fsm}
    end;
stop_1(Fsm, _) ->
    {stopped, Fsm}.

%%%===================================================================
%%% Unit test. If code lines of unit tests are more than 100, 
%%% move them to standalone test file in test folder.
%%%===================================================================
-ifdef(TEST).


-endif.
