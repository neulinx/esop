%%%-------------------------------------------------------------------
%%% @author Gary Hai <gary@XL59.com>
%%% @copyright (C) 2016, Neulinx Platforms.
%%% @doc
%%%  Trinitiy of State, FSM, Actor, with gen_server behaviours.
%%% @end
%%% Created : 27 Apr 2016 by Gary Hai <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(xl).

%% Support inline unit test for EUnit.
-ifdef(TEST).
    -include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(gen_server).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).
%% API
-export([create/1, create/2]).
-export([start_link/1, start_link/2, start_link/3]).
-export([start/1, start/2, start/3]).
-export([stop/1, stop/2, stop/3]).
-export([call/2, call/3, call/4, cast/2, cast/3, reply/2]).
-export([relay/3, relay/4]).
-export([subscribe/1, subscribe/2, unsubscribe/2, notify/2]).
-export([get/2, get_raw/2, get_all/1, put/3, delete/2, delete/3]).

%% -------------------------------------------------------------------
%% Macro definitions for default value. 
%% -------------------------------------------------------------------
%% Default timeout value of gen_server:call() is 5000ms. So we choose
%% 4000 ms as default timeout value, is smaller than 5000ms
-define(DFL_TIMEOUT, 4000).
%% Trace logs consume lots of resources and keep them from garbage
%% collecting. So the limit of max traces size should not be infinity.
-define(MAX_TRACES, 1000).            % Default trace log limit.
%% Max step limit can be a watchdog for self-heal.
-define(MAX_STEPS, infinity).         % Default max steps of a FSM.
%% To avoid excessive CPU use, retry operation is aynchronous. Even
%% retry interval is 0ms, there is at least one yield action for other
%% processes.
-define(RETRY_INTERVAL, 0).

%% -------------------------------------------------------------------
%% Types specifications.
%% 
%% Type of state() is map now, while the old version is record. State
%% data has two parts: header and body, are in same level of state
%% data structure. Header part is runtime data of state machine. Body
%% part is original data load from persistent layer. Some attributes
%% of header are convert from same name attribute (different
%% type). According to aesthetics, header and body are in same level
%% of a plain and flat data structure. The distinguish is keys names
%% of header have prefix '_'. Runtime generated attributes names
%% should be atom type. Limited by JSON decoder, attributes names of
%% raw data are binary type of string. If there are two same name
%% attributes, the raw data attribute is for initialization and fault
%% recovery.
%% 
%% There are two types of attribute, active attribute and static
%% attribute. Active attribute may be a process linked or monitered
%% by the actor process or a function. Process is loosely coupled
%% with asynchronized request while function is tightly coupled with
%% sychronized interaction. There are two link types of process
%% attribute. One is internal link linked to the actor. The other is
%% external link monitered by the actor. Once an actor process exits,
%% all internal link processes must also exit. Active attributes
%% definitions are stored in '_states', which is also an active
%% attribute. The definition may be member id registered in other
%% realm (other actor's attribute) as external link or state data for
%% internal link.
%% 
%% An actor may be act as a finite state machine when the attribute
%% named '_state' is present, which is active attribute too. States
%% set of the FSM is share the same store with links, which name is
%% '_states'. The key of a state stored in states set is different
%% from links. The key is a tuple type vector contains the vertex
%% name of 'from state' and the edge name as 'sign of
%% transition'. State sets are inherited by default which means a key
%% tuple with only edge name can match any 'from state'.
%% 
%% Binary type is not support by types and function
%% specifications. All binary type attribute names are commented and
%% binary string are replaced by tag() type currently.
%% -------------------------------------------------------------------
%% Common types exported for reuse.
-export_type([state/0,
              process/0,
              from/0,
              path/0,
              tag/0,
              message/0,
              reply/0]).
%% State attributes.
-type state() :: #{
             '_entry' => entry(),
             '_react' => react(),
             '_exit' => exit(),
             '_actions' => actions(),
             '_pid' => pid(),
             '_parent' => pid(),
             '_surname' => tag(), % Attribute name in the parent state.
             '_reason' => reason(),
             '_status' => status(),
             '_subscribers' => map(),
             '_entry_time' => pos_integer(),
             '_exit_time' => pos_integer(),
             '_input' => term(),
             '_output' => term(),
             '_states' => states(),
             '_monitors' => monitors(),
             %% Flag of FSM.
             '_state' => active_key() | {'state', state_d()} | tag(),
             %% Flag of state in FSM.
             '_of_fsm' => 'true' | 'false', % default false.
             %% Wether to submit report to parent process.
             '_report' => 'true' | 'false', % default true.
%             <<"_report">> => <<"all">> | <<"default">> | list(),
             '_sign' => sign(),
             '_step' => non_neg_integer(),
             '_traces' => active_key() | map(),
             '_retry_count' => non_neg_integer(),
             '_pending_queue' => list()
%% Runtime data with binary type names.
%             <<"_max_pending_size">> => limit(),
%             <<"_aftermath">> => aftermath(),
%             <<"_recovery">> => recovery(),
%             <<"_link_recovery">> => <<"restart">>,
%             <<"_name">> => tag(),
%             <<"_state">> => state() | [Output, Sign],
%             <<"_max_step">> => limit(),
%             <<"_preload">> => list(),
%             <<"_timeout">> => timeout(), 
%             <<"_recovery">> => recovery(),
%             <<"_max_traces">> => limit(),
%             <<"_max_retry">> => limit(),
%             <<"_retry_interval">> => limit(),
%             <<"_hibernate">> => timeout()  % mandatory, default: infinity
            } |         % Header part, common attributes.
                 map(). % Body part, data payload of the actor.

%% Definition of gen_server server.
-type server_name() :: {local, atom()} |
                       {global, atom()} |
                       {via, atom(), term()}.
-type process() :: pid() | (LocalName :: atom()).
-type from() :: {To :: process(), Tag :: identifier()}.
-type start_ret() ::  {'ok', pid()} | 'ignore' | {'error', term()}.
-type start_opt() :: {'timeout', Time :: timeout()} |
                     {'spawn_opt', [proc_lib:spawn_option()]}.
-type monitor() :: {tag(), recovery()}.
-type monitors() :: #{identifier() => monitor()}.
-type active_key() :: {'link', process(), identifier()} |
                      {'function', function()}.
-type states_map() :: #{vector() => state()}.
-type links_map() :: #{Key :: tag() => refers()}.
%% If vector() was list, links_map contains string type of attribute
%% name is conflict with states_map().
-type states() :: active_key() | states_map() | links_map().
%% Reference of another actor's attribute.
-type refer() :: {'ref', Registry :: (process() | tag()), Id :: tag()}.
%% State data with overrided actions and recovery.
%% Todo: raw data cannot support tuple type.
-type state_d() :: state() | {state(), actions(), recovery()}.
-type refers() :: refer() | state_d() | {data, term()} | term().
%% Common type for key, id, name or tag.
-type tag() :: atom() | string() | binary() | integer().
-type path() :: [process() | tag()].
-type request() :: {'xlx', from(), Command :: term()} |
                   {'xlx', from(), Path :: list(), Command :: term()}.
