%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is Spice Telephony.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <athompson at spicecsm dot com>
%%	Micah Warren <mwarren at spicecsm dot com>
%%

%% @doc Stat tracker and monitoring gen_leader module.  A combination of the cdr handler
%% and cpx_supervisor.  This handles health stats, and non-process monitoring.

-module(cpx_monitor).
-author(micahw).

-behaviour(gen_leader).

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type(parent() :: 'none' | string()).
-type(health_type() :: 'system' | 'node' | 'queue' | 'agent' | 'media').
-type(health_key() :: {health_type(), Name :: string() | atom()}).
-type(health_details() :: {string() | atom(), integer()}).
-type(other_details() :: {string() | atom(), any()}).
-type(health_tuple() :: {health_key(), parent(), health_details(), other_details()}).

-include("log.hrl").

%% API
-export([
	start_link/1,
	start/1,
	stop/0
	]).

%% gen_server callbacks
-export([init/1, 
	elected/3,
	surrendered/3,
	handle_DOWN/3,
	handle_leader_call/4,
	handle_leader_cast/3,
	from_leader/3,
	handle_call/4, 
	handle_cast/3, 
	handle_info/2,
	terminate/2, 
	code_change/4]).

-record(state, {
	nodes = [] :: [atom()],
	monitoring = [] :: [atom()],
	down = [] :: [atom()],
	auto_restart_mnesia = true :: 'false' | 'false',
	status = stable :: 'stable' | 'merging' | 'split',	
	splits = [] :: [{atom(), integer()}],
	merge_status = none :: 'none' | any(),
	merging = none :: 'none' | [atom()],
	ets :: any()
}).

-type(state() :: #state{}).
-define(GEN_LEADER, true).
-include("gen_spec.hrl").

%%====================================================================
%% API
%%====================================================================

-type(node_opt() :: {nodes, [atom()] | atom()}).
-type(auto_restart_mnesia_opt() :: 'auto_restart_mnesia' | {'auto_restart_mnesia', bool()}).
-type(option() :: [node_opt() | auto_restart_mnesia_opt()]).
-type(options() :: [option()]).
%% @doc Start the monitor using the passed options.<ul>
%% <li>nodes :: Nodes to monitor, multiple uses append new values.</li>
%% <li>auto_restart_mnesia :: if set to true, this will restart mnesia after
%% a merge when recoving from a net-split.  Otherwise mnesia must be started
%% manuall.</li>
%% </ul>
-spec(start_link/1 :: (Args :: options()) -> {'ok', pid()}).
start_link(Args) ->
	Nodes = lists:flatten(proplists:get_all_values(nodes, Args)),
	?DEBUG("nodes:  ~p", [Nodes]),
    gen_leader:start_link(?MODULE, Nodes, [], ?MODULE, Args, []).

%% @doc See {@link start_link/1}
-spec(start/1 :: (Args :: options()) -> {'ok', pid()}).
start(Args) ->
	Nodes = lists:flatten(proplists:get_all_values(nodes, Args)),
	?DEBUG("nodes:  ~p", [Nodes]),
	gen_leader:start(?MODULE, Nodes, [], ?MODULE, Args, []).

%% @doc Stops the monitor.
-spec(stop/0 :: () -> any()).
stop() ->
	gen_leader:call(?MODULE, stop).

%% @doc Creates a health entry into the ets table using the given params.
%% If there is an entry with the given name already, it is updated with the
%% passed params.  Returns 'ok' immediately.
-spec(set/4 :: (Key :: health_key() | string(), Parent :: string(), Health :: health_details(), Other :: other_details()) -> 'ok').
set({Node, Name} = Key, Parent, Health, Other) ->
	gen_leader:cast(?MODULE, {set, {Key, Parent, Health, Other}});
set(Name, Parent, Health, Other) ->
	set({node(), Name}, Parent, Health, Other).

%% @Gets all the records of the given type from the ets
-spec(get/1 :: (Type :: health_type()) -> {'ok', [health_tuple()]}).
get(Type) ->
	gen_leader:call(?MODULE, {get, Type}).

%% @doc Give the three numbers min, goal, and max, calculate a number from
%% 0 to 100 indicating how 'healthy' X is.  Values at or below Min are 0, at or
%% above Max are set to 100.
-spec(health/4 :: (Min :: float(), Goal :: float(), Max :: float(), X :: float()) -> float()).
health(Min, Goal, Max, X) when Min =< Goal, Goal =< Max ->
	case {X =< Min, X >= Max, X == Goal} of
		{true, _, _} ->
			0.0;
		{_, true, _} ->
			100.0;
		{_, _, true} ->
			50.0;
		{false, false, false} ->
			case X < Goal of
				true ->
					Range = Goal - Min,
					Ratio = (Goal - X) / Range,
					Ratio * 50;
				false ->
					Range = Max - Goal,
					Ratio = (X - Goal) / Range,
					Ratio * 50 + 50
			end
	end.
			
			
%%====================================================================
%% gen_server callbacks
%%====================================================================
%% @hidden
init(Args) when is_list(Args) ->
	process_flag(trap_exit, true),
	Nodes = lists:flatten(proplists:get_all_values(nodes, Args)),
	Mons = Nodes,
	lists:foreach(fun(N) -> monitor_node(N, true) end, Mons),
	Tid = ets:new(?MODULE, []),
    {ok, #state{
		nodes = Nodes, 
		monitoring = Mons,
		auto_restart_mnesia = proplists:get_value(auto_restart_mnesia, Args, true),
		ets = Tid
	}}.


