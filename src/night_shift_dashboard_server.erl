-module(night_shift_dashboard_server).

-export([start_view_session/2, start_start_session/4, start_resume_session/4, stop_session/1, http_get/1]).

-define(TABLE, night_shift_dashboard_sessions).
-define(HOST, "127.0.0.1").
-define(START_PORT, 8787).
-define(END_PORT, 8797).

start_view_session(RepoRoot, InitialRunId) ->
    start_session(RepoRoot, InitialRunId, undefined).

start_start_session(RepoRoot, InitialRunId, Run, Config) ->
    start_session(
        RepoRoot,
        InitialRunId,
        fun() -> run_start(Run, Config) end
    ).

start_resume_session(RepoRoot, InitialRunId, Run, Config) ->
    start_session(
        RepoRoot,
        InitialRunId,
        fun() -> run_resume(Run, Config) end
    ).

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

start_session(RepoRoot, InitialRunId, Runner) ->
    ensure_table(),
    case listen(?START_PORT) of
        {ok, Listener, Port} ->
            Handle = integer_to_binary(erlang:unique_integer([positive, monotonic])),
            ServerPid =
                spawn(fun() ->
                    maybe_spawn_runner(Runner),
                    accept_loop(Listener, RepoRoot, InitialRunId)
                end),
            ets:insert(?TABLE, {Handle, ServerPid}),
            {ok, {session, build_url(Port), Handle}};
        {error, Message} ->
            {error, Message}
    end.

listen(Port) when Port =< ?END_PORT ->
    case gen_tcp:listen(
        Port,
        [binary, {active, false}, {packet, raw}, {ip, {127, 0, 0, 1}}, {reuseaddr, true}]
    ) of
        {ok, Listener} ->
            {ok, Listener, Port};
        {error, eaddrinuse} ->
            listen(Port + 1);
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("Unable to start dashboard server: ~p", [Reason]))}
    end;
listen(_) ->
    {error, <<"Unable to start dashboard server on 127.0.0.1:8787-8797.">>}.

build_url(Port) ->
    <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>.

maybe_spawn_runner(undefined) ->
    ok;
maybe_spawn_runner(Runner) ->
    spawn(fun() -> Runner() end),
    ok.

accept_loop(Listener, RepoRoot, InitialRunId) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            spawn(fun() -> handle_client(Socket, RepoRoot, InitialRunId) end),
            accept_loop(Listener, RepoRoot, InitialRunId);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            ok
    end.

handle_client(Socket, RepoRoot, InitialRunId) ->
    Request = read_request(Socket, <<>>),
    case parse_request(Request) of
        {ok, <<"GET">>, <<"/">>} ->
            reply(Socket, 200, <<"text/html; charset=utf-8">>, night_shift@dashboard:index_html(InitialRunId));
        {ok, <<"GET">>, <<"/api/runs">>} ->
            case night_shift@dashboard:runs_json(RepoRoot) of
                {ok, Payload} ->
                    reply(Socket, 200, <<"application/json; charset=utf-8">>, Payload);
                {error, Message} ->
                    reply(Socket, 500, <<"text/plain; charset=utf-8">>, Message)
            end;
        {ok, <<"POST">>, <<"/api/runs/", Rest/binary>>} ->
            case parse_recovery_path(Rest) of
                {ok, RunId, Action} ->
                    case night_shift@dashboard:apply_recovery_action(RepoRoot, uri_string:unquote(RunId), Action) of
                        {ok, Payload} ->
                            reply(Socket, 200, <<"text/plain; charset=utf-8">>, Payload);
                        {error, Message} ->
                            reply(Socket, 400, <<"text/plain; charset=utf-8">>, Message)
                    end;
                error ->
                    reply(Socket, 404, <<"text/plain; charset=utf-8">>, <<"Not found">>)
            end;
        {ok, <<"GET">>, <<"/api/runs/", RunId/binary>>} ->
            case night_shift@dashboard:run_json(RepoRoot, uri_string:unquote(RunId)) of
                {ok, Payload} ->
                    reply(Socket, 200, <<"application/json; charset=utf-8">>, Payload);
                {error, Message} ->
                    reply(Socket, 404, <<"text/plain; charset=utf-8">>, Message)
            end;
        {ok, <<"GET">>, _Path} ->
            reply(Socket, 404, <<"text/plain; charset=utf-8">>, <<"Not found">>);
        {ok, _Method, _Path} ->
            reply(Socket, 405, <<"text/plain; charset=utf-8">>, <<"Method not allowed">>);
        error ->
            reply(Socket, 400, <<"text/plain; charset=utf-8">>, <<"Bad request">>)
    end,
    gen_tcp:close(Socket).

read_request(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            Next = <<Acc/binary, Data/binary>>,
            case binary:match(Next, <<"\r\n\r\n">>) of
                {_, _} -> Next;
                nomatch when byte_size(Next) < 65536 -> read_request(Socket, Next);
                nomatch -> Next
            end;
        {error, _Reason} ->
            Acc
    end.

parse_request(Request) ->
    case binary:split(Request, <<"\r\n">>, [global]) of
        [RequestLine | _] ->
            case binary:split(RequestLine, <<" ">>, [global]) of
                [Method, RawPath, _Version] ->
                    {ok, Method, strip_query(RawPath)};
                _ ->
                    error
            end;
        _ ->
            error
    end.

strip_query(Path) ->
    case binary:split(Path, <<"?">>) of
        [Clean | _] -> Clean;
        [] -> Path
    end.

parse_recovery_path(Rest) ->
    case binary:split(Rest, <<"/recovery/">>) of
        [RunId, Action] when RunId =/= <<>>, Action =/= <<>> ->
            {ok, RunId, Action};
        _ ->
            error
    end.

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
    ok = gen_tcp:send(Socket, Response).

status_line(200) -> <<"200 OK">>;
status_line(400) -> <<"400 Bad Request">>;
status_line(404) -> <<"404 Not Found">>;
status_line(405) -> <<"405 Method Not Allowed">>;
status_line(500) -> <<"500 Internal Server Error">>.

run_start(Run, Config) ->
    case night_shift@orchestrator:start(Run, Config) of
        {ok, _CompletedRun} ->
            ok;
        {error, Message} ->
            mark_failed(Run, Message)
    end.

run_resume(Run, Config) ->
    case night_shift@orchestrator:resume(Run, Config) of
        {ok, _CompletedRun} ->
            ok;
        {error, Message} ->
            mark_failed(Run, Message)
    end.

mark_failed(Run, Message) ->
    RepoRoot = erlang:element(3, Run),
    RunId = erlang:element(2, Run),
    case night_shift@journal:load(RepoRoot, {run_id, RunId}) of
        {ok, {LatestRun, _Events}} ->
            _ = night_shift@journal:mark_status(LatestRun, run_failed, Message),
            ok;
        {error, _} ->
            _ = night_shift@journal:mark_status(Run, run_failed, Message),
            ok
    end.

ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set]),
            ok;
        _ ->
            ok
    end.
