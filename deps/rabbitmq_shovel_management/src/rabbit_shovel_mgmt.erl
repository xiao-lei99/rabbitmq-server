%%  The contents of this file are subject to the Mozilla Public License
%%  Version 1.1 (the "License"); you may not use this file except in
%%  compliance with the License. You may obtain a copy of the License
%%  at http://www.mozilla.org/MPL/
%%
%%  Software distributed under the License is distributed on an "AS IS"
%%  basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%  the License for the specific language governing rights and
%%  limitations under the License.
%%
%%  The Original Code is RabbitMQ.
%%
%%  The Initial Developer of the Original Code is GoPivotal, Inc.
%%  Copyright (c) 2007-2014 GoPivotal, Inc.  All rights reserved.
%%

-module(rabbit_shovel_mgmt).

-behaviour(rabbit_mgmt_extension).

-export([dispatcher/0, web_ui/0]).
-export([init/1, to_json/2, content_types_provided/2, is_authorized/2]).

-import(rabbit_misc, [pget/2]).

-include_lib("rabbitmq_management/include/rabbit_mgmt.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("webmachine/include/webmachine.hrl").

dispatcher() -> [{["shovels"], ?MODULE, []}].
web_ui()     -> [{javascript, <<"shovel.js">>}].

%%--------------------------------------------------------------------

init(_Config) -> {ok, #context{}}.

content_types_provided(ReqData, Context) ->
   {[{"application/json", to_json}], ReqData, Context}.

to_json(ReqData, Context) ->
    Chs = rabbit_mgmt_db:get_all_channels(rabbit_mgmt_util:range(ReqData)),
    rabbit_mgmt_util:reply(status(Chs), ReqData, Context).

is_authorized(ReqData, Context) ->
    rabbit_mgmt_util:is_authorized_admin(ReqData, Context).

%%--------------------------------------------------------------------

status(Chs) ->
    lists:append([status(Chs, Node) || Node <- [node() | nodes()]]).

status(Chs, Node) ->
    case rpc:call(Node, rabbit_shovel_status, status, [], infinity) of
        {badrpc, {'EXIT', _}} ->
            [];
        Status ->
            [format(Node, I, Chs) || I <- Status]
    end.

format(Node, {Name, Type, Info, TS}, Chs) ->
    [{node, Node}, {timestamp, format_ts(TS)}] ++
        format_name(Type, Name) ++
        format_info(Info, Type, Name, Chs).

format_name(static,  Name)          -> [{name,  Name},
                                        {type,  static}];
format_name(dynamic, {VHost, Name}) -> [{name,  Name},
                                        {vhost, VHost},
                                        {type,  dynamic}].

format_info(starting, _Type, _Name, _Chs) ->
    [{state, starting}];

format_info({running, Props}, Type, Name, Chs) ->
    [{state, running}] ++ lookup_src_dest(Type, Name) ++
        [R || KV <-  Props,
              R  <-  [format_info_item(KV, Chs)],
              R  =/= unknown];

format_info({terminated, Reason}, _Type, _Name, _Chs) ->
    [{state,  terminated},
     {reason, print("~p", [Reason])}].

format_ts({{Y, M, D}, {H, Min, S}}) ->
    print("~w-~2.2.0w-~2.2.0w ~w:~2.2.0w:~2.2.0w", [Y, M, D, H, Min, S]).

print(Fmt, Val) ->
    list_to_binary(io_lib:format(Fmt, Val)).

format_info_item({K, B}, _Chs) when is_binary(B) ->
    {K, B};
format_info_item({K, ChPid}, Chs) when is_pid(ChPid) ->
    case rabbit_mgmt_format:strip_pids(
           [Ch || Ch <- Chs, pget(pid, Ch) =:= ChPid]) of
        [Ch] -> {K, Ch};
        []   -> unknown
    end.

lookup_src_dest(static, _Name) ->
    %% This is too messy to do, the config may be on another node and anyway
    %% does not necessarily tell us the source and destination very clearly.
    [];

lookup_src_dest(dynamic, {VHost, Name}) ->
    Def = pget(value,
               rabbit_runtime_parameters:lookup(VHost, <<"shovel">>, Name)),
    Ks = [<<"src-queue">>,  <<"src-exchange">>,  <<"src-exchange-key">>,
          <<"dest-queue">>, <<"dest-exchange">>, <<"dest-exchange-key">>],
    [{definition, [{K, V} || {K, V} <- Def, lists:member(K, Ks)]}].
