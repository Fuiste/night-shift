-module(night_shift_shell).

-export([run/3, start/3, wait/1]).

-define(TABLE, night_shift_shell_jobs).

run(Command, Cwd, LogPath) ->
    ensure_table(),
    run_internal(Command, Cwd, LogPath).

start(Command, Cwd, LogPath) ->
    ensure_table(),
    Handle = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    ets:insert(?TABLE, {Handle, pending}),
    spawn(fun() ->
        Result = run_internal(Command, Cwd, LogPath),
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

run_internal(Command, Cwd, LogPath) ->
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
    collect(Port, LogPath, [], undefined, false).

collect(Port, LogPath, Acc, Status, SeenEof) ->
    receive
        {Port, {data, {eol, Line}}} ->
            Data = <<Line/binary, "\n">>,
            append_log(LogPath, Data),
            collect(Port, LogPath, [Data | Acc], Status, SeenEof);
        {Port, {data, {noeol, Line}}} ->
            append_log(LogPath, Line),
            collect(Port, LogPath, [Line | Acc], Status, SeenEof);
        {Port, eof} ->
            maybe_finish(Port, LogPath, Acc, Status, true);
        {Port, {exit_status, ExitStatus}} ->
            maybe_finish(Port, LogPath, Acc, ExitStatus, SeenEof)
    end.

maybe_finish(_Port, _LogPath, Acc, Status, true) when Status =/= undefined ->
    {Status, iolist_to_binary(lists:reverse(Acc))};
maybe_finish(Port, LogPath, Acc, Status, SeenEof) ->
    collect(Port, LogPath, Acc, Status, SeenEof).

append_log(LogPath, Data) ->
    ok = file:write_file(binary_to_list(LogPath), Data, [append]).

ensure_log_path(LogPath) ->
    ok = filelib:ensure_dir(binary_to_list(LogPath)),
    ok.
