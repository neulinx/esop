%%%-------------------------------------------------------------------
%%% @author Gary Hai <gary@XL59.com>
%%% @copyright (C) 2016, Neulinx Collaborations Ltd.
%%% @doc
%%%  State object with gen_server behaviours.
%%% @end
%%% Created : 27 Apr 2016 by Gary Hai <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(xl_state).

-ifdef(TEST).
    -include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(gen_server).

%% API
-export([start_link/1, start_link/2, start_link/3]).
-export([start/1, start/2, start/3]).
-export([stop/1, stop/2, stop/3, detach/1, detach/2]).
-export([create/1, create/2]).
-export([call/2, call/3, cast/2, reply/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DFL_TIMEOUT, 4000).  %% Smaller than gen:call timeout.
%%%===================================================================
%%% Common types
%%%===================================================================
-export_type([from/0,
              tag/0,
              message/0,
              process/0,
              state/0,
              ok/0,
              fail/0,
              output/0]).

-type name() :: {local, atom()} | {global, atom()} | {via, atom(), term()}.
-type from() :: {To :: pid(), Tag :: identifier()}.
-type process() :: pid() | (LocalName :: atom()).
-type start_ret() ::  {'ok', pid()} | 'ignore' | {'error', term()}.
-type start_opt() ::
        {'timeout', Time :: timeout()} |
        {'spawn_opt', [proc_lib:spawn_option()]}.
-type state() :: #{
             'entry' => entry(),
             'do' => do(),
             'react' => react(),
             'exit' => exit(),
             'entry_time' => pos_integer(),
             'exit_time' => pos_integer(),
             'work_mode' => work_mode(),  % default: sync
             'worker' => pid(),
             'pid' => pid(),  % mandatory
             'timeout' => timeout(),  % default: 5000
             'hibernate' => timeout(),  % mandatory, default: infinity
             'reason' => reason(),
             'sign' => term(),
             'output' => term(),
             'status' => status()
            }.
-type tag() :: 'xlx'.
-type request() :: {tag(), from(), Command :: term()}.
-type notification() :: {tag(), Notification :: term()}.
-type message() :: request() | notification().
-type ok() :: {'ok', state()} |
              {'ok', Result :: term(), state()}.
-type output() :: {'stopped', state()} |
                  {'exception', state()} |
                  {Sign :: term(), state()}.
-type fail() :: {'stop', reason(), Result :: term(), state()} |
                {'stop', reason(), state()}.
-type status() :: 'running' |
                  'stopped' |
                  'exception' |
                  'undefined' |
                  'failover'.
-type work_mode() :: 'async' | 'sync'.
-type reason() :: 'normal' | 'detach' | term(). 
-type entry() :: fun((state()) -> ok() | fail()).
-type exit() :: fun((state()) -> output()).
-type react() :: fun((message() | term(), state()) -> ok() | fail()).
-type do() :: fun((state()) -> ok() | fail() | no_return()).
%% work done output on async mode:
%% {ok, map()} | {ok, Result::term()} | {stop, reason()}

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% Starts the server.
%%--------------------------------------------------------------------
-spec start_link(state()) -> start_ret().
start_link(State) ->
    start_link(State, []).

-spec start_link(state(), [start_opt()]) -> start_ret().
start_link(State, Options) ->
    Opts = merge_options(Options, State),
    gen_server:start_link(?MODULE, State, Opts).

-spec start_link(name(), state(), [start_opt()]) -> start_ret().
start_link(Name, State, Options) ->
    Opts = merge_options(Options, State),
    gen_server:start_link(Name, ?MODULE, State, Opts).

-spec start(state()) -> start_ret().
start(State) ->
    start(State, []).

-spec start(state(), [start_opt()]) -> start_ret().
start(State, Options) ->
    Opts = merge_options(Options, State),
    gen_server:start(?MODULE, State, Opts).

-spec start(name(), state(), [start_opt()]) -> start_ret().
start(Name, State, Options) ->
    Opts = merge_options(Options, State),
    gen_server:start(Name, ?MODULE, State, Opts).

