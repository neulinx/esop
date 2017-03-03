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
-export([call/2, call/3, call/4, cast/2, cast/3, reply/2, notify/2]).
-export([request/3, invoke/2, invoke/4]).
-export([activate/2, attach/4, remove/2, remove/3]).

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
%% 
%% System or runtime attributes should be atom type as internal
%% attributes. Raw data cannot support tuple type, neither attribute
%% name or value. Tuple type is system type for internal usage.
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
             '_bond' => 'standalone' | tag(),  % how to deal with EXIT event.
             %% Flag of FSM.
             '_state' => active_key() | {'state', state_d()} | tag(),
             %% Flag of state in FSM.
             '_of_fsm' => 'true' | 'false', % default false.
             %% Wether to submit report to parent process.
             '_report' => 'true' | 'false', % default true.
             %% <<"all">> | <<"default">> | list(),
             '_report_items' => binary() | list(),
             '_sign' => sign(),
             '_step' => non_neg_integer(),
             '_traces' => active_key() | map(),
             '_retry_count' => non_neg_integer(),
             '_pending_queue' => list(),
             '_max_pending_size' => limit(),
             %% Quit or keep running after FSM stop. Default value is
             %% <<"quit">>, stop running. If value is <<"halt">>, keep
             %% running.
             '_aftermath' => binary(),
             '_recovery' => recovery(),
             '_link_recovery' => binary(),  % default is <<"restart">>.
             '_id' => tag(),
             '_start' => map(),  % #{<<"input">>, <<"sign">>},
             '_max_steps' => limit(),
             '_preload' => list(),
             '_timeout' => timeout(), 
             '_max_traces' => limit(),
             '_max_retry' => limit(),
             '_retry_interval' => limit(),
             '_hibernate' => timeout()  % mandatory, default: infinity
            } |         % Header part, common attributes.
                 map(). % Body part, data payload of the actor.

%%%% Definition of gen_server.
-type server_name() :: {local, atom()} |
                       {global, atom()} |
                       {via, atom(), term()}.
-type start_ret() ::  {'ok', pid()} | 'ignore' | {'error', term()}.
-type start_opt() :: {'timeout', Time :: timeout()} |
                     {'spawn_opt', [proc_lib:spawn_option()]}.

%%%% Identifiers.
-type process() :: pid() | (LocalName :: atom()).
-type tag() :: atom() | string() | binary() | integer() | tuple().
-type path() :: [process() | tag()].
-type target() :: process() | path().
-type from() :: {To :: process(), Tag :: identifier()} | 'undefined'.
%% Vector is set of dimentions. Raw data does not support tuple type,
%% and list type is used. But string type in Erlang is list type
%% too. Flat states map may confused by list type vector. So vectors
%% in state map is tuple type.
-type vector() :: {GlobalEdge :: tag()} |
                  {Vetex :: tag(), Edge :: tag()}.
%% In state, '_sign' may be relative as tag() type or absolute as
%% vector() type.
-type sign() :: vector() | tag().  % tag() same as {tag()}.
-type monitor() :: {tag(), recovery()}.

%%%% attributes
%% There is no atomic or string type in raw data. Such strings are
%% all binary type as <<"AtomOrString">>.
-type active_key() :: {'link', process(), identifier()} |
                      {'function', function()}.
-type attribute() :: {'link', process(), identifier()} |
                     {'function', function()} |
                     {'state', state_d()} |
                     refers() |
                     term().
%% Reference of another actor's attribute.
-type refer() :: {'refer', path() | {target(), tag()}}.
-type redirect() :: {'redirect', target()}.
-type skip() :: {'redirect', []}.
-type refers() :: refer() | redirect() | skip().
-type monitors() :: #{identifier() => monitor()}.
%% If vector() was list, links_map contains string type of attribute
%% name is conflict with states_map().
-type states() :: active_key() | states_map() | links_map().
-type states_map() :: #{vector() => state()}.
-type links_map() :: #{Key :: tag() => attribute()}.
%% State data with overrided actions and recovery.
-type state_d() :: state() | {state(), actions()}.
-type actions() :: 'state' | module() | binary() | state_actions().
-type state_actions() :: #{'_entry' => entry(),
                           '_exit' => exit(),
                           '_react' => react()}.