-type notification() :: {'xlx', Notification :: term()}.
-type message() :: request() | notification() | term().
-type code() :: 'ok' | 'error' | 'noreply' | 'stopped' |
                'data' | 'process' | 'function' | tag().  % etc.
-type result() :: {code(), state()} |
                  {code(), term(), state()} |
                  {code(), Stop :: reason(), Reply :: term(), state()}.
-type output() :: {code(), Result :: term()}.
-type reply() :: output() | code() | term().
-type status() :: 'running' |
                  'stop' |
                  'halt' |
                  'exception' |
                  'failover' |
                  tag().
-type reason() :: 'normal' | 'shutdown' | {'shutdown', term()} | term().
%% In state, '_sign' may be relative as tag() type or absolute as
%% vector() type.
-type sign() :: vector() | tag().
%% entry action should be compatible with gen_server:init/1.
%% Notice: 'ignore' is not support.
-type entry_return() :: {'ok', state()} |
                        {'ok', state(), timeout()} |
                        {'ok', state(), 'hibernate'} |
                        {'stop', reason()} |
                        {'stop', reason(), state()}.
-type entry() :: fun((state()) -> entry_return()).
-type exit() :: fun((state()) -> state()).
-type react() :: fun((message() | term(), state()) -> result()).
-type actions() :: 'state' | module() | binary() | state_actions().
-type state_actions() :: #{'_entry' => entry(),
                           '_exit' => exit(),
                           '_react' => react()}.
%% There is a potential recovery option 'undefined' as default
%% recovery mode, crashed active attribute may be recovered by next
%% 'touch'. Actually tag() is <<"restart">> or <<"rollback">>.
-type recovery() :: integer() | vector() | tag().
%% Vector is set of dimentions. Raw data does not support tuple type,
%% and list type is used. But string type in Erlang is list type
%% too. Flat states map may confused by list type vector. So vectors
%% in state map is tuple type.
-type vector() :: {GlobalEdge :: tag()} |
                  {Vetex :: tag(), Edge :: tag()}.
%% There is not atomic or string type in raw data. Such strings are
%% all binary type as <<"AtomOrString">>.
%% -type limit() :: non_neg_integer() | 'infinity' | tag().  % <<"infinity">>.
%% Quit or keep running after FSM stop. Default value is <<"quit">>.
%% -type aftermath() :: <<"quit">> | <<"halt">>.

%% --------------------------------------------------------------------
%% Message format:
%% 
%% - normal: {xlx, From, Command} -> reply().
%% - relay with path: {xlx, From, Path, Command} -> reply().
%% - touch & activate command: {xlx, from(), xl_touch} ->
%%     {process, Pid} | {state, state_d()} | {data, Data} | {error, Error}.
%% - wakeup event: xl_wakeup
%% - hibernate command: xl_hibernate
%% - stop command: xl_stop | {xl_stop, reason()}
%% - state enter event: xl_enter.
%% - state transition event: {xl_leave, Pid, state() | {Output, vector()}},
%%   ACK: {ok, xl_leave_ack} reply to from Pid.
%% - post data package for trace log:
%%           {xl_trace, {log, Trace} | {backtrack, Back}}
%% - failover retry event: {xl_retry, recovery()} |  % for FSM
%%         {xl_retry, Key, <<"restart">>}  % for active attribute.
%% - command to notify all subscribers: {xl_notify, Notification}.
%%
%% Predefined signs:
%% Generally, all internal signs are atom type.
%% - exceed_max_steps: run out of steps limit.  fall through exception.
%% - exception: generic error.
%% - stop: machine stop and process exit.
%% - halt: machine stop but process is still alive.
%% - abort: FSM is not finished, exit by exception or command.
%% --------------------------------------------------------------------

%% --------------------------------------------------------------------
%% gen_server callbacks.
%% --------------------------------------------------------------------
%% Notice: process flag of state is trap_exit, should handle 'EXIT'
%% signal by itself.
-spec init(state()) -> {'ok', state()} | {'stop', reason()}.
init(State) ->
    process_flag(trap_exit, true),
    init_state(State).

%% To be compatible with gen_server, handle_call or handl_cast
%% callback, decode messages to xl_sop format: {'$gen_call', From,
%% Command} => {xlx, From, [], Command}, {'$gen_cast', Notification}
%% => Notification.
%%
%% Handling sync call messages.
-spec handle_call(term(), from(), state()) ->
                         {'reply', reply(), state()} |
                         {'noreply', state()} |
                         {stop, reason(), reply(), state()} |
                         {stop, reason(), state()}.
handle_call(Request, From, State) ->
    handle_info({xlx, From, [], Request}, State).

%% Handling async cast messages.
-spec handle_cast(Msg :: term(), state()) ->
                         {'noreply', state()} |
                         {stop, reason(), state()}.
handle_cast(Message, State) ->
    handle_info(Message, State).

%% Handling normal messages.
-spec handle_info(Info :: term(), state()) ->
                         {'noreply', state()} |
                         {'stop', reason(), state()}.
handle_info(Message, State) ->
    Info = normalize_msg(Message),
    Res = handle(Info, State),
    Res1 = handle_1(Info, Res),
    Res2 = handle_2(Info, Res1),
    handle_3(Res2).