merge_options(Options, #{timeout := Timeout}) ->
    Options ++ [{timeout, Timeout}];  % Quick and dirty, but it works.
merge_options(Options, _) ->
    Options.

%%--------------------------------------------------------------------
%% Create state object from module and given parameters.
%% If there is an exported function create/1 in the module, 
%%  create new state object by it instead.
%%--------------------------------------------------------------------
-spec create(module()) -> state().
create(Module) ->
    create(Module, #{}).

-spec create(module(), map() | list()) -> state().
create(Module, Data) when is_map(Data) ->
    case erlang:function_exported(Module, create, 1) of
        true ->
            Module:create(Data);
        _ ->
            Actions0 = [{entry, 1}, {do, 1}, {react, 2}, {exit, 1}],
            Filter = fun({F, A}, Acts) ->
                         case erlang:function_exported(Module, F, A) of
                             true ->
                                 Acts#{F => fun Module:F/A};
                             false ->
                                 Acts
                         end
                     end,
            Actions = lists:foldl(Filter, #{}, Actions0),
            maps:merge(Data, Actions)
    end;
%% Convert data type from proplists to maps as type state().
create(Module, Data) when is_list(Data) ->
    create(Module, maps:from_list(Data)).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server with state action entry:
%%   entry(state()) -> ok() | fail().
%% @end
%%--------------------------------------------------------------------
-spec init(state()) -> {'ok', state()} | {'stop', output()}.
init(#{status := running} = State) ->  % Nothing to do for suspended state.
    self() ! '_xlx_do_activity',
    {ok, State#{pid => self()}};
init(State) ->
    EntryTime = erlang:system_time(),
    Hib = maps:get(hibernate, State, ?DFL_TIMEOUT),
    State1 = State#{entry_time => EntryTime, pid =>self(), hibernate => Hib},
    case enter(State1) of
        {ok, S} ->
            self() ! '_xlx_do_activity',  % Trigger off activity.
            {ok, S#{status => running}};
        {stop, Reason, S} ->
            %% fun exit/1 must be called even initialization not successful.
            self() ! {xlx, {stop, Reason}},  % Trigger off destruction.
            {ok, S}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages by relay to react function.
%%   react(Message :: term(), state()) -> ok() | fail().
%% @end
%%--------------------------------------------------------------------
-spec handle_call(term(), from(), state()) ->
                         {'reply', Reply :: term(), state()} |
                         {'noreply', state()} |
                         {stop, reason(), Reply :: term(), state()} |
                         {stop, reason(), state()}.
handle_call(Request, From, State) ->
    handle_info({xlx, From, Request}, State).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages.
%% {stop, Reason} is special notification to stop or transfer the state.
%%
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Msg :: term(), state()) ->
                         {'noreply', state()} |
                         {stop, reason(), state()}.
handle_cast(Message, State) ->
    handle_info({xlx, Message}, State).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: term(), state()) ->
                         {'noreply', state()} |
                         {'stop', reason(), state()}.
handle_info(Info,  State) ->
    case handle(Info, State) of
        {noreply, #{hibernate := Timeout} = S} ->
            {noreply, S, Timeout};
        Result ->
            Result
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% state action exit is called to destruct and to output result.
%%  exit(state()) -> output().
%% @end
%%--------------------------------------------------------------------
-spec terminate(reason(), state()) -> no_return().
terminate(Reason, State) ->
    erlang:exit(leave(State, Reason)).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn :: term(), state(), Extra :: term()) ->
                         {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Same as gen_server:reply().
-spec reply(from(), Reply :: term()) -> 'ok'.
reply({To, Tag}, Reply) ->
    catch To ! {Tag, Reply},
    ok.

%% Same as gen_server:call().
-spec call(process(), Request :: term()) -> Reply :: term().
call(Process, Command) ->
    call(Process, Command, ?DFL_TIMEOUT).

-spec call(process(), Request :: term(), timeout()) -> Reply :: term().
call(Process, Command, Timeout) ->
    Tag = make_ref(),
    Process ! {xlx, {self(), Tag}, Command},
    receive
        {Tag, Result} ->
            Result
    after
        Timeout ->
            erlang:exit(timeout)
    end.

%% Same as gen_server:cast().
-spec cast(process(), Notify :: term()) -> 'ok'.
cast(Process, Notification) ->
    catch Process ! {xlx, Notification},
    ok.

%% stop is almost same effect as gen_server:stop().
-spec stop(process()) -> output().
stop(Process) ->
    stop(Process, normal, ?DFL_TIMEOUT).

-spec stop(process(), reason()) -> output().
stop(Process, Reason) ->
    stop(Process, Reason, ?DFL_TIMEOUT).

-spec stop(process(), reason(), timeout()) -> output().
stop(Process, Reason, Timeout) ->
    Mref = monitor(process, Process),
    cast(Process, {stop, Reason}),
    receive
        {'DOWN', Mref, _, _, Result} ->
            Result
    after
        Timeout ->
            demonitor(Mref, [flush]),
            erlang:exit(timeout)
    end.

-spec detach(process()) -> {'detached', state()} | term().
detach(Process) ->
    stop(Process, xlx_detach, ?DFL_TIMEOUT).
-spec detach(process(), timeout()) -> {'detached', state()} | term().
detach(Process, Timeout) ->
    stop(Process, xlx_detach, Timeout).

%%%===================================================================
%%% Internal functions
%%%===================================================================
enter(#{entry := Entry} = State) ->
    case catch Entry(State) of
        {ok, S} ->
            {ok, S};
        {stop, Reason, S} ->
            {stop, Reason, S};
        {'EXIT', Error} ->
            ErrState = State#{status => exception},
            {stop, Error, ErrState}
    end;
enter(State) ->
    {ok, State}.

leave(State, xlx_detach) ->  % detach command do not call exit action.
    Sdetach = case ensure_stopped(State, xlx_detach) of
            stopped ->
                State;
            killed ->
                State#{output => abort};
            {noreply, S} ->
                S;
            {stop, _, S} ->
                S
        end,
    {detached, Sdetach};
leave(State, Reason) ->
    {Sign, Sexit} = try_exit(State#{reason => Reason}),
    Sstop = case ensure_stopped(Sexit, Reason) of
            stopped ->
                Sexit;
            killed ->
                Sexit#{output => abort};
            {noreply, S} ->
                S;
            {stop, _, S} ->
                S
        end,
    FinalState = Sstop#{exit_time => erlang:system_time()},
    case maps:find(status, FinalState) of
        {ok, Status} when Status =/= running ->
            {Sign, FinalState};
        _ ->  % running or undefined
            {Sign, FinalState#{status := stopped}}
    end.

%% do activity can be asyn version of entry to initialize the state.
%% If there is no do activity, actions in react can be dynamic version of do.
%% '_xlx_do_activity' must be the first message handled by gen_server.
handle('_xlx_do_activity', #{do := _} = State) ->
    try do_activity(State) of
        {ok, S} ->
            {noreply, S};
        {ok, Result, S} ->
            {noreply, S#{output => Result}};
        Stop ->
            Stop
    catch
        C:E ->
            {stop, {C, E}, State#{status => exception}}
    end;
%% Worker is existed
handle({'EXIT', From, Output}, #{worker := From} = State) ->
    done(Output, State);
%% Timeout message treat as unconditional hibernate command.
handle(timeout, State) ->
    handle({xlx, hibernate}, State);
handle(Info, State) ->
    post_(Info, handle_(Info, State)).

handle_(Info, #{react := React} = State) ->
    try React(Info, State) of
        {ok, Reply, S} ->
            case Info of
                {xlx, From, _} ->  % Relay the response
                    reply(From, Reply);
                _ ->  % Drop the reply part without From tag.
                    ok
            end,
            {noreply, S};
        {ok, S} ->
            {noreply, S};
        Stop ->
            Stop
    catch
        C:E ->
            {stop, {C, E}, State#{status => exception}}
    end;
%% Gracefully leave state when receive unhandled EXIT signal.
handle_({'EXIT', _, _} = Kill, State) ->
    {stop, Kill, State};
handle_({xlx, From, _Request}, State) ->
    reply(From, {error, no_handler}),  % Empty state, just be graceful.
    {noreply, State};
handle_(_Info, State) ->
    {noreply, State}.

%% Stop machine message as system command bypass process of state machine.
post_({xlx, stop}, {noreply, State}) ->
    {stop, normal, State};
post_({xlx, {stop, Reason}}, {noreply, State}) ->
    {stop, Reason, State};
%% Hibernate command, not guarantee.
post_({xlx, hibernate}, {noreply, State}) ->
    {noreply, State, hibernate};
post_(_Info, Result) ->
    Result.

do_activity(#{do := Do} = State) ->
    case maps:get(work_mode, State, sync) of
        async ->
            erlang:process_flag(trap_exit, true),  % Potentially block exit.
            %% worker can not alert state directly.
            Worker = spawn_link(fun() -> Do(State) end),
            {ok, State#{worker => Worker}};
        _sync ->
            %% Block gen_server work loop, 
            %% mention the timeout of gen_server response.
            Do(State)
    end;
do_activity(State) ->
    {ok, State}.

done({ok, #{} = Supplement}, State) ->
    {noreply, maps:merge(State, Supplement)};
done({ok, Result}, State) ->
    {noreply, State#{output => Result}};
done({stop, #{} = Supplement}, State) ->
    Reason = maps:get(reason, Supplement, done),
    {stop, Reason, maps:merge(State, Supplement)};
done({stop, Reason}, State) ->
    {stop, Reason, State};
done(Exception, State) ->
    {stop, Exception, State#{status := exception}}.

ensure_stopped(#{worker := Worker} = State, Reason) ->
    case is_process_alive(Worker) of
        true->
            Timeout = maps:get(timeout, State, ?DFL_TIMEOUT),
            try
                done(stop(Worker, Reason, Timeout), State)
            catch
                {exit, timeout} ->
                    erlang:exit(Worker, kill),
                    killed
            end;
        false ->
            stopped
    end;
ensure_stopped(_, _) ->
    stopped.

try_exit(#{exit := Exit} = State) ->
    try Exit(State) of
        Result ->
            Result
    catch
        C:E ->
            {exception, State#{reason => {C, E}, status := exception}}
    end;
try_exit(#{status := exception} = State) ->
    {exception, State};
try_exit(#{sign := Sign} = State) ->
    {Sign, State};
try_exit(State) ->
    {stopped, State}.

%%%===================================================================
%%% Unit test
%%%===================================================================
-ifdef(TEST).

-endif.
