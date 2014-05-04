%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc SipApp plugin callbacks default implementation

-module(nksip_callbacks).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').

-include("nksip.hrl").
-include("nksip_call.hrl").
-export([app_call/3, app_method/2]).


%% @private
-spec app_call(atom(), list(), nksip:app_id()) ->
	ok | error.

app_call(Fun, Args, AppId) ->
	case catch apply(AppId, Fun, Args) of
	    {'EXIT', Error} -> 
	        ?call_error("Error calling callback ~p: ~p", [Fun, Error]),
	        error;
	    Reply ->
	        {ok, Reply}
	end.


%% @private
app_method(#trans{method='ACK'}=UAS, #call{app_id=AppId}=Call) ->
	case catch AppId:ack({user_req, UAS, Call}) of
		noreply -> ok;
		Error -> ?call_error("Error calling callback ack/1: ~p", [Error])
	end,
	Call;

app_method(#trans{method=Method}=UAS, #call{app_id=AppId}=Call) ->
	UserReq = {user_req, UAS, Call},
	ToTag = nksip_request:to_tag(UserReq),
	Fun = case Method of
		'INVITE' when ToTag == <<>> -> invite;
		'INVITE' -> reinvite;
		'BYE' -> bye;
		'INFO' -> info;
		'OPTIONS' -> options;
		'REGISTER' -> register;
		'PRACK' -> prack;
		'SUBSCRIBE' when ToTag == <<>> -> subscribe;
		'SUBSCRIBE' -> resubscribe;
		'NOTIFY' -> notify;
		'REFER' -> refer;
		'PUBLISH' -> publish
	end,
	case catch AppId:Fun(UserReq) of
		{reply, Reply} -> 
			{reply, Reply};
		noreply -> 
			noreply;
		Error -> 
			?call_error("Error calling callback ack/1: ~p", [Error]),
			{reply, {internal_error, "SipApp Error"}}
	end.












% callback1() ->
% 	io:format("NKSIP: CALLBACK1\n"),
%     ok1.

% callback2(A) ->
% 	io:format("NKSIP: CALLBACK2(~p)\n", [A]),
%     A.

% callback3(A, B, C) ->
% 	io:format("NKSIP: CALLBACK3(~p, ~p, ~p)\n", [A, B, C]),
% 	{A,B,C}.