-module(sse_handler).

-behavior(lib_http2_handler).

-include("http2_handler.hrl").

-define(TIMEOUT, 250).

-record(handler_state, {
    timer_ref :: reference(),
    count = 0 :: non_neg_integer()
}).

%% ------------------------------------------------------------------
%% lib_http2_stream exports
%% ------------------------------------------------------------------
-export([
    handle_on_request_end_stream/2,
    handle_info/2,
    validations/0
]).

%% ------------------------------------------------------------------
%% lib_http2_stream callbacks
%% ------------------------------------------------------------------
validations() ->
    [
        {<<":method">>, fun(V) -> V =:= <<"GET">> end, <<"405">>, <<"method not supported">>}
    ].

handle_on_request_end_stream(
    _Method,
    State = #state{
        request_valid = true
    }
) ->
    %% return the event-stream header to client
    %% and kick off a timer which will result in kicking off events being sent to the client
    {ok, Ref} = timer:send_after(?TIMEOUT, self(), {event, <<"hello">>}),
    HandlerState = #handler_state{timer_ref = Ref, count = 0},
    {ok, State#state{request_data = <<>>, handler_state = HandlerState}, [
        {send_headers, [{<<":status">>, <<"200">>}, {<<"content-type">>, <<"text/event-stream">>}]}
    ]}.

%% ------------------------------------------------------------------
%% info msg callbacks
%% ------------------------------------------------------------------
handle_info(
    {event, Bin} = _Msg,
    State = #state{
        stream_id = StreamId,
        client_ref = ClientRef,
        handler_state = #handler_state{timer_ref = TimerRef, count = Count} = HandlerState
    }
) when Count < 10 ->
    ok = cancel_timer(TimerRef),
    ?LOGGER(notice, ClientRef, StreamId, "sending event with bin ~p", [
        Bin
    ]),
    {ok, NewRef} = timer:send_after(?TIMEOUT, self(), {event, Bin}),
    NewHandlerState = HandlerState#handler_state{timer_ref = NewRef, count = Count + 1},
    {ok, State#state{handler_state = NewHandlerState}, [
        {send_body, lib_http2_utils:encode_sse(Bin, <<"route_update">>), false}
    ]};
handle_info(
    _Msg,
    State = #state{}
) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec cancel_timer(undefined | reference()) -> ok.
cancel_timer(undefined) ->
    ok;
cancel_timer(Ref) ->
    _ = timer:cancel(Ref),
    ok.
