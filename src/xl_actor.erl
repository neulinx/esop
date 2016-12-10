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
             '_parent' => pid(),
             '_surname' => tag(),
             '_reason' => reason(),
             '_status' => status(),
             '_sign' => tag(),
             '_recovery' => recovery(),
             '_subscribers' => map(),
             '_entry_time' => pos_integer(),
             '_exit_time' => pos_integer(),
             '_states' => active_key() | states_map() | links_map(),
             '_monitors' => monitor()
%%---------- Customized attributes --------
%             <<"_max_steps">> => limit(),
%             <<"_recovery">> => recovery(),
%             <<"_max_retry">> => limit(),
%             <<"_retry_count">> => non_neg_integer(),
%             <<"_retry_interval">> => non_neg_integer()
%             <<"_name">> => name(),
%             <<"behavior">> => behavior(),
%             <<"_timeout">> => timeout(),  % default: 5000
%             <<"_hibernate">> => timeout()  % mandatory, default: infinity
            } | map().

-type monitor() :: {tag(), recovery()}.
-type monitors() :: #{process() | reference() => monitor()}.
-type active_key() :: {'link', process(), non_neg_integer() | reference()} |
                      {'function', function()}.
-type states_map() :: #{vector() => state()}.
-type links_map() :: #{Key :: tag() => refers()}.
-type refer() :: {'ref', Registry :: (process() | tag()), tag()}.
-type state_d() :: state() | {state(), actions(), recovery()}.
-type refers() :: refer() | state_d() | {data, term()}.
-type tag() :: atom() | string() | binary() | integer().
-type path() :: [tag()].
-type request() :: {'xlx', from(), Command :: term()} |
                   {'xlx', from(), Path :: list(), Command :: term()}.
-type notification() :: {tag(), Notification :: term()}.
-type message() :: request() | notification().
-type code() :: 'ok' | 'error' | 'stop' | tag().
-type result() :: {'noreply', state()} |
                  {code(), state()} |
                  {code(), term(), state()} |
                  {code(), Stop :: reason(), Reply :: term(), state()}.
-type output() :: {'stopped', term()} |
                  {'exception', term()} |
                  {'EXIT', term()} |
                  {'DOWN', term()} |
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
-type reason() :: 'normal' | term().
-type entry_return() :: {'ok', state()} |
                        {'ok', state(), timeout()} |
                        {'ok', state(), 'hibernate'} |
                        {'stop', Reason :: term()} |
                        {'stop', Reason :: term(), state()}.
-type entry() :: fun((state()) -> entry_return()).
-type exit() :: fun((state()) -> output()).
-type react() :: fun((message() | term(), state()) -> result()).
-type actions() :: 'state' | module() | binary() | state_actions().
-type state_actions() :: #{'_entry' => entry(),
                           '_exit' => exit(),
                           '_react' => react()}.
-type recovery() :: {'rollback', integer()} |
                    {'reset', integer() | state() | vector()} |
                    'reset' |
                    'undefined'.
-type vector() :: {To :: tag()} |
                  {From:: tag(), To :: tag()} |
                  {Fsm :: tag(), From:: tag(), To :: tag()}.
                  

%%-type behavior() :: 'state' | <<"state">> | module() | binary().

