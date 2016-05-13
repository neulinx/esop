%%%-------------------------------------------------------------------
%%% @author Guiqing Hai <gary@XL59.com>
%%% @copyright (C) 2016, Guiqing Hai
%%% @doc
%%%
%%% @end
%%% Created : 30 Apr 2016 by Guiqing Hai <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(xl_fsm).

-compile({no_auto_import,[exit/1]}).
%% API
-export([create/1]).
-export([entry/1, react/2, exit/1]).

-ifdef(TEST).
    -include_lib("eunit/include/eunit.hrl").
-endif.

%%%===================================================================
%%% API
%%%===================================================================
create(Data) when is_map(Data) ->
    Data#{entry => fun ?MODULE:entry/1,
          exit => fun ?MODULE:exit/1,
          react => fun ?MODULE:react/2
         };
create(Data) when is_list(Data) ->
    create(maps:from_list(Data)).

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------
entry(Fsm) ->
    erlang:process_flag(trap_exit, true),
    transfer(Fsm, start).

react(Message, Fsm) ->
    process(Message, Fsm).

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
    next(States, '$root', Sign).

next(States, From, Sign) when is_function(States) ->
    States(From, Sign);
next(States, From, Sign) ->
    maps:get({From, Sign}, States).

process({'$xl_command', _, _} = Command, Fsm) ->
    on_command(Command, Fsm);
process({'$xl_notify', _} = Notification, Fsm) ->
    on_notify(Notification, Fsm);
process(Message, Fsm) ->
    on_message(Message, Fsm).

relay(Message, #{state := State, status := running} = Fsm) ->
    relay(Message, State, Fsm);
relay({'$xl_command', _, _}, Fsm) ->
    {reply, not_ready, Fsm};
relay(_, Fsm) ->
    {noreply, Fsm}.


relay(Message, #{react := React} = State, Fsm) ->
    case React(Message, State) of
        {reply, R, S} ->
            {reply, R, Fsm#{state := S}};
        {reply, R, S, T} ->
            {reply, R, Fsm#{state := S}, T};
        {noreply, S} ->
            {noreply, Fsm#{state := S}};
        {noreply, S, T} ->
            {noreply, Fsm#{state := S}, T};
        {stop, Reason, S} ->
            {Sign, S1} = xl_state:leave(S, Reason),
            case transfer(Fsm#{state := S1}, Sign) of
                {ok, NewFsm} ->
                    {noreply, NewFsm};
                Stop ->
                    Stop
            end;
        {stop, Reason, Reply, S} ->
            {Sign, S1} = xl_state:leave(S, Reason),
            case transfer(Fsm#{state := S1}, Sign) of
                {ok, NewFsm} ->
                    {reply, Reply, NewFsm};
                {stop, R, NewFsm} ->
                    {stop, R, Reply, NewFsm};
                Stop ->
                    Stop
            end
    end;
relay(_, _, Fsm) ->
    {noreply, Fsm}.

on_command({_, _, stop}, Fsm) ->
    {Reply, Fsm1} = stop_fsm(Fsm, command),
    {stop, command, Reply, Fsm1};
on_command({_, _, {stop, Reason}}, Fsm) ->
    {Reply, Fsm1} = stop_fsm(Fsm, Reason),
    {stop, Reason, Reply, Fsm1};
on_command({_, _, Command},
           #{state_mode := standalone,
             status := running,
             state_pid := Pid
            } = Fsm) ->
    Timeout = maps:get(timeout, Fsm, infinity),
    Result = xl_state:invoke(Pid, Command, Timeout),
    {reply, Result, Fsm};  % notice: timeout exception
on_command(Command, #{status := running} = Fsm) ->
    relay(Command, Fsm);
on_command(_, Fsm) ->
    {reply, unknown, Fsm}.

on_notify({_, Info}, #{state_mode := standalone, state_pid := Pid} = Fsm) ->
    ok = gen_server:cast(Pid, Info),
    {noreply, Fsm};
on_notify(Notification, #{status := running} = Fsm) ->
    relay(Notification, Fsm);
on_notify(_, Fsm) ->
    {noreply, Fsm}.

on_message({'EXIT', Pid, {D, S}}, #{state_pid := Pid} = Fsm) ->
    case transfer(Fsm#{state := S}, D) of 
        {ok, Fsm1} ->
            {noreply, Fsm1};
        Stop ->
            Stop
    end;
on_message(Message, #{state_mode := standalone, state_pid := Pid} = Fsm) ->
    Pid ! Message,
    {noreply, Fsm};
on_message(Message, #{status := running} = Fsm) ->
    relay(Message, Fsm);
on_message(_, Fsm) ->
    {noreply, Fsm}.

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
                {ok, State, T} ->
                    {ok, F2#{state => State}, T};
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
            case catch xl_state:deactivate(Pid, Reason, Timeout) of
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

archive(#{trace := Trace} = Fsm) when is_function(Trace) ->
    Trace(Fsm);
archive(#{state := State} = Fsm)  ->
    Trace = maps:get(trace, Fsm, []),
    Limit = maps:get(max_trace, Fsm, infinity),
    NewTrace = [State | Trace],
    if
        length(NewTrace) > Limit ->
            Fsm#{trace => lists:droplast(NewTrace)};
        true ->
            Fsm#{trace => NewTrace}
    end;
archive(Fsm) ->
    Fsm.
