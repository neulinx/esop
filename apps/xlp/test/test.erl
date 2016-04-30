%%%-------------------------------------------------------------------
%%% @author Gary Hai <gary@XL59.com>
%%% @copyright (C) 2013, Gary Hai
%%% @doc
%%%
%%% @end
%%% Created : 20 Jul 2013 by Gary Hai <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(test).

-include_lib("eunit/include/eunit.hrl").

main_test() ->
    ?assert({ok, 5} =:= {ok, 5}).
