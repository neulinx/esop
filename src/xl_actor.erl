%%%-------------------------------------------------------------------
%%% @author Gary Hai <gary@XL59.com>
%%% @copyright (C) 2016, Neulinx Platforms.
%%% @doc
%%%  Trinitiy of State, FSM, Actor, with gen_server behaviours.
%%% @end
%%% Created : 27 Apr 2016 by Gary Hai <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(xl_actor).

-ifdef(TEST).
    -include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(gen_server).

%% API
-export([start_link/1, start_link/2, start_link/3]).
-export([start/1, start/2, start/3]).
-export([stop/1, stop/2, stop/3]).
-export([create/1, create/2]).
-export([call/2, call/3, call/4, cast/2, reply/2]).
-export([subscribe/1, subscribe/2, unsubscribe/2, notify/2, notify/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(DFL_TIMEOUT, 4000).  %% Smaller than gen:call timeout.
-define(MAX_TRACES, 1000).  %% Default trace log limit.

%%%===================================================================
%%% Common types
%%%===================================================================
-export_type([from/0,
              tag/0,
              state/0,
              result/0,
              reply/0,
              output/0]).
 
-type server_name() :: {local, atom()} |
                       {global, atom()} |
                       {via, atom(), term()}.
-type from() :: {To :: process(), Tag :: identifier()}.
-type process() :: pid() | (LocalName :: atom()).
-type start_ret() ::  {'ok', pid()} | 'ignore' | {'error', term()}.
-type start_opt() ::
        {'timeout', Time :: timeout()} |
        {'spawn_opt', [proc_lib:spawn_option()]}.
%% @todo write document for state/FSM/actor attributes.
%% - Runtime attributes names is atom type with prefix '_'.
%% - Raw data (json => map) should not contain atom type or tuple type data. 
-type state() :: #{
%%---------- state base attributes --------
             '_entry' => entry(),
             '_react' => react(),
             '_exit' => exit(),
             '_pid' => pid(),
             '_reason' => reason(),
             '_status' => status(),
             '_subscribers' => map(),
             '_entry_time' => pos_integer(),
             '_exit_time' => pos_integer(),
%%---------- FSM attributes --------
             '_state' => pid() | state() | term(),
             '_states' => map() | function(),
             '_fsm' => pid(),
             '_step' => non_neg_integer(),
%%---------- Actor attributes --------
             '_links' => map() | pid() | function()
%%---------- Customized attributes --------
%             <<"_max_steps">> => limit(),
%             <<"_recovery">> => recovery(),
%             <<"_max_retry">> => limit(),
%             <<"_retry_count">> => non_neg_integer(),
%             <<"_retry_interval">> => non_neg_integer()
%             <<"_name">> => name(),
%             <<"_links">> => map(),
%             <<"behavior">> => behavior(),
%             <<"_timeout">> => timeout(),  % default: 5000
%             <<"_hibernate">> => timeout()  % mandatory, default: infinity
            } | map().

-type key() :: atom() | string() | binary().

-type tag() :: 'xlx'.
-type path() :: [key()].
-type request() :: {tag(), from(), Command :: term()} |
                   {tag(), from(), Path :: list(), Command :: term()}.
-type notification() :: {tag(), Notification :: term()}.
-type message() :: request() | notification().
-type code() :: 'ok' | 'error' | 'stop' | 'pending' | key().
-type result() :: {'noreply', state()} |
                  {code(), state()} |
                  {code(), term(), state()} |
                  {code(), Stop :: reason(), Reply :: term(), state()}.
-type output() :: {'stopped', term()} |
                  {'exception', term()} |
                  {'EXIT', term()} |
                  {Sign :: term(), term()}.
-type reply() :: {'ok', term()} | 'ok' |
                 {'error', term()} | 'error' |
                 {'stop', term()} |
                 term().
-type status() :: 'running' |
                  'stopping' |
                  'stopped' |
                  'exception' |
                  'failover'.
-type reason() :: 'normal' | 'unload' | term(). 
-type entry() :: fun((state()) -> result()).
-type exit() :: fun((state()) -> output()).
-type react() :: fun((message() | term(), state()) -> result()).

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

-spec start_link(server_name(), state(), [start_opt()]) -> start_ret().
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

-spec start(server_name(), state(), [start_opt()]) -> start_ret().
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
            A1 = case erlang:function_exported(Module, entry, 1) of
                     true->
                         Data#{'_entry' => fun Module:entry/1};
                     false ->
                         Data
                 end,
            A2 = case erlang:function_exported(Module, react, 2) of
                     true->
                         A1#{'_react' => fun Module:react/2};
                     false ->
                         A1
                 end,
            case erlang:function_exported(Module, exit, 1) of
                true->
                    A2#{'_exit' => fun Module:exit/1};
                false ->
                    A2
            end
    end;
%% Convert data type from proplists to maps as type state().
create(Module, Data) when is_list(Data) ->
    create(Module, maps:from_list(Data)).

%%--------------------------------------------------------------------
%% gen_server callback. Initializes the server with state action entry.
%%--------------------------------------------------------------------
-spec init(state()) -> {'ok', state()} | {'stop', output()}.
init(State) ->
    process_flag(trap_exit, true),
    init_state(State).

init_state(#{'_status' := running} = State) ->  % resume suspended state.
    cast(self(), xlx_wakeup),  % notify to prepare state resume.
    {ok, State#{'_pid' => self()}};
init_state(State) ->
    Monitors = maps:get('_monitors', State, #{}),
    %% '_links' should be initilized by loader.
    Links = maps:get('_links', State, #{}),
    Boundary = maps:get(<<"_boundary">>, State, closed),
    Timeout = maps:get(<<"_timeout">>, State, ?DFL_TIMEOUT),
    State1 = State#{'_entry_time' => erlang:system_time(),
                    '_monitors' => Monitors,
                    '_links' => Links,
                    '_boundary' => Boundary,
                    '_timeout' => Timeout,
                    '_pid' =>self(),
                    '_status' => running},
    case enter(State1) of
        {ok, State2} ->
            init_fsm(State2);
        Stop ->
            Stop
    end.

enter(#{'_entry' := Entry} = State) ->
    %% fun exit/1 must be called even initialization not successful.
    try Entry(State) of
        {ok, S} ->
            {ok, S};
        {stop, Reason, S} ->
            {stop, leave(S#{'_reason' => Reason})}
    catch
        C:E ->
            ErrState = State#{'_status' => exception},
            {stop, leave(ErrState#{'_reason' => {C, E}})}
    end;
enter(State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% Initialize and launch FSM.
%% Flag of FSM is the attribute named '_state' existed.
%% Specially, '_state' and '_states' data should be initialized by loader.
%% Initialization operation is for data load from persistent store.
%%--------------------------------------------------------------------
%% state type is FSM, initilize it.
init_fsm(#{'_state' := State} = Fsm) ->
    Step = maps:get(<<"_step">>, Fsm, 0),
    Traces = maps:get(<<"_traces">>, Fsm, []),
    MaxTraces = maps:get(<<"_max_traces">>, Fsm, ?MAX_TRACES),
    Fsm1 = Fsm#{'_step' => Step,
                  '_traces' => Traces,
                  '_max_traces' => MaxTraces},
    start_fsm(State, Fsm1);
init_fsm(State) ->
    {ok, State}.

%% Import external actor as FSM state.
start_fsm(Pid, Fsm) when is_pid(Pid) ->
    {ok, Fsm};
%% State is out of FSM states set.
start_fsm(#{} = State, Fsm) ->
    {ok, Pid} = start_link(State#{'_fsm' => self()}),
    {ok, Fsm#{'_state' := Pid}};
start_fsm(Sign, #{'_states' := States} = Fsm) ->
    State = next_state(Sign, States),
    {ok, Pid} = start_link(State#{'_fsm' => self()}),
    {ok, Fsm#{'_state' := Pid}}.

%%--------------------------------------------------------------------
%% There is a graph structure in states set.
%%
%% Sign must not be tuple type. Data in map should be {From, Sign} := To.
%% The first level states is wildcard, Sign for any From.
%%--------------------------------------------------------------------
next(#{<<"_name">> := Name}, Sign, States) ->
    next_state({Name, Sign}, States);
next(Name, Sign, States) ->
    next_state({Name, Sign}, States).

next_state(State, _) when is_map(State) ->
    State;
next_state(Sign, States) when is_function(States) ->
    States(Sign);
next_state(Sign, States) ->
    case maps:find(Sign, States) of
        {ok, State} ->
            State;
        error ->
            {_From, Next} = Sign,
            maps:get(Next, States)
    end.

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
    handle_info({xlx, From, [], Request}, State).

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
normalize_msg({xlx, From, Command}) ->
    {xlx, From, [], Command};
%% sugar for subscribe.
normalize_msg({xlx, {Pid, _} = From, Path, subscribe}) ->
    {xlx, From, Path, {subscribe, Pid}};
%% gen_server timeout as hibernate command.
normalize_msg(tiemout) ->
    {xlx, hibernate};
normalize_msg(Msg) ->
    Msg.


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

%% Stop or hibernate may be canceled by state react with code error.
handle_2({xlx, {stop, Reason}}, {ok, State}) ->
    {stop, Reason, State};
handle_2({xlx, {stop, Reason}}, {ok, _, State}) ->
    {stop, Reason, State};
%% Hibernate command, not guarantee.
handle_2({xlx, hibernate}, {ok, State}) ->
    {noreply, State, hibernate};
handle_2({xlx, hibernate}, {ok, _, State}) ->
    {noreply, State, hibernate};
%% Reply is not here when code is noreply or stop
handle_2({xlx, _From, _, _}, {noreply, State}) ->
    {noreply, State};
handle_2({xlx, _From, _, _}, {stop, Reason, S}) ->
    {stop, Reason, S};
%% reply special message other than gen_server.
%% Four elements of tuple is stop signal. Code is not always 'stop'.
handle_2({xlx, From, _, _}, {Code, Reason, Reply, S}) ->
    reply(From, {Code, Reply}),
    {stop, Reason, S};
handle_2({xlx, From, _, _}, {Code, Reply, S}) ->
    reply(From, {Code, Reply}),
    {noreply, S};
handle_2({xlx, From, _, _}, {Code, S}) ->
    reply(From, Code),
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
%% State transition message. From is state data or name.
default_react({xlx_leave, Vector}, Fsm) ->
    transfer(Fsm, Vector);
default_react({xlx, Info}, State) ->
    recast(Info, State);
default_react({xlx, _From, [], Command}, State) ->
    recall(Command, State);
default_react({xlx, From, Path, Command}, State) ->
    traverse(From, Path, Command, State);
default_react({'DOWN', M, process, _, Reason}, State) ->
    handle_halt(M, Reason, State);
default_react({'EXIT', Pid, Reason}, State) ->
    handle_halt(Pid, Reason, State);
default_react(_Info, State) ->
    {ok, State}.

handle_halt(Id, Reason, #{'_monitors' := M} = State) ->
    case maps:find(Id, M) of
        {ok, '_state'} ->
            transfer(State#{'_reason' => Reason}, exception);
        {ok, Key} ->
            {ok, done, S} = delete(Key, State),
            {ok, S};
        error when is_reference(Id) ->
            Subs = maps:get('_subscribers', State),
            Subs1 = maps:remove(Id, Subs),
            {ok, State#{'_subscribers' := Subs1}};
        error ->
            {ok, State}
    end.

%% Retrieve data, Activate or peek the attribute.
recall({touch, Key}, State) ->
    activate(Key, State);
recall({get, Key}, State) ->
    get(Key, State);
recall({get, Key, raw}, State) ->
    get_raw(Key, State);
recall(get, State) ->
    get_all(State);  % Exclude internal attributes and active attributes.
%% Update data
%% Internal attributes names are atom type, cannot be changed externally. 
recall({put, Key, _}, State) when is_atom(Key) ->
    {error, forbidden, State};
recall({put, Key, Value}, State) ->
    put(Key, Value, State);
%% Purge data
recall({delete, Key}, State) when is_atom(Key) ->
    {error, forbidden, State};
recall({delete, Key}, State) ->
    delete(Key, State);
%% Suberscribe and notify
recall({subscribe, Pid}, State) ->
    Subs = maps:get('_subscribers', State, #{}),
    Mref = monitor(process, Pid),
    Subs1 = Subs#{Mref => Pid},
    {ok, Mref, State#{'_subscribers' => Subs1}};
recall({unsubscribe, Mref}, #{'_subscribers' := Subs} = State) ->
    demonitor(Mref),
    Subs1 = maps:remove(Mref, Subs),
    {ok, State#{'_subscribers' := Subs1}};
recall(_, State) ->
    {error, unknown, State}.

recast({notify, Info}, #{'_subscribers' := Subs} = State) ->
    maps:fold(fun(M, P, A) ->
                      catch P ! {M, Info},
                      A
              end, 0, Subs),
    {ok, State};
recast({unsubscribe, _} = Unsub, State) ->
    {_, NewState} = recall(Unsub, State),
    {ok, NewState};
recast(_Info, State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% FSM state transition functions.
%%--------------------------------------------------------------------
transfer(Fsm, #{'_sign' := Sign} = State) ->
    transfer(Fsm, State, Sign);
transfer(Fsm, {From, To}) ->
    transfer(Fsm, From, To);
transfer(Fsm, To) ->
    transfer(Fsm, undefined, To).

transfer(#{'_step' := Step} = Fsm, From, To) ->
    Fsm1 = archive(Fsm, {From, To}),
    Res = case maps:find(<<"_max_steps">>, Fsm1) of
              {ok, MaxSteps} when Step >= MaxSteps ->
                  t1(Fsm1#{'_reason' => out_of_steps}, From, exception);
              _ ->
                  t1(Fsm1#{'_step' := Step + 1}, From, To)
          end,
    t2(Res, From, To).

t1(#{'_states' := States} = Fsm, From, To) ->
    %% You can provide your own cutomized exception and stop state.
    try next(From, To, States) of
        stop ->
            {stop, normal, Fsm};
        Next ->
            {ok, Pid} = start_link(Next#{'_fsm' => self()}),
            {ok, Fsm#{'_state' := Pid}}
    catch
        error: _BadKey when To =:= exception ->
            {stop, exception, Fsm};
        error: _BadKey when To =:= ok ->
            {stop, normal, Fsm};
        error: _BadKey when To =:= stop ->
            {stop, normal, Fsm};
        error: _BadKey when To =:= stopped ->
            {stop, normal, Fsm};
        error: _BadKey ->  % try exception handler.
            t1(Fsm, From, exception)
    end;
t1(Fsm, _From, _To) ->  % no states set, halt.
    {stop, no_more_state, Fsm}.

t2({stop, Reason, #{'_state' := Pid} = Fsm}, State, Sign) ->
    unlink(Pid),
% todo: remove from monitors.
    Fsm1 = Fsm#{'_status' := stopping, '_state' := State, '_sign' => Sign},
    {stop, Reason, Fsm1};
t2(Ok, _State, _Sign) ->
    Ok.

%% Trace is a vector of form {From, To}
archive(#{'_traces' := Traces} = Fsm, Trace) when is_function(Traces) ->
    Traces(Fsm, Trace);
archive(#{'_traces' := Traces, '_max_traces' := Limit} = Fsm, Trace)  ->
    Traces1 = enqueue(Trace, Traces, Limit),
    Fsm#{'_traces' => Traces1};
archive(Fsm, _Trace) ->
    Fsm.

enqueue(_Item, _Queue, 0) ->
    [];
enqueue(Item, Queue, infinity) ->
    [Item | Queue];
enqueue(Item, Queue, Limit) ->
    lists:sublist([Item | Queue], Limit).

%%--------------------------------------------------------------------
%% Process messages with path, when react function does not handle it.
%%--------------------------------------------------------------------
traverse(_, [Key], get, State) ->
    recall({get, Key}, State);
traverse(_, [Key], {put, Value}, State) ->
    recall({put, Key, Value}, State);
traverse(_, [Key], delete, State) ->
    recall({delete, Key}, State);
traverse(From, [Key | Path], Command, State) ->
    case get(Key, State) of
        {ok, Pid, NewS} when is_pid(Pid) ->
            Pid ! {xlx, From, Path, Command},
            {ok, NewS};
        {ok, Package, NewS} ->
            case invoke(Command, Key, Path, Package, NewS) of
                error ->
                    {error, undefined, NewS};
                {dirty, DirtyS} ->
                    {ok, DirtyS};
                {Code, Value} ->
                    {Code, Value, NewS}
            end;
        Error ->
            Error
    end.

invoke(Command, Key, [], Data, Container) ->
    invoke1(Command, Key, Data, Container);
invoke(Command, Key, [Next | Path], Branch, Container) ->
    case invoke0(Command, Next, Path, Branch) of
        {dirty, NewBranch} ->
            {dirty, Container#{Key := NewBranch}};
        NotChange ->
            NotChange
    end.

invoke0(Command, Key, [], Container) ->
    invoke2(Command, Key, Container);
invoke0(Command, Key, Path, Container) ->
    case maps:find(Key, Container) of
        {ok, Value} ->
            invoke(Command, Key, Path, Value, Container);
        error ->
            error
    end.

invoke1(get, _Key, Value, _Container) ->
    {ok, Value};
invoke1(Command, Key, _Value, Container) ->
    invoke2(Command, Key, Container).

invoke2(get, Key, Container) ->
    maps:find(Key, Container);
invoke2({put, Value}, Key, Container) ->
    NewC = maps:put(Key, Value, Container),
    {dirty, NewC};
invoke2(delete, Key, Container) ->
    NewC = maps:remove(Key, Container),
    {dirty, NewC};
invoke2(_Unknown, _, _) ->
    {error, unknown}.

%%--------------------------------------------------------------------
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% state action exit is called to destruct and to output result.
%%--------------------------------------------------------------------
-spec terminate(reason(), state()) -> no_return().
terminate(Reason, State) ->
    FinalState = stop_fsm(State, Reason),
    %% leave is reused by init function for uninitialization.
    leave(FinalState).

leave(State) ->
    {Sign, State1} = try_exit(State),
    State2 = State1#{'_exit_time' => erlang:system_time(),
                     '_status' := stopped},
    Vector = case maps:find(<<"_name">>, State2) of
                 {ok, Name} ->
                     {Name, Sign};
                 error ->
                     Sign
             end,
    FinalState = notify_all(State2, {leave, Vector}),
    notify_fsm(FinalState, Sign).

notify_all(#{'_subscribers' := Subs} = State, Info) ->
    maps:fold(fun(Mref, Pid, Acc) ->
                      catch Pid ! {Mref, Info},
                      demonitor(Mref),
                      Acc
              end, 0, Subs),
    maps:remove('_subscribers', State);
notify_all(State, _) ->
    State.

notify_fsm(#{'_fsm' := Fsm} = State, Sign) ->
    case is_process_alive(Fsm) of
        true ->
            Fsm ! {xlx_leave, {State, Sign}},
            flush_and_relay(Fsm),
            normal;
        false ->
            normal
    end.

%% flush system messages and reply application messages.
flush_and_relay(Pid) ->
    receive
        {'DOWN', _, _, _, _} ->
            flush_and_relay(Pid);
        {'EXIT', _, _} ->
            flush_and_relay(Pid);
        Message ->
            Pid ! Message,
            flush_and_relay(Pid)
    after 0 ->
            true
    end.

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

stop_fsm(#{'_status' := stopping} = Fsm, _Reason) ->
    Fsm;
stop_fsm(#{'_state' := Pid} = Fsm, Reason) ->
    case is_process_alive(Pid) of
        true ->
            Timeout = maps:get(<<"_timeout">>, Fsm,  ?DFL_TIMEOUT),
            {stopped, {Final, Sign}} = stop(Pid, Reason, Timeout),
            Fsm#{'_state' := Final, '_sign' => Sign, '_reason' => Reason};
        false ->
            Fsm
    end.
    
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
    ok;
reply(undefined, _) ->
    ok.


%% Same as gen_server:call().
-spec call(process(), Request :: term()) -> reply().
call(Process, Command) ->
    call(Process, Command, [], infinity).

-spec call(process(), Request :: term(), path()) -> reply().
call(Process, Command, Path) ->
    call(Process, Command, Path, infinity).

-spec call(process(), Request :: term(), path(), timeout()) -> reply().
call(Process, Command, Path, Timeout) ->
    Tag = make_ref(),
    Process ! {xlx, {self(), Tag}, Path, Command},
    receive
        {Tag, Result} ->
            Result
    after
        Timeout ->
            {error, timeout}
    end.

%% Same as gen_server:cast(). cast not support path, which is not traceable.
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
    cast(Process, {stopped, Reason}),
    receive
        {xlx_leave, Result} ->
            demonitor(Mref, [flush]),
            {stopped, Result};
        {'DOWN', Mref, _, _, Result} ->
            {'EXIT', Result}
    after
        Timeout ->
            demonitor(Mref, [flush]),
            erlang:exit(timeout)
    end.

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
-spec activate(key(), state()) -> {pid, pid(), state()} |
                                  {data, term(), state()} |
                                  {error, term(), state()}.
%% Raw data types of attributes:
%% {link, pid(), local} | {link, pid(), reference()} |
%%  #{'_actions' := actions()} | term().
%% when actions() :: state | module() | Module :: binary() | Actions :: map().
activate(Key, State) ->
    case maps:find(Key, State) of
        {ok, {link, Pid, _}} ->
            {pid, Pid, State};
        {ok, #{'_actions' := Actions} = Value} ->
            activate(Actions, Key, Value, State);
        {ok, Value} ->
            {data, Value, State};
        error ->  % not found, try to activate data in '_links'.
            attach(Key, State)
    end.

%% Value must be map type. Spawn state machine and link it as active attribute.
activate(Key, Value, #{'_monitors' := M} = State) ->
    {ok, Pid} = xl_state:start_link(Value),
    Monitors = M#{Pid => Key},
    {pid, Pid, State#{Key => {link, Pid, local}, '_monitors' := Monitors}}.

%% Intermediate function to bind behaviors with state.
activate(state, Key, Value, State) ->
    activate(Key, Value, State);
activate(Module, Key, Value, State) when is_atom(Module) ->
    Value1 = create(Module, Value),
    activate(Key, Value1, State);
activate(Module, Key, Value, State) when is_binary(Module) ->
    Module1 = binary_to_existing_atom(Module, utf8),
    activate(Module1, Key, Value, State);
%% Actions is map type with state behaviors: #{'_entry', '_react', '_exit'}.
activate(Actions, Key, Value, State) when is_map(Actions) ->
    Value1 = maps:merge(Value, Actions),
    activate(Key, Value1, State);
activate(_Unknown, _Key, _Value, State) ->    
    {error, unknown, State}.

%% Try to retrieve data or external actor,
%%  and attach to attribute of current actor.
attach(Key, #{'_links' := Links} = State) ->
    case fetch_link(Key, Links, State) of
        %% external actor.
        {pid, Pid, #{'_monitors' := M} = S} ->
            Mref = monitor(process, Pid),
            M1 = M#{Mref => Key},
            {pid, Pid, S#{Key => {link, Pid, Mref}, '_monitors' := M1}};
        %% state data to spawn link local child actor.
        {state, Data, S} ->
            Actions = maps:get('_actions', Data, state),
            activate(Actions, Key, Data, S);
        %% data only, copy it as initial value.
        {data, Data, S} ->
            {data, Data, S#{Key => Data}};
        Error ->
            Error
    end.

%% Links function type:
%% -spec link_fun(key(), state()) -> {pid, pid(), state()} |
%%                                   {state, state(), state()} |
%%                                   {data, term(), state()} |
%%                                   {error, term(), state()}.
fetch_link(Key, Links, State) when is_function(Links) ->
    Links(Key, State);
%% Links pid type:
%% send special command 'touch': {xlx, From, {touch, Key}}
%%   argument: Key :: key()
%%   return: {pid, pid()} | {state, state()} | {data, term()} | {error, term()}.
fetch_link(Key, Links, #{'_timeout' := Timeout} = State) when is_pid(Links) ->
    {Sign, Result} = call(Links, {touch, Key}, Timeout),
    {Sign, Result, State};
%% Links map type format:
%% {ref, Pid, Id} | {ref, Key, Id} | {state, Map} | Data
%% return: {pid, pid(), state()} | {state, state(), state()}
%%     | {data, term(), state()} | {error, term(), state()}.
fetch_link(Key, Links, #{'_timeout' := Timeout} = State) ->
    case maps:find(Key, Links) of
        error ->
            {error, undefined, State};
        %% pid of registry actor directly.
        {ok, {ref, Registry, Id}} when is_pid(Registry) ->
            {Sign, Result} = call(Registry, {touch, Id}, Timeout),
            {Sign, Result, State};
        %% attribute name as registry.
        {ok, {ref, RegName, Id}} ->
            case activate(RegName, State) of
                {pid, Registry, State1} ->
                    {Sign, Result} = call(Registry, {touch, Id}, Timeout),
                    {Sign, Result, State1};
                {data, Data, State1} when Id =/= undefined ->
                    Value = maps:get(Id, Data),
                    {data, Value, State1};
                %% when Id is undefined, return {data, Data, State1}.
                %% Same case as Error :: {error, term()}.
                Error ->
                    Error
            end;
        %% Explicit state data to spawn actor.
        {ok, {state, Data}} ->
            {state, Data, State};
        {ok, Data} ->
            {data, Data, State}
    end.

%%--------------------------------------------------------------------
%% Helper functions for data access.
%% if raw data 
%%--------------------------------------------------------------------
%% return: {ok, term(), state()} | {error, term(), state()}.
%% request of 'get' is default to fetch all data (without internal attributes).
get(Key, State) ->
    case activate(Key, State) of
        {data, Data, State1} ->
            {ok, Data, State1};
        {pid, Pid, #{'_timeout' := Timeout} = State1} ->
            {Sign, Result} = call(Pid, get, Timeout),
            {Sign, Result, State1};
        Error ->
            Error
    end.

%% Raw data in state attributes map.
get_raw(Key, State) ->
    case maps:find(Key, State) of
        {ok, Value} ->
            {ok, Value, State};
        error ->
            {error, undefined, State}
    end.

%% Pick all exportable attributes,
%%   exclude active attributes or attributes with atom type name.
get_all(State) ->
    Pred = fun(_, {link, _, _}) ->
                   false;
              (Key, _) when is_atom(Key) ->
                   false;
              (_, _) ->
                   true
           end,
    {ok, maps:filter(Pred, State), State}.

put(Key, Value, State) ->
    S = unlink_raw(Key, State),
    {ok, done, S#{Key => Value}}.

delete(Key, State) ->
    S = unlink_raw(Key, State),
    {ok, done, maps:remove(Key, S)}.

unlink_raw(Key, #{'_monitors' := M} = State) ->
    case maps:find(Key, State) of
        {ok, {link, Pid, local}} ->
            unlink(Pid),
            M1 = maps:remove(Pid, M),
            cast(Pid, {stop, update}),
            State#{'_monitors' := M1};
        {ok, {link, _, Monitor}} ->
            demonitor(Monitor),
            M1 = maps:remove(Monitor, M),
            State#{'_monitors' := M1};
        {ok, _} ->
            State;
        error ->
            State
    end.

%%%===================================================================
%%% Unit test
%%%===================================================================
-ifdef(TEST).

-endif.
