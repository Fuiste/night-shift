-module(night_shift_dashboard_server).

-export([
    start_session/2,
    stop_session/1,
    command_state/1,
    http_get/1,
    http_post/2
]).

-define(SESSIONS_TABLE, night_shift_dashboard_sessions).
-define(COMMANDS_TABLE, night_shift_dashboard_commands).

start_session(RepoRoot, InitialRunId) ->
    ensure_tables(),
    case listen() of
        {ok, Listener, Port} ->
            Handle = integer_to_binary(erlang:unique_integer([positive, monotonic])),
            ServerPid =
                spawn(fun() ->
                    accept_loop(Listener, RepoRoot, InitialRunId)
                end),
            ets:insert(?SESSIONS_TABLE, {Handle, ServerPid}),
            {ok, {session, build_url(Port), Handle}};
        {error, Message} ->
            {error, Message}
    end.

stop_session({session, _Url, Handle}) ->
    ensure_tables(),
    case ets:take(?SESSIONS_TABLE, Handle) of
        [{Handle, Pid}] ->
            exit(Pid, shutdown),
            nil;
        [] ->
            nil
    end.

command_state(RepoRoot) ->
    ensure_tables(),
    case ets:lookup(?COMMANDS_TABLE, RepoRoot) of
        [{RepoRoot, Name, RunId, StartedAt, Summary}] ->
            {some, {command_state, Name, run_id_option(RunId), StartedAt, Summary}};
        [] ->
            none
    end.

http_get(Url) ->
    request(get, Url, <<>>).

http_post(Url, Body) ->
    request(post, Url, Body).

request(Method, Url, Body) ->
    application:ensure_all_started(inets),
    Request =
        case Method of
            get -> {binary_to_list(Url), []};
            post ->
                {binary_to_list(Url), [], "application/json", binary_to_list(Body)}
        end,
    case httpc:request(Method, Request, [], [{body_format, binary}]) of
        {ok, {{_, Status, _}, _Headers, ResponseBody}} when Status >= 200, Status < 300 ->
            {ok, ResponseBody};
        {ok, {{_, Status, _}, _Headers, ResponseBody}} ->
            {error, <<(integer_to_binary(Status))/binary, ": ", ResponseBody/binary>>};
        {error, Reason} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Reason]))}
    end.

listen() ->
    case gen_tcp:listen(
        0,
        [binary, {active, false}, {packet, raw}, {ip, {127, 0, 0, 1}}, {reuseaddr, true}]
    ) of
        {ok, Listener} ->
            case inet:sockname(Listener) of
                {ok, {_Address, Port}} ->
                    {ok, Listener, Port};
                {error, Reason} ->
                    gen_tcp:close(Listener),
                    {error, format_error("Unable to determine dashboard port", Reason)}
            end;
        {error, Reason} ->
            {error, format_error("Unable to start dashboard server", Reason)}
    end.

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
    KeepOpen =
        case parse_request(Request) of
            {ok, Method, Path, Query, Body} ->
                dispatch(Socket, RepoRoot, InitialRunId, Method, Path, Query, Body);
            error ->
                reply(Socket, 400, <<"text/plain; charset=utf-8">>, <<"Bad request">>),
                close
        end,
    case KeepOpen of
        keep_open -> ok;
        close -> gen_tcp:close(Socket)
    end.

dispatch(Socket, RepoRoot, InitialRunId, <<"GET">>, <<"/">>, _Query, _Body) ->
    case night_shift@dash@assets:app_shell(InitialRunId) of
        {ok, Html} ->
            reply(Socket, 200, <<"text/html; charset=utf-8">>, Html),
            close;
        {error, Message} ->
            reply(Socket, 500, <<"text/plain; charset=utf-8">>, Message),
            close
    end;
