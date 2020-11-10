%% top level handler for incoming http2 requests received via chatterbox lib
%% the parent application is required to set this module as the chatterbox stream callback module
%% this is done by setting the chatterbox env var stream_callback_mod
%% chatterbox will then callback to this module for all incoming http2 requests
%% chatterbox also allows options to be specified which will be passed to this module as part of this init callback
%% This is done by specifying a proplist value for the chatterbox stream_callback_opts env var
%% lib_http2_handler, requires this proplist to contain the following
%% http2_handler_routing_fun: a fun which takes in a table of routes and maps request paths to an application level callback module
%% http2_client_ref_header_name: a binary which identifies an expected header in incoming client http requests whose value will be used as a client ref

-module(lib_http2_stream).

-behaviour(h2_stream).

-include("../include/http2_handler.hrl").

-type action() ::
    {send_headers, Headers :: hpack:headers()}
    | {send_body, Data :: iodata(), IsEndStream :: boolean()}.

-type actions() :: [action()].

-type validation() ::
    {Header :: binary(), CheckValidFun :: function(), ErrorRespCode :: binary(),
        ErrorRespBody :: binary()}.

-type validations() :: [validation()].

-export_type([validation/0, validations/0]).
-export_type([action/0, actions/0]).

%% ------------------------------------------------------------------
%% chatterbox h2_stream exports
%% ------------------------------------------------------------------
-export([
    init/3,
    on_receive_request_headers/2,
    on_send_push_promise/2,
    on_receive_request_data/2,
    on_request_end_stream/1,
    handle_info/2
]).

%% ------------------------------------------------------------------
%% chatterbox h2_stream callbacks
%% ------------------------------------------------------------------
-spec init(pid(), stream_id(), list()) -> {ok, any()}.
init(ConnPid, StreamId, Opts) ->
    lager:debug("init packet handler for connection ~p and streamid ~p with opts: ~p", [
        ConnPid,
        StreamId,
        Opts
    ]),
    %% get options passed in from the application layer
    HandlerRoutingFun = proplists:get_value(http2_handler_routing_fun, Opts),
    ClientRefHeader = proplists:get_value(http2_client_ref_header_name, Opts),

    AppData = proplists:get_value(http2_app_data, Opts, #{}),
    {ok, #state{
        stream_id = StreamId,
        conn_pid = ConnPid,
        app_data = AppData,
        handler_routing_fun = HandlerRoutingFun,
        client_ref_header_name = ClientRefHeader
    }}.

-spec on_receive_request_headers(
    Headers :: hpack:headers(),
    CallbackState :: any()
) -> {ok, NewState :: any()}.
on_receive_request_headers(
    Headers,
    State = #state{
        conn_pid = ConnPid,
        stream_id = StreamId,
        client_ref_header_name = ClientRefHeader,
        handler_routing_fun = HandlerFun
    }
) ->
    %% get the client ref if set in the headers, will be used for logging/tracing
    ClientRef = proplists:get_value(ClientRefHeader, Headers),
    ?LOGGER(debug, ClientRef, StreamId, "received request headers ~p", [
        Headers
    ]),
    %% get the path header and use this to identify the upstream handler module
    {Route, QueryParams} = decode_path(proplists:get_value(<<":path">>, Headers)),
    %% get the request method
    Method = proplists:get_value(<<":method">>, Headers),
    NewState = State#state{
        method = Method,
        client_ref = ClientRef,
        route = Route,
        query_params = QueryParams
    },
    case HandlerFun(Route) of
        {ok, Handler} when is_atom(Handler) ->
            %% great, we have a handler for this path
            %% if the client is presenting a cert we will copy this to our state
            ClientCert =
                case h2_connection:get_peercert(ConnPid) of
                    {ok, Cert} -> Cert;
                    _ -> undefined
                end,
            NewState1 = NewState#state{
                peer_cert = ClientCert,
                handler = Handler,
                client_ref = ClientRef,
                request_headers = Headers,
                route = Route
            },
            NewState2 = validate_request_headers(Headers, Handler:validations(), NewState1),
            Result = ?IF_EXPORTED(
                Handler,
                handle_on_receive_request_headers,
                3,
                [Method, Headers, NewState2],
                {ok, NewState2}
            ),
            handle_result(Result);
        {error, _Reason} ->
            {ok, NewState#state{
                request_valid = false,
                resp_error_code = <<"404">>,
                resp_error_msg = <<"invalid request">>
            }}
    end.

