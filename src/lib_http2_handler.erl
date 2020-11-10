-module(lib_http2_handler).

-type callback_state() :: any().

-export_type([callback_state/0]).

-type handle_on_receive_request_headers_result() ::
    {ok, CallbackState :: any()}
    | {ok, CallbackState :: any(), lib_http2_stream:actions()}.

-type handle_on_receive_request_data_result() ::
    {ok, CallbackState :: any()}
    | {ok, CallbackState :: any(), lib_http2_stream:actions()}.

-type handle_on_request_end_stream_result() ::
    {ok, CallbackState :: any()}
    | {ok, CallbackState :: any(), lib_http2_stream:actions()}.

-type handle_info_result() ::
    {ok, CallbackState :: callback_state()}
    | {ok, CallbackState :: any(), lib_http2_stream:actions()}.

-export_type([
    handle_info_result/0,
    handle_on_receive_request_data_result/0,
    handle_on_request_end_stream_result/0,
    handle_on_receive_request_headers_result/0
]).

-callback validations() -> lib_http2_stream:validations().

-callback handle_on_receive_request_headers(
    Method :: binary(),
    Request :: hpack:headers(),
    CallbackState :: callback_state()
) -> handle_on_receive_request_headers_result().

-callback handle_on_receive_request_data(
    Method :: binary(),
    Request :: term(),
    CallbackState :: callback_state()
) -> handle_on_receive_request_data_result().

-callback handle_on_request_end_stream(
    Method :: binary(),
    CallbackState :: callback_state()
) -> handle_on_request_end_stream_result().

-callback handle_info(
    Msg :: term(),
    CallbackState :: callback_state()
) -> handle_info_result().

-optional_callbacks([
    handle_on_receive_request_headers/3,
    handle_on_receive_request_data/3,
    handle_info/2
]).
