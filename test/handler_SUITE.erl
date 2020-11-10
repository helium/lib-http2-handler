-module(handler_SUITE).

-define(CLIENT_REF_NAME, <<"x-client-id">>).

-export([
    all/0,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    http2_200_test/1,
    http2_negative_test/1,
    http2_sse_test/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("chatterbox/include/http2.hrl").

%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @public
%% @doc
%%   Running tests for this suite
%% @end
%%--------------------------------------------------------------------
all() ->
    [
        http2_200_test,
        http2_negative_test,
        http2_sse_test
    ].

%%--------------------------------------------------------------------
%% TEST CASE SETUP
%%--------------------------------------------------------------------
init_per_testcase(_TestCase, Config) ->
    HandlerRoutingFun = fun
        (<<"/v1/test/me">>) -> {ok, test_handler};
        (<<"/v1/sse/test-event">>) -> {ok, sse_handler};
        (UnknownRequestType) -> {error, {handler_not_found, UnknownRequestType}}
    end,
    ok = application:set_env(chatterbox, ssl, false),
    ok = application:set_env(chatterbox, port, 8080),
    ok = application:set_env(chatterbox, concurrent_acceptors, 2),
    ok = application:set_env(chatterbox, stream_callback_mod, lib_http2_stream),
    ok = application:set_env(
        chatterbox,
        stream_callback_opts,
        [
            {http2_handler_routing_fun, HandlerRoutingFun},
            {http2_client_ref_header_name, ?CLIENT_REF_NAME}
        ]
    ),
    application:ensure_all_started(lager),
    lager:set_loglevel(lager_console_backend, debug),
    lager:set_loglevel({lager_file_backend, "log/console.log"}, debug),

    application:ensure_all_started(gun),
    chatterbox_sup:start_link(),

    Config.

%%--------------------------------------------------------------------
%% TEST CASE TEARDOWN
%%--------------------------------------------------------------------
end_per_testcase(_TestCase, Config) ->
    Config.

%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
http2_200_test(_Config) ->
    %% create a valid request
    Payload = jsx:encode(crypto:strong_rand_bytes(200)),

    {ok, ConnPid} = gun:open("localhost", 8080, #{
        transport => tcp,
        protocols => [http2],
        http2_opts => #{content_handlers => [gun_sse_h, gun_data_h]}
    }),
    {ok, http2} = gun:await_up(ConnPid),

    StreamRef = gun:post(ConnPid, "/v1/test/me", [{?CLIENT_REF_NAME, <<"req1">>}], Payload),
    case gun:await(ConnPid, StreamRef) of
        {response, fin, _Status, _Headers} ->
            ct:fail(no_response);
        {response, nofin, Status, Headers} ->
            {ok, Body} = gun:await_body(ConnPid, StreamRef),
            ct:pal("Response Headers: ~p", [Headers]),
            ct:pal("Response Body: ~p", [Body]),
            %% assert the response msg, we should have been echoed the same payload as our request
            ?assertEqual(200, Status),
            ?assertEqual(Payload, Body)
    end,

    gun:close(ConnPid),
    ok.

http2_negative_test(_Config) ->
    %% create a valid request
    %% NOTE: we encode to json for test purpose only
    %%       then handler will attempt to decode to json and return a specific error if payload is not json
    Payload = jsx:encode(crypto:strong_rand_bytes(200)),

    {ok, ConnPid} = gun:open("localhost", 8080, #{
        transport => tcp,
        protocols => [http2],
        http2_opts => #{content_handlers => [gun_sse_h, gun_data_h]}
    }),
    {ok, http2} = gun:await_up(ConnPid),

    %% send a request with no body, which should fail with a 400 error as cannot decode JSON
    StreamRef = gun:post(ConnPid, "/v1/test/me", [{?CLIENT_REF_NAME, <<"req2">>}], <<>>),
    case gun:await(ConnPid, StreamRef) of
        {response, fin, _Status, _Headers} ->
            ct:fail(no_response);
        {response, nofin, Status, Headers} ->
            ct:pal("Response Headers: ~p", [Headers]),
            ?assertEqual(400, Status)
    end,

    %% send a request with an invalid method, should fail with a 405 error
    StreamRef2 = gun:put(ConnPid, "/v1/test/me", [{?CLIENT_REF_NAME, <<"req3">>}], <<>>),
    case gun:await(ConnPid, StreamRef2) of
        {response, fin, _Status2, _Headers2} ->
            ct:fail(no_response);
        {response, nofin, Status2, Headers2} ->
            ct:pal("Response Headers: ~p", [Headers2]),
            ?assertEqual(405, Status2)
    end,

    %% send a request with an invalid path, should fail with a 404 error
    StreamRef3 = gun:put(
        ConnPid,
        "v1/bad_path/leads_to_bad_things",
        [{?CLIENT_REF_NAME, <<"req4">>}],
        Payload
    ),
    case gun:await(ConnPid, StreamRef3) of
        {response, fin, _Status3, _Headers3} ->
            ct:fail(no_response);
        {response, nofin, Status3, Headers3} ->
            ct:pal("Response Headers: ~p", [Headers3]),
            ?assertEqual(404, Status3)
    end,

    gun:close(ConnPid),
    ok.

http2_sse_test(_Config) ->
    %% simulates SSE events
    %% the handler will spin up a timer and send the same event 10 times,
    %% test will onfirm events are received by the client
    %% and then the stream should close
    {ok, Pid} = gun:open("localhost", 8080, #{
        transport => tcp,
        protocols => [http2],
        http2_opts => #{content_handlers => [gun_sse_h, gun_data_h]}
    }),
    {ok, http2} = gun:await_up(Pid),

    StreamRef = gun:get(Pid, "/v1/sse/test-event", [
        {<<"host">>, <<"localhost">>},
        {<<"accept">>, <<"text/event-stream">>}
    ]),

    %% confirm the stream is up and running
    Self = self(),
    {ok, #{
        ref := StreamRef,
        reply_to := Self,
        state := running
    }} = gun:stream_info(Pid, StreamRef),

    %% confirm we get the event-stream response from server
    %% followed by 10 events
    receive
        {gun_response, Pid, Ref, nofin, 200, Headers} ->
            {_, <<"text/event-stream">>} =
                lists:keyfind(<<"content-type">>, 1, Headers),
            event_loop(Pid, Ref, 10)
    after 5000 -> error(timeout)
    end,

    %% close the stream and then the connection
    gun:cancel(Pid, StreamRef),
    {ok, undefined} = gun:stream_info(Pid, StreamRef),
    gun:close(Pid),
    ok.

%% ------------------------------------------------------------------
%% Helper functions
%% ------------------------------------------------------------------

event_loop(_Pid, _, 0) ->
    ok;
event_loop(Pid, Ref, N) ->
    receive
        {gun_sse, Pid, Ref, Event} ->
            #{
                last_event_id := _EventId,
                event_type := _Type,
                data := Data
            } = Event,
            ct:pal("got event ~p", [Event]),
            true = is_list(Data) orelse is_binary(Data),
            event_loop(Pid, Ref, N - 1)
    after 5000 -> error(timeout)
    end.
