%%%-------------------------------------------------------------------
%%% @author Guiqing Hai <gary@XL59.com>
%%% @copyright (C) 2016, Guiqing Hai
%%% @doc
%%%
%%% @end
%%% Created : 30 Apr 2016 by Guiqing Hai <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(xl_fsm).

-compile({no_auto_import,[exit/1]})
%% API
-export([entry/1, react/2, exit/1]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------
entry(#{steps := Steps, max_steps := MaxSteps}) when Steps >= MaxSteps ->
    {stop, out_of_steps};
entry(Fsm) ->
    StartState = next(Fsm, start),
    Step = maps:get(step, Fsm, 0),
    Fsm1 = Fsm#{state = StartState, step => Step + 1},
    Fsm2 = case maps:get(engine, Fsm1, reuse) of
               standalone ->
                   erlang:process_flag(trap_exit, true),
                   Pid = xl_state:start_link(State),
                   Fsm1#{state_pid => Pid};
               _Reuse ->
                   case maps:get(entry, StartState, undefined) of
                       StateEntry ->
                           StateEntry(StartState);
                       undefined ->
                   end,
                   transfer(Fsm1)  % todo transfer
           end,
    {ok, Fsm2}.

react(Message, Fsm) ->
    case process(Message, Fsm) of
        noop ->
            proxy(Message, Fsm);
        Output ->
            Output
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
next(#{state := State}, start) ->
    State;
next(#{state := State, states := States}, Directive) ->
    Name = maps:get(state_name, State),
    next(States, Name, Directive);
next(#{states := States}, Directive) ->
    next(States, '$root', Directive).

next(States, From, Directive) when is_function(States) ->
    States(From, Directive);
next(#{{From, Directive} := To}, From, Directive) ->
    To.    

process({'$xl_command', _, _} = Command, Fsm) ->
    on_command(Fsm, Command);
process({'$xl_notify', _} = Notification, Fsm) ->
    on_notify(Fsm, Notification);
process(Message, Fsm) ->
    on_message(Fsm, Message).

proxy(Message, #{state := State} = Fsm) ->
    proxy(Message, State, Fsm).

proxy(Message, #{react := React} = State, Fsm) ->
    case react(Message, State) of
        {reply, R, S} ->
            {reply, R, Fsm#{state := S}};
        {reply, R, S, T} ->
            {reply, R, Fsm#{state := S}, T};
        {noreply, S} ->
            {noreply, Fsm#{state := S}};
        {noreply, S, T} ->
            {noreply, Fsm#{state := S}, T};
        {stop, Reason, S} ->
            {Directive, S1} = xl_state:leave(S#{reason := Reason}),
            case transfer(Fsm, S1, Directive) of
                {ok, NewFsm} ->
                    {noreply, NewFsm};
                Stop ->
                    Stop
            end;
        {stop, Reason, Reply, S} ->
            {Directive, S1} = xl_state:leave(S#{reason => Reason}),
            case transfer(Fsm, S1, Directive) of
                {ok, NewFsm} ->
                    {reply, Reply, NewFsm};
                {stop, R, NewFsm} ->
                    {stop, R, Reply, NewFsm};
                Stop ->
                    Stop
            end;
    end;
proxy(_, Fsm) ->
    {noreply, Fsm}.

on_command(Fsm, {_, stop, _}) ->
    stop_fsm(Fsm, command);
on_command(Fsm, {_, {stop, Reason}, _}) ->
    stop_fsm(Reason, Fsm);
%    {stop, Reason, Reply, Fsm1};
on_command(#{engine := standalone, state_pid := Pid} = Fsm, Command) ->
    Timeout = maps:get(timeout, Fsm, infinity),
    Result = gen_server:call(Pid, Command, Timeout),
    {reply, Result, Fsm};  % notice: timeout exception
on_command(_Fsm, _Command, _From) ->
    noop.

on_notify(#{engine := standalone, state_pid := Pid} = Fsm, Notification) ->
    ok = gen_server:cast(Pid, Notification),
    {noreply, Fsm};
on_notify(_, _) ->
    noop.

on_message(#{state_pid := Pid} = Fsm, {'EXIT', Pid, {D, S}}) ->
    transfer(Fsm, S, D);
on_message(#{engine := standalone, state_pid := Pid} = Fsm, Message) ->
    Pid ! Message,
    {noreply, Fsm};
on_message(_, _) ->
    noop.

transfer(#{steps := Steps, max_steps := MaxSteps}) when Steps >= MaxSteps ->
    {stop, out_of_steps};
transfer(Fsm) ->
    StartState = next(Fsm, start),
    Step = maps:get(step, Fsm, 0),
    Fsm1 = Fsm#{state = StartState, step => Step + 1},
    Fsm2 = case maps:get(engine, Fsm1, reuse) of
               standalone ->
                   erlang:process_flag(trap_exit, true),
                   Pid = xl_state:start_link(State),
                   Fsm1#{state_pid => Pid};
               _Reuse ->
                   case maps:get(entry, StartState, undefined) of
                       StateEntry ->
                           StateEntry(StartState);
                       undefined ->
                   end,
                   transfer(Fsm1)  % todo transfer
           end,
    {ok, Fsm2}.

