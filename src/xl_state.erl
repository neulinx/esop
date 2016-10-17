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
-export([get/2, put/3, delete/2]).

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
             '_entry' => entry(),
             '_do' => do(),
             '_react' => react(),
             '_exit' => exit(),
             '_pid' => pid(),
             '_worker' => pid(),
             '_io' => term(),  % Input or output data as payload of state.
             '_sign' => term(),
             '_reason' => reason(),
             '_status' => status(),
             '_subscribers' => map(),
             '_entry_time' => pos_integer(),
             '_exit_time' => pos_integer()
%             <<"behavior">> => behavior(),
%             <<"_work_mode">> => work_mode(),  % default: sync
%             <<"_timeout">> => timeout(),  % default: 5000
%             <<"_hibernate">> => timeout()  % mandatory, default: infinity
            } | map().
-type tag() :: 'xlx'.
-type key() :: atom() | string() | binary().
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
%-type work_mode() :: 'async' | 'sync'.
-type mix_mode() :: 'inner_first' | 'outer_first' | 'takeover'.
-type reason() :: 'normal' | 'unload' | term(). 
-type entry() :: fun((state()) -> result()).
-type exit() :: fun((state()) -> output()).
-type react() :: fun((message() | term(), state()) -> result()).
-type do() :: fun((state()) -> result() | no_return()).

%%-type behavior() :: 'state' | <<"state">> | module() | binary().

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

