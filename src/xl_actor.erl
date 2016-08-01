%%%-------------------------------------------------------------------
%%% @author Gary Hai <gary@XL59.com>
%%% @copyright (C) 2016, Neulinx Platforms.
%%% @doc
%%%  Actor model implementation by graph topology.
%%% @end
%%% Created : 22 Jun 2016 by Gary Hai <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(xl_actor).

-compile({no_auto_import,[exit/1]}).
%% API
-export([entry/1, exit/1, react/2]).
-export([call/3, call/4]).

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
          'realm' => process(), % Domain keeper.
          'actor' => process(), % parent actor to hold data.
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
-type result() :: xl_state:result().
-type reply() :: xl_state:reply().
-type path() :: [process()].
%%-type from() :: {path() | process(), Tag :: identifier()}.

%%--------------------------------------------------------------------
%% Initialize the actor.
%% Main task of entry is ensure dependent actors preloaded.
%% Perform preload in entry action for fail-fast (synchronous return).
%%--------------------------------------------------------------------
-spec entry(actor()) -> {'ok', actor()}.
entry(Actor) ->
    process_flag(trap_exit, true),
    Links = maps:get(links, Actor, #{}),
    Monitors = maps:get(monitors, Actor, #{}),
    Timeout = maps:get(timeout, Actor, ?DFL_TIMEOUT),
    A = Actor#{links => Links, monitors => Monitors, timeout => Timeout},
    preload(A).

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
react({xlx, From, [], Message}, Actor) ->
    react({xlx, From, Message}, Actor);
react({xlx, From, [Next | Path], Message}, Actor) ->
    %% relay to next hop
    case ensure_load(Next, Actor) of
        {ok, Pid, A} when Path =:= [] ->
            Pid ! {xlx, From, Message},
            {ok, A};
        {ok, Pid, A} ->
            Pid ! {xlx, From, Path, Message},
            {ok, A};
        _Error ->
            {error, unreachable, Actor}
    end;
react({xlx, _, Command}, Actor) ->
    try invoke(Command, Actor) of
        {Code, Reply} ->
            {Code, Reply, Actor};
        Res ->
            Res
    catch
        C:E ->
            {error, {C, E}, Actor}
    end;
react(_Message, Actor) ->
    {ok, unhandled, Actor}.

invoke({load, Link}, Actor) ->
    ensure_load(Link, Actor);
invoke({link, Link}, Actor) ->
    ensure_link(Link, Actor);
invoke({link, Link, true}, Actor) ->
    ensure_load(Link, Actor);
invoke({link, Link, _}, Actor) ->
    ensure_link(Link, Actor);
invoke({unlink, Name} = Command, #{realm := R, timeout := T} = Actor) ->
    xl_state:call(R, Command, T),  % ignore result of realm unlink
    unlink(Name, Actor);
invoke({unlink, Name}, Actor) ->
    unlink(Name, Actor);
invoke(_, Actor) ->
    {ok, unhandled, Actor}.


%% Same as gen_server:call().
-spec call(process(), path(), Request :: term()) -> reply().
call(Process, Path, Command) ->
    call(Process, Path, Command, ?DFL_TIMEOUT).

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

%%--------------------------------------------------------------------
%% Failover, only for local link.
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

hotfix(ErrState, Pid, #{links := L, monitors := M, failover := F} = Actor) ->
    {A, Name, InitState} = deactive(Pid, Actor),
    NewState = heal(F, InitState, ErrState),
    {ok, NewPid} = spawn_actor(NewState, A),
    L1 = L#{Name := {InitState, NewPid}},
    A#{links := L1, monitors := M#{NewPid => Name}};
hotfix(_, Pid, Actor) ->
    {A, _, _} = deactive(Pid, Actor),
    A.


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
    {ok, _, A} = ensure_load(Dep, Actor),  % link & load
    preload(Rest, A);
preload([], Actor) ->
    {ok, Actor};
%% Customized preload progress.
preload(Preload, Actor) when is_function(Preload) ->
    Preload(Actor).

flat_link({Name, State}) ->
    {Name, State};
flat_link(#{gid := Gid} = State) ->
    {Gid, State};
flat_link(#{name := Name} = State) ->
    {Name, State};
flat_link(Id) ->
    {Id, undefined}.

ensure_load(Link, Actor) ->
    {Name, State} = flat_link(Link),
    ensure_link(Name, State, Actor, true).

ensure_link(Link, Actor) ->
    {Name, State} = flat_link(Link),
    ensure_link(Name, State, Actor, false).

ensure_link(Name, Link, #{links := L} = Actor, Load) ->
    B = maps:get(boundary, Actor, closed),  % default realm is closed.
    V =  maps:find(Name, L),
    case check_link(Link, V, B) of
        {ok, Id} ->
            {ok, Id, Actor};
        {link, State} ->
            link_(Name, State, Actor, Load);
        link ->
            link_(Name, Name, Actor, Load);
        Error ->
            Error
    end.

%% check boundary
check_link(_, error, Boundary) when Boundary =/= opened ->
    {error, forbidden};
check_link(Link, error, _) ->
    check_link(Link, undefined);
check_link(Link, {ok, V}, _) ->
    check_link(Link, V).

%% compare links data.
check_link(undefined, undefined) ->  %  maybe global link.
    link;
check_link(undefined, {_, Pid}) ->  % local active link
    {ok, Pid};
check_link(undefined, {_, Pid, _}) ->  % global active link
    {ok, Pid};
check_link(undefined, State) ->  % inactive link
    {link, State};
check_link(Link, undefined) ->  % not registered
    {link, Link};
check_link(Link, Link) ->  % inactive link
    {link, Link};
check_link(Link, {Link, Pid}) ->  % active local link
    {ok, Pid};
check_link(Link, {Link, Pid, _}) ->  % active global link
    {ok, Pid};
check_link(Gid, #{gid := Gid} = State) ->  % not registered global link
    {link, State};
check_link(Gid, {#{gid := Gid}, Pid}) -> % no parent, it is realm keeper.
    {ok, Pid};
check_link(_, _) ->
    {error, existed}.

%% If gid is presented, it is global actor, fetch from realm keeper.
%% Or current actor acts as realm keeper if no present realm.
link_(Name, #{gid := Gid} = State, #{realm := R} = Actor, Load) ->
    g_link(Name, Gid, R, {link, {Gid, State}, Load}, Actor);
link_(Name, #{} = State, #{links := L, monitors := M} = Actor, true) ->
    {ok, Member} = spawn_actor(State, Actor),
    L1 = L#{Name => {State, Member}},
    M1 = M#{Member => Name},
    A = Actor#{links := L1, monitors => M1},
    {ok, Member, A};
link_(Name, #{} = State, #{links := L} = Actor, false) ->
    A = Actor#{links := L#{Name => State}},
    {ok, Name, A};
link_(Name, Gid, #{realm := R} = Actor, Load) ->
    g_link(Name, Gid, R, {link, Gid, Load}, Actor);
link_(_N, _S, _A, _L) ->
    {error, invalid}.

g_link(Name, Gid, Realm, Command,
       #{links := L, monitors := M, timeout := T} = Actor) ->
    case xl_state:call(Realm, Command, T) of
        {ok, Gid} ->  % not active
            A = Actor#{links := L#{Name => Gid}},
            {ok, Gid, A};
        {ok, Pid} ->
            Mid = monitor(process, Pid),
            A = Actor#{links := L#{Name => {Gid, Pid, Mid}},
                       monitors => M#{Mid => Name}},
            {ok, Pid, A};
        _Error ->
            {error, fail_to_link}
    end.

spawn_actor(State, Actor) ->
    Realm = maps:get(realm, Actor, self()),
    xl_state:start_link(State#{realm => Realm, actor => self()}).

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
    xl_state:cast(Pid, {stop, normal});
deactive(Monitor) ->
    demonitor(Monitor).

unlink(Name, #{boundary := opened, links := L, monitors := M} = Actor) ->
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
new_actor(Data) ->
    xl_state:create(xl_actor, Data).
%% root, a->b, a->c, b->c, b->x, b->y.
g1_test() ->
    error_logger:tty(false),
    Root = new_actor(#{gid => 0, name => root, boundary => opened}),
    {ok, Ra} = xl_state:start(Root),
    X = new_actor(#{name => x}),
    C = new_actor(#{gid => 3, name => c}),
    Bl = #{c => C, x => X, y => X#{name := y}},
    B = new_actor(#{gid => 2, name => b, links => Bl}),
    Al = #{b => B, c => C},
    A = new_actor(#{gid => 1, name => a, links => Al}),
    {ok, Aa} = xl_state:call(Ra, {load, A}),
    ?assertMatch({ok, a}, xl_state:call(Aa, {get, name})),
    %% ?debugVal(xl_state:call(Ra, {get, links})),
    %% ?debugVal(xl_state:call(Aa, {get, links})),
    ?assertMatch({ok, c}, call(Aa, [c], {get, name})),
    ?assertMatch({ok, c}, call(Aa, [b, c], {get, name})),
    ?assertMatch({ok, x}, call(Aa, [b, x], {get, name})),
    xl_state:stop(Aa),
    xl_state:stop(Ra).
    
-endif.
