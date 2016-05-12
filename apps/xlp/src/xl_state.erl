%%%-------------------------------------------------------------------
%%% @author Guiqing Hai <gary@XL59.com>
%%% @copyright (C) 2016, Guiqing Hai
%%% @doc
%%%
%%% @end
%%% Created : 27 Apr 2016 by Guiqing Hai <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(xl_state).

-ifdef(TEST).
    -include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(gen_server).

%% API
-export([start_link/1, start_link/2, start/1, start/2]).

-export([invoke/2, invoke/3, notify/2]).
-export([deactivate/1, deactivate/2, deactivate/3]).
-export([enter/1, leave/1, leave/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(State) ->
    start_link(State, []).

start_link(State, Options) ->
    gen_server:start_link(?MODULE, State, Options).

start(State) ->
    start(State, []).

start(State, Options) ->
    gen_server:start(?MODULE, State, Options).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init(State) ->
    case catch enter(State) of
        {'EXIT', Error} ->
            exit({exception, State#{reason := Error}});
        {ok, _} = Ok ->
            Ok;
        {ok, _, _} = Ok ->
            Ok;
        Result ->
            {stop, Result}
    end.

enter(State) ->
    EntryTime = erlang:system_time(),
    State1 = State#{entry_time => EntryTime, pid =>self()},
    case catch start_work(State1) of
        {ok, S} ->
            {ok, S#{status => running}};
        {ok, S, T} ->
            {ok, S#{status => running}, T};
        {stop, Reason, S} ->
            leave(S, Reason);
        {'EXIT', Error} ->
            ErrState = State1#{status => exception},
            leave(ErrState, Error)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(Request, From, #{react := React} = State) ->
    case catch React({'$xl_command', From, Request}, State) of
        {'EXIT', Reason} ->
            {stop, Reason, {error, abort}, State#{status => exception}};
        Result ->
            Result
    end;
handle_call(_Request, _From, State) ->
    {reply, unknown, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(Message, #{react := React} = State) ->
    case catch React({'$xl_notify', Message}, State) of
        {'EXIT', Reason} ->
            {stop, Reason, State#{status => exception}};
        Result ->
            Result
    end;

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(Info, #{react := React} = State) ->
    case catch React(Info, State) of
        {'EXIT', Reason} ->
            {stop, Reason, State#{status => exception}};
        {reply, Reply, S} ->
            case Info of
                {'$xl_command', From, _} ->
                    gen_server:reply(From, Reply),
                    {noreply, S};
                _ ->
                    {noreply, S}
            end;
        {reply, Reply, S, T} ->
            case Info of
                {'$xl_command', From, _} ->
                    gen_server:reply(From, Reply),
                    {noreply, S, T};
                _ ->
                    {noreply, S, T}
            end;
        Result ->
            Result
    end;
%% worker is existed
handle_info({'EXIT', From, Reason}, #{worker := From} = State) ->
    {stop, Reason, State};
handle_info(_Info, State) ->
    {noreply, State}.  % todo: add hibernate parameter for state without handle.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(Reason, State) ->
    exit(leave(State, Reason)).

leave(#{reason := Reason} = State) ->
    leave(State, Reason);
leave(State) ->
    leave(State, normal).

leave(State, Reason) ->
    S1 = State#{reason => Reason},
    S2 = case catch stop_work(S1, Reason) of
             stopped ->
                 S1;
             Workout ->
                 S1#{output => Workout}
         end,
    {Sign, S3} = try_exit(S2),
    FinalState = S3#{exit_time => erlang:system_time(), status => stopped},
    {Sign, FinalState}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

invoke(Pid, Command) ->
    invoke(Pid, Command, infinity).

invoke(Pid, Command, 0) ->
    Pid ! {'$xl_notify', Command},
    ok;
invoke(Pid, Command, Timeout) ->
    Tag = make_ref(),
    Pid ! {'$xl_command', {self(), Tag}, Command},
    receive
        {Tag, Result} ->
            Result
    after
        Timeout ->
            exit(timeout)
    end.

notify(Pid, Message) ->
    invoke(Pid, Message, 0).

deactivate(Pid) ->
    deactivate(Pid, normal, infinity).

deactivate(Pid, Reason) ->
    deactivate(Pid, Reason, infinity).

deactivate(Pid, Reason, Timeout) ->
    notify(Pid, {stop, Reason}),
    receive
        {'EXIT', Pid, Result} ->
            Result
    after
        Timeout ->
            exit(timeout)
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
start_work(#{entry := Entry} = State) ->
    case Entry(State) of
        {ok, NewState} ->
            do_activity(NewState);
        Error ->
            Error
    end;
start_work(State) ->
    do_activity(State).

do_activity(#{do := Do} = State) ->
    case maps:get(work_mode, State, standalone) of
        takeover ->  % redefine xl_state behaviors.
            gen_server:enter_loop(Do, [], State);
        block ->  % mention the timeout of gen_server response.
            Do(State);
        _standalone ->
            erlang:process_flag(trap_exit, true),
            %% worker can not alert state directly.
            Worker = spawn_link(fun() -> Do(State) end),
            {ok, State#{worker => Worker}}
    end;
do_activity(State) ->
    {ok, State}.

stop_work(#{worker := Worker} = State, Reason) ->
    case is_process_alive(Worker) of
        true->
            Timeout = maps:get(timeout, State, infinity),
            deactivate(Worker, Reason, Timeout);
        false ->
            stopped
    end;
stop_work(_, _) ->
    stopped.

try_exit(#{exit := Exit} = State) ->
    case catch Exit(State) of
        {'EXIT', _} ->
            {exception, State};
        Result ->
            Result
    end;
try_exit(#{status := exception} = State) ->
    {exception, State};
try_exit(#{sign := Sign} = State) ->
    {Sign, State};
try_exit(State) ->
    {stopped, State}.
