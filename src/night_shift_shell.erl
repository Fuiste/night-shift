-module(night_shift_shell).

-export([run/3, run_streaming/3, run_streaming_prefixed/4, start/3, start_streaming/4, wait/1]).

-define(TABLE, night_shift_shell_jobs).

run(Command, Cwd, LogPath) ->
    ensure_table(),
    run_internal(Command, Cwd, LogPath, false, <<>>).

run_streaming(Command, Cwd, LogPath) ->
    ensure_table(),
    run_internal(Command, Cwd, LogPath, true, <<>>).

run_streaming_prefixed(Command, Cwd, LogPath, Prefix) ->
    ensure_table(),
    run_internal(Command, Cwd, LogPath, true, Prefix).

start(Command, Cwd, LogPath) ->
    ensure_table(),
    Handle = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    ets:insert(?TABLE, {Handle, pending}),
    spawn(fun() ->
        Result = run_internal(Command, Cwd, LogPath, false, <<>>),
        ets:insert(?TABLE, {Handle, done, Result})
    end),
    Handle.

start_streaming(Command, Cwd, LogPath, Prefix) ->
    ensure_table(),
    Handle = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    ets:insert(?TABLE, {Handle, pending}),
    spawn(fun() ->
        Result = run_internal(Command, Cwd, LogPath, true, Prefix),
        ets:insert(?TABLE, {Handle, done, Result})
    end),
    Handle.

wait(Handle) ->
    ensure_table(),
    case ets:lookup(?TABLE, Handle) of
        [{Handle, done, Result}] ->
            ets:delete(?TABLE, Handle),
            Result;
        _ ->
            timer:sleep(100),
            wait(Handle)
    end.

ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, set]),
            ok;
        _ ->
            ok
    end.

run_internal(Command, Cwd, LogPath, StreamOutput, Prefix) ->
    ok = ensure_log_path(LogPath),
    _ = file:write_file(binary_to_list(LogPath), <<>>),
    Port =
        open_port(
            {spawn_executable, "/bin/sh"},
            [
                binary,
                exit_status,
                use_stdio,
                stderr_to_stdout,
                eof,
                {line, 16384},
                {cd, binary_to_list(Cwd)},
                {args, ["-lc", binary_to_list(Command)]}
            ]
        ),
    collect(Port, LogPath, [], undefined, false, StreamOutput, Prefix, {false, none, 0, false}).

collect(Port, LogPath, Acc, Status, SeenEof, StreamOutput, Prefix, StreamState) ->
    receive
        {Port, {data, {eol, Line}}} ->
            Data = <<Line/binary, "\n">>,
            append_log(LogPath, Data),
            NextStreamState = maybe_stream(Data, StreamOutput, Prefix, StreamState),
            collect(
                Port,
                LogPath,
                [Data | Acc],
                Status,
                SeenEof,
                StreamOutput,
                Prefix,
                NextStreamState
            );
        {Port, {data, {noeol, Line}}} ->
            append_log(LogPath, Line),
            NextStreamState = maybe_stream(Line, StreamOutput, Prefix, StreamState),
            collect(
                Port,
                LogPath,
                [Line | Acc],
                Status,
                SeenEof,
                StreamOutput,
                Prefix,
                NextStreamState
            );
        {Port, eof} ->
            maybe_finish(Port, LogPath, Acc, Status, true, StreamOutput, Prefix, StreamState);
        {Port, {exit_status, ExitStatus}} ->
            maybe_finish(
                Port,
                LogPath,
                Acc,
                ExitStatus,
                SeenEof,
                StreamOutput,
                Prefix,
                StreamState
            )
    end.

maybe_finish(_Port, _LogPath, Acc, Status, true, _StreamOutput, _Prefix, _StreamState) when Status =/= undefined ->
    {Status, iolist_to_binary(lists:reverse(Acc))};
maybe_finish(Port, LogPath, Acc, Status, SeenEof, StreamOutput, Prefix, StreamState) ->
    collect(Port, LogPath, Acc, Status, SeenEof, StreamOutput, Prefix, StreamState).

append_log(LogPath, Data) ->
    ok = file:write_file(binary_to_list(LogPath), Data, [append]).

maybe_stream(_Data, false, _Prefix, StreamState) ->
    StreamState;
