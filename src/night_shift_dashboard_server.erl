-module(night_shift_dashboard_server).

-export([start_session/1, stop_session/1, http_get/1, http_post/2]).

-define(TABLE, night_shift_dashboard_sessions).
-define(DEFAULT_START_PORT, 8787).
-define(PORT_WINDOW, 20).
-define(HOST, "127.0.0.1").

start_session(RepoRoot) ->
    ensure_table(),
    StartPort = preferred_start_port(),
    case listen(StartPort, StartPort + ?PORT_WINDOW - 1) of
        {ok, Listener, Port} ->
            Handle = integer_to_binary(erlang:unique_integer([positive, monotonic])),
            ServerPid =
                spawn(fun() ->
                    process_flag(trap_exit, true),
                    accept_loop(Listener, RepoRoot)
                end),
            ets:insert(?TABLE, {Handle, ServerPid}),
            {ok, {session, build_url(Port), Handle}};
        {error, Message} ->
            {error, Message}
    end.

stop_session({session, _Url, Handle}) ->
    ensure_table(),
    case ets:take(?TABLE, Handle) of
        [{Handle, Pid}] ->
            exit(Pid, shutdown),
            nil;
        [] ->
            nil
    end.

http_get(Url) ->
    application:ensure_all_started(inets),
    case httpc:request(get, {binary_to_list(Url), []}, [], [{body_format, binary}]) of
        {ok, {{_, Status, _}, _Headers, Body}} when Status >= 200, Status < 300 ->
            {ok, Body};
        {ok, {{_, Status, _}, _Headers, Body}} ->
            {error, <<(integer_to_binary(Status))/binary, ": ", Body/binary>>};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

http_post(Url, Body) ->
    application:ensure_all_started(inets),
    Request =
        {binary_to_list(Url), [], "application/json; charset=utf-8", Body},
    case httpc:request(post, Request, [], [{body_format, binary}]) of
        {ok, {{_, Status, _}, _Headers, ResponseBody}} when Status >= 200, Status < 300 ->
            {ok, ResponseBody};
        {ok, {{_, Status, _}, _Headers, ResponseBody}} ->
            {error, <<(integer_to_binary(Status))/binary, ": ", ResponseBody/binary>>};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

preferred_start_port() ->
    case os:getenv("NIGHT_SHIFT_PORT_BASE") of
        false ->
            ?DEFAULT_START_PORT;
        Value ->
            case string:to_integer(Value) of
                {Int, _} when Int > 0 ->
                    Int;
                _ ->
                    ?DEFAULT_START_PORT
            end
    end.

listen(Port, EndPort) when Port =< EndPort ->
    case gen_tcp:listen(
        Port,
        [binary, {active, false}, {packet, raw}, {ip, {127, 0, 0, 1}}, {reuseaddr, true}]
    ) of
        {ok, Listener} ->
            {ok, Listener, Port};
        {error, eaddrinuse} ->
            listen(Port + 1, EndPort);
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("Unable to start dash server: ~p", [Reason]))}
    end;
listen(StartPort, EndPort) ->
    {error,
        unicode:characters_to_binary(
            io_lib:format("Unable to start dash server on 127.0.0.1:~B-~B.", [StartPort, EndPort])
        )}.

build_url(Port) ->
    <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>.

ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set]),
            ok;
        _ ->
            ok
    end.

accept_loop(Listener, RepoRoot) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            spawn(fun() -> handle_client(Socket, RepoRoot) end),
            accept_loop(Listener, RepoRoot);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            ok
    end.

handle_client(Socket, RepoRoot) ->
    Request = read_request(Socket),
    case parse_request(Request) of
        {ok, <<"GET">>, <<"/">>, _Query, _Body} ->
            reply(Socket, 200, <<"text/html; charset=utf-8">>, night_shift@dashboard:index_html(<<>>));
        {ok, <<"GET">>, <<"/api/bootstrap">>, Query, _Body} ->
            reply_dashboard_json(Socket, 200, night_shift@dashboard:bootstrap_json(RepoRoot, query_value(Query, <<"run_id">>)));
        {ok, <<"GET">>, <<"/api/audit">>, Query, _Body} ->
            reply_dashboard_json(Socket, 200, night_shift@dashboard:audit_json(RepoRoot, query_value(Query, <<"run_id">>)));
        {ok, <<"GET">>, <<"/api/provider-models">>, Query, _Body} ->
            reply_dashboard_json(Socket, 200, night_shift@dashboard:provider_models_json(RepoRoot, query_value(Query, <<"provider">>)));
        {ok, <<"GET">>, <<"/api/artifacts">>, Query, _Body} ->
            serve_artifact(Socket, RepoRoot, query_value(Query, <<"path">>));
        {ok, <<"GET">>, <<"/api/events">>, Query, _Body} ->
            serve_events(Socket, RepoRoot, query_value(Query, <<"run_id">>));
        {ok, <<"POST">>, <<"/api/commands/", Command/binary>>, _Query, Body} ->
            reply_dashboard_json(Socket, 200, night_shift@dashboard:command_json(RepoRoot, Command, Body));
        {ok, <<"GET">>, _Path, _Query, _Body} ->
            reply(Socket, 404, <<"text/plain; charset=utf-8">>, <<"Not found">>);
        {ok, _Method, _Path, _Query, _Body} ->
            reply(Socket, 405, <<"text/plain; charset=utf-8">>, <<"Method not allowed">>);
        error ->
            reply(Socket, 400, <<"text/plain; charset=utf-8">>, <<"Bad request">>)
    end.

