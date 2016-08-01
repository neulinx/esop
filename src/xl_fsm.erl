%%%-------------------------------------------------------------------
%%% @author Gary Hai <gary@XL59.com>
%%% @copyright (C) 2016, Neulinx Platforms.
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
-type process() :: pid() | atom().
-type state() :: #{'name' := term(),
                   'actor' := process(),
                   'fsm' := process(),
                   'engine' => engine()} | xl_state:state().
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
                 'state_mode' => engine(),
                 'actor' => process(),
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
-type engine() :: 'reuse' | 'standalone'.

%%--------------------------------------------------------------------
%% @doc
%% Actions of state.
%% @end
%%--------------------------------------------------------------------
-spec do(fsm()) -> xl_state:result().
do(Fsm) ->
    erlang:process_flag(trap_exit, true),
    transfer(Fsm, start).

-spec react(Message :: term(), fsm()) -> xl_state:result().
react(Message, Fsm) ->
    try process(Message, Fsm) of
        Output ->
            Output
    catch
        C: E ->
            %% skip the fatal message    {ok, Fsm1} = pending(Message, Fsm),
            case maps:find(state_mode, Fsm) of 
                {ok, reuse} ->
                    State = maps:get(state, Fsm),
                    S0 = State#{status := exception},
                    {Sign, S} = xl_state:leave(S0, {C, E}),
                    transfer(Fsm#{reason => {C, E}, state := S}, Sign);
                _ ->
                    transfer(Fsm#{reason => {C, E}}, exception)
            end
    end.

-spec exit(fsm()) -> xl_state:output().
exit(Fsm) ->
    Reason = maps:get(reason, Fsm, normal),
    {Sign, F} = stop_fsm(Fsm, Reason),
    Output = get_payload(F),
    {Sign, F#{io => Output}}.

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

relay(Message, #{state := State, status := running} = Fsm) ->
    relay(Message, State, Fsm);
relay({xlx, _, _}, Fsm) ->
    {error, not_ready, Fsm};
relay(_, Fsm) ->
    {ok, unhandled, Fsm}.

relay(Message, #{react := React} = State, Fsm) ->
    case React(Message, State) of
        {Code, S} ->
            {Code, Fsm#{state := S}};
        {stop, Reason, S} ->
            {Sign, S1} = xl_state:leave(S, Reason),
            transfer(Fsm#{state := S1}, Sign);
        {Code, Reason, Reply, S} ->
            {Sign, S1} = xl_state:leave(S, Reason),
            case transfer(Fsm#{state := S1}, Sign) of
                {ok, NewFsm} ->
                    {ok, Reply, NewFsm};
                {stop, R, NewFsm} ->
                    {Code, R, Reply, NewFsm}
            end;
        {Code, R, S} ->
            {Code, R, Fsm#{state := S}}
    end;
relay(_, _, Fsm) ->
    {ok, unhandled, Fsm}.

%% Subscribe do not relay to state.
%% todo: special subscribe method for FSM
on_command({_, _, subscribe}, Fsm) ->
    {ok, unhandled, Fsm};
on_command({_, _, {subscribe, _}}, Fsm) ->
    {ok, unhandled, Fsm};
%% First layer, FSM attribute. Atomic type is reserved for internal.
on_command({_, _, {get, Key}}, Fsm) when is_atom(Key) ->
    case maps:find(Key, Fsm) of
        {ok, V} ->
            {ok, V, Fsm};
        error ->
            {error, not_found, Fsm}
        end;
on_command(Command, #{state_mode := reuse, status := running} = Fsm) ->
    relay(Command, Fsm);
on_command(Command, #{status := running, state_pid := Pid} = Fsm) ->
    Pid ! Command,  % relay message and noreply for call.
    {ok, Fsm};
on_command(Command, #{status := failover} = Fsm) ->
    pending(Command, Fsm);
on_command(_Command, Fsm) ->
    {ok, unhandled, Fsm}.

%% The very first message wake up from unload.
on_notify({_, xlx_wakeup} = Info, #{state := S} = Fsm) ->
    erlang:process_flag(trap_exit, true),  % restore trap_exit.
    Actor = maps:get(actor, Fsm, self()),
    NewS = S#{actor => Actor, fsm => self()},
    NewF = Fsm#{state := NewS},
    case maps:get(state_mode, NewF) of
        reuse ->
            relay(Info, NewF);
        standalone ->
            case xl_state:start_link(NewS) of
                {ok, Pid} ->
                    {ok, NewF#{state_pid => Pid}};
                {error, {Sign, NewS1}} ->
                    transfer(NewF#{state => NewS1}, Sign);
                {error, Exception} ->
                    transfer(NewF#{reason => Exception}, exception)
            end
    end;
%% todo: notify and unsubscribe
on_notify({_, {unsubscribe, _}}, Fsm) ->
    {ok, unhandled, Fsm};
on_notify({_, {notify, _}}, Fsm) ->
    {ok, unhandled, Fsm};
%% Queue the notification received in failover status.
on_notify(Info, #{status := failover} = Fsm) ->
    pending(Info, Fsm);
%% Unload command cause FSM stop and thow current FSM data dehydrated.
on_notify({_, {stop, xlx_unload}},
          #{state_mode := reuse, state := S, status := running} = Fsm) ->
    case xl_state:leave(S, xlx_unload) of
        {unloaded, State} ->
            {stop, xlx_unload, Fsm#{state => State}};
        NotReady ->
            {error, NotReady, Fsm}
    end;
on_notify({_, {stop, xlx_unload}},
          #{state_pid := Pid, status := running} = Fsm) ->
    Timeout = maps:get(timeout, Fsm, ?DFL_TIMEOUT),
    case xl_state:unload(Pid, Timeout) of
        {unloaded, State} ->
            {stop, xlx_unload, Fsm#{state => State}};
        NotReady ->
            {error, NotReady, Fsm}
    end;
on_notify(Info, #{state_mode := reuse, status := running} = Fsm) ->
    relay(Info, Fsm);
on_notify(Info, #{state_pid := Pid,
                  status := running} = Fsm) ->
    Pid ! Info,
    {ok, Fsm};
on_notify(_, Fsm) ->
    {ok, unhandled, Fsm}.

on_message(xlx_retry, #{status := failover} = Fsm) ->
    retry(Fsm); 
on_message(Info, #{status := failover} = Fsm) ->
    pending(Info, Fsm);
on_message({'EXIT', Pid, {D, S}}, #{state_pid := Pid} = Fsm) ->
    transfer(Fsm#{state := S}, D);
on_message({'EXIT', Pid, Exception}, #{state_pid := Pid} = Fsm) ->
    transfer(Fsm#{reason => Exception}, exception);
on_message({'EXIT', Pid, Result}, #{state_mode := reuse,
                                    status := running,
                                    state := #{worker := Pid} = S} = Fsm) ->
    case xl_state:yield(Result, S) of
        {Code, NewS} ->
            {Code, Fsm#{state := NewS}};
        {stop, Reason, SFail} ->
            {Sign, S1} = xl_state:leave(SFail, Reason),
            transfer(Fsm#{state := S1}, Sign)
    end;
on_message(Message, #{state_mode := reuse, status := running} = Fsm) ->
    relay(Message, Fsm);
on_message(Message, #{status := running,
                      state_pid := Pid} = Fsm) ->
    Pid ! Message,
    {ok, Fsm};
on_message(_, Fsm) ->
    {ok, unhandled, Fsm}.

%%--------------------------------------------------------------------
%% Main part of FSM logic, state changing.
%%--------------------------------------------------------------------
%% limit steps, fetch next state, load input data. 
pre_transfer(#{steps := Steps, max_steps := MaxSteps} = Fsm, _)
  when Steps >= MaxSteps ->
    pre_transfer(Fsm#{reason => out_of_steps}, exception);
pre_transfer(#{status := Status} = Fsm, Sign) ->
    %% You can provide your own cutomized exception and stop state.
    try next(Fsm, Sign) of
        stop ->
            {stop, normal, Fsm};
        Next when Status =:= failover ->
            {ok, Next, Fsm#{status := running}};
        Next ->
            Payload = get_payload(Fsm),
            {ok, Next#{io => Payload}, Fsm}
    catch
        error: _BadKey when Sign =:= exception ->
            {recover, Fsm};
        error: _BadKey when Sign =:= ok ->
            {stop, normal, Fsm};
        error: _BadKey when Sign =:= stop ->
            {stop, normal, Fsm};
        error: _BadKey when Sign =:= stopped ->
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

%% transfer(#{state := #{name := Name}, step := Step} = F, Sign) ->
%%     ?debugVal({Step, Name, Sign}),
%%     transfer_(F, Sign);
%% transfer(F, Sign) ->
%%     ?debugVal({fsm, Sign}),
%%     transfer_(F, Sign).    

transfer(Fsm, Sign) ->
    Step = maps:get(step, Fsm, 0),
    F1 = Fsm#{step => Step + 1},
    post_transfer(transfer(pre_transfer(F1, Sign))).

transfer({recover, Fsm}) ->
    recover(Fsm);
transfer({stop, _, _} = Stop) ->
    Stop;
transfer({ok, NewState, Fsm}) ->
    F1 = archive(Fsm),  % archive successful states only, for recovery.
    Actor = maps:get(actor, F1, self()),
    S = NewState#{actor => Actor, fsm => self()},
    F2 = F1#{state => S},
    Engine = engine_mode(F2),
    F3 = maps:remove(state_pid, F2#{state_mode => Engine}),
    case Engine of
        standalone ->
            case xl_state:start_link(S) of
                {ok, Pid} ->
                    {ok, F3#{state_pid => Pid}};
                {error, {Sign, S1}} ->
                    transfer(F3#{state => S1}, Sign);
                {error, Exception} ->
                    transfer(F3#{reason => Exception}, exception)
            end;
        reuse ->
            case xl_state:enter(S) of
                {ok, S1} ->
                    case xl_state:do_activity(S1) of
                        {_, S2} ->  % ok or error, but still running.
                            {ok, F3#{state => S2}};
                        {stop, Reason, S2} ->
                            {Sign, Final} = xl_state:leave(S2, Reason),
                            transfer(F3#{state => Final}, Sign)
                    end;
                {stop, {Flag, ErrState}} ->
                    transfer(F3#{state => ErrState}, Flag)
            end
    end.

%% standalone is the default mode.
engine_mode(#{state := #{engine := Mode}}) ->
    Mode;
engine_mode(#{engine := Mode}) ->
    Mode;
engine_mode(_) ->
    standalone.

%% extract payload, may be input or output.
get_payload(#{state := S}) ->
    maps:get(io, S, undefined);
get_payload(#{io := Payload}) ->
    Payload;
get_payload(_) ->
    undefined.

%% Get input only, should be the previous state output.
%% N is not positive data, minus means previous steps.
get_input(#{traces := Traces} = Fsm, N) ->
    case history(Traces, N - 1) of
        #{io := Input} ->
            Input;
        _ ->  % no payload found, original input of the Fsm.
            maps:get(io, Fsm, undefined)
    end;
get_input(#{io := Input}, _) ->
    Input;
get_input(_, _) ->
    undefined.

%%--------------------------------------------------------------------
%% Failover and recovery.
%%-------------------------------------------------------------------- 
%% To slow down the failover progress, retry operation always
%% triggered by message.
recover(#{retry_count := Count, max_retry := Max} = Fsm) when Count >= Max ->
    {stop, max_retry, Fsm#{status := exception}};
recover(#{recovery := _} = Fsm) ->
    Interval = maps:get(retry_interval, Fsm, ?RETRY_INTERVAL),
    Count = maps:get(retry_count, Fsm, 0),
    erlang:send_after(Interval, self(), xlx_retry),
    {ok, Fsm#{status := failover, retry_count => Count + 1}};
recover(Fsm) ->
    {stop, exception, Fsm#{status := exception}}.

retry(#{recovery := Recovery} = Fsm) ->
    try mend(Recovery, Fsm) of
        NewFsm ->
            transfer(NewFsm, start)
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
    Payload = maps:get(io, Fsm, undefined),
    Fsm#{state => Start#{io => Payload}};  % reset payload also.
%% Reset state and rollback payload.
failover(#{state := #{name := Name}, states := States} = Fsm, 0, reset) ->
    S = locate(States, Name),
    Input = get_input(Fsm, 0),
    Fsm#{state := S#{io => Input}};
failover(Fsm, 0, _) ->  % Rewind, keep current payload untouched.
    Fsm;
failover(#{traces := Traces, states := States} = Fsm, N, Mode)
  when N < 0 ->  % Rollback, back to history state.
    Input = get_input(Fsm, N),  % is step N-1 output.
    case history(Traces, N) of
        out_of_range ->
            throw({stop, out_of_range, Fsm#{status := exception}});
        #{name := Name} when Mode =:= reset ->
            S = locate(States, Name),
            Fsm#{state := S#{io => Input}};
        History ->
            Fsm#{state := History#{io => Input}}  % should rollback payload.
    end;
failover(#{states := States} = Fsm, Reroute, _Mode) ->  % Reroute.
    Input = get_payload(Fsm),
    State = locate(States, Reroute),  % not bypass, redirect a new state
    Fsm#{state => State#{io => Input}}.
    
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

stop_1(#{state_mode := reuse, state := State} = Fsm, Reason) ->
    {Sign, FinalState} = xl_state:leave(State, Reason),
    {Sign, Fsm#{state => FinalState, sign => Sign}};
stop_1(#{state_pid := Pid} = Fsm, Reason) ->
    case is_process_alive(Pid) of
        true->
            Timeout = maps:get(timeout, Fsm, ?DFL_TIMEOUT),
            try xl_state:stop(Pid, Reason, Timeout) of
                {Sign, FinalState} ->
                    {Sign, Fsm#{state => FinalState, sign => Sign}}
            catch
                exit: timeout ->
                    erlang:exit(Pid, kill),  % Mention case of trap exit.
                    {abort, Fsm#{status := exception}}                    
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