dispatch(Socket, _RepoRoot, _InitialRunId, <<"GET">>, <<"/assets/", Rest/binary>>, _Query, _Body) ->
    Segments = split_path(Rest),
    case night_shift@dash@assets:read_asset(Segments) of
        {ok, Contents} ->
            ContentType = night_shift@dash@assets:content_type(Segments),
            reply(Socket, 200, ContentType, Contents),
            close;
        {error, Message} ->
            reply(Socket, 404, <<"text/plain; charset=utf-8">>, Message),
            close
    end;
dispatch(Socket, RepoRoot, _InitialRunId, <<"GET">>, <<"/api/workspace">>, Query, _Body) ->
    case night_shift@dash@api:workspace_json(RepoRoot, query_run(Query)) of
        {ok, Payload} ->
            reply(Socket, 200, <<"application/json; charset=utf-8">>, Payload),
            close;
        {error, Message} ->
            reply(Socket, 400, <<"text/plain; charset=utf-8">>, Message),
            close
    end;
dispatch(Socket, RepoRoot, _InitialRunId, <<"GET">>, <<"/api/init/models">>, Query, _Body) ->
    case maps:get(<<"provider">>, Query, undefined) of
        undefined ->
            reply(Socket, 400, <<"text/plain; charset=utf-8">>, <<"Missing provider query parameter">>),
            close;
        Provider ->
            case night_shift@dash@api:init_models_json(RepoRoot, Provider) of
                {ok, Payload} ->
                    reply(Socket, 200, <<"application/json; charset=utf-8">>, Payload),
                    close;
                {error, Message} ->
                    reply(Socket, 400, <<"text/plain; charset=utf-8">>, Message),
                    close
            end
    end;
dispatch(Socket, RepoRoot, _InitialRunId, <<"GET">>, <<"/api/runs">>, _Query, _Body) ->
    case night_shift@dashboard:runs_json(RepoRoot) of
        {ok, Payload} ->
            reply(Socket, 200, <<"application/json; charset=utf-8">>, Payload),
            close;
        {error, Message} ->
            reply(Socket, 400, <<"text/plain; charset=utf-8">>, Message),
            close
    end;
dispatch(Socket, RepoRoot, _InitialRunId, <<"GET">>, <<"/api/runs/", Rest/binary>>, Query, _Body) ->
    case parse_run_path(Rest) of
        {events, RunId} ->
            sse_reply(Socket),
            stream_events(
                Socket,
                RepoRoot,
                case RunId of
                    <<"latest">> -> none;
                    _ -> some_string(RunId)
                end,
                none
            ),
            keep_open;
        {run, RunId} ->
            case night_shift@dashboard:run_json(RepoRoot, unquote_binary(RunId)) of
                {ok, Payload} ->
                    reply(Socket, 200, <<"application/json; charset=utf-8">>, Payload),
                    close;
                {error, Message} ->
                    reply(Socket, 404, <<"text/plain; charset=utf-8">>, Message),
                    close
            end;
        error ->
            reply(Socket, 404, <<"text/plain; charset=utf-8">>, <<"Not found">>),
            close
    end;
dispatch(Socket, RepoRoot, _InitialRunId, <<"GET">>, <<"/artifacts/runs/", Rest/binary>>, _Query, _Body) ->
    case parse_artifact_path(Rest) of
        {ok, RunId, Segments} ->
            serve_artifact(Socket, RepoRoot, unquote_binary(RunId), Segments);
        error ->
            reply(Socket, 404, <<"text/plain; charset=utf-8">>, <<"Not found">>),
            close
    end;
dispatch(Socket, RepoRoot, _InitialRunId, <<"POST">>, <<"/api/init">>, _Query, Body) ->
    handle_sync_command(Socket, RepoRoot, <<"init">>, <<>>, fun() ->
        night_shift@dash@api:init_action(RepoRoot, Body)
    end);
dispatch(Socket, RepoRoot, _InitialRunId, <<"POST">>, <<"/api/plans">>, _Query, Body) ->
    handle_sync_command(Socket, RepoRoot, <<"plan">>, <<>>, fun() ->
        night_shift@dash@api:plan_action(RepoRoot, Body, false)
    end);
