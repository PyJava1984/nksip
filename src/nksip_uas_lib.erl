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

%% @doc UAS Process helper functions
-module(nksip_uas_lib).
-author('Carlos Gonzalez <carlosj.gf@gmail.com>').
-export([preprocess/2, response/6]).
-include("nksip.hrl").


%% ===================================================================
%% Private
%% ===================================================================

%% @doc Preprocess an incoming request.
%% Returns `own_ack' if the request is an ACK to a [3456]xx response generated by
%% NkSip, or the preprocessed request in any other case. 
%%
%% If performs the following actions:
%% <ul>
%%  <li>Adds rport, received and transport options to Via.</li>
%%  <li>Generates a To Tag candidate.</li>
%%  <li>Performs strict routing processing.</li>
%%  <li>Updates the request if maddr is present.</li>
%%  <li>Removes first route if it is poiting to us.</li>
%% </ul>
%%

-spec preprocess(nksip:request(), binary()) ->
    nksip:request() | own_ack.

preprocess(Req, GlobalId) ->
    #sipmsg{
        class = {req, Method},
        app_id = AppId, 
        call_id = CallId, 
        to1 = {_, ToTag},
        transport = #transport{proto=Proto, remote_ip=Ip, remote_port=Port}, 
        vias = [Via|ViaR]
    } = Req,
    Received = nksip_lib:to_host(Ip, false), 
    ViaOpts1 = [{<<"received">>, Received}|Via#via.opts],
    % For UDP, we honor de rport option
    % For connection transports, we force inclusion of remote port 
    % to reuse the same connection
    ViaOpts2 = case lists:member(<<"rport">>, ViaOpts1) of
        false when Proto==udp -> ViaOpts1;
        _ -> [{<<"rport">>, nksip_lib:to_binary(Port)} | ViaOpts1 -- [<<"rport">>]]
    end,
    Via1 = Via#via{opts=ViaOpts2},
    Branch = nksip_lib:get_binary(<<"branch">>, ViaOpts2),
    ToTag1 = case ToTag of
        <<>> -> nksip_lib:hash({GlobalId, Branch});
        _ -> ToTag
    end,
    case Method=='ACK' andalso nksip_lib:hash({GlobalId, Branch})==ToTag of
        true -> 
            ?debug(AppId, CallId, "Received ACK for own-generated response", []),
            own_ack;
        false ->
            Req1 = Req#sipmsg{
                vias = [Via1|ViaR], 
                to_tag_candidate = ToTag1
            },
            preprocess_route(Req1)
    end.


%% @doc Generates a new `Response' based on a received `Request'.
%%
%% Recognized options are:
%% <ul>
%%  <li>`contact': Add Contact headers</li>
%%  <li>`make_www_auth': Generates a WWW-Authenticate header</li>
%%  <li>`make_proxy_auth': Generates a Proxy-Authenticate header</li>
%%  <li>`allow': Generates an Allow header</li>
%%  <li>`supported': Generates a Supported header</li>
%%  <li>`accept': Generates an Accept header</li>
%%  <li>`date': Generates a Date header</li>
%%  <li>`make_100rel': If present a Require: 100rel header will be included</li>
%%  <li>`{expires, non_neg_integer()}: If present generates a Event header</li>
%%  <li>`reason_phrase': Custom reason phrase</li>
%%  <li>`to_tag': If present, it will override the To tag in the request</li>
%% </ul>
%%
%% It will return the generated response:
%% <ul>
%%  <li>If code is 100, and a Timestamp header is present in the request, it is
%%      copied in the response</li>
%%  <li>For INVITE requests, it will generate automatically Support, Allow
%%      and Contact headers (if not `contact' option is present).
%%      If response code is 101-299 it will copy Record-Route headers 
%%      from the request to the response</li>
%%  <li>If the request has no To tag, the stored candidate is used</li>
%% </ul>
%%
%% It will also return the following send options:
%% <ul>
%%  <li>`contact' when the request is INVITE and no `contact' option is present
%%      or it is present in options</li>
%%  <li>`secure' if request-uri, first route, or Contact (if no route), are `sips'</li>
%%  <li>`make_rseq' must generate a RSeq header</li>
%% </ul>
%%
-spec response(nksip:request(), nksip:response_code(), [nksip:header()], 
                nksip:body(), nksip_lib:proplist(), nksip_lib:proplist()) -> 
    {ok, nksip:response(), nksip_lib:proplist()} | {error, Error}
    when Error :: invalid_contact | invalid_content_type | invalid_require | 
                  invalid_reason | invalid_service_route.

response(Req, Code, Headers, Body, Opts, AppOpts) ->
    try 
        response2(Req, Code, Headers, Body, Opts, AppOpts)
    catch
        throw:Error -> {error, Error}
    end.


%% @private
-spec response2(nksip:request(), nksip:response_code(), [nksip:header()], 
                nksip:body(), nksip_lib:proplist(), nksip_lib:proplist()) -> 
    {ok, nksip:response(), nksip_lib:proplist()}.

response2(Req, Code, Headers, Body, Opts, AppOpts) ->
    #sipmsg{
        class = {req, Method},
        ruri = RUri,
        dialog_id = DialogId,
        call_id = CallId,
        vias = [LastVia|_] = Vias,
        from = {#uri{domain=FromDomain}, _},
        to1 = {To, ToTag}, 
        contacts = ReqContacts,
        routes = ReqRoutes,
        headers = ReqHeaders, 
        to_tag_candidate = ToTagCandidate,
        require = ReqRequire,
        supported = ReqSupported,
        expires = ReqExpires
    } = Req, 
    case Code > 100 of
        true when Method=='INVITE'; Method=='UPDATE'; 
                  Method=='SUBSCRIBE'; Method=='REFER' ->
            MakeAllow = MakeSupported = true;
        _ ->
            MakeAllow = lists:member(allow, Opts),
            MakeSupported = lists:member(supported, Opts)
    end,
    HeaderOps = [
        case Code of
            100 ->
                case nksip_sipmsg:header(Req, <<"timestamp">>, integers) of
                    [Time] -> {single, <<"timestamp">>, Time};
                    _ -> none
                end;
            _ ->
                none
        end,
        case nksip_lib:get_value(make_www_auth, Opts) of
            undefined -> 
                none;
            from -> 
                {multi, <<"www-authenticate">>, 
                    nksip_auth:make_response(FromDomain, Req)};
            Realm -> 
                {multi, <<"www-authenticate">>, 
                    nksip_auth:make_response(Realm, Req)}
        end,
        case nksip_lib:get_value(make_proxy_auth, Opts) of
            undefined -> 
                none;
            from -> 
                {multi, <<"proxy-authenticate">>,
                    nksip_auth:make_response(FromDomain, Req)};
            Realm -> 
                {multi, <<"proxy-authenticate">>,
                    nksip_auth:make_response(Realm, Req)}
        end,
        case MakeAllow of
            true -> 
                Allow = case lists:member(registrar, AppOpts) of
                    true -> <<(?ALLOW)/binary, ",REGISTER">>;
                    false -> ?ALLOW
                end,
                {default_single, <<"allow">>, Allow};
            false -> 
                none
        end,
        case lists:member(accept, Opts) of
            true -> 
                Accept = nksip_lib:get_value(accept, AppOpts, ?ACCEPT),
                {default_single, <<"accept">>, nksip_unparse:token(Accept)};
            false -> 
                none
        end,
        case lists:member(date, Opts) of
            true -> {default_single, <<"date">>, nksip_lib:to_binary(
                                                httpd_util:rfc1123_date())};
            false -> none
        end,
        % Copy Record-Route from Request
        if
            Code>100 andalso Code<300 andalso
            (Method=='INVITE' orelse Method=='NOTIFY') ->
                {multi, <<"record-route">>, 
                        proplists:get_all_values(<<"record-route">>, ReqHeaders)};
            true ->
                none
        end,
        % Copy Path from Request
        case Code>=200 andalso Code<300 andalso Method=='REGISTER' of
            true ->
                {multi, <<"path">>, 
                        proplists:get_all_values(<<"path">>, ReqHeaders)};
            false ->
                 none
        end,
        case nksip_lib:get_value(reason, Opts) of
            undefined ->
                [];
            Reason1 ->
                case nksip_unparse:error_reason(Reason1) of
                    error -> throw(invalid_reason);
                    Reason2 -> {default_single, <<"reason">>, Reason2}
                end
        end,
        case 
            Code>=200 andalso Code<300 andalso Method=='REGISTER' andalso
            nksip_lib:get_value(service_route, Opts, false) 
        of
            false ->
                [];
            ServiceRoute1 ->
                case nksip_parse:uris(ServiceRoute1) of
                    error -> throw(invalid_service_route);
                    ServiceRoute2 -> {default_single, <<"service-route">>, ServiceRoute2}
                end
        end
    ],
    RespHeaders = nksip_headers:update(Headers, HeaderOps),
    % Get To1 and ToTag1 
    % If to_tag is present in Opts, it takes priority. Used by proxy server
    % when it generates a 408 response after a remote party has already sent a 
    % response
    case nksip_lib:get_binary(to_tag, Opts) of
        _ when Code < 101 ->
            ToTag1 = <<>>,
            ToOpts1 = lists:keydelete(<<"tag">>, 1, To#uri.ext_opts),
            To1 = To#uri{ext_opts=ToOpts1};
        <<>> ->
            % To tag is not forced
            case ToTag of
                <<>> ->
                    % The request has no previous To tag
                    case ToTagCandidate of
                        <<>> ->
                            ToTag1 = nksip_lib:hash(make_ref()),
                            To1 = To#uri{ext_opts=[{<<"tag">>, ToTag1}|To#uri.ext_opts]};
                        ToTag1 ->
                            % We have prepared a To tag in preprocess/2
                            To1 = To#uri{ext_opts=[{<<"tag">>, ToTag1}|To#uri.ext_opts]}
                    end;
                _ ->
                    % The request already has a To tag
                    To1 = To,
                    ToTag1 = ToTag
            end;
        ToTag1 ->
            ToOpts1 = lists:keydelete(<<"tag">>, 1, To#uri.ext_opts),
            To1 = To#uri{ext_opts=[{<<"tag">>, ToTag1}|ToOpts1]}
    end,
    RespContentType = case nksip_lib:get_binary(content_type, Opts) of
        <<>> when is_record(Body, sdp) -> 
            {<<"application/sdp">>, []};
        <<>> when not is_binary(Body) -> 
            {<<"application/nksip.ebf.base64">>, []};
        <<>> -> 
            undefined;
        ContentTypeSpec -> 
            case nksip_parse:tokens(ContentTypeSpec) of
                [ContentTypeToken] -> ContentTypeToken;
                error -> throw(invalid_content_type)
            end
    end,
    RespSupported = case MakeSupported of
        true -> nksip_lib:get_value(supported, AppOpts, ?SUPPORTED);
        false -> []
    end,
    RespRequire1 = case nksip_lib:get_value(require, Opts) of
        undefined -> 
            [];
        RR1 ->
            case nksip_parse:tokens(RR1) of
                error -> throw(invalid_require);
                RR2 -> [T || {T, _}<-RR2]
            end
    end,
    Reliable = case Method=='INVITE' andalso Code>100 andalso Code<200 of
        true ->
            case lists:member(<<"100rel">>, ReqRequire) of
                true ->
                    true;
                false ->
                    case lists:member(<<"100rel">>, ReqSupported) of
                        true -> lists:member(make_100rel, Opts);
                        false -> false
                    end
            end;
        false ->
            false
    end,
    RespRequire2 = case Reliable of
        true -> [<<"100rel">>|RespRequire1];
        false -> RespRequire1
    end,
    Secure = case RUri#uri.scheme of
        sips ->
            true;
        _ ->
            case ReqRoutes of
                [#uri{scheme=sips}|_] -> 
                    true;
                [] ->
                    case ReqContacts of
                        [#uri{scheme=sips}|_] -> true;
                        _ -> false
                    end;
                _ ->
                    false
            end
    end,
    ReasonPhrase = nksip_lib:get_binary(reason_phrase, Opts),
    RespContacts = case nksip_lib:get_value(contact, Opts) of
        undefined ->
            [];
        RespContacts0 ->
            case nksip_parse:uris(RespContacts0) of
                error -> throw(invalid_contact);
                RespContacts1 -> RespContacts1
            end
    end,
    Expires = case nksip_lib:get_value(expires, Opts) of
        OptExpires when is_integer(OptExpires), OptExpires>=0 -> 
            case Method of 
                'SUBSCRIBE' when is_integer(ReqExpires), Code>=200, Code<300 -> 
                    min(ReqExpires, OptExpires);
               _ ->
                    OptExpires
            end;
        _ when Method=='SUBSCRIBE', is_integer(ReqExpires), Code>=200, Code<300 -> 
            ReqExpires;
        _ when Method=='SUBSCRIBE' ->
            ?DEFAULT_EVENT_EXPIRES;
        _ ->
            undefined
    end,
    Event = case 
        Method=='SUBSCRIBE' orelse Method=='NOTIFY' orelse Method=='PUBLISH'
    of
        true -> Req#sipmsg.event;
        _ -> undefined
    end,
    RespVias = case Code of
        100 -> [LastVia];
        _ -> Vias
    end,
    % Transport is copied to the response
    Resp = Req#sipmsg{
        id = nksip_sipmsg:make_id(resp, CallId),
        class = {resp, Code, ReasonPhrase},
        dialog_id = DialogId,
        vias = RespVias,
        to1 = {To1, ToTag1},
        forwards = 70,
        cseq = setelement(2, Req#sipmsg.cseq, Method),
        routes = [],
        contacts = RespContacts,
        headers = RespHeaders,
        content_type = RespContentType,
        supported = RespSupported,
        require = RespRequire2,
        expires = Expires,
        event = Event,
        body = Body
    },
    SendOpts = lists:flatten([
        case lists:member(contact, Opts) of
            true when Code>100 -> 
                contact;
            false when Code>100 andalso 
                RespContacts==[] andalso
                (Method=='INVITE' orelse Method=='SUBSCRIBE' orelse 
                 Method=='REFER') ->
                contact;
            _ -> 
                []
        end,
        case Secure of
            true -> secure;
            _ -> []
        end,
        case Reliable of
            true -> make_rseq;
            false -> []
        end
    ]),
    {ok, Resp, SendOpts}.


%% @private Process RFC3261 16.4
-spec preprocess_route(nksip:request()) ->
    nksip:request().

preprocess_route(Request) ->
    Request1 = strict_router(Request),
    _Request2 = ruri_has_maddr(Request1).
    % remove_local_route(Request2).



%% ===================================================================
%% Internal
%% ===================================================================


%% @private If the Request-URI has a value we have placed on a Record-Route header, 
% change it to the last Route header and remove it. This gets back the original 
% RUri "stored" at the end of the Route header when proxing through a strict router
% This could happen if
% - in a previous request, we added a Record-Route header with our ip
% - the response generated a dialog
% - a new in-dialog request has arrived from a strict router, that copied our Record-Route
%   in the ruri
strict_router(#sipmsg{app_id=AppId, ruri=RUri, call_id=CallId, 
                      routes=Routes}=Request) ->
    case 
        nksip_lib:get_value(<<"nksip">>, RUri#uri.opts) /= undefined 
        andalso nksip_transport:is_local(AppId, RUri) of
    true ->
        case lists:reverse(Routes) of
            [] ->
                Request;
            [RUri1|RestRoutes] ->
                ?notice(AppId, CallId, 
                        "recovering RURI from strict router request", []),
                Request#sipmsg{ruri=RUri1, routes=lists:reverse(RestRoutes)}
        end;
    false ->
        Request
    end.    


%% @private If RUri has a maddr address that corresponds to a local ip and has the 
% same transport class and local port than the transport, change the Ruri to
% this address, default port and no transport parameter
ruri_has_maddr(#sipmsg{
                    app_id = AppId, 
                    ruri = RUri, 
                    transport=#transport{proto=Proto, local_port=LPort}
                } = Request) ->
    case nksip_lib:get_binary(<<"maddr">>, RUri#uri.opts) of
        <<>> ->
            Request;
        MAddr -> 
            case nksip_transport:is_local(AppId, RUri#uri{domain=MAddr}) of
                true ->
                    case nksip_parse:transport(RUri) of
                        {Proto, _, LPort} ->
                            RUri1 = RUri#uri{
                                port = 0,
                                opts = nksip_lib:delete(RUri#uri.opts, 
                                                        [<<"maddr">>, <<"transport">>])
                            },
                            Request#sipmsg{ruri=RUri1};
                        _ ->
                            Request
                    end;
                false ->
                    Request
            end
    end.


% %% @private Remove top routes if reached
% remove_local_route(#sipmsg{app_id=AppId, routes=Routes}=Request) ->
%     case Routes of
%         [] ->
%             Request;
%         [Route|RestRoutes] ->
%             case nksip_transport:is_local(AppId, Route) of
%                 true -> remove_local_route(Request#sipmsg{routes=RestRoutes});
%                 false -> Request
%             end 
%     end.