-spec on_send_push_promise(
    Headers :: hpack:headers(),
    CallbackState :: any()
) -> {ok, NewState :: any()}.
on_send_push_promise(_Headers, State) -> {ok, State}.

-spec on_receive_request_data(
    iodata(),
    CallbackState :: any()
) -> {ok, NewState :: any()}.
on_receive_request_data(
    Data,
    State = #state{
        handler = undefined,
        client_ref = ClientRef,
        stream_id = StreamId
    }
) ->
    ?LOGGER(
        debug,
        ClientRef,
        StreamId,
        "received data whilst handler is not set, most like invalid path, ignoring ~p",
        [
            Data
        ]
    ),
    %% if we hit here, we prob have an invalid handler
    %% set request_valid to false, a response will be returned as part of on_request_end_stream
    {ok, State#state{request_valid = false}};
on_receive_request_data(
    Data,
    State = #state{
        handler = Handler,
        method = Method,
        client_ref = ClientRef,
        stream_id = StreamId
    }
) ->
    ?LOGGER(debug, ClientRef, StreamId, "received data ~p pushing to handler ~p", [
        Data,
        Handler
    ]),
    Result = ?IF_EXPORTED(
        Handler,
        handle_on_receive_request_data,
        3,
        [Method, Data, State],
        {ok, State}
    ),
    handle_result(Result).

-spec on_request_end_stream(
    CallbackState :: any()
) -> {ok, NewState :: any()}.
on_request_end_stream(
    State = #state{
        handler = undefined,
        resp_error_code = RespErrorCode,
        resp_error_msg = RespErrorMsg
    }
) ->
    %% no handler is set, so we must have an invalid route
    %% return the error code set in our state
    ResponseHeaders = [{<<":status">>, RespErrorCode}],
    ok = send_headers(ResponseHeaders, State),
    ok = send_body(RespErrorMsg, true, State),
    {ok, State};
on_request_end_stream(
    State = #state{
        request_valid = false,
        resp_error_code = RespErrorCode,
        resp_error_msg = RespErrorMsg
    }
) ->
    %% the request is marked as invalid
    %% likely failed to pass header validations, unsupported method for example
    %% return the error code set in our state
    %% NOTE: not pushing up to the handler, just returning the error and be done with it
    %% only pushing successful requests to the handler
    %% this is to reduce boilerplate but if we need it in the handler, fix it here
    ResponseHeaders = [{<<":status">>, RespErrorCode}],
    ok = send_headers(ResponseHeaders, State),
    ok = send_body(RespErrorMsg, true, State),
    {ok, State};
on_request_end_stream(
    State = #state{
        handler = Handler,
        method = Method,
        stream_id = StreamId,
        client_ref = ClientRef
    }
) ->
    ?LOGGER(debug, ClientRef, StreamId, "received end_stream, pushing to handler ~p", [Handler]),
    Result = Handler:handle_on_request_end_stream(Method, State),
    handle_result(Result).

%% ------------------------------------------------------------------
%% info msg callbacks are pushed to handler
%% ------------------------------------------------------------------
handle_info(
    _Msg,
    State = #state{handler = undefined, client_ref = ClientRef, stream_id = StreamId}
) ->
    ?LOGGER(
        warning,
        ClientRef,
        StreamId,
        "received info msg whilst handler is not set, ignoring: ~p",
        [
            _Msg
        ]
    ),
    State;
