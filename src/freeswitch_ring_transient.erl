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
%%	The Original Code is OpenACD.
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
%%	Andrew Thompson <andrew at hijacked dot us>
%%	Micah Warren <micahw at lordnull dot com>
%%

%% @doc A transient ring channel.

-module(freeswitch_ring_transient).

-include("log.hrl").
-include("call.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

% freeswitch_ring callbacks
-export([
	init/2,
	handle_event/4,
	handle_call/4,
	handle_cast/3,
	handle_info/3,
	terminate/3,
	code_change/3
]).

% "public" api.
-export([
	complete_agent_transfer/1
]).

-record(state, {
	call :: 'undefined' | #call{},
	no_oncall_on_bridge :: 'undefined' | 'true' | 'once',
	hold :: 'hold' | 'undefined',
	oncaller :: 'undefined' | pid()
}).

%% ======
%% API
%% ======

complete_agent_transfer(Pid) ->
	gen_server:cast(Pid, complete_agent_transfer).

%% =====
%% freeswitch_ring callbacks
%% =====

%% =====
%% init
%% =====
init(_Fsref, Options) ->
	{ok, [], #state{
		call = proplists:get_value(call, Options),
		no_oncall_on_bridge = proplists:get_value(no_oncall_on_bridge, Options)
	}}.

%% =====
%% handle_call
%% =====
handle_call(_Msg, _From, _FsRef, State) ->
	{reply, invalid, State}.