%% There is a potential recovery option 'undefined' as default
%% recovery mode, crashed active attribute may be recovered by next
%% 'touch'. Actually tag() is <<"restart">> or <<"rollback">>.
-type recovery() :: integer() | vector() | tag().

%%%% Messages and results.
-type request() :: {'xlx', from(), Command :: term()} |
                   {'xlx', from(), Path :: list(), Command :: term()}.
-type notification() :: {'xlx', Notification :: term()}.
-type message() :: request() | notification() | term().
-type code() :: 'ok' | 'error' | 'noreply' | 'stopped' |
                'data' | 'process' | 'function' | tag().  % etc.
-type result() :: {code(), state()} |
                  {code(), term(), state()} |
                  {code(), Stop :: reason(), Reply :: term(), state()} |
                  {code(), Reply :: term(), state(), 'hibernate'}.
-type output() :: {code(), Result :: term()}.
-type reply() :: output() | code() | term().
-type status() :: 'running' |
                  'stop' |
                  'halt' |
                  'exception' |
                  'failover' |
                  tag().
-type reason() :: 'normal' | 'shutdown' | {'shutdown', term()} | term().
-type active_return() :: {process, pid(), state()} |
                         {function, function(), state()} |
                         {data, term(), state()} |
                         {tag(), term(), state()} |
                         {error, term(), state()}.

%%%% Behaviours.
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

%%%% Misc
-type limit() :: non_neg_integer() | 'infinity'.

%% --------------------------------------------------------------------
%% Message format:
%% 
%% - wakeup event: xl_wakeup
%% - hibernate command: xl_hibernate
%% - stop command: xl_stop | {xl_stop, reason()}
%% - state enter event: xl_enter.
%% - state transition event: {xl_leave, Pid, state() | {Output, vector()}}
%% - messages in the gap between states: {xl_intransition, Message}
%%   ACK: {ok, xl_leave_ack} reply to from Pid.
%% - post data package for trace log:
%%           {xl_trace, {log, Trace} | {backtrack, Back}}
%% - failover retry event: {xl_retry, recovery()} |  % for FSM
%%         {xl_retry, Key, <<"restart">>}  % for active attribute.
%% - command to notify all subscribers: {xl_notify, Notification}.
%%
%% Request format: {xlx, From, To, Command} -> reply().
%%   - xlx, tag of sop request.
%%   - From, should be form of {SourcePid, reference()}. If From is undefined,
%%     response is not necessary, same as notification.
%%   - To, relative path to the target actor, should be list type.
%%     - [], path to current actor root;
%%     - [<<".">>], path to current actor root, do not relay to state actor;
%%     - [Key], path to attribute by name Key;
%%     - [NextHop, Hops], relay to next hop.
%%   - Command, any form of request to target.
%%
%% Predefined commands:
%% - touch and activate: touch -> touch_return.
%%   - Start actor by value of the Key or last hop of the Path.
%%   - Initialize the value by states.
%%   - Return the activated value of the Key with type.
%%   - Return current pid() if Key is not present.
%% - get: get -> {code(), Result, state()}.
%%   - Code is preferred 'ok' or 'error'.
%%   - If value of Key is process or function, get request relay to process
%%     or call the function.
%%   - get request always fire activate action of the Key.
%%   - get without Key parameter may return all data of current actor,
%%     get rid of system data (Attribute name type is atom). 
%% - get raw data without touch: get_raw -> term().
%%   - raw data of the Key, or all data of the actor.
%%   - get_raw do not trigger activate action, just return data as is.
%% - update: {put, Value} -> {code(), Result, state()}.
%%   - put operation may create new Key or update existed Key;
%%   - Response is preferred {ok, done, state()} or {error, Error, state()};
%%   - put perform replace operation on data;
%% - patch: {patch, Value} -> {code(), Result, state()}.
%%   - patch operation may create new Key or update existed Key;
%%   - Value should be map type;
%%   - Response is preferred {ok, done, state()} or {error, Error, state()};
%%   - patch perform merge operation on data;
%% - delete: delete -> {code(), Result, state()}.
%%   - Response is preferred {ok, done, state()} or {error, Error, state()};
%%
%% Predefined signs:
%% Generally, all internal signs are atom type.
%% - exceed_max_steps: run out of steps limit.  fall through exception.
%% - exception: generic error.
%% - stop: machine stop and process exit.
%% - halt: machine stop but process is still alive.
%% - escape: FSM is not finished, but current state is finished.
%% - abort: FSM is not finished, current state is terminated by command.
%% --------------------------------------------------------------------
-type command() :: 'touch' | 'get' | 'get_raw' | 'delete' |
                   {'put', term()} | {'patch', term()} |
                   {'subscribe', process()} | {'unsubscribe', reference()} |
                   {'xl_notify', term()} |
                   'xl_stop' | {'xl_stop', term()} | 'xl_hibernate'.
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
    case pre_handle(Message) of
        {xlx, From, _, _} = Info ->
            Source = From;
        Info ->
            Source = noreply
    end,
    Result = case handle(Info, State) of
                 {ok, unhandled, State1} ->
