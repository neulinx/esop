%%%-------------------------------------------------------------------
%%% @author Gary Hai <gary@XL59.com>
%%% @copyright (C) 2016, Neulinx Collaborations Ltd.
%%% @doc
%%%  Actor model implementation by graph topology.
%%% @end
%%% Created : 22 Jun 2016 by Gary Hai <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(xl_actor).

-compile({no_auto_import,[exit/1]}).
%% API
-export([entry/1, do/1, exit/1, react/2]).

-ifdef(TEST).
    -include_lib("eunit/include/eunit.hrl").
-endif.

-define(DFL_TIMEOUT, 4000).

%%--------------------------------------------------------------------
%% Common types
%%--------------------------------------------------------------------
-type state() :: xl_state:state().
-type actor() :: 
        #{'gid' => id(),  % Should be globally unique ID, for migration
          'name' => name(),
          'pid' => pid(),  % Actor ID, same as OTP process pid.
          'realm' => process(), % Actor of the domain keeper.
          'links' => links(),  % states graph, loaded and unloaded.
          'monitors' => monitors(), % Local or global monitor.
          'boundary' => 'opened' | 'closed',
          'preload' => [name()] | function(),
          'failover' => failover()  % for this actor's supervisor.
         } | state().
-type id() :: name() | integer().
-type name() :: string() | bitstring().
-type links() :: #{name() => link()}.
-type monitors() :: #{monitor() => name()}.
-type gid_or_data() :: actor() | id().
-type link() :: gid_or_data() |  % local or global inactive link.
                {actor(), pid()} |  % local active link
                {gid_or_data(), pid(), monitor()}.  % global active link
-type monitor() :: identifier().
-type process() :: pid() | atom().
-type failover() :: 'restore' | 'reset' |
                    {'restore', Mend :: map()} |
                    {'reset', Mend :: map()}.
-type result() :: xl_state:ok() | xl_state:fail().
%%-type path() :: [process()].
%%-type from() :: {path() | process(), Tag :: identifier()}.

%%--------------------------------------------------------------------
%% Behaviors of state.
%%
%% There are two type of actor boundary: opened or closed. Currently
%% support closed boundary only. It is easy for opened boundary implemented.
%%--------------------------------------------------------------------
%% Main task of entry is ensure dependent actors preloaded.
%% Perform preload in entry action for fail-fast (synchronous return).
-spec entry(actor()) -> {'ok', actor()}.
entry(Actor) ->
    process_flag(trap_exit, true),
    preload(Actor).

%% Do nothing.
-spec do(actor()) -> result().
do(Actor) ->
    {ok, Actor}.

