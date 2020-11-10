-module(lib_http2_utils).

%% API
-export([
    encode_sse/2
]).

-spec encode_sse(binary(), binary()) -> binary().
encode_sse(Payload, _EventType) ->
    Bin64 = base64:encode(Payload),
    <<"data: ", Bin64/binary, "\n\n">>.