dispatch(Socket, RepoRoot, _InitialRunId, <<"POST">>, <<"/api/plans/from-reviews">>, _Query, Body) ->
    handle_sync_command(Socket, RepoRoot, <<"plan_from_reviews">>, <<>>, fun() ->
        night_shift@dash@api:plan_action(RepoRoot, Body, true)
    end);
dispatch(Socket, RepoRoot, _InitialRunId, <<"POST">>, <<"/api/runs/", Rest/binary>>, _Query, Body) ->
    case parse_run_command_path(Rest) of
        {start, RunId} ->
            handle_async_command(Socket, RepoRoot, <<"start">>, unquote_binary(RunId), fun() ->
                night_shift@dash@api:start_command(RepoRoot, unquote_binary(RunId))
            end);
        {resume, RunId} ->
            handle_async_command(Socket, RepoRoot, <<"resume">>, unquote_binary(RunId), fun() ->
                night_shift@dash@api:resume_command(RepoRoot, unquote_binary(RunId))
            end);
        {resolve_decisions, RunId} ->
            handle_sync_command(Socket, RepoRoot, <<"resolve_decisions">>, unquote_binary(RunId), fun() ->
                night_shift@dash@api:resolve_decisions_action(
                    RepoRoot,
                    unquote_binary(RunId),
                    Body
                )
            end);
        {recovery, RunId, Action} ->
            handle_sync_command(Socket, RepoRoot, <<"recovery">>, unquote_binary(RunId), fun() ->
                night_shift@dash@api:recovery_action(
                    RepoRoot,
                    unquote_binary(RunId),
                    unquote_binary(Action),
                    Body
                )
            end);
        error ->
            reply(Socket, 404, <<"text/plain; charset=utf-8">>, <<"Not found">>),
            close
    end;
dispatch(Socket, _RepoRoot, _InitialRunId, <<"GET">>, _Path, _Query, _Body) ->
    reply(Socket, 404, <<"text/plain; charset=utf-8">>, <<"Not found">>),
    close;
dispatch(Socket, _RepoRoot, _InitialRunId, _Method, _Path, _Query, _Body) ->
    reply(Socket, 405, <<"text/plain; charset=utf-8">>, <<"Method not allowed">>),
    close.

handle_sync_command(Socket, RepoRoot, Name, RunId, Fun) ->
    case begin_command(RepoRoot, Name, RunId) of
        ok ->
            Response =
                try Fun() of
                    {ok, Payload} ->
                        finish_command(RepoRoot),
                        {200, <<"application/json; charset=utf-8">>, Payload};
                    {error, Message} ->
                        finish_command(RepoRoot),
                        {400, <<"text/plain; charset=utf-8">>, Message}
                catch
                    Class:Reason:Stack ->
                        finish_command(RepoRoot),
                        {500, <<"text/plain; charset=utf-8">>, format_crash(Class, Reason, Stack)}
                end,
            reply(Socket, element(1, Response), element(2, Response), element(3, Response)),
            close;
        {error, Message} ->
            reply(Socket, 409, <<"text/plain; charset=utf-8">>, Message),
            close
    end.

handle_async_command(Socket, RepoRoot, Name, RunId, Fun) ->
    case begin_command(RepoRoot, Name, RunId) of
        ok ->
            spawn(fun() ->
                try Fun() of
                    _ -> ok
                catch
                    _:_:_ -> ok
                after
                    finish_command(RepoRoot)
                end
            end),
            reply(
                Socket,
                202,
                <<"application/json; charset=utf-8">>,
                async_payload(Name, RunId)
            ),
            close;
        {error, Message} ->
            reply(Socket, 409, <<"text/plain; charset=utf-8">>, Message),
            close
    end.

async_payload(Name, RunId) ->
    iolist_to_binary([
        <<"{\"ok\":true,\"summary\":\"Dash started ">>,
        Name,
        <<" for run ">>,
        RunId,
        <<".\",\"next_action\":\"Watch Dash for live updates.\",\"run_id\":\"">>,
        RunId,
        <<"\"}">>
    ]).

