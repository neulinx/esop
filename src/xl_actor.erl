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
-export([entry/1, exit/1, react/2]).

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
%% Initialize the actor.
%% Main task of entry is ensure dependent actors preloaded.
%% Perform preload in entry action for fail-fast (synchronous return).
%%--------------------------------------------------------------------
-spec entry(actor()) -> {'ok', actor()}.
entry(Actor) ->
    process_flag(trap_exit, true),
    preload(Actor).

%%--------------------------------------------------------------------
%% Uninitialize, stop all local actors.
%%--------------------------------------------------------------------
%% Stop local links before exit.
-spec exit(actor()) -> {'stopped', actor()}.
exit(#{links := L, monitors := M} = Actor) ->
    Links = maps:fold(fun cleanup/3, L, M),
    {stopped, Actor#{monitors := #{}, links := Links}};
exit(Actor) ->
    {stopped, Actor}.

%%--------------------------------------------------------------------
%% Message process
%%--------------------------------------------------------------------
-spec react(Message :: term(), actor()) -> result().
%% Local link, try to hotfix on error.
react({'EXIT', Pid, Output}, Actor) ->
    A = checkout(Pid, Output, Actor),
    {ok, A};
%% For global link, update link with no more action.
%% todo: archive output according by link.
react({'DOWN', Monitor, process, _, _Output}, Actor) ->
    {A, _, _} = deactive(Monitor, Actor),
    {ok, A};
%% Messages with path, relay message to next hop.
%% Notice: it is a backdoor if PID in path, so remove it.
react({xlx, From, [Next | Path], Message}, Actor) ->
    %% relay to next hop
    case ensure_link(Next, Actor, true) of
        {ok, Pid, A} ->
            Pid ! {xlx, From, Path, Message},
            {ok, A};
        _Error ->
            {ok, unreachable, Actor}
    end;
react({xlx, From, [], Message}, Actor) ->
    react({xlx, From, Message}, Actor);
react({xlx, _From, Command}, Actor) ->
    try invoke(Command, Actor) of
        {ok, Result, A} ->
            {ok, {ok, Result}, A};
        Error ->
            {ok, Error, Actor}
    catch
        _: Error ->
            {ok, {error, Error}, Actor}
    end;
react(_Message, Actor) ->
    {ok, {error, unhandled}, Actor}.

invoke({get_active_link, Id}, Actor) ->
    ensure_link(Id, Actor, true);
invoke({link, Link}, Actor) ->
    ensure_link(Link, Actor, false);
invoke({link, Link, Load}, Actor) ->
    ensure_link(Link, Actor, Load);
invoke({unlink, Name}, Actor) ->
    unlink(Name, Actor);
%% default behavior is data access
invoke(Key, Actor) ->
    {ok, maps:find(Key, Actor), Actor}.

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

hotfix(ErrState, Pid, #{links := L, monitors :=M} = Actor) ->
    {A, Name, InitState} = deactive(Pid, Actor),
    Failover = maps:get(failover, A, restore),
    NewState = heal(Failover, InitState, ErrState),
    {ok, Pid} = xl_state:start_link(NewState),
    L1 = L#{Name := {InitState, Pid}},
    A#{links := L1, monitors := M#{Pid => Name}}.

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
    {ok, _, A} = ensure_link(Dep, Actor, true),  % link & load
    preload(Rest, A);
preload([], Actor) ->
    {ok, Actor};
%% Customized preload progress.
preload(Preload, Actor) when is_function(Preload) ->
    Preload(Actor).

ensure_link({Name, State}, Actor, Load) ->
    ensure_link(Name, State, Actor, Load);
ensure_link(#{gid := Gid} = State, Actor, Load) ->
    ensure_link(Gid, State, Actor, Load);
ensure_link(#{name := Name} = State, Actor, Load) ->
    ensure_link(Name, State, Actor, Load);
ensure_link(Id, Actor, Load) ->
    ensure_link(Id, Id, Actor, Load).

ensure_link(_Name, Link, #{boundary := B}, _Load)
  when B =/= opened andalso is_map(Link) ->
    %% boudary is closed, link cannot be changed.
    {error, forbidden};
ensure_link(Name, Link, #{links := L} = Actor, Load) ->
    case maps:find(Name, L) of
        error ->
            link_(Name, Link, Actor, Load);  % not registered
        {ok, {Link, Pid}} ->  % local active link
            {ok, Pid, Actor};
        {ok, {Link, Pid, _}} ->  % global active link
            {ok, Pid, Actor};
        {ok, Link} when Load ->  % registered but inactive link
            link_(Name, Link, Actor, Load);
        {ok, Link} ->  % already registered, but same data. It is ok.
            {ok, Name, Actor};
        {ok, State} when Load ->  % local inactive link
            link_(Name, State, Actor, Load);
        {ok, _Existed} ->  % Link is different, is conflict.
            {error, existed}
    end.

%% If gid is presented, it is global actor, fetch from realm keeper.
%% Or current actor acts as realm keeper if no present realm.
link_(Name, #{gid := Gid} = State, #{realm := R} = Actor, Load) ->
    g_link(Name, Gid, R, {link, {Gid, State}, Load}, Actor);
link_(Name, #{} = State, #{links := L} = Actor, true) ->
    {ok, Member} = xl_state:start_link(State),
    L1 = L#{Name => {State, Member}},
    M = maps:get(monitors, Actor, #{}),
    M1 = M#{Member => Name},
    A = Actor#{links := L1, monitors => M1},
    {ok, Member, A};
link_(Name, #{} = State, #{links := L} = Actor, false) ->
    A = Actor#{links := L#{Name => State}},
    {ok, Name, A};
link_(Name, Gid, #{realm := R} = Actor, Load) ->
    g_link(Name, Gid, R, {get_link, Gid, Load}, Actor);
link_(_N, _S, _A, _L) ->
    {error, invalid}.

g_link(Name, Gid, Realm, Command, #{links := L} = Actor) ->
    Timeout = maps:get(timeout, Actor, ?DFL_TIMEOUT),
    case xl_state:call(Realm, Command, Timeout) of
        {ok, Gid} ->  % not active
            A = Actor#{links := L#{Name => Gid}},
            {ok, Gid, A};
        {ok, Pid} ->
            Mid = monitor(process, Pid),
            M = maps:get(monitors, Actor, #{}),
            A = Actor#{links := L#{Name => {Gid, Pid, Mid}},
                       monitors := M#{Mid => Name}},
            {ok, Pid, A};
        _Error ->
            {error, fail_to_link}
    end.

%%--------------------------------------------------------------------
%% Stop, deactivate and unlink.
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

unlink(Name, #{boundary := opened, links := L} = Actor) ->
    M = maps:get(monitors, Actor, #{}),
    case maps:find(Name, L) of
        {ok, {_S, Pid}} ->  % local link
            deactive(Pid),
            L1 = maps:remove(Name, L),
            M1 = mpas:remove(Pid, M),
            {ok, unlinked, Actor#{links := L1, monitors := M1}};
        {ok, {_S, _Pid, Monitor}} ->  % global link.
            deactive(Monitor),
            L1 = maps:remove(Name, L),
            M1 = mpas:remove(Monitor, M),
            {ok, unlinked, Actor#{links := L1, monitors := M1}};
        error ->
            {error, not_found}
    end;
unlink(_Name, _Actor) ->
    {error, forbidden}.
            
%%%===================================================================
%%% Unit test
%%%===================================================================

-ifdef(TEST).

-endif.
