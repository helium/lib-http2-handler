-include_lib("chatterbox/include/http2.hrl").

-record(state, {
    conn_pid :: pid(),
    stream_id :: stream_id(),
    client_ref_header_name :: undefined | binary(),
    client_ref :: undefined | binary(),
    app_data = #{} :: map(),
    peer_cert :: undefined | binary(),
    request_valid = true :: boolean(),
    resp_error_code :: undefined | binary(),
    resp_error_msg :: undefined | binary(),
    request_headers :: undefined | hpack:headers(),
    request_data = <<>> :: binary(),
    handler_routing_fun :: undefined | function(),
    method :: undefined | binary(),
    path :: undefined | binary(),
    handler :: atom(),
    route :: undefined | binary(),
    query_params = [] :: [] | [tuple()],
    handler_state :: any()
}).

-define(IF_EXPORTED(Mod, Function, Arity, Args, NotExportedReply),
    case erlang:function_exported(Mod, Function, Arity) of
        true -> apply(Mod, Function, Args);
        false -> NotExportedReply
    end
).

-define(LOGGER(Level, ClientRef, StreamID, LogMsg, LogParams),
    lager:Level("clientref: ~p streamid: ~p " ++ LogMsg, [
        ClientRef,
        StreamId
        | LogParams
    ])
).

-define(LOGGER(Level, ClientRef, Route, StreamID, LogMsg, LogParams),
    lager:Level("clientref: ~p streamid: ~p route: ~p. " ++ LogMsg, [
        ClientRef,
        StreamId,
        Route
        | LogParams
    ])
).
