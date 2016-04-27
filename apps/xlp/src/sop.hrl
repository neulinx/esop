%% File: sop.hrl

%%-----------------------------------------------------------
%% Data Type: person
%% where:
%%    name:  A string (default is undefined).
%%    age:   An integer (default is undefined).
%%    phone: A list of integers (default is []).
%%    dict:  A dictionary containing various information 
%%           about the person. 
%%           A {Key, Value} list (default is the empty list).
%%------------------------------------------------------------
-record(action, {entry, do, handle, exit}).
-record(asset, {data, get, put}).
-record(state, {action=#action{}, asset=#asset{}}).