%%%%%%%%%% Defend here? or trust the defence line of gen_server?
                     default_react(Info, State1);
                 Res0 ->
                     Res0
             end,
    case post_handle(Result, Source) of
        {noreply, #{'_hibernate' := Timeout} = State2} ->
            {noreply, State2, Timeout};
        Res2 ->
            Res2
    end.

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
    {ok, State}.                                % ignore_coverage_test

%% --------------------------------------------------------------------
%% Starts the server.
%% 
%% start/3 or start_link/3 spawn actor with local or global name. If
%% server_name is 'undefined', the functions same as start/2 or
%% start_link/2.
%% 
%% Value of '_timeout' attribute will affect the entire life
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
merge_options(Options, #{'_timeout' := Timeout}) ->
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
reply(_, _) ->
    ok.

%% Same as gen_server:call().
-spec call(target(), Request :: term()) -> reply().
call([Process | Path], Command) ->
    call(Process, Path, Command, infinity);
call(Process, Command) ->
    call(Process, [], Command, infinity).

-spec call(target(), Request :: term(), timeout()) -> reply().
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

scall(Process, Command, #{'_timeout' := Timeout}) ->
    call(Process, Command, Timeout);
scall(Process, Command, _) ->
    call(Process, Command, ?DFL_TIMEOUT).

-spec cast(target(), Message :: term()) -> 'ok'.
cast([Process | Path], Command) ->
    cast(Process, Path, Command);
cast(Process, Command) ->
    cast(Process, [], Command).

-spec cast(process(), path(), Message :: term()) -> 'ok'.
cast(Process, Path, Message) ->
    catch Process ! {xlx, noreply, Path, Message},
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

%% The function generate notification send to all subscribers.
-spec notify(process(), Info :: term()) -> 'ok'.
notify(Process, Info) ->
    catch Process ! {xl_notify, Info},
    ok.

%% --------------------------------------------------------------------
%% Process messages with path, when react function does not handle it.
%%
%% Hierarchical data in a state data map can only support
%% touch/get/put/delete operations.
%%
%% request/3 is sync operation that wait for expected reply. Instant
%% return version is invoke/4 with first parameter 'undefined':
%% 
%% invoke(undefined, Path, Notification, State).
%%
%% Compare with similar functions call and cast, function invoke is
%% called inside actor process while call/cast is called outside the
%% process.
%% --------------------------------------------------------------------
%%%% request to the actor without special key.
-spec invoke(command(), state()) -> result().
%% May be request for far far away source for shortcut link.
invoke(touch, State) ->
    {process, self(), State};
%% get request to root return all data without internal data.
invoke(get, State) ->
    Pred = fun(Key, Value) when is_atom(Key) orelse
                                is_tuple(Key) orelse
                                is_tuple(Value) ->
                   false;
              (_, _) ->
                   true
           end,
    {ok, maps:filter(Pred, State), State};
%% Retrieve all raw data of state.
invoke(get_raw, State) ->
    {ok, State, State};
%% @notice: patch may override internal data.
invoke({patch, Patch}, State) ->
    Update = fun(K, V, S) ->
                     {ok, done, S1} = invoke(undefined, [K], {put, V}, S),
                     S1
             end,
    NewS = maps:fold(Update, State, Patch),
    {ok, done, NewS};
invoke({subscribe, Pid}, State) ->
    Subs = maps:get('_subscribers', State, #{}),
    Mref = monitor(process, Pid),
    Subs1 = Subs#{Mref => Pid},
    {ok, Mref, State#{'_subscribers' => Subs1}};
%% Unsubscribe operation may be triggered by request or notification
%% with different message format: {xlx, From, Path, {unsubscribe,
%% Ref}} vs {unsubscribe, Ref}.
invoke({xl_notify, Info}, #{'_subscribers' := Subs} = State) ->
    maps:fold(fun(M, P, A) ->
                      catch P ! {M, Info},
                      A
              end, 0, Subs),
    {ok, done, State};
invoke({unsubscribe, Ref}, #{'_subscribers' := Subs} = State) ->
    demonitor(Ref, [flush]),
    Subs1 = maps:remove(Ref, Subs),
    {ok, done, State#{'_subscribers' := Subs1}};
%% Interactive stop.
invoke({xl_stop, Reason}, State) ->
    {ok, Reason, done, State};
invoke(xl_stop, State) ->
    {ok, normal, done, State};
invoke(xl_hibernate, State) ->
    {ok, done, State, hibernate};
invoke(_, State) ->
    {error, unknown, State}.

%% Synchoronous version of request, wait for response till timeout.
-spec request(target(), Command :: term(), state()) -> result().
request(Path, Command, State) ->
    case invoke(undefined, Path, Command, State) of
        {'_pending', Tag, S} ->
            Timeout = maps:get('_timeout', S, ?DFL_TIMEOUT),
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

%% Asynchoronous version of request, return immediately.
-spec invoke(from(), target(), Command :: term(), state()) -> result().
invoke(_, [], Command, State) ->
    invoke(Command, State);
invoke(_, [Key], touch, State) ->
    activate(Key, State);
invoke(_, [Key], get_raw, State) ->
    case maps:find(Key, State) of
        {ok, Value} ->
            {ok, Value, State};
        error ->
            {error, undefined, State}
    end;
invoke(_, [Key], {put, Value}, State) ->
    S = remove(Key, State, true),
    {ok, done, S#{Key => Value}};
invoke(_, [Key], delete, State) ->
    S = remove(Key, State, true),
    {ok, done, S};
%% Sugar for '_state' access.
invoke(From, [<<>> | Path], Command, State) ->
    invoke(From, ['_state' | Path], Command, State);
invoke(From, [Key | Path], Command, State) ->
    case activate(Key, State) of
        {process, Pid, S} when From =:= undefined ->
            Tag = make_ref(),
            Pid ! {xlx, {self(), Tag}, Path, Command},
            {'_pending', Tag, S};
        {process, Pid, S} ->  % relay request to the linked actor.
            Pid ! {xlx, From, Path, Command},
            {noreply, S};
        %% Func should checkeck From value as above cases of process.
        {function, Func, S} ->  % relay request to message handler.
            Func({xlx, From, Path, Command}, S);
        {data, Package, S} ->  % traverse local forest.
           case iterate(Command, Path, Package) of
                {dirty, Data} ->
                    {ok, done, S#{Key => Data}};
                {Code, Value} ->  % {ok, Value} | {error, Error}.
                    {Code, Value, S}
            end;
        Error ->
            Error
    end.

iterate(touch, [], {Type, Data}) ->
    {Type, Data};
iterate(touch, [], Data) ->
    {data, Data};
iterate(get, [], Data) ->
    {ok, Data};
iterate(get_raw, [], Data) ->
    {ok, Data};
iterate({patch, V1}, [], V) when is_map(V) andalso is_map(V1) ->
    {dirty, maps:merge(V, V1)};
iterate(_, [], _) ->
    {error, badarg};
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
            {error, undefined}
    end.

%% Untie fatal link or monitor of the attribute reference. Attribute
%% is removed too. If Stop is true, cast stop message to the
%% process linked before.
-spec remove(tag(), state()) -> state().
remove(Key, State) ->
    remove(Key, State, true).

-spec remove(tag(), state(), boolean()) -> state().
remove(Key, #{'_monitors' := M} = State, Stop) ->
    S = case maps:find(Key, State) of
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
        end,
    maps:remove(Key, S).

%% --------------------------------------------------------------------
%% States is map or active attribute to keep state data, which is not
%% only for FSMs but also for links. For FSMs, key of the state map
%% must be tuple type, which is form of {Vertex, Edge} as a vector of
%% graph. To simplify states arrangement, single element Vector:{Edge}
%% is global vector can match any Vertex.
%%
%% Data types of attributes:
%% {link, pid(), identifier()} |
%% refers(),
%% {state, {state(), actions()}} | {state, state()} | Value :: term().
%% when actions() :: state | module() | Module :: binary() | Actions :: map().
-spec activate(tag(), state()) -> active_return().
activate(Key, State) ->
    case maps:find(Key, State) of
        {ok, {link, Pid, _}} ->
            {process, Pid, State};
        {ok, {function, Func}} ->
            {function, Func, State};
        {ok, {Type, Data}} ->
            attach(Type, Data, Key, State);
        {ok, Value} ->
            {data, Value, State};
        error when Key =:= '_states' ->
            {error, undefined, State};
        error ->
            %% Try to retrieve data or external actor, and attach to
            %% attribute of current actor. Cache data if states retrun
            %% {data, Data, State}.
            {Type, Data, State1} = request(['_states', Key], touch, State),
            attach(Type, Data, Key, State1)
    end.

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
    Recovery = maps:get('_recovery', Start, undefined),
    Monitors = M#{Pid => {Key, Recovery}},
    {process, Pid, State#{Key => {link, Pid, Pid}, '_monitors' := Monitors}}.

-spec attach(tag(), Data :: term(), Key :: term(), state()) -> active_return().
%% attach function to an active attribute.
attach(function, Func, Key, State) ->
    {function, Func, State#{Key => {function, Func}}};
%% Process is pid or registered name of a process.
attach(process, Process, Key, #{'_monitors' := M} = State) ->
    Mref = monitor(process, Process),
    Recovery = maps:get('_link_recovery', State, undefined),
    M1 = M#{Mref => {Key, Recovery}},
    NewState = State#{Key => {link, Process, Mref}, '_monitors' := M1},
    {process, Process, NewState};
%% state data to spawn link local child actor.
attach(state, {Data, Actions}, Key, State) ->
    activate(Actions, Key, Data, State);
attach(state, Data, Key, State) ->
    Actions = maps:get('_actions', Data, state),
    activate(Actions, Key, Data, State);
%% data only, copy it as initial value.
attach(data, Data, Key, State) ->
    {data, Data, State#{Key => Data}};
%% reference type, may cause recurisively request.
attach(refer, {Path, Id}, Key, State) ->  % external reference.
    {Code, Result} = scall(Path, {touch, Id}, State),
    attach(Code, Result, Key, State);
attach(refer, Path, Key, State) ->  % internal reference.
    {Code, Result, S} = request(Path, touch, State),
    attach(Code, Result, Key, S);
%% Error or volatile data need not cache in attribute Key.
attach(Type, Data, _Key, State) ->
    {Type, Data, State}.

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
    %% try to initialize FSM if it is.
    prepare(init_fsm(S2), false);
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
preload(#{'_preload' := Preload} = State) ->
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
%% Flag of FSM is existence of the attribute named _state. _state may
%% be pre-spawned external process as an introducer, function share
%% same process with the fsm actor, or data map with '_sign' '_output'
%% '_recovery' keys. '_output' key name is compatible with transfer
%% function, actually means input of next state.
%% --------------------------------------------------------------------
init_fsm(Fsm) ->
    %% undefined _recovery of start state use '_recovery'
    %% of the FSM as default.
    %%
    %% Request _input value means may be active attribute. Activate
    %% and get value. If error occured, Input should be undefined.
    {_, Input, Fsm1} = request(['_input'], get, Fsm),
    case activate('_state', Fsm1) of
        {data, #{'_output' := _} = Start, Fsm2} ->
            transfer(Fsm2, Start);  % start state has it own input.
        {data, Start, Fsm2} when is_map(Start) ->
            transfer(Fsm2, Start#{'_output' => Input});
        {data, Start, Fsm2} ->
            transfer(Fsm2, #{'_sign' => Start, '_output' => Input});
        %% {process, _, F} ->  % pre-spawn process as start state
        %%     {ok, F};
        %% {function, _, F} -> % function as start state, may share process.
        %%     {ok, F};
        %% {error, undefined, F} ->  % no '_state' present.
        %%     {ok, F};
        {_, _, F} ->
            {ok, F}
    end.

%% --------------------------------------------------------------------
%% Handling messages by relay to react function and default
%% procedure. 
%% --------------------------------------------------------------------
%% Empty path, the last hop.
pre_handle({xlx, From, Command}) ->
    {xlx, From, [], Command};
%% Sugar for stop.
pre_handle(xl_stop) ->
    {xl_stop, normal};
%% gen_server timeout as hibernate command.
pre_handle(timeout) ->
    xl_hibernate;
pre_handle(Msg) ->
    Msg.

%% Notice: if there is no '_react' action or '_react' action do not
%% process this message, should return {ok, unhandled, State} to
%% handle it by default routine. Otherwise, the message will be
%% ignored. As a syntactic sugar, {ok, unhandled, State} is generated
%% automatically.
handle(Info, #{'_react' := React} = State) ->
    try
        React(Info, State)
    catch
        error : function_clause ->
            {ok, unhandled, State}
    end;
handle(_Info, State) ->
    {ok, unhandled, State}.

%% Sugar for stop result.
post_handle({stop, S}, _) ->
    Reason = maps:get('_reason', S, normal),
    {stop, Reason, S};
post_handle({_, S}, _) ->
    {noreply, S};
post_handle({stop, _, _} = Stop, _) ->
    Stop;
post_handle({_, S, hibernate}, _) ->
    {noreply, S, hibernate};
post_handle({reply, Reply, S}, Source) ->
    reply(Source, Reply),
    {noreply, S};
post_handle({_, _, S}, noreply) ->
    {noreply, S};
post_handle({Code, Result, S}, Source) ->
    reply(Source, {Code, Result}),
    {noreply, S};
post_handle({stop, Reason, Reply, S}, Source) ->
    reply(Source, Reply),
    {stop, Reason, S};
post_handle({Code, Result, S, hibernate}, Source) ->
    reply(Source, {Code, Result}),
    {noreply, S, hibernate};
post_handle({Code, Stop, Result, S}, Source) ->
    reply(Source, {Code, Result}),
    {stop, Stop, S}.

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
%% default_react(xl_enter, State) ->
%%     {noreply, State};
%% default_react(xl_wakeup, State) ->
%%     {noreply, State};
%% External links of active attributes and subscribers are all
%% processes monitored by the actor. All of them may raise 'DOWN'
%% events at ending.
default_react({'DOWN', M, _, _, _} = Down, State) ->
    handle_halt(M, Down, State);
%% Since all actor process flag is trap_exit, all linked processes may
%% generate 'EXIT' message on quitting. If '_parent' process crashed
%% and bond type is not standalone, current actor should exit
%% too. Strategy of actor to handle unknown 'EXIT' is to ignore it.
default_react({'EXIT', Pid, _} = Exit,
              #{'_parent' := Pid, '_bond' := standalone} = State) ->
    handle_halt(Pid, Exit, State);
default_react({'EXIT', Pid, _}, #{'_parent' := Pid} = State) ->
    {stop, {shutdown, break}, State};
default_react({'EXIT', Pid, _} = Exit, State) ->
    handle_halt(Pid, Exit, State);
%% Delay restart for failed active attribute.
default_react({xl_retry, Key, <<"restart">>}, State) ->
    {_, _, S} = activate(Key, State),
    {noreply, S};
%% Delay recovery for FSM.
default_react({xl_retry, Recovery}, #{'_status' := failover} = Fsm) ->
    retry(Fsm, Recovery);
%% State transition message. Output :: state() | {term(), vector()}.
default_react({xl_leave, From, Output}, #{'_state' := _} = Fsm) ->
    catch From ! {ok, xl_leave_ack},
    transfer(Fsm, Output);
%% Drop transition message if this actor is not FSM.
default_react({xl_leave, From, _}, State) when is_pid(From) ->
    catch From ! {ok, xl_leave_ack},
    {noreply, State};
%% Failover status of FSM, cache the messages into pending queue.
%% Notice: if _max_pending_size is not present, do not cache message.
default_react({xl_intransition, Message}, State) ->
    enqueue_message(Message, State);
default_react({xlx, From, ['_state' | Path], Command}, 
              #{'_status' := failover} = State) ->
    enqueue_message({xlx, From, Path, Command}, State);
%% ------ handle request ------
default_react({xlx, From, Path, Command}, State) ->
    invoke(From, Path, Command, State);
default_react(Info, State) ->
    invoke(Info, State).

enqueue_message(Message, #{'_state' := {link, Pid, _}} = State) ->
    Pid ! Message,
    {noreply, State};
enqueue_message(Message, State) ->
    Size = maps:get('_max_pending_size', State, infinity),
    Q = maps:get('_pending_queue', State, []),
    Q1 = enqueue(Message, Q, Size),
    {noreply, State#{'_pending_queue' => Q1}}.

handle_halt(Id, Throw, #{'_monitors' := M} = State) ->
    case maps:find(Id, M) of
        %% Self-heal for FSM.
        {ok, {'_state', Recovery}} ->
            %% Throw is output, exception is sign. If there is a
            %% state for {exception} in '_states', 'Recovery' will be
            %% ignored.
            FailState = #{'_sign' => {exception},
                          '_recovery' => Recovery,
                          '_output' => Throw},
            transfer(State, FailState);
        {ok, {Key, undefined}} ->
            Recovery = maps:get('_recovery', State, undefined),
            aa_recover(Key, Recovery, State);
        {ok, {Key, Recovery}} ->
            aa_recover(Key, Recovery, State);
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

%% Self-heal for active attribute, it is just reload at a
%% while. Compare with default recovery, it is reload on next
%% demand.
aa_recover(Key, <<"restart">>, State) ->
    S = remove(Key, State),
    Interval = maps:get('_retry_interval', S, ?RETRY_INTERVAL),
    erlang:send_after(Interval, self(), {xl_retry, Key, <<"restart">>}),
    {ok, S};
aa_recover(Key, _, State) ->
    %% Just remove it and wait for next access to trigger recovery.
    S = remove(Key, State, false),
    {ok, S}.

%% --------------------------------------------------------------------
%% FSM state transition functions.
%%
%% xl_leave is a notification of format {xl_leave, Output}, where
%% Output may be tuple of {Output, Vector} or runtime state data.  If
%% FSM process crashed, the state data has no time to output, message
%% maybe {{'EXIT', Pid, Reason}, {exception}}. If state process would
%% not output all state data, it may select and customize the state
%% data map output.
transfer(Fsm, Indication) ->
    notify(self(), {transition, Indication}),
    {_, _, Fsm1} = archive(Fsm, Indication),
    Recovery = maps:get('_recovery', Indication, undefined),
    Output = maps:get('_output', Indication, undefined),
    Vector = make_vector(Indication),
    transfer(Fsm1, Vector, Output, Recovery).

%% To support different recovery option for each state.
transfer(Fsm, Vector, Output, Recovery) ->
    case t1(Fsm, Vector, Output) of
        %% Halt the FSM but keep actor running for data access.
        {stop, #{'_aftermath' := <<"halt">>} = F2} ->
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
            {process, Pid, F3} = attach(state, S2, '_state', F2),
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
t1(#{'_step' := Step, '_max_steps' := MaxSteps} = Fsm, _, Output)
  when Step >= MaxSteps ->
    t2(Fsm, exceed_max_steps, Output);
t1(Fsm, Vector, Output) ->
    t2(Fsm, Vector, Output).

%% Sign of 'exception' should be final state without next hop. But for
%% feature of customized exception handler, FSM may provide next state
%% for exception, which must be the final state.
t2(Fsm, Vector, Output) ->
    %% Prepare for transition. Remove runtime '_state', increase step
    %% counter, add output and sign attributes.
    case next_state(Vector, Fsm) of
        {exception, Fsm1} ->
            %% You can provide your own exception and stop state.
            t2(Fsm1, {exception}, Output);
        {Next, Fsm1} ->            
            Step = maps:get('_step', Fsm1, 0),
            F = remove('_state', Fsm1, false),
            {Next, F#{'_step' => Step + 1,
                      '_output' => Output,
                      '_sign' => Vector}}
    end.

next_state(Vector, Fsm) ->
    %% Currently, accept only data of map type as state.
    case request(['_states', Vector], touch, Fsm) of
        {data, State, F} when is_map(State) ->
            {State, F};
        {_, _, F} ->  % undefined or badarg.
            case default_sign(Vector) of
                exception ->
                    {recover, F};
                halt ->
                    {halt, F};
                stop ->
                    {stop, F};
                exceed_max_steps ->
                    {stop, F};
                _ ->
                    {exception, F}
            end
    end.
    

%% Absolute sign as vector() type.
make_vector(#{'_sign' := Sign}) when is_tuple(Sign) ->
    Sign;
%% Relative sign with ID.
make_vector(#{'_sign' := Sign, '_id' := Id}) ->
    {Id, Sign};
%% Relative sign without ID, treated as global sign.
make_vector(#{'_sign' := Sign}) ->
    {Sign};
%% Stop is default sign if it is not present.
make_vector(_) ->
    {stop}.

%% Extract sign of transition from vector.
default_sign({Sign}) ->
    Sign;
default_sign({_, Sign}) ->
    Sign;
default_sign(Sign) ->
    Sign.

%% --------------------------------------------------------------------
%% Failover and recovery.
%% --------------------------------------------------------------------
%% '_retry_count' is lifetime count of all failover. The retry count
%% is cumulative unless the actor is reset. If '_max_retry' is not
%% present, retry times is unlimited.
recover(#{'_retry_count' := Count, '_max_retry' := Max} = Fsm, _)
  when Count >= Max ->
    {stop, {shutdown, too_many_retry}, Fsm#{'_status' := exception}};
recover(#{'_recovery' := undefined} = Fsm, undefined) ->
    {stop, {shutdown, exception}, Fsm#{'_status' := exception}};
recover(#{'_recovery' := Recovery} = Fsm, undefined) ->
    recover(Fsm, Recovery);
recover(Fsm, undefined) ->
    {stop, {shutdown, exception}, Fsm#{'_status' := exception}};
%% To slow down the failover progress, retry operation always
%% triggered by message. Even the "_retry_interval" is 0, retry
%% operation is still asynchronous.
recover(Fsm, Recovery) ->
    Interval = maps:get('_retry_interval', Fsm, ?RETRY_INTERVAL),
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
    Bypass = #{'_output' => Output, '_sign' => Vector},
    transfer(Fsm, Bypass).

%% If '_traces' is not present, archive do nothing. So trace log is
%% disable default, but '_max_traces' default value is
%% MAX_TRACES. Trace is form of state() | {Output, Vector}.
archive(#{'_traces' := {function, Traces}} = Fsm, Trace) ->
    Traces({log, Trace}, Fsm);
archive(#{'_traces' := {link, Traces, _}} = Fsm, Trace) ->
    {Code, Result} = scall(Traces, {xl_trace, {log, Trace}}, Fsm),
    {Code, Result, Fsm};
archive(#{'_traces' := Traces} = Fsm, Trace)  ->
    Limit = maps:get('_max_traces', Fsm, ?MAX_TRACES),
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
    State#{'_sign' => {exception}};
ensure_sign(#{'_reason' := normal} = State) ->
    State#{'_sign' => {stop}};
ensure_sign(#{'_reason' := shutdown} = State) ->
    State#{'_sign' => {stop}};
ensure_sign(#{'_reason' := {shutdown, _}} = State) ->
    State#{'_sign' => {stop}};
ensure_sign(State) ->
    State#{'_sign' => {exception}}.

%% If FSM is not stopped normally, sign of the FSM is abort. The FSM
%% can then be reloaded to continue running. In such case, '_output'
%% of the FSM is previous result because of current state may have no
%% time to yield output.
stop_fsm(#{'_state' := {link, Pid, _}} = Fsm, Reason) ->
    Timeout = maps:get('_timeout', Fsm, ?DFL_TIMEOUT),
    case stop(Pid, Reason, Timeout) of
        {ok, Output} ->
            Fsm#{'_state' := Output,
                 '_sign' => {escape}};
        {stopped, Result} ->
            Fsm#{'_state' := {Result, {abort}},
                 '_sign' => {abort}};
        {error, Error} ->
            Fsm#{'_state' := {Error, exception},
                 '_sign' => {exception}}
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
    Detail = maps:get('_report_items', State, <<"default">>),
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
    Detail = maps:get('_report_items', State, <<"default">>),
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
    make_report(['_id', '_sign', '_output', '_recovery'], State);
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
            flush_and_relay(Pid, Timeout);
        {'EXIT', _, _} ->
            flush_and_relay(Pid, Timeout);
        Message ->
            Pid ! {xl_intransition, Message},
            flush_and_relay(Pid, Timeout)
    after Timeout ->
            true
    end.

%%%===================================================================
%%% Unit test
%%%===================================================================
-ifdef(TEST).

-endif.