%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored. State action exit is
%% called to destruct and to output result. Processes and monitores of
%% active attributes and monitors are released by otp process.
%% gen_server:terminate call try_terminate, get {ok, FinalState}
%% result.
-spec terminate(reason(), state()) -> no_return().
terminate(Reason, State) ->
    S = stop_fsm(State, Reason),
    S1 = S#{'_exit_time' => erlang:system_time()},
    S2 = try_exit(S1#{'_reason' => Reason}),
    S3 = ensure_sign(S2),
    goodbye1(S3#{'_status' := stop}).

%% Convert process state when code is changed
-spec code_change(OldVsn :: term(), state(), Extra :: term()) ->
                         {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% --------------------------------------------------------------------
%% Starts the server.
%% 
%% start/3 or start_link/3 spawn actor with local or global name. If
%% server_name is 'undefined', the functions same as start/2 or
%% start_link/2.
%% 
%% Value of <<"_timeout">> attribute will affect the entire life
%% cycle of this actor, include init function and request response.
%% --------------------------------------------------------------------
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

%% If option {timeout,Time} is present, the gen_server process is
%% allowed to spend $Time milliseconds initializing or it is
%% terminated and the start function returns {error,timeout}.
merge_options(Options, #{<<"_timeout">> := Timeout}) ->
    Options ++ [{timeout, Timeout}];  % Quick and dirty, but it works.
merge_options(Options, _) ->
    Options.

%% --------------------------------------------------------------------
%% Create state object from module and given parameters.  If there is
%% an exported function create/1 in the module, create new state
%% object by it instead.
%%
%% Parameter Data is static data of a state that may be map or list
%% type. And the list type Data will convert to map type.
%%
%% Notice:
%% - fun Module:exit/1 conflict with auto-exported fun exit/1.
%% - Data may contain its own actions, but they will be overrided
%%   by Module.
%% --------------------------------------------------------------------
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

%% --------------------------------------------------------------------
%% API for invocation by message wrapping.
%% --------------------------------------------------------------------
%% Same as gen_server:reply().
-spec reply(from(), Reply :: term()) -> 'ok'.
reply({To, Tag}, Reply) ->
    catch To ! {Tag, Reply},
    ok;
reply(undefined, _) ->
    ok.

%% Same as gen_server:call().
-spec call(process() | path(), Request :: term()) -> reply().
call([Process | Path], Command) ->
    call(Process, Path, Command, infinity);
call(Process, Command) ->
    call(Process, [], Command, infinity).

-spec call(process() | path(), Request :: term(), timeout()) -> reply().
call([Process | Path], Command, Timeout) ->
    call(Process, Path, Command, Timeout);
call(Process, Command, Timeout) ->
    call(Process, [], Command, Timeout).

-spec call(process(), path(), Request :: term(), timeout()) -> reply().
call(Process, Path, Command, Timeout) ->
    Tag = make_ref(),
    Process ! {xlx, {self(), Tag}, Path, Command},
    receive
        {Tag, Result} ->
            Result
    after
        Timeout ->
            {error, timeout}
    end.

scall(Process, Command, #{<<"_timeout">> := Timeout}) ->
    call(Process, [], Command, Timeout);
scall(Process, Command, _) ->
    call(Process, [], Command, ?DFL_TIMEOUT).

-spec cast(process() | path(), Message :: term()) -> 'ok'.
cast([Process | Path], Command) ->
    cast(Process, Path, Command);
cast(Process, Command) ->
    cast(Process, [], Command).

-spec cast(process(), path(), Message :: term()) -> 'ok'.
cast(Process, Path, Message) ->
    catch Process ! {xlx, undefined, Path, Message},
    ok.

%% stop is almost same effect as gen_server:stop().
-spec stop(process()) -> output().
stop(Process) ->
    stop(Process, normal, ?DFL_TIMEOUT).

-spec stop(process(), reason()) -> output().
stop(Process, Reason) ->
    stop(Process, Reason, ?DFL_TIMEOUT).

-spec stop(process(), reason(), timeout()) -> output().
stop(Process, normal, Timeout) ->
    stop_(Process, normal, Timeout);
stop(Process, shutdown, Timeout) ->
    stop_(Process, shutdown, Timeout);
stop(Process, {shutdown, _} = Reason, Timeout) ->
    stop_(Process, Reason, Timeout);
stop(Process, Reason, Timeout) ->
    stop_(Process, {shutdown, Reason}, Timeout).

stop_(Process, Reason, Timeout) ->
    Mref = monitor(process, Process),
    Process ! {xl_stop, Reason},
    receive
        {xl_leave, From, Result} ->
            catch From ! {ok, xl_leave_ack},
            demonitor(Mref, [flush]),
            {ok, Result};
        {'DOWN', Mref, _, _, Result} ->
            {stopped, Result}
    after
        Timeout ->
            demonitor(Mref, [flush]),
            {error, timeout}
    end.

-spec subscribe(process() | path()) -> {'ok', reference()}.
subscribe(Process) ->
    subscribe(Process, self()).

-spec subscribe(process() | path(), process()) -> {'ok', reference()}.
subscribe(Process, Pid) ->
    call(Process, {subscribe, Pid}).

-spec unsubscribe(process() | path(), reference()) -> 'ok'.
unsubscribe(Process, Ref) ->
    catch Process ! {xl_unsubscribe, Ref},
    ok.

%% The function generate notification send to all subscribers.
-spec notify(process(), Info :: term()) -> 'ok'.
notify(Process, Info) ->
    catch Process ! {xl_notify, Info},
    ok.

%% --------------------------------------------------------------------
%% API for internal data access.
%% --------------------------------------------------------------------
%% Request of 'get' is default to fetch all data (without internal
%% attributes).
-spec get(tag(), state()) -> {'ok', term(), state()} |
                             {'error', term(), state()}.
get(Key, State) ->
    case activate(Key, State) of
        {data, Data, State1} ->
            {ok, Data, State1};
        {process, Pid, State1} ->
            {Sign, Result} = scall(Pid, get, State1),
            {Sign, Result, State1};
        {function, Func, State1} ->
            Func({get, Key}, State1);
        Error ->
            Error
    end.

%% Raw data in state attributes map.
-spec get_raw(tag(), state()) -> {'ok', term(), state()} |
                                 {'error', 'undefined', state()}.
get_raw(Key, State) ->
    case maps:find(Key, State) of
        {ok, Value} ->
            {ok, Value, State};
        error ->
            {error, undefined, State}
    end.

%% Pick all exportable attributes, exclude active attributes or
%% attributes with atom type name.
-spec get_all(state()) -> {'ok', map(), state()}.
get_all(State) ->
    Pred = fun(_, {link, _, _}) ->
                   false;
              (_, {function, _}) ->
                   false;
              (Key, _) when is_atom(Key) ->
                   false;
              (Key, _) when is_tuple(Key) ->
                   false;
              (_, _) ->
                   true
           end,
    {ok, maps:filter(Pred, State), State}.

-spec put(tag(), Value :: term(), state()) -> {'ok', 'done', state()}.
put(Key, {process, Process}, State) ->
    S = unlink(Key, State, true),
    {process, _, S1} = attach(Key, Process, S),
    {ok, done, S1};
put(Key, {function, Func}, State) ->
    S = unlink(Key, State, true),
    {function, _, S1} = attach(Key, Func, S),
    {ok, done, S1};
put(Key, Value, State) ->
    S = unlink(Key, State, true),
    {ok, done, S#{Key => Value}}.


-spec delete(tag(), state()) -> {'ok', 'done', state()}.
delete(Key, State) ->
    delete(Key, State, true).

%% It is ugly, no word.
-spec delete(tag(), state(), boolean()) -> {'ok', 'done', state()}.
delete(Key, State, Stop) ->
    S = unlink(Key, State, Stop),
    {ok, done, maps:remove(Key, S)}.

unlink(Key, #{'_monitors' := M} = State, Stop) ->
    case maps:find(Key, State) of
        {ok, {link, Pid, Pid}} ->
            unlink(Pid),
            M1 = maps:remove(Pid, M),
            case Stop of
                true ->
                    catch Pid ! {xl_stop, shutdown};
                false ->
                    ok
            end,
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

%% --------------------------------------------------------------------
%% Process messages with path, when react function does not handle it.
%%
%% Hierarchical data in a state data map can only support
%% get/put/delete operations.
%%
%% relay/3 is sync operation that wait for expected reply. Instant
%% return version of relay is relay/4 with first parameter
%% 'undefined': relay(undefined, Path, Notification, State). Compare
%% with similar functions call and cast, function relay is called
%% inside actor process while call/cast is called outside the process.
%% --------------------------------------------------------------------
-spec relay(path(), Command :: term(), state()) -> result().
relay(Path, Command, State) ->
    Tag = make_ref(),
    case relay({self(), Tag}, Path, Command, State) of
        {ok, S} ->
            Timeout = maps:get(<<"_timeout">>, S, ?DFL_TIMEOUT),
            receive
                {Tag, {Code, Result}} ->
                    {Code, Result, S}
            after
                Timeout ->
                    {error, timeout, S}
            end;
        Done ->
            Done
    end.

-spec relay(from(), path(), Command :: term(), state()) -> result().
relay(_, [Key], get, State) ->
    recall({get, Key}, State);
relay(_, [Key], {put, Value}, State) ->
    recall({put, Key, Value}, State);
relay(_, [Key], delete, State) ->
    recall({delete, Key}, State);
relay(From, [Key | Path], Command, State) ->
    case activate(Key, State) of
        {process, Pid, S} ->
            Pid ! {xlx, From, Path, Command},
            {ok, S};
        {function, Func, S} ->
            Func({xlx, From, Path, Command}, S);
        {data, Package, S} ->  % Path is not empty.
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
    end.

%% --------------------------------------------------------------------
%% gen_server callbacks. Initializes the server with state action
%% entry. The order of initialization is: [initialize runtime
%% attributes] -> [call '_entry' action] -> [preload depended actors]
%% -> [if it is FSM, start it]. The '_entry' action may affect
%% follow-up steps. Callback init/1 is a synchronous operation, _entry
%% function must return as soon as possible. Time-costed operations
%% and waitting for parent must place in _react function when xl_enter
%% event raised.
%% --------------------------------------------------------------------
%% '_entry' action of state may be ignored if state is loaded from
%% suspended state (by '_status' attribute) because it is already
%% initialized.
init_state(#{'_status' := running} = State) ->
    self() ! xl_wakeup,  % notify '_react' action but ignore '_entry'.
    {ok, State#{'_pid' => self()}};
%% Initialize must-have attributes to the state.
init_state(State) ->
    self() ! xl_enter,
    Monitors = maps:get('_monitors', State, #{}),
    %% '_states' should be initilized by loader.
    State1 = State#{'_entry_time' => erlang:system_time(),
                    '_monitors' => Monitors,
                    '_pid' => self(),
                    '_status' => running},
    Res = enter(State1),
    prepare(Res, true).

prepare({stop, _} = Stop, _) ->
    Stop;
prepare({stop, Reason, _}, _) ->
    {stop, Reason};
prepare(Ok, false) ->
    Ok;
prepare({ok, State}, true) ->
    %% Active '_states' and '_traces' at first.
    {_, _, S} = activate('_states', State),
    {_, _, S1} = activate('_traces', S),
    %% load dependent links.
    S2 = preload(S1),
    %% load introducer of FSM.
    {_, _, S3} = activate('_state', S2),
    %% try to initialize FSM if it is.
    prepare(init_fsm(S3), false);
prepare({ok, State, Option}, true) ->
    case prepare({ok, State}, true) of
        {ok, NewState} ->
            {ok, NewState, Option};
        Stop ->
            Stop
    end.

%% Return of '_entry' function is compatible with
%% gen_server:init/1. '_exit' action will not be called if init
%% failed.
enter(#{'_entry' := Entry} = State) ->
    case Entry(State) of
        {stop, Reason, _S} ->
            %% gen_server handle the exit exception.
            {stop, Reason};
        Result ->
            Result
    end;
enter(State) ->
    {ok, State}.

%% fail-fast of pre-load actors.
preload(#{<<"_preload">> := Preload} = State) ->
    Activate = fun(Key, S) ->
                       case activate(Key, S) of
                           {error, Error, _S1} ->
                               error({preload_failure, Error});
                           {_, _, S1} ->
                               S1
                       end
               end,
    lists:foldl(Activate, State, Preload);
preload(State) ->
    State.

%% --------------------------------------------------------------------
%% Initialize and launch FSM.
%% 
%% Flag of FSM is existence of the attribute named _state.  Specially,
%% '_states' data should be initialized by loader.  Initialization
%% operation is for data load from persistent store.  External links
%% can be used as state processes, but it is not recommended to do
%% so. But intializer of the FSM may pre-spawn a process as
%% starter. Here is a simple initializing routine for raw data of
%% <<"_state">>. Assert <<"_state">> is map of #{<<"input">> := Input,
%% <<"sign">> := Sign}, where Sign must be present and be list format.
%% Note that the raw data does not support the tuple type. Raw data
%% vector in list type may convert to tuple type at first.
%% --------------------------------------------------------------------
%% Pre-spawned state as an introducer.
init_fsm(#{'_state' := {link, _, _}} = Fsm) ->
    {ok, Fsm};
%% Initialized by another routine. InitializedState is form of map()
%% or {Input, Sign} that is compatible with the second paramenter of
%% fun transfer/2.
init_fsm(#{'_state' := InitializedState} = Fsm) ->
    transfer(Fsm, InitializedState);
%% Be not initialized, accept only two parameters of <<"_state">> map.
init_fsm(#{<<"_state">> := Map} = Fsm) ->
    Input = maps:get(<<"input">>, Map, undefined),
    Sign = maps:get(<<"sign">>, Map),
    Next = {Input, list_to_tuple(Sign)},
    init_fsm(Fsm#{'_state' => Next});
%% It is not FSM.
init_fsm(State) ->
    {ok, State}.

%% --------------------------------------------------------------------
%% States is map or active attribute to keep state data, which is not
%% only for FSMs but also for links. For FSMs, key of the state map
%% must be tuple type, which is form of {Vertex, Edge} as a vector of
%% graph. To simplify states arrangement, single element Vector:{Edge}
%% is global vector can match any Vertex.
%%
%% There are rules for states set:
%% - Sign must not be tuple type.
%% - If {FromState, ToSign} is not found, then try {ToSign}.
%% - If it is not found at last, throw excepion rather than return error.
%% --------------------------------------------------------------------
next_state(Vector, States, Fsm) when not is_tuple(Vector) ->
    next_state({Vector}, States, Fsm);
next_state(Vector, {function, States}, Fsm) ->
    {data, State, Fsm1} = States(Vector, Fsm),
    {State, Fsm1};
next_state(Vector, {link, States, _}, Fsm) ->
    %% Internal data structure of States actor is same as States map.
    %% In special case, touch operation may make a cache of #{{From,
    %% To} => state()} in States.
    case scall(States, {xl_touch, Vector}, Fsm) of
        {data, Data} ->  % Do not accept other types, only data.
            {Data, Fsm};
        _ ->
            error({get_state, badarg})
    end;
next_state(Vector, States, Fsm) ->
    {locate(Vector, States), Fsm}.

%% As a vector, Vector parameter may contain many dimensions, 1, 2 or
%% larger than 2. Current version only support 2 dimensions.
locate(Vector, States) ->
    case maps:find(Vector, States) of
        {ok, State} ->
            State;
        error ->
            {_, Global} = Vector,  % Fall through to global.
            locate({Global}, States)
    end.

%% --------------------------------------------------------------------
%% Handling messages by relay to react function and default
%% procedure. 
%% --------------------------------------------------------------------
%% Empty path, the last hop.
normalize_msg({xlx, From, Command}) ->
    {xlx, From, [], Command};
%% Sugar for stop.
normalize_msg(xl_stop) ->
    {xl_stop, normal};
%% gen_server timeout as hibernate command.
normalize_msg(timeout) ->
    xl_hibernate;
normalize_msg(Msg) ->
    Msg.

%% Notice: if there is no '_react' action or '_react' action do not
%% process this message, should return {ok, unhandled, State} to
%% handle it by default routine. Otherwise, the message will be
%% ignored.
handle(Info, #{'_react' := React} = State) ->
    React(Info, State);
handle(_Info, State) ->
    {ok, unhandled, State}.


%% Process unhandled message by default handlers.
handle_1(Info, {ok, unhandled, State}) ->
    default_react(Info, State);
handle_1(_Info, Res) ->
    Res.

%% Stop or hibernate may be canceled by state react with code error.
handle_2({xl_stop, Reason}, {ok, State}) ->
    {stop, Reason, State};
%% Cut off the reply because of no receiver.
handle_2({xl_stop, Reason}, {ok, _, State}) ->
    {stop, Reason, State};
%% Hibernate command, not guarantee.
handle_2(xl_hibernate, {ok, State}) ->
    {noreply, State, hibernate};
handle_2(xl_hibernate, {ok, _, State}) ->
    {noreply, State, hibernate};
%% Reply is not here when code is noreply or stop. 'noreply' is
%% explicit code for later response.
handle_2({xlx, _From, _, _}, {noreply, State}) ->
    {noreply, State};
%% 'stop' without reply means response is sent already or later.
handle_2({xlx, _From, _, _}, {stop, Reason, S}) ->
    {stop, Reason, S};
%% Reply special message other than gen_server.  Four elements of
%% tuple is stop signal. Code is not always 'stop'.
handle_2({xlx, From, _, _}, {Code, Reason, Reply, S}) ->
    reply(From, {Code, Reply}),
    {stop, Reason, S};
%% Generic reply.
handle_2({xlx, From, _, _}, {Code, Reply, S}) ->
    reply(From, {Code, Reply}),
    {noreply, S};
%% Sugar for stop result.
handle_2(_, {stop, S}) ->
    Reason = maps:get('_reason', S, normal),
    {stop, Reason, S};
handle_2(_, {stop, _, _} = Stop) ->
    Stop;
%% Message is handled by '_react' or default handler.
handle_2(_, {_, S}) ->
    {noreply, S};
handle_2(_, {_, _, S}) ->
    {noreply, S};
%% Assert it is stop result, even if it is not.
handle_2(_, Stop) ->  % {stop, _, _, _}
    Stop.

%% Only for OTP hibernate.
handle_3({noreply, #{<<"_hibernate">> := Timeout} = S}) ->
    {noreply, S, Timeout};  % add hibernate support.
handle_3(Result) ->
    Result.

%% --------------------------------------------------------------------
%% Default handlers for messages are 'unhandled'
%%
%% Special cases for FSM type actor:
%% - Request with path such as {xlx, From, Path, Command} do not relay
%%   to state.
%% - xl_leave, xl_retry, 'DOWN' and 'EXIT' message do not relay to state.
%% - Request with path [<<".">>] is explicit request do not relay to state.
%% - In failover status, message may be queued in _pending_queue, that
%%   may be relayed when FSM be recovered.
%% --------------------------------------------------------------------
%% Do not spread xl_enter and xl_wakeup messages to children.
default_react(xl_enter, State) ->
    {noreply, State};
default_react(xl_wakeup, State) ->
    {noreply, State};
%% 'stop' message is high priority.
default_react({xl_stop, Reason}, State) ->
    {stop, Reason, State};
%% External links of active attributes and subscribers are all
%% processes monitored by the actor. All of them may raise 'DOWN'
%% events at ending.
default_react({'DOWN', M, _, _, _} = Down, State) ->
    handle_halt(M, Down, State);
%% Since all actor process flag is trap_exit, all linked processes may
%% generate 'EXIT' message on quitting. Strategy of actor to handle
%% unknown 'EXIT' is to ignore it.
default_react({'EXIT', Pid, _} = Exit, State) ->
    handle_halt(Pid, Exit, State);
%% Delay restart for failed active attribute.
default_react({xl_retry, Key, <<"restart">>}, State) ->
    {_, _, S} = activate(Key, State),
    {noreply, S};
%% Delay recovery for FSM.
default_react({xl_retry, Recovery}, #{'_status' := failover} = Fsm) ->
    retry(Fsm, Recovery);
%% Special message: For FSM type actor, when path is ".", call FSM
%% actor directly.
default_react({xlx, _From, [<<".">>], Command}, State) ->
    recall(Command, State);
%% State transition message. Output :: state() | {term(), vector()}.
default_react({xl_leave, From, Output}, #{'_state' := _} = Fsm) ->
    catch From ! {ok, xl_leave_ack},
    transfer(Fsm, Output);
%% Drop transition message if this actor is not FSM.
default_react({xl_leave, From, _}, State) ->
    catch From ! {ok, xl_leave_ack},
    {noreply, State};
%% FSM type actor relay messages without path to state process.
default_react({xlx, _From, [], _} = Request,
              #{'_state' := {link, _, _}} = Fsm) ->
    recast(Request, Fsm);
default_react({xlx, _, [], _} = Request,
              #{'_status' := failover} = Fsm) ->
    recast(Request, Fsm);
default_react({xlx, _From, [], Command}, State) ->
    recall(Command, State);
default_react({xlx, From, Path, Command}, State) ->
    relay(From, Path, Command, State);
%% ------ Messages for actor or FSM ------
default_react(Info, State) ->
    recast(Info, State).

handle_halt(Id, Throw, #{'_monitors' := M} = State) ->
    case maps:find(Id, M) of
        %% Self-heal for FSM.
        {ok, {'_state', Recovery}} ->
            %% Throw is output, excepption is sign. If there is a
            %% state for {exception} in '_states', 'Recovery' will be
            %% ignored.
            transfer(State, {Throw, {exception}}, Recovery);
        %% Self-heal for active attribute, it is just reload at a
        %% while. Compare with default recovery, it is reload on next
        %% demand.
        {ok, {Key, <<"restart">>}} ->
            {ok, done, S} = delete(Key, State),
            Interval = maps:get(<<"_retry_interval">>, S, ?RETRY_INTERVAL),
            erlang:send_after(Interval, self(), {xl_retry, Key, <<"restart">>}),
            {ok, S};
        %% Just remove it and wait for next access to trigger recovery.
        {ok, {Key, undefined}} ->
            {ok, done, S} = delete(Key, State, false),
            {ok, S};
        %% Down message from subscriber or not, remove it.
        error when is_reference(Id) ->
            Subs = maps:get('_subscribers', State),
            Subs1 = maps:remove(Id, Subs),
            {ok, State#{'_subscribers' := Subs1}};
        %% Unknown message source, ignore it. It violate OTP design
        %% principles.
        error ->
            {ok, State}
    end.

%% Retrieve data, activate or peek the attribute, like 'touch' command
%% in bash shell.
recall({xl_touch, Key}, State) ->
    activate(Key, State);
%% Normal case data fetching.
recall({get, Key}, State) ->
    get(Key, State);
%% Raw data value of attribute.
recall({get, Key, raw}, State) ->
    get_raw(Key, State);
%% All exportable data, exclude internal attributes and active
%% attributes.
recall(get, State) ->
    get_all(State);  % 
%% Internal attributes names are atom type, cannot be changed
%% externally.
recall({put, Key, _}, State) when is_atom(Key) ->
    {error, forbidden, State};
recall({put, Key, Value}, State) ->
    put(Key, Value, State);
%% Purge data
recall({delete, Key}, State) when is_atom(Key) ->
    {error, forbidden, State};
recall({delete, Key}, State) ->
    delete(Key, State);
recall({subscribe, Pid}, State) ->
    Subs = maps:get('_subscribers', State, #{}),
    Mref = monitor(process, Pid),
    Subs1 = Subs#{Mref => Pid},
    {ok, Mref, State#{'_subscribers' => Subs1}};
%% Unsubscribe operation may be triggered by request or notification
%% with different message format: {xlx, From, Path, {unsubscribe,
%% Ref}} vs {xl_unsubscribe, Ref}.
recall({unsubscribe, Ref}, State) ->
    {ok, NewState} = recast({xl_unsubscribe, Ref}, State),
    {ok, done, NewState};
%% Interactive stop.
recall({xl_stop, Reason}, State) ->
    {ok, Reason, done, State};
recall(xl_stop, State) ->
    {ok, normal, done, State};
recall(_, State) ->
    {error, unknown, State}.

recast({xl_notify, Info}, #{'_subscribers' := Subs} = State) ->
    maps:fold(fun(M, P, A) ->
                      catch P ! {M, Info},
                      A
              end, 0, Subs),
    {ok, State};
recast({xl_unsubscribe, Ref}, #{'_subscribers' := Subs} = State) ->
    demonitor(Ref, [flush]),
    Subs1 = maps:remove(Ref, Subs),
    {ok, State#{'_subscribers' := Subs1}};
%% Failover status of FSM, cache the messages into pending queue.
%% Notice: if _max_pending_size is 0, do not cache message.
%% 
%% recast(Info, #{'_status' := failover,
%%                <<"_max_pending_size">> := Size} = Fsm) ->
recast(Info, #{'_status' := failover} = Fsm) ->
    Size = maps:get(<<"_max_pending_size">>, Fsm, infinity),
    Q = maps:get('_pending_queue', Fsm, []),
    Q1 = enqueue(Info, Q, Size),
    {noreply, Fsm#{'_pending_queue' => Q1}};
%% Relay all other messages to state process and return explicit noreply.
recast(Info, #{'_state' := {link, Pid, _}} = Fsm) ->
    Pid ! Info,
    {noreply, Fsm};
recast(_Info, State) ->
    {ok, State}.

%% --------------------------------------------------------------------
%% FSM state transition functions.
%%
%% xl_leave is a notification of format {xl_leave, Output}, where
%% Output may be tuple of {Output, Vector} or runtime state data.  If
%% FSM process crashed, the state data has no time to output, message
%% maybe {{'EXIT', Pid, Reason}, {exception}}. If state process would
%% not output all state data, it may select and customize the state
%% data map output.
transfer(Fsm, #{<<"_recovery">> := Recovery} = Output) ->
    transfer(Fsm, Output, Recovery);
transfer(Fsm, Output) ->
    transfer(Fsm, Output, undefined).

%% To support different recovery option for each state.
transfer(Fsm, Output, Recovery) ->
    notify(self(), {transition, Output}),
    {_, _, F1} = archive(Fsm, Output),
    case t1(F1, Output) of
        %% Halt the FSM but keep actor running for data access.
        {stop, #{<<"_aftermath">> := <<"halt">>} = F2} ->
            {ok, F2#{'_status' := halt}};
        {halt, F2} ->
            {ok, F2#{'_status' := halt}};
        %% Trigger termination routine.
        {stop, F2} ->
            {stop, normal, F2#{'_status' := stop}};
        %% Try to heal from exceptional state.
        {recover, F2} ->
            recover(F2, Recovery);
        %% '_output' is passed in next state as '_input'.
        {S, F2} ->      % S must be map().
            S1 = case maps:find('_output', F2) of
                     {ok, V} when V =/= undefined ->
                         S#{'_input' => V};
                     _ ->
                         S
                 end,
            %% Mark state in FSM and pass output as input.
            S2 = S1#{'_report' => true, '_of_fsm' => true},
            {process, Pid, F3} = activate('_state', S2, F2),
            F4 = F3#{'_status' := running},
            %% relay the cached messages in failover status.
            case maps:find('_pending_queue', F4) of
                {ok, Gap} ->
                    [Pid ! Message || Message <- Gap],  % Re-send.
                    {ok, F4#{'_pending_queue' := []}};
                error ->
                    {ok, F4}
            end
    end.

%% Max steps limited is a watch dog for unexpected loop. When max
%% steps is exceede, the full transition message is treated as output
%% includes sign in it. So healer may create new process with the
%% output as start state.
t1(#{'_step' := Step, <<"_max_steps">> := MaxSteps} = Fsm, Output)
  when Step >= MaxSteps ->
    t2(Fsm, Output, exceed_max_steps);
%% Exception: output is tuple type, in case of being simple or crashed.
t1(Fsm, {Vector}) ->
    t2(Fsm, undefined, Vector);
t1(Fsm, {Output, Vector}) ->
    t2(Fsm, Output, Vector);
%% Normal: output is state map type. Must-have attribute '_sign' of state is
%% directive for next state to transfer
t1(Fsm, State) ->
    Output = maps:get('_output', State, undefined),
    Vector = make_vector(State),
    t2(Fsm, Output, Vector).

%% Sign of 'exception' should be final state without next hop. But for
%% feature of customized exception handler, FSM may provide next state
%% for exception, which must be the final state.
t2(#{'_states' := States} = Fsm, Output, Vector) ->
    To = extract_sign(Vector),
    %% You can provide your own exception and stop state.
    Next = try
               next_state(Vector, States, Fsm)
           catch
               error: _BadKey when To =:= exception ->
                   {recover, Fsm};
               error: _BadKey when To =:= halt ->
                   {halt, Fsm};
               error: _BadKey when To =:= stop ->
                   {stop, Fsm};
               error: _BadKey when To =:= exceed_max_steps ->
                   {stop, Fsm};
               %% Be noted that steps of the exception state is not checked.
               error: _BadKey ->
                   {exception, Fsm}
           end,
    t3(Next, Output, Vector);
t2(Fsm, Output, Vector) ->
    t3({stop, Fsm}, Output, Vector).

%% Prepare for transition. Remove runtime '_state', increase step
%% counter, add output and sign attributes.
t3({exception, Fsm}, Output, _) ->
    t2(Fsm, Output, exception);
t3({Next, Fsm}, Output, Vector) ->
    Step = maps:get('_step', Fsm, 0),
    {ok, done, F} = delete('_state', Fsm, false),
    {Next, F#{'_step' => Step + 1, '_output' => Output, '_sign' => Vector}}.

%% Absolute sign as vector() type.
make_vector(#{'_sign' := Sign}) when is_tuple(Sign) ->
    Sign;
%% Relative sign with name.
make_vector(#{'_sign' := Sign, <<"_name">> := Name}) ->
    {Name, Sign};
%% Relative sign without name, treated as global sign.
make_vector(#{'_sign' := Sign}) ->
    {Sign};
%% Stop is default sign if it is not present.
make_vector(_) ->
    {stop}.

%% Extract sign of transition from vector.
extract_sign({Sign}) ->
    Sign;
extract_sign({_, Sign}) ->
    Sign;
extract_sign(Sign) ->
    Sign.

%% --------------------------------------------------------------------
%% Failover and recovery.
%% --------------------------------------------------------------------
%% '_retry_count' is lifetime count of all failover. The retry count
%% is cumulative unless the actor is reset. If <<"_max_retry">> is not
%% present, retry times is unlimited.
recover(#{'_retry_count' := Count, <<"_max_retry">> := Max} = Fsm, _)
  when Count >= Max ->
    {stop, {shutdown, too_many_retry}, Fsm#{'_status' := exception}};
%% Attention: if value of <<"_recovery">> is undefined, here is an
%% infinite loop!
recover(#{<<"_recovery">> := Recovery} = Fsm, undefined) ->
    recover(Fsm, Recovery);
recover(Fsm, undefined) ->
    {stop, {shutdown, incurable}, Fsm#{'_status' := exception}};
%% To slow down the failover progress, retry operation always
%% triggered by message. Even the "_retry_interval" is 0, retry
%% operation is still asynchronous.
recover(Fsm, Recovery) ->
    Interval = maps:get(<<"_retry_interval">>, Fsm, ?RETRY_INTERVAL),
    Count = maps:get('_retry_count', Fsm, 0),
    erlang:send_after(Interval, self(), {xl_retry, Recovery}),
    {ok, Fsm#{'_status' := failover, '_retry_count' => Count + 1}}.

%% retry() is callback function for xl_retry message. 
%%
%% "rollback" to the latest successful trace.
retry(Fsm, <<"rollback">>) ->
    {ok, Trace, Fsm1} = backtrack(<<"rollback">>, Fsm),
    transfer(Fsm1, Trace);
%% "restart" is special recovery mode, reset the FSM immediately.
retry(Fsm, <<"restart">>) ->
    prepare({ok, Fsm}, true);
retry(Fsm, Rollback) when Rollback < 0 ->
    {ok, Trace, Fsm1} = backtrack(Rollback, Fsm),
    transfer(Fsm1, Trace);
%% For recovery, 'Vector' should be absolute sign, which is tuple type.
retry(#{'_output' := Output} = Fsm, Vector) ->
    transfer(Fsm, {Output, Vector}).

%% If '_traces' is not present, archive do nothing. So trace log is
%% disable default, but <<"_max_traces">> default value is
%% MAX_TRACES. Trace is form of state() | {Output, Vector}.
archive(#{'_traces' := {function, Traces}} = Fsm, Trace) ->
    Traces({log, Trace}, Fsm);
archive(#{'_traces' := {link, Traces, _}} = Fsm, Trace) ->
    {Code, Result} = scall(Traces, {xl_trace, {log, Trace}}, Fsm),
    {Code, Result, Fsm};
archive(#{'_traces' := Traces} = Fsm, Trace)  ->
    Limit = maps:get(<<"_max_traces">>, Fsm, ?MAX_TRACES),
    Traces1 = enqueue(Trace, Traces, Limit),
    {ok, done, Fsm#{'_traces' => Traces1}};
archive(Fsm, _Trace) ->
    {error, undefined, Fsm}.

backtrack(Back, #{'_traces' := {function, Traces}} = Fsm) ->
    Traces({backtrack, Back}, Fsm);
backtrack(Back, #{'_traces' := {link, Traces, _}} = Fsm) ->
    {Code, Result} = scall(Traces, {xl_trace, {backtrack, Back}}, Fsm),
    {Code, Result, Fsm};
backtrack(<<"rollback">>, #{'_traces' := Traces} = Fsm)  ->
    {Code, Result} = rollback(Traces),
    {Code, Result, Fsm};    
backtrack(Back, #{'_traces' := Traces} = Fsm)  ->
    {ok, lists:nth(-Back, Traces), Fsm}.

rollback([]) ->
    {error, incurable};
rollback([{_, exception} | Rest]) ->
    rollback(Rest);
rollback([{_, {exception}} | Rest]) ->
    rollback(Rest);
rollback([#{'_sign' := {exception}} | Rest]) ->
    rollback(Rest);
rollback([#{'_sign' := exception} | Rest]) ->
    rollback(Rest);
rollback([Health | _]) ->
    {ok, Health}.

enqueue(_Item, _Queue, 0) ->
    [];
enqueue(Item, Queue, infinity) ->
    [Item | Queue];
enqueue(Item, Queue, Limit) ->
    lists:sublist([Item | Queue], Limit).

%% --------------------------------------------------------------------
%% Terminating and submit final report.
%% --------------------------------------------------------------------
try_exit(#{'_exit' := Exit} = State) ->
    Exit(State);
try_exit(State) ->
    State.

%% Ensure sign is present.
ensure_sign(#{'_sign' := _} = State) ->
    State;
ensure_sign(#{'_status' := exception} = State) ->
    State#{'_sign' => exception};
ensure_sign(#{'_reason' := normal} = State) ->
    State#{'_sign' => stop};
ensure_sign(#{'_reason' := shutdown} = State) ->
    State#{'_sign' => stop};
ensure_sign(#{'_reason' := {shutdown, _}} = State) ->
    State#{'_sign' => stop};
ensure_sign(State) ->
    State#{'_sign' => exception}.

%% If FSM is not stopped normally, sign of the FSM is abort. The FSM
%% can then be reloaded to continue running. In such case, '_output'
%% of the FSM is previous result because of current state may have no
%% time to yield output.
stop_fsm(#{'_state' := {link, Pid, _}} = Fsm, Reason) ->
    Timeout = maps:get(<<"_timeout">>, Fsm, ?DFL_TIMEOUT),
    case stop(Pid, Reason, Timeout) of
        {ok, Output} ->
            Fsm#{'_state' := Output,
                 '_sign' => abort};
        {stopped, Result} ->
            Fsm#{'_state' := {Result, {exception}},
                 '_sign' => exception};
        {error, Error} ->
            Fsm#{'_state' := {Error, exception},
                 '_sign' => exception}
    end;
stop_fsm(Fsm, _) ->
    Fsm.

%% State transferring, yield and notifications.
%% Goodbye, active attributes!
goodbye1(#{'_monitors' := M} = State) ->
    maps:fold(fun(Pid, _, _) when is_pid(Pid) ->
                      catch Pid ! {xl_stop, normal},
                      ok;
                 (Mref, _, _) ->
                      catch demonitor(Mref),
                      ok
              end, ok, M),
    goodbye2(maps:remove('_monitors', State));
goodbye1(State) ->
    goodbye2(State).

%% Goodbye, subscribers! And submit leave report.
goodbye2(#{'_subscribers' := Subs} = State) ->
    Detail = maps:get(<<"_report">>, State, <<"default">>),
    Report = make_report(Detail, State),
    Info = {exit, Report},
    %% Notify and remove all subscribers.
    maps:fold(fun(Mref, Pid, _) ->
                      catch Pid ! {Mref, Info},
                      demonitor(Mref),
                      ok
              end, 0, Subs),
    S = maps:remove('_subscribers', State),
    goodbye3(S, Report);
goodbye2(State) ->
    goodbye3(State, undefined).

%% Goodbye supervisor! And submit leave report on-demanded.
goodbye3(#{'_parent' := Supervisor, '_report' := true} = State, Report) ->
    case is_process_alive(Supervisor) of
        true ->
            report(Supervisor, Report, State);
        false ->
            State
    end;
goodbye3(State, _) ->
    State.

%% For FSM, relay messages as potential yield. FSM state actions
%% should not send xl_leave message. If it have to send customized
%% xl_leave message, please set '_report' flag to false in state
%% attribute.
report(Supervisor, undefined, State) ->
    Detail = maps:get(<<"_report">>, State, <<"default">>),
    Report = make_report(Detail, State),
    report(Supervisor, Report, State);
report(Supervisor, Report, #{'_of_fsm' := true} = State) ->
    Supervisor ! {xl_leave, self(), Report},
    flush_and_relay(Supervisor),
    State;
report(Supervisor, Report, State) ->
    Supervisor ! {xl_leave, undefined, Report},
    State.

%% Selective report.
make_report(false, _) ->
    #{};
make_report([], _) ->
    #{};
make_report(<<"all">>, State) ->
    State;
make_report(<<"default">>, State) ->
    make_report([<<"_name">>, '_sign', '_output', <<"_recovery">>], State);
%% Selections is a list of attributes to yield.
make_report(Selections, State) ->
    maps:with(Selections, State).

%% flush system messages and reply application messages.
flush_and_relay(Pid) ->
    flush_and_relay(Pid, ?DFL_TIMEOUT).

flush_and_relay(Pid, Timeout) ->
    receive
        {ok, xl_leave_ack} ->
            flush_and_relay(Pid, 0);
        {'DOWN', _, _, _, _} ->
            flush_and_relay(Pid);
        {'EXIT', _, _} ->
            flush_and_relay(Pid);
        Message ->
            Pid ! Message,
            flush_and_relay(Pid)
    after Timeout ->
            true
    end.

%% --------------------------------------------------------------------
%% Helper functions for active attribute access.
%% --------------------------------------------------------------------
%% Data types of attributes:
%% {link, pid(), identifier()} |
%%   {state, {state(), actions()}} | {state, state()} | Value :: term().
%% when actions() :: state | module() | Module :: binary() | Actions :: map().
%% -spec activate(tag(), state()) -> {process, pid(), state()} |
%%                                   {function, fun(), state()} |
%%                                   {data, term(), state()} |
%%                                   {error, term(), state()}.
activate(Key, State) ->
    case maps:find(Key, State) of
        {ok, {link, Pid, _}} ->
            {process, Pid, State};
        {ok, {function, Func}} ->
            {function, Func, State};
        {ok, {state, S}} ->
            activate(Key, S, State);
        {ok, Value} ->
            {data, Value, State};
        error ->  % not found, try to activate data in '_states'.
            attach(Key, State)
    end.

activate(Key, {S, Actions}, State) ->
    activate(Actions, Key, S, State);
activate(Key, Value, State) ->
    Actions = maps:get('_actions', Value, state),
    activate(Actions, Key, Value, State).

%% Intermediate function to bind behaviors with state.
activate(state, Key, Value, State) ->
    activate_(Key, Value, State);
activate(Module, Key, Value, State) when is_atom(Module) ->
    Value1 = create(Module, Value),
    activate_(Key, Value1, State);
activate(Module, Key, Value, State) when is_binary(Module) ->
    Module1 = binary_to_existing_atom(Module, utf8),
    activate(Module1, Key, Value, State);
%% Actions is map type with state behaviors: #{'_entry', '_react', '_exit'}.
activate(Actions, Key, Value, State) when is_map(Actions) ->
    Value1 = maps:merge(Value, Actions),
    activate_(Key, Value1, State);
activate(_Unknown, _Key, _Value, State) ->    
    {error, unknown, State}.

%% Value must be map type. Spawn state machine and link it as active
%% attribute.
%% 
%% Todo: Every state may have own recovery settings. Recovery may be
%% the initial state data for fast rollback.
activate_(Key, Value, #{'_monitors' := M} = State) ->
    Start = Value#{'_parent' => self(), '_surname' => Key},
    {ok, Pid} = start_link(Start),
    Recovery = maps:get(<<"_recovery">>, Start, undefined),
    Monitors = M#{Pid => {Key, Recovery}},
    {process, Pid, State#{Key => {link, Pid, Pid}, '_monitors' := Monitors}}.

%% Try to retrieve data or external actor, and attach to attribute of
%% current actor.  Reovery :: restart | undeinfed.
attach(Key, #{'_states' := Links} = State) ->
    case fetch_link(Key, Links, State) of
        %% external actor.
        {process, Pid, S} ->
            attach(Key, Pid, S);
        {function, Func, S} ->
            attach(Key, Func, S);
        %% state data to spawn link local child actor.
        {state, Data, S} ->
            activate(Key, Data, S);
        %% data only, copy it as initial value.
        {data, Data, S} ->
            {data, Data, S#{Key => Data}};
        Error ->
            Error
    end;
attach(_, State) ->
    {error, undefined, State}.

%% attach process or function to an active attribute.
attach(Key, Func, State) when is_function(Func) ->
    {function, Func, State#{Key => {function, Func}}};
%% Process is pid or registered name of a process.
attach(Key, Process, #{'_monitors' := M} = State) ->
    Mref = monitor(process, Process),
    Recovery = maps:get('_link_recovery', State, undefined),
    M1 = M#{Mref => {Key, Recovery}},
    NewState = State#{Key => {link, Process, Mref}, '_monitors' := M1},
    {process, Process, NewState}.

%% -type state_d() :: state() | {state(), actions(), recovery()}.
%% -type result() :: {process, pid(), state()} | 
%%                   {function, Func, state()} |
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
fetch_link(Key, {link, Links, _}, State) ->
    {Sign, Result} = scall(Links, {xl_touch, Key}, State),
    {Sign, Result, State};
%% Links map type format:
%% {ref, Registry :: (pid() | tag()), tag()} |
%%   {state, state_d()} |
%%   {data, term()}.
%% return: {process, pid(), state()} | {state, state_d(), state()}
%%     | {data, term(), state()} | {error, term(), state()}.
fetch_link(Key, Links, State) ->
    case maps:find(Key, Links) of
        error ->
            {error, undefined, State};
        %% Registry process directly.
        %% Should be deprecated because of no monitor.
        {ok, {ref, Registry, Id}} when is_pid(Registry) ->
            {Sign, Result} = scall(Registry, {xl_touch, Id}, State),
            {Sign, Result, State};
        %% attribute name as registry.
        {ok, {ref, RegName, Id}} ->
            case activate(RegName, State) of
                {process, Registry, State1} ->
                    {Sign, Result} = scall(Registry, {xl_touch, Id}, State1),
                    {Sign, Result, State1};
                {function, Registry, State1} ->
                    Registry({xl_touch, Id}, State1);
                {data, Data, State1} when Id =/= undefined ->
                    Value = maps:get(Id, Data),
                    {data, Value, State1};
                %% when Id is undefined, return {data, Data, State1}.
                %% Same case as Error :: {error, term()}.
                Error ->
                    Error
            end;
        %% Type: state, process, function, data
        {ok, {Type, Data}} ->
            {Type, Data, State};
        {ok, Data} ->
            {data, Data, State}
    end.

%%%===================================================================
%%% Unit test
%%%===================================================================
-ifdef(TEST).

-endif.