handle_info(
    Msg,
    State = #state{handler = Handler, client_ref = ClientRef, stream_id = StreamId}
) ->
    ?LOGGER(debug, ClientRef, StreamId, "received info msg: ~p", [
        Msg
    ]),
    Result = ?IF_EXPORTED(Handler, handle_info, 2, [Msg, State], {ok, State}),
    handle_info_result(Result).

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec validate_request_headers(
    Headers :: hpack:headers(),
    Validations :: validations(),
    CallbackState :: any()
) -> NewCallBackState :: any().
validate_request_headers(Headers, Validations, State) ->
    case do_validate_request_headers(Headers, Validations) of
        ok ->
            State;
        {error, HttpResponseCode, HttpResponseBody} ->
            State#state{
                request_valid = false,
                resp_error_code = HttpResponseCode,
                resp_error_msg = HttpResponseBody
            }
    end.

-spec do_validate_request_headers(Headers :: hpack:headers(), Validations :: validations()) ->
    ok | {error, binary(), binary()}.
do_validate_request_headers(_Headers, []) ->
    ok;
do_validate_request_headers(Headers, [{Header, ValidateFun, ErrorResponseCode, ErrorMsg} | Rest]) ->
    HeaderVal = proplists:get_value(Header, Headers),
    case ValidateFun(HeaderVal) of
        true -> do_validate_request_headers(Headers, Rest);
        false -> {error, ErrorResponseCode, ErrorMsg}
    end.

-spec handle_result(
    {ok, CallbackState :: any()} | {ok, CallbackState :: any(), Actions :: actions()}
) -> {ok, NewCallbackState :: any()}.
handle_result({ok, State}) ->
    {ok, State};
handle_result({ok, State, Actions}) ->
    NewState = handle_actions(Actions, State),
    {ok, NewState}.

-spec handle_info_result(
    {ok, CallbackState :: any()} | {ok, CallbackState :: any(), Actions :: actions()}
) -> NewCallbackState :: any().
handle_info_result({ok, State}) ->
    State;
handle_info_result({ok, State, Actions}) ->
    NewState = handle_actions(Actions, State),
    NewState.

-spec handle_actions(Actions :: actions(), CallbackState :: #state{}) -> NewCallbackState :: any().
handle_actions([], State = #state{}) ->
    State;
handle_actions([{send_headers, Headers} | Tail], State = #state{}) ->
    ok = send_headers(Headers, State),
    handle_actions(Tail, State);
handle_actions([{send_body, Body} | Tail], State = #state{}) ->
    ok = send_body(Body, true, State),
    handle_actions(Tail, State);
handle_actions([{send_body, Body, SendEndStream} | Tail], State = #state{}) ->
    ok = send_body(Body, SendEndStream, State),
    handle_actions(Tail, State).

-spec decode_path(Path :: binary()) -> {Route :: binary(), QueryParams :: [tuple()]}.
decode_path(Path) ->
    URIParts = uri_string:parse(Path),
    decode_query_params(URIParts).

-spec decode_query_params(map()) -> {Route :: binary(), QueryParams :: [tuple()]}.
decode_query_params(#{path := RoutePart, query := QueryPart}) ->
    QueryParams = uri_string:dissect_query(QueryPart),
    {RoutePart, QueryParams};
decode_query_params(#{path := RoutePart}) ->
    {RoutePart, []}.

-spec send_headers(Headers :: hpack:headers(), CallbackState :: any()) -> ok.
send_headers(
    Headers,
    _State = #state{conn_pid = ConnPid, client_ref = ClientRef, stream_id = StreamId}
) ->
    ?LOGGER(debug, ClientRef, StreamId, "sending headers ~p for stream id ~p", [
        Headers,
        StreamId
    ]),
    h2_connection:send_headers(ConnPid, StreamId, Headers).

-spec send_body(Data :: iodata(), SendEndStream :: boolean(), CallbackState :: any()) -> ok.
send_body(
    Data,
    SendEndStream,
    _State = #state{conn_pid = ConnPid, client_ref = ClientRef, stream_id = StreamId}
) ->
    ?LOGGER(debug, ClientRef, StreamId, "sending body ~p for stream id ~p", [
        Data,
        StreamId
    ]),
    h2_connection:send_body(ConnPid, StreamId, Data, [{send_end_stream, SendEndStream}]).
