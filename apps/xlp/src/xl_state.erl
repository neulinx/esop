%%%-------------------------------------------------------------------
%%% @author Guiqing Hai <gary@XL59.com>
%%% @copyright (C) 2016, Guiqing Hai
%%% @doc
%%%
%%% @end
%%% Created : 27 Apr 2016 by Guiqing Hai <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(xl_state).

-behaviour(gen_server).

%% API
-export([start_link/1, start_link/2, start/1, start/2]).

-export([invoke/3, invoke/4, notify/3]).

-export([leave/1]).

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
    EntryTime = erlang:system_time(),
    case catch start_work(State) of
        {ok, S} ->
            NewState = S#{entry_time => EntryTime,
                          status => running},
            {ok, NewState};
        {ok, S, T} ->
            NewState = S#{entry_time => EntryTime,
                          status => running},
            {ok, NewState, T};
        {stop, Reason} ->
            terminate(Reason, State);
        {'EXIT', Error} ->
            exit({exception, State#{reason => Error, status => stopped}})
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
        Output ->
            Output
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
        Output ->
            Output
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
        Output ->
            Output
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
    S1 = State#{reason => Reason},
    S2 = case catch stop_work(S1) of
             {'EXIT', _} ->
                 S1;
             {_, NewS} ->
                 NewS
         end,
    {Directive, S3} = leave(S2),
    FinalState = S3#{exit_time => erlang:system_time(), status = stopped},
    exit({Directive, FinalState}).

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

invoke(Pid, Command, State) ->
    invoke(Pid, Command, State, infinity).

invoke(Pid, Command, State, 0) ->
    Pid ! {{'$xl_notify', Command}, State},
    ok;
invoke(Pid, Command, State, Timeout) ->
    Tag = make_ref(),
    Pid ! {{'$xl_command', {self(), Tag}, Command}, State},
    receive
        {Tag, Output} ->
            Output;
        {'EXIT', Pid, Output} ->
            Output
    after
        Timeout ->
            {timeout, State}
    end.

notify(Pid, Message, State) ->
    invoke(Pid, Message, State, 0).

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
    case maps:get(work_mode, State) of
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

stop_work(#{worker := Worker} = State) ->
    case is_process_alive(Worker) of
        true->
            Timeout = maps:get(timeout, State, infinity),
            case invoke(Worker, stop, State, Timeout) of
                {timeout, State} = Output ->
                    exit(Worker, kill),
                    Output;
                Output ->  % worker return the output by reason field.
                    Output  % {stopping, State#{reason := Workout}}.
            end;
        false ->
            {stopped, State}
    end;
stop_work(State) ->
    {ok, State}.

leave(#{exit := Exit} = State) ->
    case catch Exit(State) of
        {'EXIT', _} ->
            {exception, State};
        Output ->
            Output
    end;
leave(State#{status := exception}) ->
    {exception, State};
leave(State#{directive := Directive}) ->
    {Directive, State};
leave(State) ->
    {stopped, State}.