%% @hidden
elected(State, Election, Node) -> 
	?INFO("elected by ~w", [Node]),
	% what was down and is now up?
	% TODO extend this to do more than agent_auth
	Edown = gen_leader:down(Election),
	Foldf = fun({N, T}, {Up, Down}) ->
		case lists:member(N, Edown) of
			true ->
				{Up, [{N, T} | Down]};
			false ->
				{[{N, T} | Up], Down}
		end
	end,
	{Merge, Stilldown} = lists:foldl(Foldf, {[], []}, State#state.splits),
	Findoldest = fun({_N, T}, Time) when T > Time ->
			T;
		({_N, T}, Time) ->
			Time
	end,
	case Merge of
		[] ->
			{ok, ok, State};
		_Else ->
			Oldest = lists:foldl(Findoldest, 0, Merge),
			Mergenodes = lists:map(fun({N, _T}) -> N end, Merge),
			P = spawn_link(agent_auth, merge, [[node() | Mergenodes], Oldest, self()]),
			Qspawn = spawn_link(call_queue_config, merge, [[node() | Mergenodes], Oldest, self()]),
			Cdrspawn = spawn_link(cdr, merge, [[node() | Mergenodes], Oldest, self()]),
			?DEBUG("spawned for agent_auth:  ~p", [P]),
			?DEBUG("Spawned for call_queue_config:  ~w", [Qspawn]),
			?DEBUG("Spawned for cdr:  ~w", [Cdrspawn]),
			{ok, ok, State#state{status = merging, merge_status = dict:new(), merging = Mergenodes}}
	end.

%% @hidden
surrendered(State, _LeaderState, _Election) -> 
	{ok, State}.
	
%% @hidden
handle_DOWN(Node, State, _Election) ->
	Newsplits = case proplists:get_value(Node, State#state.splits) of
		undefined ->
			[{Node, util:now()} | State#state.splits];
		_Time ->
			State#state.splits
	end,
	{ok, State#state{splits = Newsplits}}.

%% @hidden
handle_leader_call(Message, From, State, _Election) ->
	?WARNING("received unexpected leader_call ~p from ~p", [Message, From]),
	{reply, ok, State}.

%% @hidden
handle_leader_cast(Message, State, Election) ->
	?WARNING("received unexpected leader_cast ~p", [Message]),
	{noreply, State}.

%% @hidden
from_leader(_Msg, State, _Election) -> 
	?DEBUG("Stub from leader.", []),
	{ok, State}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%--------------------------------------------------------------------
%% @hidden
handle_call({get, What}, _From, #state{ets = Tid} = State, _Election) ->
	Pattern = {{What, '_'}, '_', '_', '_'},
	Results = ets:match_object(Tid, Pattern),
	{reply, {ok, Results}, State};
handle_call(stop, _From, State, Election) ->
	{stop, normal, ok, State};
handle_call(_Request, _From, State, Election) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%--------------------------------------------------------------------
%% @hidden
handle_cast({set, Entry}, #state{ets = Tid} = State, _Election) when is_tuple(Entry), size(4) ->
	ets:insert(Tid, Entry),
	{noreply, State};
handle_cast(_Request, State, _Election) -> 
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%--------------------------------------------------------------------
%% @hidden
handle_info({merge_complete, Mod, _Recs}, #state{merge_status = none, status = Status}= State) when Status == stable; Status == split ->
	?INFO("Prolly a late merge complete from ~w.", [Mod]),
	{noreply, State};
handle_info({merge_complete, Mod, Recs}, #state{status = merging} = State) ->
	Newmerged = dict:store(Mod, Recs, State#state.merge_status),
	case merge_complete(Newmerged) of
		true ->
			write_rows(Newmerged),
			case State#state.auto_restart_mnesia of
				true ->
					P = restart_mnesia(State#state.monitoring -- [node()]),
					?DEBUG("process to restart mnesia:  ~p", [P]);
				false ->
					ok
			end,
			case State#state.down of
				[] ->
					{noreply, State#state{status = stable, merging = [], merge_status = none}};
				_Else ->
					{noreply, State#state{status = split, merging = [], merge_status = none}}
			end;
		false ->
			{noreply, State#state{merge_status = Newmerged}}
	end;
handle_info({'EXIT', From, Reason}, State) ->
	?INFO("~p said it died due to ~p.", [From, Reason]),
	{noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
%% @hidden
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
%% @hidden
code_change(_OldVsn, State, _Election, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

restart_mnesia(Nodes) ->
	F = fun() ->
		?WARNING("automatically restarting mnesia on formerly split nodes: ~p", [Nodes]),
		lists:foreach(fun(N) -> 
			case net_adm:ping(N) of
				pong ->
					S = rpc:call(N, mnesia, stop, [], 1000), 
					?DEBUG("stoping mnesia on ~w got ~p", [N, S]),
					G = rpc:call(N, mnesia, start, [], 1000),
					?DEBUG("Starging mnesia on ~w got ~p", [N, G]);
				pang ->
					?ALERT("Not restarting mnesia on ~w, it's not pingable!", [N])
			end
		end, Nodes)
	end,
	spawn_link(F).

recover(Node) ->
	gen_server:cast(?MODULE, {recover, Node}).

recovery_watch(Node) ->
	monitor_node(Node, false),
	receive
		{nodedown, Node} ->
			timer:send_after(1000, check)
	after 100 ->
		recover(Node),
		ok
	end,
	check_loop(Node).

check_loop(Node) ->
	receive
		check ->
			recovery_watch(Node); 
		_Otherwise -> 
			check_loop(Node)
	end.
	
merge_complete(Dict) ->
	% TODO extend this to more than just agent_auth
	Agent = case dict:find(agent_auth, Dict) of
		error ->
			false;
		{ok, waiting} ->
			false;
		{ok, _AgentRows} ->
			true
	end,
	Queue = case dict:find(call_queue_config, Dict) of
		error ->
			false;
		{ok, waiting} ->
			false;
		{ok, _QueueRows} ->
			true
	end,
	Cdr = case dict:find(cdr, Dict) of
		error ->
			false;
		{ok, waiting} ->
			false;
		{ok, _Cdrrows} ->
			true
	end,
	case {Agent, Queue, Cdr} of
		{true, true, true} ->
			true;
		_Else ->
			false
	end.

write_rows(Dict) ->
	write_rows_loop(dict:to_list(Dict)).

write_rows_loop([]) ->
	?DEBUG("No more to write.", []),
	ok;
write_rows_loop([{_Mod, Recs} | Tail]) ->
	?DEBUG("Writing ~p to mnesia", [Recs]),
	F = fun() ->
		lists:foreach(fun(R) -> mnesia:write(R) end, Recs)
	end,
	mnesia:transaction(F),
	write_rows_loop(Tail).	

-ifdef(EUNIT).

health_test_() ->
	[{"straight translations",
	fun() ->
		?assertEqual(50.0, health(0, 50, 100, 50)),
		?assertEqual(0.0, health(0, 50, 100, 0)),
		?assertEqual(100.0, health(0, 50, 100, 100)),
		?assertEqual(25.0, health(0, 50, 100, 25))
	end},
	{"lopsied",
	fun() ->
		?assertEqual(50.0, health(0, 70, 100, 70)),
		?assertEqual(75.0, health(0, 8, 10, 9)),
		?assertEqual(25.0, health(0, 8, 10, 4))
	end},
	{"lopsided the other way",
	fun() ->
		?assertEqual(50.0, health(0, 3, 10, 3)),
		?assertEqual(25.0, health(0, 2, 10, 1)),
		?assertEqual(75.0, health(0, 4, 10, 7))
	end}].
	
multinode_test_() ->
	{foreach,
	fun() ->
		[_Name, Host] = string:tokens(atom_to_list(node()), "@"),
		Master = list_to_atom(lists:append("master@", Host)),
		Slave = list_to_atom(lists:append("slave@", Host)),
		slave:start(net_adm:localhost(), master, " -pa debug_ebin"),
		slave:start(net_adm:localhost(), slave, " -pa debug_ebin"),
		mnesia:stop(),
		
		mnesia:change_config(extra_db_nodes, [Master, Slave]),
		mnesia:delete_schema([node(), Master, Slave]),
		mnesia:create_schema([node(), Master, Slave]),
		
		cover:start([Master, Slave]),
		
		rpc:call(Master, mnesia, start, []),
		rpc:call(Slave, mnesia, start, []),
		mnesia:start(),
		
		mnesia:change_table_copy_type(schema, Master, disc_copies),
		mnesia:change_table_copy_type(schema, Slave, disc_copies),
		
		rpc:call(Master, agent_auth, start, []),
		rpc:call(Slave, agent_auth, start, []),
		
		{Master, Slave}
	end,
	fun({Master, Slave}) ->
		rpc:call(Master, agent_auth, stop, []),
		rpc:call(Slave, agent_auth, stop, []),
		cover:stop([Master, Slave])
	end,
	[fun({Master, Slave}) ->
		{"Happy fun start!",
		fun() ->
			Mrez = rpc:call(Master, cpx_monitor, start, [[{nodes, [Master, Slave]}]]),
			Srez = rpc:call(Slave, cpx_monitor, start, [[{nodes, [Master, Slave]}]]),
			?INFO("Mrez  ~p", [Mrez]),
			?INFO("Srez ~p", [Srez]),
			?assertNot(Mrez =:= Srez),
			?assertMatch({ok, _Pid}, Mrez),
			?assertMatch({ok, _Pid}, Srez)
		end}
	end]}.
	
-endif.