serve_artifact(Socket, RepoRoot, RunId, Segments) ->
    case night_shift@dash@api:artifact_contents(RepoRoot, RunId, Segments) of
        {ok, {ContentType, Contents}} ->
            reply(Socket, 200, ContentType, Contents),
            close;
        {error, Message} ->
            reply(Socket, 404, <<"text/plain; charset=utf-8">>, Message),
            close
    end.

read_request(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {HeaderEnd, 4} ->
            Headers = binary:part(Acc, 0, HeaderEnd + 4),
            ContentLength = content_length(Headers),
            BodyLength = byte_size(Acc) - (HeaderEnd + 4),
            case BodyLength >= ContentLength of
                true ->
                    Acc;
                false ->
                    case gen_tcp:recv(Socket, 0) of
                        {ok, Data} -> read_request(Socket, <<Acc/binary, Data/binary>>);
                        {error, _Reason} -> Acc
                    end
            end;
        nomatch ->
            case gen_tcp:recv(Socket, 0) of
                {ok, Data} when byte_size(Acc) + byte_size(Data) < 1048576 ->
                    read_request(Socket, <<Acc/binary, Data/binary>>);
                {ok, Data} ->
                    <<Acc/binary, Data/binary>>;
                {error, _Reason} ->
                    Acc
            end
    end.

parse_request(Request) ->
    case binary:split(Request, <<"\r\n\r\n">>) of
        [HeaderBin, Body] ->
            Lines = binary:split(HeaderBin, <<"\r\n">>, [global]),
            case Lines of
                [RequestLine | HeaderLines] ->
                    case binary:split(RequestLine, <<" ">>, [global]) of
                        [Method, RawPath, _Version] ->
                            {Path, Query} = split_query(RawPath),
                            {ok, Method, Path, parse_query(Query), Body};
                        _ ->
                            error
                    end;
                _ ->
                    error
            end;
        _ ->
            error
    end.

split_query(RawPath) ->
    case binary:split(RawPath, <<"?">>) of
        [Path, Query] -> {Path, Query};
        [Path] -> {Path, <<>>}
    end.

parse_query(<<>>) -> #{};
parse_query(Query) ->
    lists:foldl(
        fun(Pair, Acc) ->
            case binary:split(Pair, <<"=">>) of
                [Key, Value] ->
                    maps:put(Key, unquote_binary(Value), Acc);
                [Key] ->
                    maps:put(Key, <<>>, Acc)
            end
        end,
        #{},
        binary:split(Query, <<"&">>, [global])
    ).

content_length(Headers) ->
    Lines = binary:split(Headers, <<"\r\n">>, [global]),
    case lists:dropwhile(
        fun(Line) ->
            not lists:prefix("content-length:", string:lowercase(binary_to_list(Line)))
        end,
        Lines
    ) of
        [Line | _] ->
            case binary:split(Line, <<":">>) of
                [_Key, Value] ->
                    binary_to_integer(
                        unicode:characters_to_binary(
                            string:trim(binary_to_list(Value), both, " ")
                        )
                    );
                _ ->
                    0
            end;
        [] ->
            0
    end.

sse_reply(Socket) ->
    Response =
        <<
            "HTTP/1.1 200 OK\r\n",
            "Content-Type: text/event-stream\r\n",
            "Cache-Control: no-store\r\n",
            "Connection: keep-alive\r\n\r\n"
        >>,
    ok = gen_tcp:send(Socket, Response).

stream_events(Socket, RepoRoot, RunOption, Previous) ->
    Current = case night_shift@dash@stream:snapshot(RepoRoot, RunOption) of
        {ok, Value} -> Value;
        {error, _} -> none
    end,
    Events = night_shift@dash@stream:diff_events(Previous, Current),
    case send_sse_events(Socket, Events) of
        ok ->
            timer:sleep(1000),
            stream_events(Socket, RepoRoot, RunOption, Current);
        closed ->
            ok
    end.

send_sse_events(_Socket, []) ->
    ok;
send_sse_events(Socket, [Event | Rest]) ->
    Payload = night_shift@dash@stream:event_json(Event),
    Frame = <<"data: ", Payload/binary, "\n\n">>,
    case gen_tcp:send(Socket, Frame) of
        ok -> send_sse_events(Socket, Rest);
        {error, _} -> closed
    end.

reply(Socket, StatusCode, ContentType, Body) when is_binary(ContentType), is_binary(Body) ->
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
    ok = gen_tcp:send(Socket, Response);
reply(Socket, StatusCode, ContentType, Body) when is_list(Body) ->
    reply(Socket, StatusCode, ContentType, unicode:characters_to_binary(Body));
reply(Socket, StatusCode, ContentType, Body) when is_list(ContentType) ->
    reply(Socket, StatusCode, unicode:characters_to_binary(ContentType), Body).

status_line(200) -> <<"200 OK">>;
status_line(202) -> <<"202 Accepted">>;
status_line(400) -> <<"400 Bad Request">>;
status_line(404) -> <<"404 Not Found">>;
status_line(405) -> <<"405 Method Not Allowed">>;
status_line(409) -> <<"409 Conflict">>;
status_line(500) -> <<"500 Internal Server Error">>.

ensure_tables() ->
    ensure_table(?SESSIONS_TABLE),
    ensure_table(?COMMANDS_TABLE).

ensure_table(Name) ->
    case ets:info(Name) of
        undefined ->
            ets:new(Name, [named_table, public, set]),
            ok;
        _ ->
            ok
    end.

begin_command(RepoRoot, Name, RunId) ->
    ensure_tables(),
    case ets:lookup(?COMMANDS_TABLE, RepoRoot) of
        [] ->
            ets:insert(
                ?COMMANDS_TABLE,
                {RepoRoot, Name, empty_to_undefined(RunId), night_shift_system:timestamp(), <<"Running command">>}
            ),
            ok;
        _ ->
            {error, <<"Another Dash command is already running for this repository.">>}
    end.

finish_command(RepoRoot) ->
    ets:delete(?COMMANDS_TABLE, RepoRoot),
    ok.

build_url(Port) ->
    <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>.

run_id_option(<<>>) -> none;
run_id_option(undefined) -> none;
run_id_option(RunId) -> {some, RunId}.

query_run(Query) ->
    case maps:get(<<"run">>, Query, undefined) of
        undefined -> none;
        <<"latest">> -> none;
        <<>> -> none;
        RunId -> {some, RunId}
    end.

some_string(Value) -> {some, Value}.

empty_to_undefined(<<>>) -> undefined;
empty_to_undefined(Value) -> Value.

format_error(Prefix, Reason) ->
    unicode:characters_to_binary(io_lib:format("~s: ~p", [Prefix, Reason])).

format_crash(Class, Reason, Stack) ->
    unicode:characters_to_binary(io_lib:format("~p:~p ~p", [Class, Reason, Stack])).

unquote_binary(Value) ->
    unicode:characters_to_binary(uri_string:unquote(binary_to_list(Value))).

split_path(Path) ->
    [Segment || Segment <- binary:split(Path, <<"/">>, [global]), Segment =/= <<>>].

parse_run_path(Rest) ->
    case split_path(Rest) of
        [RunId, <<"events">>] -> {events, RunId};
        [RunId] -> {run, RunId};
        _ -> error
    end.

parse_run_command_path(Rest) ->
    case split_path(Rest) of
        [RunId, <<"start">>] -> {start, RunId};
        [RunId, <<"resume">>] -> {resume, RunId};
        [RunId, <<"resolve">>, <<"decisions">>] -> {resolve_decisions, RunId};
        [RunId, <<"recovery">>, Action] -> {recovery, RunId, Action};
        _ -> error
    end.

parse_artifact_path(Rest) ->
    case split_path(Rest) of
        [RunId | Segments] when Segments =/= [] ->
            {ok, RunId, [unquote_binary(Segment) || Segment <- Segments]};
        _ ->
            error
    end.
