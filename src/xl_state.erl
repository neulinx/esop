%%%-------------------------------------------------------------------
%%% @author Gary Hai <gary@XL59.com>
%%% @copyright (C) 2016, Neulinx Platforms.
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
-export([stop/1, stop/2, stop/3, unload/1, unload/2]).
-export([enter/1, leave/2, do_activity/1, yield/2]).
-export([create/1, create/2, merge/2, merge/3]).
-export([call/2, call/3, cast/2, reply/2]).
-export([subscribe/1, subscribe/2, unsubscribe/2, notify/2, notify/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DFL_TIMEOUT, 4000).  %% Smaller than gen:call timeout.
%%%===================================================================
%%% Common types
%%%===================================================================
-export_type([from/0,
              tag/0,
              state/0,
              result/0,
              reply/0,
              output/0]).

-type name() :: {local, atom()} | {global, atom()} | {via, atom(), term()}.
-type from() :: {To :: process(), Tag :: identifier()}.
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
             'io' => term(),  % Input or output data as payload of state.
             'work_mode' => work_mode(),  % default: sync
             'worker' => pid(),
             'pid' => pid(),  % mandatory
             'timeout' => timeout(),  % default: 5000
             'hibernate' => timeout(),  % mandatory, default: infinity
             'reason' => reason(),
             'sign' => term(),
             'status' => status(),
             'subscribers' => map()
            } | map().
-type tag() :: 'xlx'.
-type code() :: 'ok' | 'error' | 'stop' | 'pending' | atom().
-type request() :: {tag(), from(), Command :: term()} |
                   {tag(), from(), Path :: list(), Command :: term()}.
-type notification() :: {tag(), Notification :: term()}.
-type message() :: request() | notification().
-type result() :: {code(), state()} |
                  {code(), term(), state()} |
                  {code(), Stop :: reason(), Reply :: term(), state()}.
-type output() :: {'stopped', state()} |
                  {'exception', state()} |
                  {Sign :: term(), state()}.
-type reply() :: {'ok', term()} | 'ok' |
                 {'error', term()} | 'error' |
                 {'stop', term()} |
                 term().
-type status() :: 'running' |
                  'stopped' |
                  'exception' |
                  'undefined' |
                  'failover'.
-type work_mode() :: 'async' | 'sync'.
-type mix_mode() :: 'inner_first' | 'outer_first' | 'takeover'.
-type reason() :: 'normal' | 'unload' | term(). 
-type entry() :: fun((state()) -> result()).
-type exit() :: fun((state()) -> output()).
-type react() :: fun((message() | term(), state()) -> result()).
-type do() :: fun((state()) -> reply() | no_return()).

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
start_link(undefined, State, Options) ->
    start_link(State, Options);
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
start(undefined, State, Options) ->
    start(State, Options);
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
            maps:merge(Actions, Data)
    end;
%% Convert data type from proplists to maps as type state().
create(Module, Data) when is_list(Data) ->
    create(Module, maps:from_list(Data)).

%% Merges two states into a single state. If two keys exists in both states
%% the value in State1 will be superseded by the value in State2.
%% Actions merge according to the mix_mode parameter.
-spec merge(state(), state()) -> state().
merge(Inner, Outer) ->
    merge(Inner, Outer, inner_first).