%%--------------------------------------------------------------------
%% Messages format.
%%--------------------------------------------------------------------
%% System message format.
%% - normal: {xlx, From, Command} -> {Code, Result} | {error, Error}.
%% - traverse with path: {xlx, From, Path, Command} -> result().
%% - notify: {xlx, Command} -> no_return. To be deprecated, merge into normal.
%% - touch & activate command: {xlx, From, xl_touch} ->
%%            {pid, Pid} | {state, state_d()} | {data, Data} | {error, Error}.
%% - wakeup event: {xlx, xl_wakeup}, To be tuned.
%% - hibernate command: {xlx, xl_hibernate}, To be tuned.
%% - stop command: {xlx, {stop, Reason}}, To be tuned.
%% - state transition event: {xlx, {xl_leave, Vector}}, To be tuned.

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
    cast(self(), xl_wakeup),  % notify to prepare state resume.
    {ok, State#{'_pid' => self()}};
%% Initialize must-have attributes to the state.
init_state(State) ->
    Monitors = maps:get('_monitors', State, #{}),
    %% '_states' should be initilized by loader.
    States = maps:get('_states', State, #{}),
    Timeout = maps:get(<<"_timeout">>, State, ?DFL_TIMEOUT),
    State1 = State#{'_entry_time' => erlang:system_time(),
                    '_monitors' => Monitors,
                    '_states' => States,
                    '_timeout' => Timeout,
                    '_pid' =>self(),
                    '_status' => running},
    State2 = preload(State1),
    case enter(State2) of
        {ok, State3} ->
            {ok, preload(State3)};
        {ok, State3, Option} ->  % Option :: Timeout | hibernate.
            {ok, preload(State3), Option};
        Error ->
            Error
    end.

preload(#{<<"_preload">> := Preload} = State) ->
    MakeActive = fun(Key, S) ->
                         case activate(Key, S) of
                             {error, Error, S1} ->
                                 error({preload_failure, Error});
                             {_, _, S1} ->
                                 S1
                         end
                 end,
    lists:foldl(MakeActive, State, Preload);
preload(State) ->
    State.

enter(#{'_entry' := Entry} = State) ->
    case Entry(State) of
        {stop, Reason, _S} ->
            {stop, Reason};
        Ok ->
            Ok
    end;
enter(State) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% States set is a map structure to keep state data, which is not only for FSMs
%% but also for links. For FSMs, key of the state map must be tuple type.
%%
%% Each FSM type active attribute has its own states set. To store all the
%% FSMs' states sets in a single map, key of the map should contains
%% information of FSM name, state name and directive to next state. So the
%% key format may be {FsmName, StateName, Direction} or
%% {FsmName, {StateName, Direction}}. I prefer to use the flat format rather
%%  than the nest format.
%%
%% There are rules for states map:
%% - Sign must not be tuple type.
%% - If {Surname, Name, Sign} is not found, then try {Name, Sign}.
%% - If {Name, Sign} is not found, then try {Sign}.
%% - If it is not found at last, throw excepion rather than return error.
%%--------------------------------------------------------------------
%% Helper function to gather information for .
next(#{'_surname' := Key, <<"_name">> := Name}, Sign, States) ->
    next_state({Key, Name, Sign}, States);
next(#{<<"_name">> := Name}, Sign, States) ->
    next_state({Name, Sign}, States);
next(Name, Sign, States) ->
    next_state({Name, Sign}, States).

%% If first parameter is state data, return it without lookup.
%% If there is no state data by key: {From, To}, try to find key: To.
next_state(State, _) when is_map(State) ->
    State;
%% -spec states(vector()) -> state().
next_state(Vector, {function, States}) ->
    States(Vector);
next_state(Vector, {link, States, _}) ->
    %% Internal data structure of States actor is same as States map.
    %% touch operation may make a cache of #{{From, To} => state()} in States.
    case call(States, {xl_touch, Vector}, Timeout) of
        {data, Data} ->
            Data;
        _ ->
            error({get_state, badarg})
    end;
next_state(Vector, States) ->
    locate(Vector, States).

locate(Vector, States) ->
    case maps:find(Vector, States) of
        {ok, State} ->
            State;
        error ->
            locate(erlang:delete_element(1, Vector), States)
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
    {xlx, xl_hibernate};
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
handle_2({xlx, xl_hibernate}, {ok, State}) ->
    {noreply, State, hibernate};
handle_2({xlx, xl_hibernate}, {ok, _, State}) ->
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
default_react({xlx, {xl_leave, Vector}}, Fsm) ->
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
recall({xl_touch, Key}, State) ->
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
    demonitor(Mref, [flush]),
    Subs1 = maps:remove(Mref, Subs),
    {ok, done, State#{'_subscribers' := Subs1}};
recall(_, State) ->
    {error, unknown, State}.

recast({notify, Info}, #{'_subscribers' := Subs} = State) ->
    maps:fold(fun(M, P, A) ->
                      catch P ! {M, Info},
                      A
              end, 0, Subs),
    {ok, State};
recast({unsubscribe, _} = Unsub, State) ->
    {ok, done, NewState} = recall(Unsub, State),
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
            F = unlink('_state', Fsm),
            {pid, _, F1} = activate(undefined, '_state', Next, F),
            {ok, F1}
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

t2({stop, Reason, Fsm}, State, Sign) ->
    {ok, done, F} = put('_state', {state, State}, Fsm),
% todo: remove from monitors.
    F1 = F#{'_status' := stopping, '_sign' => Sign},
    {stop, Reason, F1};
t2(Ok, _State, _Sign) ->
    Ok.

%% Trace is a vector of form {From, To}
archive(#{'_traces' := {function, Traces}} = Fsm, Trace) ->
    Traces(Fsm, Trace);
archive(#{'_traces' := {link, Traces, _}} = Fsm, Trace) ->
    Timeout = maps:get('_timeout', Fsm),
    call(Traces, {xlx_trace, Trace}, Timeout),
    Fsm;
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
    case activate(Key, State) of
        {pid, Pid, S} ->
            Pid ! {xlx, From, Path, Command},
            {ok, S};
        {data, Package, S} ->  % Assert Path not [].
            case iterate(Command, Path, Package) of
                error ->
                    {error, undefined, S};
                {dirty, Data} ->
                    {ok, done, S#{Key => Data}};
                {Code, Value} ->  % {ok, Value} | {error, Error}.
                    {Code, Value, S}
            end;
        Error ->
            Error
    end.

iterate(_, _, Container) when not is_map(Container) ->
    {error, badarg};
iterate(get, [Key], Container) ->
    maps:find(Key, Container);
iterate({put, Value}, [Key], Container) ->
    NewC = maps:put(Key, Value, Container),
    {dirty, NewC};
iterate(delete, [Key], Container) ->
    NewC = maps:remove(Key, Container),
    {dirty, NewC};
iterate(Command, [Key | Path], Container) ->
    case maps:find(Key, Container) of
        {ok, Branch} ->
            case iterate(Command, Path, Branch) of
                {dirty, NewB} ->
                    {dirty, Container#{Key := NewB}};
                Result ->
                    Result
            end;
        error ->
            {error, badarg}
    end;
iterate(_, _, _) ->
    {error, badarg}.

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

%% Active attributes and monitors are released by otp process.
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
    FinalState = notify_subscribers(State2, {leave, Vector}),
    notify_fsm(FinalState, Sign).

notify_subscribers(#{'_subscribers' := Subs} = State, Info) ->
    maps:fold(fun(Mref, Pid, Acc) ->
                      catch Pid ! {Mref, Info},
                      demonitor(Mref, [flush]),
                      Acc
              end, 0, Subs),
    maps:remove('_subscribers', State);
notify_subscribers(State, _) ->
    State.

notify_fsm(#{'_parent' := Fsm} = State, Sign) ->
    case is_process_alive(Fsm) of
        true ->
            cast(Fsm, {xl_leave, {State, Sign}}),
            flush_and_relay(Fsm),
            ok;
        false ->
            ok
    end;
notify_fsm(_, _) ->
    ok.


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
stop_fsm(#{'_state' := {link, Pid, _}} = Fsm, Reason) ->
    Timeout = maps:get(<<"_timeout">>, Fsm,  ?DFL_TIMEOUT),
    case stop(Pid, Reason, Timeout) of
        {ok, {Final, Sign}} ->
            Fsm#{'_state' := {state, Final},
                 '_sign' => Sign,
                 '_reason' => Reason};
        {error, Error} ->
            Fsm#{'_state' := exception,
                 '_sign' => exception,
                 '_reason' => Error}
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
        {xlx, {xl_leave, Result}} ->
            demonitor(Mref, [flush]),
            {ok, Result};
        {'DOWN', Mref, _, _, Result} ->
            {error, Result}
    after
        Timeout ->
            demonitor(Mref, [flush]),
            {error, timeout}
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
%% Data types of attributes:
%% {link, pid(), Step :: non_neg_integer() | Monitor :: reference()} |
%%   {state, {state(), actions(), recovery()}} | {state, state()} |
%%   {reset} |
%%   Value :: term().
%% when actions() :: state | module() | Module :: binary() | Actions :: map().
%% -spec activate(tag(), state()) -> {pid, pid(), state()} |
%%                                   {data, term(), state()} |
%%                                   {error, term(), state()}.
activate(Key, State) ->
    case maps:find(Key, State) of
        {ok, {link, Pid, _}} ->
            {pid, Pid, State};
        {ok, {state, S}} ->
            activate(Key, S, State);
        {ok, {reset}} ->
            attach(Key, reset, State);
        {ok, Value} ->
            {data, Value, State};
        error ->  % not found, try to activate data in '_states'.
            attach(Key, undefined, State)
    end.

activate(Key, {S, Actions, Recovery}, State) ->
    activate(Actions, Key, S, Recovery, State);
activate(Key, Value, State) ->
    Actions = maps:get('_actions', Value, state),
    Recovery = maps:get('_recovery', Value, undefined),
    activate(Actions, Key, Value, Recovery, State).

%% Intermediate function to bind behaviors with state.
activate(state, Key, Value, Recovery, State) ->
    activate(Key, Value, Recovery, State);
activate(Module, Key, Value, Recovery, State) when is_atom(Module) ->
    Value1 = create(Module, Value),
    activate(Key, Value1, Recovery, State);
activate(Module, Key, Value, Recovery, State) when is_binary(Module) ->
    Module1 = binary_to_existing_atom(Module, utf8),
    activate(Module1, Key, Value, Recovery, State);
%% Actions is map type with state behaviors: #{'_entry', '_react', '_exit'}.
activate(Actions, Key, Value, Recovery, State) when is_map(Actions) ->
    Value1 = maps:merge(Value, Actions),
    activate(Key, Value1, Recovery, State);
activate(_Unknown, _Key, _Value, _Recovery, State) ->    
    {error, unknown, State}.

%% Value must be map type. Spawn state machine and link it as active attribute.
activate(Key, Value, Recovery, #{'_monitors' := M} = State) ->
    {ok, Pid} = start_link(Value#{'_parent' => self(), '_surname' => Key}),
    Monitors = M#{Pid => {Key, Recovery}},
    {pid, Pid, State#{Key => {link, Pid, 0}, '_monitors' := Monitors}}.

%% Try to retrieve data or external actor,
%%  and attach to attribute of current actor.
%% Here: Reovery :: reset | undeinfed.
attach(Key, Recovery, #{'_states' := Links} = State) ->
    case fetch_link(Key, Links, State) of
        %% external actor.
        {pid, Pid, #{'_monitors' := M} = S} ->
            Mref = monitor(process, Pid),
            M1 = M#{Mref => {Key, Recovery}},
            {pid, Pid, S#{Key => {link, Pid, Mref}, '_monitors' := M1}};
        %% state data to spawn link local child actor.
        {state, Data, S} ->
            activate(Key, Data, S);
        %% data only, copy it as initial value.
        {data, Data, S} ->
            {data, Data, S#{Key => Data}};
        Error ->
            Error
    end.

%% -type state_d() :: state() | {state(), actions(), recovery()}.
%% -type result() :: {pid, pid(), state()} | 
%%                 {state, state_d(), state()} |
%%                 {data, term(), state()} |
%%                 {error, term(), state()}.
%% Links function type:
%% -spec link_fun(tag(), state()) -> result().
fetch_link(Key, {function, Links}, State) ->
    Links(Key, State);
%% Links pid type:
%% send special command 'touch': {xlx, From, {xl_touch, Key}},
%%   argument: Key :: tag(),
%%   return: result() without last state() element.
fetch_link(Key, {link, Links, _}, #{'_timeout' := Timeout} = State) ->
    {Sign, Result} = call(Links, {xl_touch, Key}, Timeout),
    {Sign, Result, State};
%% Links map type format:
%% {ref, Registry :: (pid() | tag()), tag()} |
%%   {state, state_d()} |
%%   {data, term()}.
%% return: {pid, pid(), state()} | {state, state_d(), state()}
%%     | {data, term(), state()} | {error, term(), state()}.
fetch_link(Key, Links, #{'_timeout' := Timeout} = State) ->
    case maps:find(Key, Links) of
        error ->
            {error, undefined, State};
        %% Registry process directly.
        %% Should be deprecated because of no monitor.
        {ok, {ref, Registry, Id}} when is_pid(Registry) ->
            {Sign, Result} = call(Registry, {xl_touch, Id}, Timeout),
            {Sign, Result, State};
        %% attribute name as registry.
        {ok, {ref, RegName, Id}} ->
            case activate(RegName, State) of
                {pid, Registry, State1} ->
                    {Sign, Result} = call(Registry, {xl_touch, Id}, Timeout),
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
        {ok, {data, Data}} ->
            {data, Data, State};
        _Unknown ->
            {error, badarg, State}
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
              (Key, _) when is_tuple(Key) ->
                   false;
              (_, _) ->
                   true
           end,
    {ok, maps:filter(Pred, State), State}.

put(Key, Value, State) ->
    S = unlink(Key, State),
    {ok, done, S#{Key => Value}}.

delete(Key, State) ->
    S = unlink(Key, State),
    {ok, done, maps:remove(Key, S)}.

unlink(Key, #{'_monitors' := M} = State) ->
    case maps:find(Key, State) of
        {ok, {link, Pid, local}} ->
            unlink(Pid),
            M1 = maps:remove(Pid, M),
            cast(Pid, {stop, update}),
            State#{'_monitors' := M1};
        {ok, {link, _, Monitor}} ->
            demonitor(Monitor, [flush]),
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