%% =====
%% handle_cast
%% =====
handle_cast(complete_agent_transfer, _FsRef, #state{oncaller = Pid} = State) when is_pid(Pid) ->
	Pid ! continue,
	{noreply, State};

handle_cast({agent_state, oncall, #call{type = IsVoice}}, _FsRef, State) when IsVoice =:= voice; IsVoice =:= voicemail ->
	% bridging will happen, and all will be happy.
	{noreply, State};
handle_cast({agent_state, AState, _Data}, FsRef, State) ->
	handle_cast({agent_state, AState}, FsRef, State);
handle_cast({agent_state, _AState}, {FsNode, UUID}, State) ->
	% live fast, die young, leave a beautiful exit message.
	freeswitch:bgapi(FsNode, uuid_kill, UUID),
	{stop, normal, State};
handle_cast(_Msg, _FsRef, State) ->
	{noreply, State}.

%% =====
%% handle_info
%% =====
handle_info({stop, Reason}, _FsRef, State) ->
	{stop, Reason, State};
handle_info(_Msg, _FsRef, State) ->
	{noreply, State}.

%% =====
%% handle_event
%% =====
handle_event("CHANNEL_ANSWER", _Data, _FsRef, #state{call = undefined} = State) ->
	{noreply, State};
handle_event("CHANNEL_ANSWER", _Data, {FSNode, UUID}, #state{call = #call{type = IsVoice} = Call} = State) when IsVoice =:= voice; IsVoice =:= voicemail ->
	%% the freeswitch media will ask self() for some info,
	%% so the needs to be spawned out.
	Self = self(),
	Statedata = freeswitch_media:statedata(Call#call.source),
	Statename = proplists:get_value(statename, Statedata),
	OncallUUID = case proplists:get_value(ringuuid, Statedata) of
		undefined ->
			OcRingPid = proplists:get_value(ringchannel, Statedata),
			freeswitch_ring:get_uuid(OcRingPid);
		OncallUUIDElse ->
			OncallUUIDElse
	end,
	?DEBUG("The statename and oc uuid:  ~p; ~p", [Statename, OncallUUID]),
	Fun = fun() ->
		% there was an issue where going oncall (bridging) too quickly after
		% the answer during an agent transfer would cause sofia (freeswitch) to
		% error (RTP reinvite error).  Various solutions were tried, including
		% triggering this after park.  However, this was the most consistent
		% in resolving the issue.
		case Statename of
			Q when Q =:= inqueue; Q =:= inqueue_ringing ->
				ok;
			NotHold when NotHold =:= oncall; NotHold =:= oncall_ringing ->
				timer:sleep(2000);
			_ ->
				BridgeRes = freeswitch:api(FSNode, uuid_bridge, OncallUUID ++ " " ++ UUID),
				?INFO("agent warm transfer bridge res:  ~p", [BridgeRes]),
				SelfMon = erlang:monitor(process, Self),
				receive
					continue -> ok;
					{'DOWN', SelfMon, process, Self, Down} ->
						?DEBUG("Exiting with my parent", []),
						exit(Down);
					cancel -> exit(normal)
				end
		end,
		try gen_media:oncall(Call#call.source) of
			invalid ->
				freeswitch:api(FSNode, uuid_park, Call#call.id),
				?DEBUG("Death due to invalid oncall request", []),
				Self ! {stop, normal};
			ok ->
				ok
		catch
			exit:{noproc, _} ->
				?WARNING("~p died before I could complete the bridge", [Call#call.source]),
				freeswitch:api(FSNode, uuid_park, Call#call.id),
				?DEBUG("Death due to noproc error on oncall attempt", []),
				Self ! {stop, normal}
		end
	end,
	NoHoldList = [inqueue, inqueue_ringing, oncall, oncall_ringing],
	QOrNotHold = lists:member(Statename, NoHoldList),
	IfBridge = case {QOrNotHold, State#state.no_oncall_on_bridge} of
		{false, undefined} -> once;
		_ -> State#state.no_oncall_on_bridge
	end,
	Pid = proc_lib:spawn(Fun),
	{noreply, State#state{oncaller = Pid, no_oncall_on_bridge = IfBridge}};
handle_event("CHANNEL_ANSWER", _Data, {FsNode, UUID}, #state{call = Call} = State) ->
	% Ah, this is not a freeswitch call.  If the oncall works, I can die.
	try gen_media:oncall(Call#call.source) of
		invalid ->
			{noreply, State};
		ok ->
			freeswitch:api(FsNode, uuid_kill, UUID),
			?DEBUG("Death due to non-voice call answered", []),
			{stop, normal, State}
	catch
		exit:{noproc, _} ->
			freeswitch:api(FsNode, uuid_kill, UUID),
			?DEBUG("Death due to noproc error setting non-voice call oncall", []),
			{stop, normal, State}
	end;
handle_event("CHANNEL_BRIDGE", _Data, _FsRef, #state{no_oncall_on_bridge = true} = State) ->
	{noreply, State};
handle_event("CHANNEL_BRIDGE", _Data, _FsRef, #state{no_oncall_on_bridge = once} = State) ->
	{noreply, State#state{no_oncall_on_bridge = undefined}};
handle_event("CHANNEL_BRIDGE", _Data, {Fsnode, _UUID}, #state{call = #call{type = voice} = Call} = State) ->
	try gen_media:oncall(Call#call.source) of
		invalid ->
			freeswitch:api(Fsnode, uuid_park, Call#call.id),
			?DEBUG("Death due to invalid oncall request after bridge", []),
			{stop, normal, State};
		ok ->
			{noreply, State}
	catch
		exit:{noproc, _} ->
			?WARNING("~p died before I could complete the bridge, I die with it", [Call#call.source]),
			freeswitch:api(Fsnode, uuid_park, Call#call.id),
			{stop, normal, State}
	end;
handle_event("CHANNEL_HANGUP", _Data, _FsData, State) ->
	?NOTICE("CHANNEL_HANGUP event, exiting", []),
	{stop, "CHANNEL_HANGUP", State};
handle_event(Event, _, _, State) ->
	?INFO("Unhandled event ~s", [Event]),
	{noreply, State}.

%% =====
%% terminate
%% =====

terminate(Reason, _Fsref, _State) ->
	?NOTICE("Going down:  ~p", [Reason]),
	ok.

%% =====
%% code_change
%% =====

code_change(_oldVsn, State, _Extra) ->
	{ok, State}.

%% =====
%% internal api
%% =====