-spec merge(state(), state(), mix_mode()) -> state().
merge(#{work_mode := async}, _, _) ->
    error(invalid);
merge(_, #{work_mode := async}, _) ->
    error(invalid);
merge(Inner, Outer, inner_first) ->
    M1 = mix_entry(Inner, Outer, #{}),
    M2 = mix_do(Inner, Outer, M1),
    M3 = mix_react(Inner, Outer, M2),
    M4 = mix_exit(Inner, Outer, M3),
    State = maps:merge(Inner, Outer),
    maps:merge(State, M4);
merge(Inner, Outer, outer_first) ->
    M1 = mix_entry(Inner, Outer, #{}),
    M2 = mix_do(Inner, Outer, M1),
    M3 = mix_react(Outer, Inner, M2),
    M4 = mix_exit(Inner, Outer, M3),
    State = maps:merge(Inner, Outer),
    maps:merge(State, M4);
merge(Inner, Outer, takeover) ->
    I = maps:without([entry, do, react, exit], Inner),
    maps:merge(I, Outer).

%% Enter outer first then inner.
mix_entry(#{entry := E1}, #{entry := E2}, M) ->
    F = fun(S) ->
                case E2(S) of
                    {ok, NewS} ->
                        E1(NewS);
                    Error ->
                        Error
                end
        end,
    M#{entry => F};
mix_entry(_, _, M) ->
    M.

%% Leave inner first then outer
mix_exit(#{exit := E1}, #{exit := E2}, M) ->
    F = fun(S) ->
                R1 = E1(S),
                InnerExit = maps:get(inner_exit, S, []),
                NewS = S#{inner_exit => [R1 | InnerExit]},
                E2(NewS)
        end,
    M#{exit => F};
mix_exit(_, _, M) ->
    M.

mix_react(#{react := R1}, #{react := R2}, M) ->
    F = fun(Info, State) ->
                case R1(Info, State) of
                    {ok, unhandled, NewS} ->
                        R2(Info, NewS);
                    Handled ->
                        Handled
                end
        end,
    M#{react => F};
mix_react(_, _, M) ->
    M.

mix_do(#{do := D1}, #{do := D2}, M) ->
    F = fun(S) ->
            case D1(S) of
                {ok, NewS} ->
                    D2(NewS);
                Stop ->
                    Stop
            end
        end,
    M#{do => F};
mix_do(_, _, M) ->
    M.
    
%%--------------------------------------------------------------------
%% gen_server callback. Initializes the server with state action entry.
%%--------------------------------------------------------------------
-spec init(state()) -> {'ok', state()} | {'stop', output()}.
init(#{status := running} = State) ->  % resume suspended state.
    cast(self(), xlx_wakeup),  % notify to prepare state resume.
    {ok, State#{pid => self()}};
init(State) ->
    case enter(State) of
        {ok, S} ->
            self() ! '_xlx_do_activity',  % Trigger off activity.
            {ok, S};
        Stop ->
            Stop
    end.

-spec enter(state()) -> result().
enter(State) ->
    EntryTime = erlang:system_time(),
    State1 = State#{entry_time => EntryTime, pid =>self(), status => running},
    enter_(State1).

enter_(#{entry := Entry} = State) ->
    %% fun exit/1 must be called even initialization not successful.
    try Entry(State) of
        {ok, S} ->
            {ok, S};
        {stop, Reason, S} ->
            {stop, leave(S, Reason)}
    catch
        C:E ->
            ErrState = State#{status => exception},
            {stop, leave(ErrState, {C, E})}
    end;
enter_(State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Handling messages by relay to react function.
%%--------------------------------------------------------------------
%% Handling sync call messages.
-spec handle_call(term(), from(), state()) ->
                         {'reply', reply(), state()} |
                         {'noreply', state()} |
                         {stop, reason(), reply(), state()} |
                         {stop, reason(), state()}.
handle_call(Request, From, State) ->
    handle_info({xlx, From, Request}, State).

%% Handling async cast messages.
%% {stop, Reason} is special notification to stop or transfer the state.
-spec handle_cast(Msg :: term(), state()) ->
                         {'noreply', state()} |
                         {stop, reason(), state()}.
handle_cast(Message, State) ->
    handle_info({xlx, Message}, State).

%% Handling customized messages.
-spec handle_info(Info :: term(), state()) ->
                         {'noreply', state()} |
                         {'stop', reason(), state()}.
handle_info(Info,  State) ->
    case post_handle(Info, pre_handle(Info, State)) of
        {noreply, #{hibernate := Timeout} = S} ->
            {noreply, S, Timeout};  % add hibernate support.
        Result ->
            Result
    end.

%%--------------------------------------------------------------------
%% All three types message relay to one react handler.
%%--------------------------------------------------------------------
%% do activity can be asyn version of entry to initialize the state.
%% If there is no do activity, actions in react can be dynamic version of do.
%% '_xlx_do_activity' must be the first message handled by gen_server.
pre_handle('_xlx_do_activity', #{do := _} = State) ->
    do_activity(State);
%% Worker is existed
pre_handle({'EXIT', From, Output}, #{worker := From} = State) ->
    yield(Output, State);
%% try to remove suberscriber before processing.
pre_handle({'DOWN', M, process, _, _} = Info, #{subscribers := Subs} = S) ->
    Subs1 = maps:remove(M, Subs),
    handle(Info, S#{subscribers := Subs1});
%% Timeout message treat as unconditional hibernate command.
pre_handle(timeout, State) ->
    handle({xlx, hibernate}, State);
pre_handle(Info, State) ->
    handle(Info, State).

handle(Info, #{react := React} = State) ->
    try
        React(Info, State)
    catch
        C:E ->
            {stop, {C, E}, State#{status => exception}}
    end;
%% Gracefully leave state when receive unhandled EXIT signal.
handle({'EXIT', _, _} = Kill, State) ->
    {stop, Kill, State};
handle(_Info, S) ->
    {ok, unhandled, S}.

%% stop or hibernate may be canceled by state react with code error.
post_handle({xlx, {stop, Reason}}, {ok, State}) ->
    {stop, Reason, State};
post_handle({xlx, {stop, Reason}}, {ok, _, State}) ->
    {stop, Reason, State};
%% Hibernate command, not guarantee.
post_handle({xlx, hibernate}, {ok, State}) ->
    {noreply, State, hibernate};
post_handle({xlx, hibernate}, {ok, _, State}) ->
    {noreply, State, hibernate};
%% Normalize very special commands.
post_handle({xlx, {Pid, _} = From, subscribe}, Res) ->  % for subscribe
    post_handle({xlx, From, {subscribe, Pid}}, Res);
%% redirect to unhandle info process.
post_handle({xlx, From, Command}, {ok, unhandled, State}) ->
    {Reply, NewState} = recall(Command, State),
    reply(From, Reply),
    {noreply, NewState};
post_handle({xlx, Info}, {ok, unhandled, State}) ->
    NewState = recast(Info, State),
    {noreply, NewState};
%% reply message before gen_server
%% Four elements of tuple is stop signal.
post_handle({xlx, From, _}, {Code, Reason, Reply, S}) ->
    reply(From, {Code, Reply}),
    {stop, Reason, S};
post_handle({xlx, _From, _}, {stop, Reason, S}) ->
    {stop, Reason, S};
post_handle({xlx, From, _}, {Code, Reply, S}) ->
    reply(From, {Code, Reply}),
    {noreply, S};
post_handle(_, {stop, S}) ->
    Reason = maps:get(reason, S, normal),
    {stop, Reason, S};
post_handle(_, {stop, _, _} = Stop) ->
    Stop;
post_handle(_, {_, S}) ->
    {noreply, S};
post_handle(_, {_, _, S}) ->
    {noreply, S};
post_handle(_, Stop) ->  % {stop, _, _, _}
    Stop.

%% data read, any key type
recall({get, Key}, State) ->
    Reply = case maps:find(Key, State) of
                error ->
                    {error, not_found};
                Value ->
                    Value
            end,
    {Reply, State};
%% Update or new data entry with the KV pair, key must not be atom type.
recall({put, Key, _}, State) when is_atom(Key) ->
    {{error, forbidden}, State};
recall({put, Key, Value}, State) ->
    NewS = maps:put(Key, Value, State),
    {ok, NewS};
recall({delete, Key}, State) when is_atom(Key) ->
    {{error, forbidden}, State};
recall({delete, Key}, State) ->
    NewS = maps:remove(Key, State),
    {ok, NewS};
recall({subscribe, Pid}, State) ->
    Subs = maps:get(subscribers, State, #{}),
    Mref = monitor(process, Pid),
    Subs1 = Subs#{Mref => Pid},
    {{ok, Mref}, State#{subscribers => Subs1}};
recall({unsubscribe, Mref}, #{subscribers := Subs} = State) ->
    demonitor(Mref),
    Subs1 = maps:remove(Mref, Subs),
    {ok, State#{subscribers := Subs1}};
recall(_, State) ->
    {{error, unknown}, State}.

recast({notify, Info}, #{subscribers := Subs} = State) ->
    maps:fold(fun(M, P, A) ->
                      catch P ! {M, Info},
                      A
              end, 0, Subs),
    State;
recast({unsubscribe, _} = Unsub, State) ->
    {_, NewState} = recall(Unsub, State),
    NewState;
recast(_Info, State) ->
    State.

    

%%--------------------------------------------------------------------
%% Time-consuming activity in two mode: sync or async.
%% async mode is perfered.
%%--------------------------------------------------------------------
-spec do_activity(state()) -> result().
do_activity(#{do := Do} = State) when is_function(Do) ->
    case maps:get(work_mode, State, sync) of
        async ->
            erlang:process_flag(trap_exit, true),  % Potentially block exit.
            %% worker can not alert state directly.
            Worker = spawn_link(fun() -> Do(State) end),
            {ok, State#{worker => Worker}};
        _sync ->
            %% Block gen_server work loop, 
            %% mention the timeout of gen_server response.
            try
                Do(State)
            catch
                C:E ->
                    {stop, {C, E}, State#{status => exception}}
            end
    end;
do_activity(State) ->
    {ok, State}.

-spec yield(Output :: term(), state()) -> result().
%% Merge output into state.
yield({Code, #{} = Result}, State) ->  % work done.
    {Code, maps:merge(State, Result)};
yield({Code, _} = Output, State) ->  % work done.
    {Code, State#{io => Output}};
yield({stop, Reason, #{} = Result}, State) ->  % work done and stop.
    {stop, Reason, maps:merge(State, Result)};
yield({Code, Reason, Result}, State) ->  % work done and stop.
    {stop, Reason, State#{io => {Code, Result}}};
yield(Exception, State) ->  % unknown error
    {stop, Exception, State#{status := exception}}.

%%--------------------------------------------------------------------
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% state action exit is called to destruct and to output result.
%%--------------------------------------------------------------------
-spec terminate(reason(), state()) -> no_return().
terminate(Reason, State) ->
    erlang:exit(leave(State, Reason)).

-spec leave(state(), Reason :: term()) -> output().
leave(State, xlx_unload) ->  % unload command do not call exit action.
    Sunload = case ensure_stopped(State, xlx_unload) of
            {_, S} ->
                S;
            {stop, _, S} ->
                S
        end,
    Final = final_notify(Sunload, unload),
    %% notice: please remove subscribers when persistent in database.
    {unloaded, Final};
leave(State, Reason) ->
    {Sign, Sexit} = try_exit(State#{reason => Reason}),
    Sstop = case ensure_stopped(Sexit, Reason) of
            {_, S} ->
                S;
            {stop, _, S} ->
                S
        end,
    Sfinal = Sstop#{exit_time => erlang:system_time()},
    Output = maps:get(io, Sfinal, undefined),
    FinalState = final_notify(Sexit, {stop, {Sign, Output}}),
    case maps:find(status, FinalState) of
        {ok, Status} when Status =/= running ->
            {Sign, FinalState};
        _ ->  % running or undefined
            {Sign, FinalState#{status := stopped}}
    end.

final_notify(#{subscribers := Subs} = State, Info) ->
    maps:fold(fun(Mref, Pid, Acc) ->
                      catch Pid ! {Mref, Info},
                      demonitor(Mref),
                      Acc
              end, 0, Subs),
    maps:remove(subscribers, State);
final_notify(State, _) ->
    State.

ensure_stopped(#{worker := Worker} = State, Reason) ->
    case is_process_alive(Worker) of
        true->
            unlink(Worker),  % Provide from crash unexpected.
            Timeout = maps:get(timeout, State, ?DFL_TIMEOUT),
            try 
                yield(stop(Worker, Reason, Timeout), State)
            catch
                exit: timeout ->
                    erlang:exit(Worker, kill),
                    {stop, abort, State}
            end;
        false ->
            {stop, stopped, State}
    end;
ensure_stopped(State, _) ->
    {stop, stopped, State}.

%% Mind the priority of sign extracting.
try_exit(#{exit := Exit} = State) ->
    try
        Exit(State)
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

%%--------------------------------------------------------------------
%% Convert process state when code is changed
%%--------------------------------------------------------------------
-spec code_change(OldVsn :: term(), state(), Extra :: term()) ->
                         {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Helper functions for invocation by message wrapping.
%%--------------------------------------------------------------------
%% Same as gen_server:reply().
-spec reply(from(), Reply :: term()) -> 'ok'.
reply({To, Tag}, Reply) ->
    catch To ! {Tag, Reply},
    ok.

%% Same as gen_server:call().
-spec call(process(), Request :: term()) -> reply().
call(Process, Command) ->
    call(Process, Command, infinity).

-spec call(process(), Request :: term(), timeout()) -> reply().
call(Process, Command, Timeout) ->
    Tag = make_ref(),
    Process ! {xlx, {self(), Tag}, Command},
    receive
        {Tag, Result} ->
            Result
    after
        Timeout ->
            {error, timeout}
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

%% Unload context data from engine.
-spec unload(process()) -> {'unloaded', state()} | term().
unload(Process) ->
    stop(Process, xlx_unload, ?DFL_TIMEOUT).
-spec unload(process(), timeout()) -> {'unloaded', state()} | term().
unload(Process, Timeout) ->
    stop(Process, xlx_unload, Timeout).

-spec subscribe(process()) -> {'ok', reference()}.
subscribe(Process) ->
    subscribe(Process, self()).

-spec subscribe(process(), process()) -> {'ok', reference()}.
subscribe(Process, Pid) ->
    call(Process, {subscribe, Pid}).

-spec unsubscribe(process(), reference()) -> 'ok'.
unsubscribe(Process, Ref) ->
    cast(Process, {unsubscribe, Ref}).

-spec notify(process(), Info :: term()) -> 'ok'.
notify(Process, Info) ->
    cast(Process, {notify, Info}).

-spec notify(process(), Tag :: term(), Info :: term()) -> 'ok'.
notify(Process, Tag, Info) ->
    cast(Process, {notify, {Tag, Info}}).

%%%===================================================================
%%% Unit test
%%%===================================================================
-ifdef(TEST).

%% get, put, delete, subscribe, unsubscribe, notify
basic_test() ->
    error_logger:tty(false),
    {ok, Pid} = start(#{io => hello}),
    {ok, running} = call(Pid, {get, status}),
    {ok, Pid} = call(Pid, {get, pid}),
    {error, forbidden} = call(Pid, {put, a, 1}),
    ok = call(Pid, {put, "a", a}),
    {ok, a} = call(Pid, {get, "a"}),
    {error, forbidden} = call(Pid, {delete, a}),
    ok = call(Pid, {delete, "a"}),
    {error, not_found} = call(Pid, {get, "a"}),
    {ok, Ref} = subscribe(Pid),
    notify(Pid, test),
    {Ref, test} = receive
                      Info ->
                          Info
                  end,
    unsubscribe(Pid, Ref),
    notify(Pid, test),
    timeout = receive
                  Info1 ->
                      Info1
              after
                  10 ->
                      timeout
              end,
    {ok, Ref1} = subscribe(Pid),
    stop(Pid),
    {Ref1, {stop, {stopped, hello}}} = receive
                                       Notify ->
                                           Notify
                                   end.
-endif.
