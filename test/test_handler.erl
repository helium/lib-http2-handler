-module(test_handler).

-behavior(lib_http2_handler).

-include("http2_handler.hrl").

%% ------------------------------------------------------------------
%% lib_http2_stream exports
%% ------------------------------------------------------------------
-export([
    handle_on_receive_request_data/3,
    handle_on_request_end_stream/2,
    validations/0
]).

%% ------------------------------------------------------------------
%% lib_http2_stream callbacks
%% ------------------------------------------------------------------
validations() ->
    [
        {<<":method">>, fun(V) -> V =:= <<"POST">> end, <<"405">>, <<"method not supported">>}
    ].

handle_on_receive_request_data(
    _Method,
    Data,
    State = #state{request_valid = true, request_data = Buffer}
) ->
    {ok, State#state{request_data = <<Buffer/binary, Data/binary>>}};
handle_on_receive_request_data(_Method, _Data, State = #state{request_valid = false}) ->
    {ok, State}.

handle_on_request_end_stream(
    _Method,
    State = #state{
        request_valid = true,
        request_data = Data
    }
) ->
    case deserialize_request(Data) of
        {ok, _Msg} ->
            %% we verified its valid json, so now echo the same payload back to the client
            {ok, State#state{request_data = <<>>}, [
                {send_headers, [{<<":status">>, <<"200">>}]},
                {send_body, Data, true}
            ]};
        {error, _Reason} ->
            NewState = State#state{
                request_data = <<>>,
                request_valid = false,
                resp_error_code = <<"400">>,
                resp_error_msg = <<"bad request">>
            },
            {ok, NewState, [
                {send_headers, [{<<":status">>, <<"400">>}]},
                {send_body, <<"bad request">>, true}
            ]}
    end.

%% ------------------------------------------------------------------
%% Internal functions
%% ------------------------------------------------------------------
-spec deserialize_request(binary()) -> {ok, any()} | {error, any()}.
deserialize_request(Data) ->
    try jsx:decode(Data) of
        Msg ->
            {ok, Msg}
    catch
        _E:_R ->
            {error, {decode_failed, _E, _R}}
    end.