%% Stop local links before exit.
-spec exit(actor()) -> {'stopped', actor()}.
exit(#{links := L, monitors := M} = Actor) ->
    Links = maps:fold(fun cleanup/3, L, M),
    {stopped, Actor#{monitors := #{}, links := Links}};
exit(Actor) ->
    {stopped, Actor}.

-spec react(Message :: term(), actor()) -> result().
react(Message, Actor) ->
    on_message(Message, Actor).

%%--------------------------------------------------------------------
%% Message handlers
%%--------------------------------------------------------------------
%% Local link, try to hotfix on error.
on_message({'EXIT', Pid, Output}, Actor) ->
    A = checkout(Pid, Output, Actor),
    {ok, A};
%% For global link, update link with no more action.
%% todo: archive output according by link.
on_message({'DOWN', Monitor, process, _, _Output}, Actor) ->
    {A, _, _} = deactive(Monitor, Actor),
    {ok, A};
%% Messages with path, relay message to next hop.
%% Notice: it is a backdoor if PID in path, so remove it.
on_message({xlx, From, [Next | Path], Message}, Actor) ->
    %% relay to next hop
    case ensure_load(Next, Actor) of
        {ok, Pid, A} ->
            Pid ! {xlx, From, Path, Message},
            {ok, A};
        _Error ->
            {ok, unreachable, Actor}
    end;
on_message({xlx, From, [], Message}, Actor) ->
    on_message({xlx, From, Message}, Actor);
on_message({xlx, _From, Command}, Actor) ->
    invoke(Command, Actor);
on_message(_Message, Actor) ->
    {ok, {error, unhandled}, Actor}.

invoke({Tag, _} = Command, #{realm := R} = Actor)
  when Tag =:= get_active_actor orelse
       Tag =:= register orelse
       Tag =:= register_load ->
    Timeout = maps:get(timeout, Actor, ?DFL_TIMEOUT),
    Result = xl_state:call(R, Command, Timeout),
    {ok, Result, Actor};
invoke({get_active_actor, Id}, Actor) ->
    case ensure_load(Id, Actor) of
        {ok, Pid, A} ->
            {ok, {ok, Pid}, A};
        Error ->
            {ok, Error, Actor}
    end;
invoke({register, State}, #{boundary := opened} = Actor) ->
    register_actor(State, Actor);
invoke({register_load, State},  #{boundary := opened} = Actor) ->
    register_and_load(State, Actor);
%% default behavior is data access
invoke(Key, Actor) ->
    {ok, maps:find(Key, Actor), Actor}.

%%--------------------------------------------------------------------
%% register, globally or locally.
%%--------------------------------------------------------------------
register_actor(#{gid := Gid} = State, #{links := L} = Actor) ->
    case maps:is_key(Gid, L) of
        true ->
            {ok, {error, already_existed}, Actor};
        false ->
            L1 = L#{Gid => State},
            {ok, {ok, Gid}, Actor#{links := L1}}
    end;
register_actor(_, Actor) ->
    {ok, {error, invalid_data}, Actor}.

register_and_load(#{gid := Gid} = State, #{links := L} = Actor) ->
    case maps:is_key(Gid, L) of
        true ->
            {ok, {error, already_existed}, Actor};
        false ->
            {ok, Pid, A} = ensure_load(Gid, State, Actor),
            {ok, {ok, Pid}, A}
    end;
register_and_load(_, Actor) ->
    {ok, {error, invalid_data}, Actor}.


%%--------------------------------------------------------------------
%% Failover
%%--------------------------------------------------------------------
%% Normal exit
checkout(Pid, {Sign, _}, Actor) when Sign =/= exception ->
    {A, _, _} = deactive(Pid, Actor),
    A;
%% Known exception
checkout(Pid, {exception, Exception}, Actor) ->
    hotfix(Exception, Pid, Actor);
%% Unknown exception
checkout(Pid, _Exception, Actor) ->
    hotfix(undefined, Pid, Actor).

hotfix(ErrState, Pid, Actor) ->
    {A, Name, InitState} = deactive(Pid, Actor),
    Failover = maps:get(failover, A, restore),
    NewState = heal(Failover, InitState, ErrState),
    {ok, _, A1} = ensure_load(Name, NewState, A),
    A1.

heal(restore, InitState, undefined) ->
    InitState;
heal(restore, _, ErrState) ->
    ErrState;
heal(reset, InitState, _) ->
    InitState;
heal({Mode, Mend}, InitState, ErrState) ->
    State = heal(Mode, InitState, ErrState),
    maps:merge(State, Mend).

%%--------------------------------------------------------------------
%% Load and link.
%%--------------------------------------------------------------------
%% Load dependent actors at first.
preload(#{preload := P} = Actor) ->
    preload(P, Actor);
preload(Actor) ->
    {ok, Actor}.

preload([Dep | Rest], Actor) ->
    {ok, _, A} = ensure_load(Dep, Actor),
    preload(Rest, A);
preload([], Actor) ->
    {ok, Actor};
%% Customized preload progress.
preload(Preload, Actor) when is_function(Preload) ->
    Preload(Actor).

%% Early phase of load, get state by name and check if loaded.
ensure_load(Name, #{links := L} = Actor) ->
    case maps:find(Name, L) of
        {ok, {_S, Pid}} ->  % Tuple type means loaded.
            {ok, Pid, Actor};
        {ok, State} ->
            ensure_load(Name, State, Actor);
        _NotFound ->
            {error, undefined}
    end.

%% If gid is presented, it is global actor, fetch from realm keeper.
%% Or current actor acts as realm keeper if no present realm.
ensure_load(Name, #{gid := _} = State, #{realm := Realm} = Actor) ->
    global_invoke(register_load, Name, State, Realm, Actor);
%% Local actor, also act as registrar if no realm keeper.
ensure_load(Name, State, Actor) when is_map(State) ->
    {ok, Member} = xl_state:start_link(State),
    A = activate(Name, {State, Member}, Member, Actor),
    {ok, Member, A};
ensure_load(Name, Id, #{realm := Realm} = Actor) ->
    global_invoke(get_active_actor, Name, Id, Realm, Actor).

global_invoke(Command, Name, IdOrData, Realm, Actor) ->
    %% For pattern matching, Neighbor should be pid type.
    Neighbor = case xl_state:call(Realm, {Command, IdOrData}) of
                   {ok, Pid} when is_pid(Pid) ->
                       Pid;
                   {ok, PName} when is_atom(PName) ->
                       whereis(PName)
               end,
    Monitor = monitor(process, Neighbor),
    %% Update link
    A = activate(Name, {IdOrData, Neighbor, Monitor}, Monitor, Actor),
    {ok, Neighbor, A}.


%% todo: check for closed realm, which will not add new link.
%% todo: support function type links.
activate(Name, Link, Monitor, #{links := L} = Actor) ->
    M = maps:get(monitors, Actor, #{}),
    Actor#{links := L#{Name := Link},
           monitors => M#{Monitor => Name}}.

%%--------------------------------------------------------------------
%% Stop actor and deactivate local links.
%%--------------------------------------------------------------------
%% When 'EXIT' or 'DOWN' tag message received, demonitor is not necessary.
deactive(Monitor, #{monitors := M} = Actor) ->
    case maps:find(Monitor, M) of
        {ok, Name} ->
            deactive(Name, Monitor, Actor)
        %% Fail-fast as Erlang/OTP level link when not found.
    end.

deactive(Name, Monitor, #{links := L, monitors := M} = Actor) ->
    M1 = maps:remove(Monitor, M),
    case maps:find(Name, L) of
        {ok, Link} when is_tuple(Link) ->
            State = element(1, Link),
            L1 = L#{Name := State},
            {Actor#{links := L1, monitors := M1}, Name, State}
        %% Fail-fast
    end.

cleanup(Monitor, Name, Links) ->
    deactive(Monitor),
    {ok, Link} =  maps:find(Name, Links),
    State = element(1, Link),
    Links#{Name := State}.

deactive(Pid) when is_pid(Pid) ->
    xl_state:cast(Pid, stop);
deactive(Monitor) ->
    demonitor(Monitor).

%%%===================================================================
%%% Unit test
%%%===================================================================

-ifdef(TEST).

-endif.