merge_options(Options, #{<<"_timeout">> := Timeout}) ->
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
            A0 = #{},
            A1 = case erlang:function_exported(Module, entry, 1) of
                     true->
                         A0#{'_entry' => fun Module:entry/1};
                     false ->
                         A0
                 end,
            A2 = case erlang:function_exported(Module, do, 1) of
                     true->
                         A1#{'_do' => fun Module:do/1};
                     false ->
                         A1
                 end,
            A3 = case erlang:function_exported(Module, react, 2) of
                     true->
                         A2#{'_react' => fun Module:react/2};
                     false ->
                         A2
                 end,
            A4 = case erlang:function_exported(Module, exit, 1) of
                     true->
                         A3#{'_exit' => fun Module:exit/1};
                     false ->
                         A3
                 end,
            maps:merge(A4, Data)
    end;
%% Convert data type from proplists to maps as type state().
create(Module, Data) when is_list(Data) ->
    create(Module, maps:from_list(Data)).

%% Merges two states into a single state. If two keys exists in both states
%% the value in State1 will be superseded by the value in State2.
%% Actions merge according to the mix_mode parameter.
%% Todo: add a mix mode for handle message both.
-spec merge(state(), state()) -> state().
merge(Inner, Outer) ->
    merge(Inner, Outer, inner_first).

-spec merge(state(), state(), mix_mode()) -> state().
%% merge(#{'_work_mode' := async}, _, _) ->
%%     error(invalid);
%% merge(_, #{'_work_mode' := async}, _) ->
%%     error(invalid);
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
    I = maps:without(['_entry', '_do', '_react', '_exit'], Inner),
    maps:merge(I, Outer).

%% Enter outer first then inner.
mix_entry(#{'_entry' := E1}, #{'_entry' := E2}, M) ->
    F = fun(S) ->
                case E2(S) of
                    {ok, NewS} ->
                        E1(NewS);
                    Error ->
                        Error
                end
        end,
    M#{'_entry' => F};
mix_entry(_, _, M) ->
    M.

%% Leave inner first then outer
mix_exit(#{'_exit' := E1}, #{'_exit' := E2}, M) ->
    F = fun(S) ->
                {Sign, Final} = E1(S),
                E2(Final#{'_sign' => Sign})
        end,
    M#{'_exit' => F};
mix_exit(_, _, M) ->
    M.

mix_react(#{'_react' := R1}, #{'_react' := R2}, M) ->
    F = fun(Info, State) ->
                case R1(Info, State) of
                    {ok, unhandled, NewS} ->
                        R2(Info, NewS);
                    Handled ->
                        Handled
                end
        end,
    M#{'_react' => F};
mix_react(_, _, M) ->
    M.

mix_do(#{'_do' := D1}, #{'_do' := D2}, M) ->
    F = fun(S) ->
            case D1(S) of
                {ok, NewS} ->
                    D2(NewS);
                Stop ->
                    Stop
            end
        end,
    M#{'_do' => F};
mix_do(_, _, M) ->
    M.
    
%%--------------------------------------------------------------------
%% gen_server callback. Initializes the server with state action entry.
%%--------------------------------------------------------------------
-spec init(state()) -> {'ok', state()} | {'stop', output()}.
init(#{'_status' := running} = State) ->  % resume suspended state.
    cast(self(), xlx_wakeup),  % notify to prepare state resume.
    {ok, State#{'_pid' => self()}};
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
    State1 = State#{'_entry_time' => EntryTime,
                    '_pid' =>self(), '_status' => running},
    enter_(State1).

enter_(#{'_entry' := Entry} = State) ->
    %% fun exit/1 must be called even initialization not successful.
    try Entry(State) of
        {ok, S} ->
            {ok, S};
        {stop, Reason, S} ->
            {stop, leave(S, Reason)}
    catch
        C:E ->
            ErrState = State#{'_status' => exception},
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
handle_info(Message,  State) ->
    Info = normalize_msg(Message),
    Res = handle(Info, State),
    Res1 = handle_1(Info, Res),
    Res2 = handle_2(Info, Res1),
    handle_3(Res2).

%% empty path, the last hop.
normalize_msg({xlx, From, [], Command}) ->
    {xlx, From, Command};
%% sugar for subscribe.
normalize_msg({xlx, {Pid, _} = From, subscribe}) ->
    {xlx, From, {subscribe, Pid}};
%% gen_server timeout as hibernate command.
normalize_msg(tiemout) ->
    {xlx, hibernate};
normalize_msg(Msg) ->
    Msg.


%% do activity can be asyn version of entry to initialize the state.
%% If there is no do activity, actions in react can be dynamic version of do.
%% '_xlx_do_activity' must be the first message handled by gen_server.
handle('_xlx_do_activity', State) ->
    do_activity(State);
handle(Info, #{'_react' := React} = State) ->
    try
        React(Info, State)
    catch
        C:E ->
            {stop, {C, E}, State#{'_status' => exception}}
    end;
handle(_Info, State) ->
    {ok, unhandled, State}.


%% Process unhandled message.
handle_1(Info, {ok, unhandled, State}) ->
    default_react(Info, State);
handle_1(_Info, Res) ->
    Res.

%% stop or hibernate may be canceled by state react with code error.
handle_2({xlx, {stop, Reason}}, {ok, State}) ->
    {stop, Reason, State};
handle_2({xlx, {stop, Reason}}, {ok, _, State}) ->
    {stop, Reason, State};
%% Hibernate command, not guarantee.
handle_2({xlx, hibernate}, {ok, State}) ->
    {noreply, State, hibernate};
handle_2({xlx, hibernate}, {ok, _, State}) ->
    {noreply, State, hibernate};
%% reply message before gen_server
%% Four elements of tuple is stop signal.
handle_2({xlx, From, _}, {Code, Reason, Reply, S}) ->
    reply(From, {Code, Reply}),
    {stop, Reason, S};
handle_2({xlx, _From, _}, {stop, Reason, S}) ->
    {stop, Reason, S};
handle_2({xlx, From, _}, {Code, Reply, S}) ->
    reply(From, {Code, Reply}),
    {noreply, S};
handle_2(_, {stop, S}) ->
    Reason = maps:get('_reason', S, normal),
    {stop, Reason, S};
handle_2(_, {stop, _, _} = Stop) ->
    Stop;
handle_2(_, {_, S}) ->
    {noreply, S};
handle_2(_, {_, _, S}) ->
    {noreply, S};
handle_2(_, Stop) ->  % {stop, _, _, _}
    Stop.

handle_3({noreply, #{<<"_hibernate">> := Timeout} = S}) ->
    {noreply, S, Timeout};  % add hibernate support.
handle_3(Result) ->
    Result.

%%--------------------------------------------------------------------
%% Default message handler called when message is 'unhandled' by react function.
%%--------------------------------------------------------------------
default_react({xlx, _From, Command}, State) ->
    recall(Command, State);
default_react({xlx, Info}, State) ->
    recast(Info, State);
default_react({xlx, From, Path, Command}, State) ->
    traverse(From, Path, Command, State);
default_react({'DOWN', M, process, _, _}, #{'_subscribers' := Subs} = S) ->
    Subs1 = maps:remove(M, Subs),
    {ok, S#{'_subscribers' := Subs1}};  % todo: DOWN for links
default_react({'EXIT', From, Output}, #{'_worker' := From} = State) ->
    NewS = maps:remove('_worker', State),
    yield(Output, NewS);
%% Gracefully leave state when receive unhandled EXIT signal.
default_react({'EXIT', _, _} = Kill, State) ->
    {stop, Kill, State};  % todo: handler for 'EXIT'
default_react(_Info, State) ->
    {ok, State}.

%% data read, any key type
recall({get, Key}, State) ->
    recall({get, Key, raw}, State);
recall({get, Key, raw}, State) ->
    case maps:find(Key, State) of
        error ->
            {error, not_found, State};
        {ok, Value} ->
            {ok, Value, State}
    end;
recall({get, Key, active}, State) ->
    get(Key, State);
%% Update or new data entry with the KV pair, key must not be atom type.
recall({put, Key, Value}, State) ->
    recall({put, Key, Value, raw}, State);
recall({put, Key, _, _}, State) when is_atom(Key) ->
    {error, forbidden, State};
recall({put, Key, Value, raw}, State) ->
    NewS = maps:put(Key, Value, State),
    {ok, updated, NewS};
recall({put, Key, Value, active}, State) ->
    put(Key, Value, State);
recall({delete, Key}, State) ->
    recall({delete, Key, raw}, State);
recall({delete, Key, _}, State) when is_atom(Key) ->
    {error, forbidden, State};
recall({delete, Key, raw}, State) ->
    NewS = maps:remove(Key, State),
    {ok, deleted, NewS};
recall({delete, Key, active}, State) ->
    delete(Key, State);
recall({subscribe, Pid}, State) ->
    Subs = maps:get('_subscribers', State, #{}),
    Mref = monitor(process, Pid),
    Subs1 = Subs#{Mref => Pid},
    {ok, Mref, State#{'_subscribers' => Subs1}};
recall({unsubscribe, Mref}, #{'_subscribers' := Subs} = State) ->
    demonitor(Mref),
    Subs1 = maps:remove(Mref, Subs),
    {ok, unsubscribed, State#{'_subscribers' := Subs1}};
recall(_, State) ->
    {error, unknown, State}.

recast({notify, Info}, #{'_subscribers' := Subs} = State) ->
    maps:fold(fun(M, P, A) ->
                      catch P ! {M, Info},
                      A
              end, 0, Subs),
    State;
recast({unsubscribe, _} = Unsub, State) ->
    {_, _, NewState} = recall(Unsub, State),
    NewState;
recast(_Info, State) ->
    State.

%%--------------------------------------------------------------------
%% Process messages with path, when react function does not handle it.
%%--------------------------------------------------------------------
traverse(From, [Key | Path], Command, State) ->
    case get(Key, State) of
        {ok, Pid, NewS} when is_pid(Pid) ->
            Pid ! {xlx, From, Path, Command},
            {ok, NewS};
        {ok, Package, NewS} ->
            case invoke(Command, Key, Path, Package, NewS) of
                error ->
                    {error, not_found, NewS};
                {Code, Value} ->
                    {Code, Value, NewS};
                Result ->
                    Result
            end;
        Error ->
            Error
    end.

invoke(Command, Key, [], Data, Container) ->
    invoke_(Command, Key, Data, Container);
invoke(Command, Key, [Next | Path], Branch, Container) ->
    case invoke(Command, Next, Path, Branch) of
        {ok, Value, NewBranch} ->
            {ok, Value, Container#{Key := NewBranch}};
        NotChange ->
            NotChange
    end.

invoke(Command, Key, [], Container) ->
    invoke_(Command, Key, Container);
invoke(Command, Key, Path, Container) ->
    case maps:find(Key, Container) of
        {ok, Value} ->
            invoke(Command, Key, Path, Value, Container);
        Error ->
            Error
    end.

invoke_(get, _Key, Value, _Container) ->
    {ok, Value};
invoke_(Command, Key, _Value, Container) ->
    invoke_(Command, Key, Container).

invoke_(get, Key, Container) ->
    maps:find(Key, Container);
invoke_({put, Value}, Key, Container) ->
    NewC = maps:put(Key, Value, Container),
    {ok, updated, NewC};
invoke_(delete, Key, Container) ->
    NewC = maps:remove(Key, Container),
    {ok, deleted, NewC};
invoke_(_Unknown, _, _) ->
    {error, unknown}.

%%--------------------------------------------------------------------
%% Time-consuming activity in two mode: sync or async.
%% async mode is perfered.
%%--------------------------------------------------------------------
-spec do_activity(state()) -> result().
do_activity(#{'_do' := Do} = State) when is_function(Do) ->
    case maps:get(<<"_work_mode">>, State, sync) of
        async ->
            erlang:process_flag(trap_exit, true),  % Potentially block exit.
            %% worker can not alert state directly.
            Worker = spawn_link(fun() -> Do(State) end),
            {ok, State#{'_worker' => Worker}};
        _sync ->
            %% Block gen_server work loop, 
            %% mention the timeout of gen_server response.
            try
                Do(State)
            catch
                C:E ->
                    {stop, {C, E}, State#{'_status' => exception}}
            end
    end;
do_activity(State) ->
    {ok, State}.

-spec yield(Output :: term(), state()) -> result().
%% Merge output into state.
yield({Code, #{} = Result}, State) ->  % work done.
    {Code, maps:merge(State, Result)};
yield({Code, _} = Output, State) ->  % work done.
    {Code, State#{'_io' => Output}};
yield({stop, Reason, #{} = Result}, State) ->  % work done and stop.
    {stop, Reason, maps:merge(State, Result)};
yield({Code, Reason, Result}, State) ->  % work done and stop.
    {stop, Reason, State#{'_io' => {Code, Result}}};
yield(Exception, State) ->  % unknown error
    {stop, Exception, State#{'_status' := exception}}.

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
    {Sign, Sexit} = try_exit(State#{'_reason' => Reason}),
    Sstop = case ensure_stopped(Sexit, Reason) of
            {_, S} ->
                S;
            {stop, _, S} ->
                S
        end,
    Sfinal = Sstop#{'_exit_time' => erlang:system_time()},
    Output = maps:get('_io', Sfinal, undefined),
    FinalState = final_notify(Sexit, {stop, {Sign, Output}}),
    case maps:find('_status', FinalState) of
        {ok, Status} when Status =/= running ->
            {Sign, FinalState};
        _ ->  % running or undefined
            {Sign, FinalState#{'_status' := stopped}}
    end.

final_notify(#{'_subscribers' := Subs} = State, Info) ->
    maps:fold(fun(Mref, Pid, Acc) ->
                      catch Pid ! {Mref, Info},
                      demonitor(Mref),
                      Acc
              end, 0, Subs),
    maps:remove('_subscribers', State);
final_notify(State, _) ->
    State.

ensure_stopped(#{'_worker' := Worker} = State, Reason) ->
    case is_process_alive(Worker) of
        true->
            unlink(Worker),  % Provide from crash unexpected.
            Timeout = maps:get(<<"_timeout">>, State, ?DFL_TIMEOUT),
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
try_exit(#{'_exit' := Exit} = State) ->
    try
        Exit(State)
    catch
        C:E ->
            {exception, State#{'_reason' => {C, E}, '_status' := exception}}
    end;
try_exit(#{'_status' := exception} = State) ->
    {exception, State};
try_exit(#{'_sign' := Sign} = State) ->
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

%%--------------------------------------------------------------------
%% Helper functions for active attribute access.
%%--------------------------------------------------------------------
-spec get(key(), state()) -> {'ok', Value :: term(), state()} |
                             {'error', 'not_found', state()}.
get(Key, State) ->
    case maps:find(Key, State) of
        {ok, Pid} when is_pid(Pid) ->
            {ok, Pid, State};
        {ok, {Pid, _}} when is_pid(Pid) ->
            {ok, Pid, State};
        {ok, V} ->
            active(Key, V, State);
        _ ->
            try_link(Key, State)
    end.

-spec active(key(), Value, state()) -> {'ok', Value, state()}
                                           when Value :: term().
active(K, #{<<"_behavior">> := <<"state">>} = V, S) ->
    active_(K, V, S);
active(K, #{<<"_behavior">> := state} = V, S) ->
    active_(K, V, S);
active(K, #{<<"_behavior">> := Module} = V, S) when is_binary(Module) ->
    M = binary_to_existing_atom(Module, utf8),
    V1 = xl_state:create(M, V),
    active_(K, V1, S);
active(K, #{<<"_behavior">> := Module} = V, S) ->
    V1 = xl_state:create(Module, V),  % assert Module type is atom.
    active_(K, V1, S);
active(_K, V, S) ->
    {ok, V, S}.

active_(K, V, S) ->
    M = maps:get('_monitors', S, #{}),
    {ok, Pid} = xl_state:start_link(V),
    Monitors = M#{Pid => K},
    {ok, Pid, S#{K => Pid, '_monitors' => Monitors}}.

try_link(Key, #{<<"_id">> := Id, '_global' := R} = State) ->
    case call(R, {get, {Id, Key}, active}) of
        {ok, Pid} ->
            M = maps:get('_monitors', State, #{}),
            Mref = monitor(process, Pid),
            M1 = M#{Mref => Key},
            {ok, Pid, State#{Key => {Pid, Mref}, '_monitors' => M1}};
        {error, Error} ->
            {error, Error, State}
    end;
try_link(_Key, State) ->
    {error, not_found, State}.



-spec put(key(), Value, state()) -> {'ok', Value, state()}
                                        when Value :: term().
put(Key, Value, State) ->
    case maps:find(Key, State) of
        {ok, V} when is_pid(V) ->
            {ok, deleted, S1} = delete(Key, State),
            active(Key, Value, S1);
        _ ->
            active(Key, Value, State)
    end.

-spec delete(key(), state()) -> {'ok', 'deleted', state()} |
                                {'error', 'not_found', state()}.
delete(Key, #{'_monitors' := M} = State) ->
    case maps:find(Key, State) of
        {ok, V} when is_pid(V) ->
            erlang:unlink(V),
            M1 = maps:remove(V, M),
            S1 = maps:remove(Key, State),
            {ok, deleted, S1#{'_monitors' := M1}};
        _ ->
            {ok, deleted, maps:remove(Key, State)}
    end;
delete(Key, State) ->
    {ok, deleted, maps:remove(Key, State)}.

%%%===================================================================
%%% Unit test
%%%===================================================================
-ifdef(TEST).

%% get, put, delete, subscribe, unsubscribe, notify
basic_test() ->
    error_logger:tty(false),
    {ok, Pid} = start(#{'_io' => hello}),
    {ok, running} = call(Pid, {get, '_status'}),
    {ok, Pid} = call(Pid, {get, '_pid'}),
    {error, forbidden} = call(Pid, {put, a, 1}),
    {ok, updated} = call(Pid, {put, "a", a}),
    {ok, a} = call(Pid, {get, "a"}),
    {error, forbidden} = call(Pid, {delete, a}),
    {ok, deleted} = call(Pid, {delete, "a"}),
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