maybe_stream(Data, true, Prefix, StreamState) ->
    case classify_stream_line(Data, StreamState) of
        {skip, NextStreamState} ->
            NextStreamState;
        {print, PrintData, NextStreamState} ->
            print_stream(PrintData, Prefix),
            NextStreamState;
        {print_many, PrintList, NextStreamState} ->
            lists:foreach(fun(PrintData) -> print_stream(PrintData, Prefix) end, PrintList),
            NextStreamState
    end.

classify_stream_line(Data, {SuppressHtml, ExecMode, ExecLines, ExecTruncated}) when ExecMode =/= none ->
    case is_exec_boundary_line(Data) of
        true ->
            classify_stream_line(Data, {SuppressHtml, none, 0, false});
        false ->
            classify_exec_output(Data, {SuppressHtml, ExecMode, ExecLines, ExecTruncated})
    end;
classify_stream_line(Data, {true, ExecMode, ExecLines, ExecTruncated}) ->
    case binary:match(Data, <<"</html>">>) of
        nomatch -> {skip, {true, ExecMode, ExecLines, ExecTruncated}};
        _ -> {skip, {false, ExecMode, ExecLines, ExecTruncated}}
    end;
classify_stream_line(Data, {false, _ExecMode, _ExecLines, _ExecTruncated}) ->
    case classify_exec_status_line(Data) of
        {ok, succeeded} ->
            {print_many, [Data, <<"  output hidden; see log for full command output\n">>], {false, succeeded, 0, false}};
        {ok, failed} ->
            {print, Data, {false, failed, 0, false}};
        error ->
    case should_suppress_line(Data) of
                suppress_html -> {skip, {true, none, 0, false}};
                suppress -> {skip, {false, none, 0, false}};
                keep -> {print, Data, {false, none, 0, false}}
            end
    end.

classify_exec_output(_Data, {SuppressHtml, succeeded, ExecLines, ExecTruncated}) ->
    {skip, {SuppressHtml, succeeded, ExecLines, ExecTruncated}};
classify_exec_output(Data, {SuppressHtml, failed, ExecLines, false}) when ExecLines < 8 ->
    {print, Data, {SuppressHtml, failed, ExecLines + 1, false}};
classify_exec_output(_Data, {SuppressHtml, failed, ExecLines, false}) ->
    {print, <<"  output truncated; see log for full command output\n">>, {SuppressHtml, failed, ExecLines, true}};
classify_exec_output(_Data, {SuppressHtml, failed, ExecLines, true}) ->
    {skip, {SuppressHtml, failed, ExecLines, true}}.

should_suppress_line(Data) ->
    case is_plugin_manifest_warning(Data) orelse is_shell_snapshot_warning(Data) of
        true -> suppress;
        false ->
            case is_featured_plugin_warning(Data) of
                true -> suppress_html;
                false -> keep
            end
    end.

is_plugin_manifest_warning(Data) ->
    binary:match(Data, <<"WARN codex_core::plugins::manifest: ignoring interface.defaultPrompt:">>) =/= nomatch.

is_featured_plugin_warning(Data) ->
    binary:match(Data, <<"WARN codex_core::plugins::manager: failed to warm featured plugin ids cache">>) =/= nomatch.

is_shell_snapshot_warning(Data) ->
    binary:match(Data, <<"WARN codex_core::shell_snapshot: Failed to delete shell snapshot">>) =/= nomatch.

classify_exec_status_line(Data) ->
    case binary:match(Data, <<" succeeded in ">>) =/= nomatch of
        true -> {ok, succeeded};
        false ->
            case binary:match(Data, <<" failed in ">>) =/= nomatch of
                true -> {ok, failed};
                false -> error
            end
    end.

is_exec_boundary_line(<<"codex\n">>) ->
    true;
is_exec_boundary_line(<<"exec\n">>) ->
    true;
is_exec_boundary_line(Data) ->
    binary:match(Data, <<"NIGHT_SHIFT_RESULT_START">>) =/= nomatch
        orelse binary:match(Data, <<"Updated planning brief:">>) =/= nomatch
        orelse binary:match(Data, <<"OpenAI Codex v">>) =/= nomatch.

print_stream(Data, <<>>) ->
    ok = io:put_chars(Data);
print_stream(Data, Prefix) ->
    ok = io:put_chars([<<"[">>, Prefix/binary, <<"] ">>, Data]).

ensure_log_path(LogPath) ->
    ok = filelib:ensure_dir(binary_to_list(LogPath)),
    ok.