read_request(Socket) ->
    read_request(Socket, <<>>, undefined).

read_request(Socket, Acc, ExpectedBodyLength) ->
    case has_complete_request(Acc, ExpectedBodyLength) of
        true ->
            Acc;
        false ->
            case gen_tcp:recv(Socket, 0) of
                {ok, Data} ->
                    Next = <<Acc/binary, Data/binary>>,
                    read_request(Socket, Next, determine_expected_body_length(Next, ExpectedBodyLength));
                {error, _Reason} ->
                    Acc
            end
    end.

determine_expected_body_length(_Request, Expected) when Expected =/= undefined ->
    Expected;
determine_expected_body_length(Request, undefined) ->
    case split_headers_body(Request) of
        {ok, Headers, _Body} ->
            content_length(Headers);
        error ->
            undefined
    end.

has_complete_request(Request, ExpectedBodyLength) ->
    case split_headers_body(Request) of
        {ok, _Headers, Body} ->
            case ExpectedBodyLength of
                undefined ->
                    true;
                Length ->
                    byte_size(Body) >= Length
            end;
        error ->
            false
    end.

split_headers_body(Request) ->
    case binary:match(Request, <<"\r\n\r\n">>) of
        {Index, 4} ->
            HeaderSize = Index,
            BodyStart = Index + 4,
            BodySize = byte_size(Request) - BodyStart,
            <<Headers:HeaderSize/binary, _Separator:4/binary, Body:BodySize/binary>> = Request,
            {ok, Headers, Body};
        nomatch ->
            error
    end.

content_length(Headers) ->
    Lines = binary:split(Headers, <<"\r\n">>, [global]),
    content_length_from_lines(Lines).

content_length_from_lines([]) ->
    0;
content_length_from_lines([Line | Rest]) ->
    Lower = to_binary(string:lowercase(binary_to_list(Line))),
    case binary:split(Lower, <<":">>, [global]) of
        [<<"content-length">>, RawValue] ->
            parse_length(to_binary(string:trim(binary_to_list(RawValue))));
        _ ->
            content_length_from_lines(Rest)
    end.

parse_length(Value) ->
    case string:to_integer(binary_to_list(Value)) of
        {Int, _} when Int >= 0 ->
            Int;
        _ ->
            0
    end.

parse_request(Request) ->
    case split_headers_body(Request) of
        {ok, Headers, Body} ->
            case binary:split(Headers, <<"\r\n">>, [global]) of
                [RequestLine | _] ->
                    case binary:split(RequestLine, <<" ">>, [global]) of
                        [Method, RawPath, _Version] ->
                            {ok, Method, strip_query(RawPath), parse_query(RawPath), trim_body(Body)};
                        _ ->
                            error
                    end;
                _ ->
                    error
            end;
        error ->
            error
    end.

trim_body(Body) ->
    Body.

strip_query(Path) ->
    case binary:split(Path, <<"?">>) of
        [Clean | _] -> Clean;
        [] -> Path
    end.

parse_query(Path) ->
    case binary:split(Path, <<"?">>) of
        [_PathOnly, QueryString] ->
            parse_query_pairs(binary:split(QueryString, <<"&">>, [global]), #{});
        _ ->
            #{}
    end.

parse_query_pairs([], Acc) ->
    Acc;
parse_query_pairs([<<>> | Rest], Acc) ->
    parse_query_pairs(Rest, Acc);
parse_query_pairs([Pair | Rest], Acc) ->
    case binary:split(Pair, <<"=">>, [global]) of
        [Key, Value] ->
            parse_query_pairs(Rest, Acc#{uri_string:unquote(Key) => uri_string:unquote(Value)});
        [Key] ->
            parse_query_pairs(Rest, Acc#{uri_string:unquote(Key) => <<>>});
        _ ->
            parse_query_pairs(Rest, Acc)
    end.

query_value(Query, Key) ->
    maps:get(Key, Query, <<>>).

reply_dashboard_json(Socket, SuccessStatus, Result) ->
    case Result of
        {ok, Payload} ->
            reply(Socket, SuccessStatus, <<"application/json; charset=utf-8">>, Payload);
        {error, Payload} ->
            reply(Socket, 400, <<"application/json; charset=utf-8">>, Payload)
    end.

serve_artifact(Socket, _RepoRoot, <<>>) ->
    reply(Socket, 400, <<"text/plain; charset=utf-8">>, <<"Missing artifact path">>);
serve_artifact(Socket, RepoRoot, Path) ->
    case artifact_path_allowed(RepoRoot, Path) of
        false ->
            reply(Socket, 403, <<"text/plain; charset=utf-8">>, <<"Artifact path is outside the current repository.">>);
        true ->
            case file:read_file(binary_to_list(Path)) of
                {ok, Body} ->
                    reply(Socket, 200, artifact_content_type(Path), Body);
                {error, enoent} ->
                    reply(Socket, 404, <<"text/plain; charset=utf-8">>, <<"Artifact not found">>);
                {error, Reason} ->
                    reply(
                        Socket,
                        500,
                        <<"text/plain; charset=utf-8">>,
                        unicode:characters_to_binary(io_lib:format("Unable to read artifact: ~p", [Reason]))
                    )
            end
    end.

artifact_path_allowed(RepoRoot, Path) ->
    RepoAbs = filename:absname(binary_to_list(RepoRoot)),
    PathAbs = filename:absname(binary_to_list(Path)),
    PathAbs =:= RepoAbs orelse lists:prefix(RepoAbs ++ "/", PathAbs).

artifact_content_type(Path) ->
    case filename:extension(binary_to_list(Path)) of
        ".json" -> <<"application/json; charset=utf-8">>;
        ".jsonl" -> <<"application/json; charset=utf-8">>;
        ".html" -> <<"text/html; charset=utf-8">>;
        ".md" -> <<"text/markdown; charset=utf-8">>;
        ".toml" -> <<"text/plain; charset=utf-8">>;
        ".log" -> <<"text/plain; charset=utf-8">>;
        ".env" -> <<"text/plain; charset=utf-8">>;
        _ -> <<"text/plain; charset=utf-8">>
    end.

serve_events(Socket, RepoRoot, RequestedRunId) ->
    Headers =
        <<
            "HTTP/1.1 200 OK\r\n",
            "Content-Type: text/event-stream; charset=utf-8\r\n",
            "Cache-Control: no-store\r\n",
            "Connection: keep-alive\r\n\r\n"
        >>,
    ok = gen_tcp:send(Socket, Headers),
    case night_shift@dashboard:bootstrap_json(RepoRoot, RequestedRunId) of
        {ok, Payload} ->
            case send_sse(Socket, <<"bootstrap">>, Payload) of
                ok ->
                    event_loop(Socket, RepoRoot, RequestedRunId, Payload, 0);
                _ ->
                    ok
            end;
        {error, Payload} ->
            _ = send_sse(Socket, <<"error">>, Payload),
            gen_tcp:close(Socket)
    end.

event_loop(Socket, RepoRoot, RequestedRunId, PreviousPayload, IdleTicks) ->
    timer:sleep(500),
    case night_shift@dashboard:bootstrap_json(RepoRoot, RequestedRunId) of
        {ok, Payload} when Payload =/= PreviousPayload ->
            case send_sse(Socket, <<"state">>, Payload) of
                ok ->
                    event_loop(Socket, RepoRoot, RequestedRunId, Payload, 0);
                _ ->
                    gen_tcp:close(Socket)
            end;
        {ok, Payload} ->
            case maybe_send_keepalive(Socket, IdleTicks) of
                ok ->
                    event_loop(Socket, RepoRoot, RequestedRunId, Payload, IdleTicks + 1);
                _ ->
                    gen_tcp:close(Socket)
            end;
        {error, Payload} ->
            _ = send_sse(Socket, <<"error">>, Payload),
            gen_tcp:close(Socket)
    end.

maybe_send_keepalive(Socket, IdleTicks) when IdleTicks >= 9 ->
    gen_tcp:send(Socket, <<": keep-alive\n\n">>);
maybe_send_keepalive(_Socket, _IdleTicks) ->
    ok.

send_sse(Socket, Event, Payload) ->
    Data = escape_sse_payload(Payload),
    gen_tcp:send(
        Socket,
        <<"event: ", Event/binary, "\n", "data: ", Data/binary, "\n\n">>
    ).

escape_sse_payload(Payload) ->
    re:replace(Payload, <<"\n">>, <<"\ndata: ">>, [global, {return, binary}]).

reply(Socket, StatusCode, ContentType, Body) ->
    StatusLine = status_line(StatusCode),
    Response =
        <<
            "HTTP/1.1 ", StatusLine/binary, "\r\n",
            "Content-Type: ", ContentType/binary, "\r\n",
            "Cache-Control: no-store\r\n",
            "Content-Length: ", (integer_to_binary(byte_size(Body)))/binary, "\r\n",
            "Connection: close\r\n\r\n",
            Body/binary
        >>,
    ok = gen_tcp:send(Socket, Response),
    gen_tcp:close(Socket).

status_line(200) -> <<"200 OK">>;
status_line(400) -> <<"400 Bad Request">>;
status_line(403) -> <<"403 Forbidden">>;
status_line(404) -> <<"404 Not Found">>;
status_line(405) -> <<"405 Method Not Allowed">>;
status_line(500) -> <<"500 Internal Server Error">>.

to_binary(Value) when is_binary(Value) ->
    Value;
to_binary(Value) ->
    unicode:characters_to_binary(Value).
