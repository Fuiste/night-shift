-module(night_shift_shell).

-export([run/3, run_streaming/7, start/3, start_streaming/7, wait/1]).

-define(TABLE, night_shift_shell_jobs).
-define(RENDERER, night_shift_shell_renderer).
-define(START_MARKER, <<"NIGHT_SHIFT_RESULT_START">>).
-define(END_MARKER, <<"NIGHT_SHIFT_RESULT_END">>).

run(Command, Cwd, LogPath) ->
    ensure_table(),
    run_internal(Command, Cwd, LogPath, none).

run_streaming(Command, Cwd, LogPath, Label, PromptPath, Harness, Phase) ->
    ensure_table(),
    StreamMeta = make_stream_meta(Label, PromptPath, Harness, Phase, LogPath),
    run_internal(Command, Cwd, LogPath, StreamMeta).

start(Command, Cwd, LogPath) ->
    ensure_table(),
    Handle = unique_handle(),
    ets:insert(?TABLE, {Handle, pending}),
    spawn(fun() ->
        Result = run_internal(Command, Cwd, LogPath, none),
        ets:insert(?TABLE, {Handle, done, Result})
    end),
    Handle.

start_streaming(Command, Cwd, LogPath, Label, PromptPath, Harness, Phase) ->
    ensure_table(),
    Handle = unique_handle(),
    StreamMeta =
        maps:put(id, Handle, make_stream_meta(Label, PromptPath, Harness, Phase, LogPath)),
    ets:insert(?TABLE, {Handle, pending}),
    spawn(fun() ->
        Result = run_internal(Command, Cwd, LogPath, StreamMeta),
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

run_internal(Command, Cwd, LogPath, StreamMeta) ->
    ok = ensure_log_path(LogPath),
    _ = file:write_file(binary_to_list(LogPath), <<>>),
    StreamMeta1 =
        case StreamMeta of
            none ->
                none;
            Meta ->
                EventLogPath = maps:get(event_log_path, Meta),
                ok = ensure_log_path(EventLogPath),
                _ = file:write_file(binary_to_list(EventLogPath), <<>>),
                Meta1 =
                    case maps:is_key(id, Meta) of
                        true -> Meta;
                        false -> maps:put(id, unique_handle(), Meta)
                    end,
                init_stream(Meta1)
        end,
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
                {args, ["-c", binary_to_list(Command)]}
            ]
        ),
    collect(
        Port,
        LogPath,
        [],
        undefined,
        false,
        StreamMeta1,
        #{parser_failed => false, pending_line => <<>>}
    ).

collect(Port, LogPath, Acc, Status, SeenEof, StreamMeta, ParserState) ->
    receive
        {Port, {data, {eol, Line}}} ->
            Data = <<Line/binary, "\n">>,
            maybe_append_raw_log(LogPath, StreamMeta, Data),
            NextParserState = maybe_stream(Data, true, StreamMeta, ParserState),
            collect(Port, LogPath, [Data | Acc], Status, SeenEof, StreamMeta, NextParserState);
        {Port, {data, {noeol, Line}}} ->
            maybe_append_raw_log(LogPath, StreamMeta, Line),
            NextParserState = maybe_stream(Line, false, StreamMeta, ParserState),
            collect(Port, LogPath, [Line | Acc], Status, SeenEof, StreamMeta, NextParserState);
        {Port, eof} ->
            maybe_finish(Port, LogPath, Acc, Status, true, StreamMeta, ParserState);
        {Port, {exit_status, ExitStatus}} ->
            maybe_finish(Port, LogPath, Acc, ExitStatus, SeenEof, StreamMeta, ParserState)
    end.

maybe_finish(_Port, _LogPath, Acc, Status, true, StreamMeta, _ParserState) when Status =/= undefined ->
    maybe_complete_stream(StreamMeta, Status),
    {Status, iolist_to_binary(lists:reverse(Acc))};
maybe_finish(Port, LogPath, Acc, Status, SeenEof, StreamMeta, ParserState) ->
    FlushedState = flush_pending_line(StreamMeta, ParserState),
    collect(Port, LogPath, Acc, Status, SeenEof, StreamMeta, FlushedState).

maybe_stream(_Data, _CompleteLine, none, ParserState) ->
    ParserState;
maybe_stream(Data, CompleteLine, StreamMeta, ParserState) ->
    Pending = maps:get(pending_line, ParserState, <<>>),
    Combined = <<Pending/binary, Data/binary>>,
    case CompleteLine of
        false ->
            maps:put(pending_line, Combined, ParserState);
        true ->
            process_complete_line(
                Combined,
                StreamMeta,
                maps:put(pending_line, <<>>, ParserState)
            )
    end.

process_complete_line(Data, StreamMeta, ParserState) ->
    LogPath = maps:get(log_path, StreamMeta),
    case maps:get(parser_failed, ParserState, false) of
        true ->
            append_file(LogPath, Data),
            send_renderer(StreamMeta, raw_event(StreamMeta, normalize_raw_text(Data))),
            ParserState;
        false ->
            process_structured_line(Data, StreamMeta, ParserState)
    end.

flush_pending_line(none, ParserState) ->
    maps:put(pending_line, <<>>, ParserState);
flush_pending_line(StreamMeta, ParserState) ->
    case maps:get(pending_line, ParserState, <<>>) of
        <<>> -> ParserState;
        Pending ->
            process_complete_line(
                Pending,
                StreamMeta,
                maps:put(pending_line, <<>>, ParserState)
            )
    end.

process_structured_line(Data, StreamMeta, ParserState) ->
    Trimmed = trim_binary(Data),
    LogPath = maps:get(log_path, StreamMeta),
    case Trimmed of
        <<>> -> ParserState;
        _ ->
            case binary:at(Trimmed, 0) of
                ${ ->
                    case decode_json(Trimmed) of
                        {ok, Json} ->
                            append_file(maps:get(event_log_path, StreamMeta), <<Trimmed/binary, "\n">>),
                            Events = normalize_json_event(Json, StreamMeta),
                            lists:foreach(fun(Event) -> handle_event(StreamMeta, Event) end, Events),
                            ParserState;
                        error ->
                            append_file(LogPath, Data),
                            send_renderer(StreamMeta, raw_event(StreamMeta, normalize_raw_text(Data))),
                            maps:put(parser_failed, true, ParserState)
                    end;
                _ ->
                    case normalize_non_json_line(Trimmed, StreamMeta) of
                        [] -> ParserState;
                        Events ->
                            lists:foreach(fun(Event) -> handle_event(StreamMeta, Event) end, Events),
                            ParserState
                    end
            end
    end.

handle_event(StreamMeta, Event) ->
    case event_log_line(Event) of
        <<>> -> ok;
        Line -> append_file(maps:get(log_path, StreamMeta), Line)
    end,
    send_renderer(StreamMeta, Event).

maybe_complete_stream(none, _ExitStatus) ->
    ok;
maybe_complete_stream(StreamMeta, ExitStatus) ->
    Status =
        case ExitStatus of
            0 -> completed;
            _ -> failed
        end,
    send_renderer(
        StreamMeta,
        #{
            kind => stream_done,
            status => Status,
            exit_code => ExitStatus,
            text => format_done_text(Status, ExitStatus, maps:get(log_path, StreamMeta))
        }
    ).

normalize_non_json_line(Data, _StreamMeta) ->
    case should_suppress_line(Data) of
        true -> [];
        false ->
            Text = normalize_raw_text(Data),
            case Text of
                <<>> -> [];
                _ ->
                    case is_warning_line(Data) of
                        true -> [warning_event(Text)];
                        false -> [raw_event(#{}, Text)]
                    end
            end
    end.

normalize_json_event(#{<<"type">> := <<"thread.started">>}, _StreamMeta) ->
    [session_event(<<"Session started.">>)];
normalize_json_event(#{<<"type">> := <<"turn.started">>}, _StreamMeta) ->
    [];
normalize_json_event(
    #{<<"type">> := <<"item.started">>, <<"item">> := #{<<"type">> := <<"command_execution">>} = Item},
    _StreamMeta
) ->
    [tool_started_event(command_label(Item))];
normalize_json_event(
    #{<<"type">> := <<"item.completed">>, <<"item">> := #{<<"type">> := <<"command_execution">>} = Item},
    _StreamMeta
) ->
    [tool_finished_event(command_label(Item), maps:get(<<"exit_code">>, Item, 0), command_output(Item))];
normalize_json_event(
    #{<<"type">> := <<"item.completed">>, <<"item">> := #{<<"type">> := <<"agent_message">>, <<"text">> := Text}},
    _StreamMeta
) ->
    assistant_events(Text);
normalize_json_event(#{<<"type">> := <<"turn.completed">>}, _StreamMeta) ->
    [];
normalize_json_event(#{<<"type">> := <<"system">>, <<"subtype">> := <<"init">>} = Json, _StreamMeta) ->
    Model = maps:get(<<"model">>, Json, <<"unknown">>),
    [session_event(<<"Session started (", Model/binary, ").">>)];
normalize_json_event(#{<<"type">> := <<"user">>}, _StreamMeta) ->
    [];
normalize_json_event(#{<<"type">> := <<"assistant">>} = Json, _StreamMeta) ->
    case maps:is_key(<<"timestamp_ms">>, Json) of
        true -> [assistant_delta_event(extract_cursor_assistant_text(Json))];
        false -> []
    end;
normalize_json_event(
    #{<<"type">> := <<"tool_call">>, <<"subtype">> := <<"started">>} = Json,
    _StreamMeta
) ->
    [tool_started_event(cursor_tool_label(Json))];
normalize_json_event(
    #{<<"type">> := <<"tool_call">>, <<"subtype">> := <<"completed">>} = Json,
    _StreamMeta
) ->
    [tool_finished_event(cursor_tool_label(Json), cursor_tool_exit_code(Json), cursor_tool_output(Json))];
normalize_json_event(#{<<"type">> := <<"result">>, <<"result">> := Text}, _StreamMeta) ->
    assistant_events(Text);
normalize_json_event(#{<<"type">> := <<"error">>} = Json, _StreamMeta) ->
    [error_event(extract_field(Json, [<<"message">>], <<"Harness error.">>))];
normalize_json_event(_, _StreamMeta) ->
    [].

assistant_events(Text) ->
    case strip_payload(Text) of
        {<<>>, true} -> [result_event(<<"Structured result captured.">>)];
        {Visible, true} -> [assistant_final_event(Visible), result_event(<<"Structured result captured.">>)];
        {Visible, false} when Visible =/= <<>> -> [assistant_final_event(Visible)];
        _ -> []
    end.

strip_payload(Text) ->
    case binary:match(Text, ?START_MARKER) of
        nomatch -> {trim_binary(Text), false};
        {Start, _} ->
            Before = trim_binary(binary:part(Text, 0, Start)),
            AfterStart = binary:part(Text, Start, byte_size(Text) - Start),
            case binary:match(AfterStart, ?END_MARKER) of
                nomatch -> {Before, true};
                {EndStart, EndLen} ->
                    SuffixOffset = EndStart + EndLen,
                    SuffixLength = byte_size(AfterStart) - SuffixOffset,
                    Suffix =
                        case SuffixLength > 0 of
                            true -> trim_binary(binary:part(AfterStart, SuffixOffset, SuffixLength));
                            false -> <<>>
                        end,
                    {join_visible_text([Before, Suffix]), true}
            end
    end.

join_visible_text(Parts) ->
    NonEmpty = [trim_binary(Part) || Part <- Parts, trim_binary(Part) =/= <<>>],
    case NonEmpty of
        [] -> <<>>;
        _ -> iolist_to_binary(string:join([binary_to_list(Part) || Part <- NonEmpty], "\n"))
    end.

session_event(Text) -> #{kind => session, text => Text}.
assistant_delta_event(Text) -> #{kind => assistant_delta, text => Text}.
assistant_final_event(Text) -> #{kind => assistant_final, text => Text}.
tool_started_event(Text) -> #{kind => tool_started, text => Text}.
tool_finished_event(Text, ExitCode, Output) -> #{kind => tool_finished, text => Text, exit_code => ExitCode, output => Output}.
warning_event(Text) -> #{kind => warning, text => Text}.
error_event(Text) -> #{kind => error, text => Text}.
result_event(Text) -> #{kind => result, text => Text}.
raw_event(_StreamMeta, Text) -> #{kind => raw, text => Text}.

event_log_line(#{kind := assistant_delta}) ->
    <<>>;
event_log_line(#{kind := assistant_final, text := Text}) ->
    format_log_entry(<<"assistant">>, Text);
event_log_line(#{kind := tool_started, text := Text}) ->
    format_log_entry(<<"tool">>, <<"started: ", Text/binary>>);
event_log_line(#{kind := tool_finished, text := Text, exit_code := ExitCode, output := Output}) ->
    Suffix =
        case Output of
            <<>> -> <<>>;
            _ -> <<"\n", Output/binary>>
        end,
    format_log_entry(<<"tool">>, <<"finished (", (integer_to_binary(ExitCode))/binary, "): ", Text/binary, Suffix/binary>>);
event_log_line(#{kind := warning, text := Text}) ->
    format_log_entry(<<"warning">>, Text);
event_log_line(#{kind := error, text := Text}) ->
    format_log_entry(<<"error">>, Text);
event_log_line(#{kind := result, text := Text}) ->
    format_log_entry(<<"result">>, Text);
event_log_line(#{kind := session, text := Text}) ->
    format_log_entry(<<"session">>, Text);
event_log_line(#{kind := raw, text := Text}) ->
    format_log_entry(<<"output">>, Text);
event_log_line(#{kind := stream_done, text := Text}) ->
    format_log_entry(<<"status">>, Text);
event_log_line(_) ->
    <<>>.

format_log_entry(Tag, Text) ->
    <<"[", Tag/binary, "] ", Text/binary, "\n">>.

decode_json(Data) ->
    try
        {ok, json:decode(Data)}
    catch
        _:_ -> error
    end.

command_label(Item) ->
    trim_binary(maps:get(<<"command">>, Item, <<"command">>)).

command_output(Item) ->
    compact_output(maps:get(<<"aggregated_output">>, Item, <<>>)).

extract_cursor_assistant_text(Json) ->
    Content = extract_field(Json, [<<"message">>, <<"content">>], []),
    extract_cursor_text_blocks(Content).

extract_cursor_text_blocks(Content) when is_list(Content) ->
    Texts =
        [maps:get(<<"text">>, Block, <<>>) || Block <- Content, is_map(Block), maps:get(<<"type">>, Block, <<>>) =:= <<"text">>],
    iolist_to_binary(Texts);
extract_cursor_text_blocks(_) ->
    <<>>.

cursor_tool_label(Json) ->
    Description = extract_field(Json, [<<"tool_call">>, <<"shellToolCall">>, <<"description">>], <<>>),
    case trim_binary(Description) of
        <<>> ->
            extract_field(Json, [<<"tool_call">>, <<"shellToolCall">>, <<"args">>, <<"command">>], <<"tool">>);
        Value -> Value
    end.

cursor_tool_exit_code(Json) ->
    extract_field(Json, [<<"tool_call">>, <<"shellToolCall">>, <<"result">>, <<"success">>, <<"exitCode">>], 0).

cursor_tool_output(Json) ->
    Output =
        extract_field(
            Json,
            [<<"tool_call">>, <<"shellToolCall">>, <<"result">>, <<"success">>, <<"interleavedOutput">>],
            <<>>
        ),
    compact_output(Output).

extract_field(Value, [], _Default) ->
    Value;
extract_field(Map, [Key | Rest], Default) when is_map(Map) ->
    case maps:get(Key, Map, missing) of
        missing -> Default;
        Next -> extract_field(Next, Rest, Default)
    end;
extract_field(_, _, Default) ->
    Default.

compact_output(Output) ->
    Trimmed = trim_binary(Output),
    case byte_size(Trimmed) > 160 of
        true -> <<(binary:part(Trimmed, 0, 157))/binary, "...">>;
        false -> Trimmed
    end.

send_renderer(StreamMeta, Event) ->
    Renderer = ensure_renderer(),
    Renderer ! {stream_event, maps:get(id, StreamMeta), StreamMeta, Event},
    ok.

init_stream(StreamMeta) ->
    append_file(
        maps:get(log_path, StreamMeta),
        <<"[session] ", (maps:get(harness, StreamMeta))/binary, " ", (maps:get(phase, StreamMeta))/binary, " stream for ", (maps:get(label, StreamMeta))/binary, "\n",
          "[session] Prompt hidden; see ", (maps:get(prompt_path, StreamMeta))/binary, "\n",
          "[session] Raw event log: ", (maps:get(event_log_path, StreamMeta))/binary, "\n">>
    ),
    Renderer = ensure_renderer(),
    Renderer ! {register_stream, maps:get(id, StreamMeta), StreamMeta},
    StreamMeta.

ensure_renderer() ->
    case whereis(?RENDERER) of
        undefined ->
            Pid = spawn(fun renderer_loop/0),
            true = register(?RENDERER, Pid),
            Pid;
        Pid -> Pid
    end.

renderer_loop() ->
    renderer_loop(
        #{
            mode => ui_mode(),
            color => color_enabled(),
            width => terminal_width(),
            height => terminal_height(),
            streams => #{},
            finished => [],
            focus => undefined,
            pinned => undefined,
            render_pending => false,
            alt_active => false,
            spinner_index => 0
        }
    ).

renderer_loop(State) ->
    receive
        {register_stream, Id, StreamMeta} ->
            State1 = maybe_enter_alt(State),
            Stream =
                #{
                    id => Id,
                    label => maps:get(label, StreamMeta),
                    prompt_path => maps:get(prompt_path, StreamMeta),
                    harness => maps:get(harness, StreamMeta),
                    phase => maps:get(phase, StreamMeta),
                    log_path => maps:get(log_path, StreamMeta),
                    status => running,
                    started_at => erlang:monotonic_time(millisecond),
                    updated_at => erlang:monotonic_time(millisecond),
                    transcript => [],
                    live_assistant => <<>>,
                    last_activity => <<"Waiting for harness output...">>
                },
            State2 =
                State1#{
                    streams := maps:put(Id, Stream, maps:get(streams, State1)),
                    focus := choose_focus(Id, State1)
                },
            State3 = maybe_print_plain_register(State2, Stream),
            maybe_continue_renderer(schedule_render(State3));
        {stream_event, Id, _StreamMeta, Event} ->
            State1 = maybe_print_plain_event_before_update(State, Id, Event),
            State2 = update_stream_state(State1, Id, Event),
            State3 = maybe_print_plain_event_after_update(State2, Id, Event),
            maybe_continue_renderer(schedule_render(State3));
        render ->
            State1 = render_now(State#{render_pending := false}),
            maybe_continue_renderer(State1)
    end.

maybe_continue_renderer(State) ->
    case maps:size(maps:get(streams, State)) =:= 0 andalso maps:get(render_pending, State) =:= false of
        true -> ok;
        false -> renderer_loop(State)
    end.

maybe_print_plain_event_before_update(State, Id, Event = #{kind := stream_done}) ->
    maybe_print_plain_event(State, Id, Event);
maybe_print_plain_event_before_update(State, _Id, _Event) ->
    State.

maybe_print_plain_event_after_update(State, _Id, #{kind := stream_done}) ->
    State;
maybe_print_plain_event_after_update(State, Id, Event) ->
    maybe_print_plain_event(State, Id, Event).

maybe_print_plain_register(State = #{mode := plain}, Stream) ->
    safe_put_chars(format_plain_prefix(Stream) ++ " " ++ binary_to_list(<<"prompt hidden; see ", (maps:get(prompt_path, Stream))/binary, "\n">>)),
    State;
maybe_print_plain_register(State, _Stream) ->
    State.

maybe_print_plain_event(State = #{mode := plain}, Id, Event) ->
    case maps:get(Id, maps:get(streams, State), undefined) of
        undefined -> State;
        Stream ->
            case plain_event_line(Stream, Event, maps:get(color, State)) of
                <<>> -> State;
                Line ->
                    safe_put_chars(Line),
                    State
            end
    end;
maybe_print_plain_event(State, _Id, _Event) ->
    State.

plain_event_line(_Stream, #{kind := assistant_delta}, _ColorEnabled) ->
    <<>>;
plain_event_line(Stream, #{kind := assistant_final, text := Text}, ColorEnabled) ->
    format_plain_line(Stream, <<"assistant: ", Text/binary>>, ColorEnabled);
plain_event_line(Stream, #{kind := tool_started, text := Text}, ColorEnabled) ->
    format_plain_line(Stream, <<"tool: ", Text/binary>>, ColorEnabled);
plain_event_line(Stream, #{kind := tool_finished, text := Text, exit_code := ExitCode, output := Output}, ColorEnabled) ->
    Message =
        case Output of
            <<>> -> <<"tool finished (", (integer_to_binary(ExitCode))/binary, "): ", Text/binary>>;
            _ -> <<"tool finished (", (integer_to_binary(ExitCode))/binary, "): ", Text/binary, " => ", Output/binary>>
        end,
    format_plain_line(Stream, Message, ColorEnabled);
plain_event_line(Stream, #{kind := warning, text := Text}, ColorEnabled) ->
    format_plain_line(Stream, <<"warning: ", Text/binary>>, ColorEnabled);
plain_event_line(Stream, #{kind := error, text := Text}, ColorEnabled) ->
    format_plain_line(Stream, <<"error: ", Text/binary>>, ColorEnabled);
plain_event_line(Stream, #{kind := result, text := Text}, ColorEnabled) ->
    format_plain_line(Stream, <<"result: ", Text/binary>>, ColorEnabled);
plain_event_line(Stream, #{kind := raw, text := Text}, ColorEnabled) ->
    format_plain_line(Stream, Text, ColorEnabled);
plain_event_line(Stream, #{kind := stream_done, text := Text}, ColorEnabled) ->
    format_plain_line(Stream, Text, ColorEnabled);
plain_event_line(Stream, #{kind := session, text := Text}, ColorEnabled) ->
    format_plain_line(Stream, Text, ColorEnabled);
plain_event_line(_, _, _) ->
    <<>>.

format_plain_line(Stream, Message, ColorEnabled) ->
    Prefix =
        case ColorEnabled of
            true -> <<"\e[36m[", (maps:get(label, Stream))/binary, "]\e[0m">>;
            false -> <<"[", (maps:get(label, Stream))/binary, "]">>
        end,
    <<Prefix/binary, " ", Message/binary, "\n">>.

format_plain_prefix(Stream) ->
    binary_to_list(<<"[", (maps:get(label, Stream))/binary, "]">>).

update_stream_state(State, Id, Event) ->
    Streams = maps:get(streams, State),
    case maps:get(Id, Streams, undefined) of
        undefined -> State;
        Stream ->
            Stream1 = apply_event(Stream, Event),
            Streams1 =
                case maps:get(kind, Event) of
                    stream_done ->
                        maps:remove(Id, Streams);
                    _ ->
                        maps:put(Id, Stream1, Streams)
                end,
            Finished1 =
                case maps:get(kind, Event) of
                    stream_done ->
                        [finished_stream(Stream1) | maps:get(finished, State)];
                    _ ->
                        maps:get(finished, State)
                end,
            Focus = ensure_focus(next_focus(State, Id, Event), Streams1),
            Pinned = ensure_pinned(next_pinned(State, Id, Event), Streams1),
            State#{
                streams := Streams1,
                finished := Finished1,
                focus := Focus,
                pinned := Pinned
            }
    end.

apply_event(Stream, #{kind := assistant_delta, text := Text}) ->
    Stream#{
        live_assistant := <<(maps:get(live_assistant, Stream))/binary, Text/binary>>,
        updated_at := erlang:monotonic_time(millisecond),
        last_activity := <<"Assistant is typing...">>
    };
apply_event(Stream, #{kind := assistant_final, text := Text}) ->
    Stream#{
        live_assistant := <<>>,
        transcript := append_transcript(maps:get(transcript, Stream), <<"assistant: ", Text/binary>>),
        updated_at := erlang:monotonic_time(millisecond),
        last_activity := <<"Assistant responded.">>
    };
apply_event(Stream, #{kind := tool_started, text := Text}) ->
    Stream#{
        transcript := append_transcript(maps:get(transcript, Stream), <<"tool: ", Text/binary>>),
        updated_at := erlang:monotonic_time(millisecond),
        last_activity := <<"Tool started: ", Text/binary>>
    };
apply_event(Stream, #{kind := tool_finished, text := Text, exit_code := ExitCode, output := Output}) ->
    Line =
        case Output of
            <<>> -> <<"tool finished (", (integer_to_binary(ExitCode))/binary, "): ", Text/binary>>;
            _ -> <<"tool finished (", (integer_to_binary(ExitCode))/binary, "): ", Text/binary, " => ", Output/binary>>
        end,
    Stream#{
        transcript := append_transcript(maps:get(transcript, Stream), Line),
        updated_at := erlang:monotonic_time(millisecond),
        last_activity := <<"Tool finished.">>
    };
apply_event(Stream, #{kind := warning, text := Text}) ->
    Stream#{
        transcript := append_transcript(maps:get(transcript, Stream), <<"warning: ", Text/binary>>),
        updated_at := erlang:monotonic_time(millisecond),
        last_activity := <<"Warning received.">>
    };
apply_event(Stream, #{kind := error, text := Text}) ->
    Stream#{
        transcript := append_transcript(maps:get(transcript, Stream), <<"error: ", Text/binary>>),
        updated_at := erlang:monotonic_time(millisecond),
        last_activity := <<"Harness error.">>
    };
apply_event(Stream, #{kind := result, text := Text}) ->
    Stream#{
        transcript := append_transcript(maps:get(transcript, Stream), <<"result: ", Text/binary>>),
        updated_at := erlang:monotonic_time(millisecond),
        last_activity := <<"Structured result captured.">>
    };
apply_event(Stream, #{kind := raw, text := Text}) ->
    Stream#{
        transcript := append_transcript(maps:get(transcript, Stream), Text),
        updated_at := erlang:monotonic_time(millisecond),
        last_activity := <<"Streaming raw output.">>
    };
apply_event(Stream, #{kind := session, text := Text}) ->
    Stream#{
        transcript := append_transcript(maps:get(transcript, Stream), Text),
        updated_at := erlang:monotonic_time(millisecond),
        last_activity := Text
    };
apply_event(Stream, #{kind := stream_done, status := Status, text := Text}) ->
    Stream#{
        status := Status,
        live_assistant := <<>>,
        transcript := append_transcript(maps:get(transcript, Stream), Text),
        updated_at := erlang:monotonic_time(millisecond),
        last_activity := Text
    };
apply_event(Stream, _) ->
    Stream.

append_transcript(Lines, Line) ->
    Trimmed = trim_binary(Line),
    case Trimmed of
        <<>> -> Lines;
        _ ->
            Updated = Lines ++ [Trimmed],
            case length(Updated) > 120 of
                true -> lists:nthtail(length(Updated) - 120, Updated);
                false -> Updated
            end
    end.

next_focus(_State, Id, #{kind := stream_done, status := failed}) ->
    Id;
next_focus(#{pinned := Pinned}, _Id, _Event) when Pinned =/= undefined ->
    Pinned;
next_focus(_State, Id, #{kind := assistant_delta}) ->
    Id;
next_focus(_State, Id, #{kind := assistant_final}) ->
    Id;
next_focus(_State, Id, #{kind := tool_started}) ->
    Id;
next_focus(_State, Id, #{kind := tool_finished}) ->
    Id;
next_focus(_State, Id, #{kind := warning}) ->
    Id;
next_focus(_State, Id, #{kind := error}) ->
    Id;
next_focus(State, _Id, _Event) ->
    maps:get(focus, State).

next_pinned(_State, _Id, #{kind := stream_done}) ->
    undefined;
next_pinned(State, _Id, _Event) ->
    maps:get(pinned, State).

choose_focus(Id, #{pinned := undefined}) -> Id;
choose_focus(_Id, State) -> maps:get(pinned, State).

schedule_render(State = #{mode := plain}) ->
    State;
schedule_render(State = #{render_pending := true}) ->
    State;
schedule_render(State) ->
    _ = erlang:send_after(60, self(), render),
    State#{render_pending := true}.

render_now(State = #{mode := plain}) ->
    State;
render_now(State) ->
    Lines = render_screen(State),
    safe_put_chars([<<"\e[H\e[2J">>, Lines]),
    case maps:size(maps:get(streams, State)) of
        0 ->
            State1 = maybe_leave_alt(State),
            print_finished_summary(State1),
            State1#{finished := []};
        _ ->
            _ = erlang:send_after(120, self(), render),
            State#{render_pending := true, spinner_index := maps:get(spinner_index, State) + 1}
    end.

render_screen(State) ->
    Width = maps:get(width, State),
    Height = maps:get(height, State),
    Now = erlang:monotonic_time(millisecond),
    Streams = maps:values(maps:get(streams, State)),
    HeaderLines = render_header_lines(State, Streams, Width),
    FooterLines = render_footer_lines(State, Streams, Width),
    MiddleHeight = max(Height - length(HeaderLines) - length(FooterLines) - 2, 0),
    Focused = focused_stream(State, Streams),
    BodyLines =
        case Width >= 100 of
            true ->
                LeftWidth = min(max(38, Width div 3), 46),
                RightWidth = max(Width - LeftWidth - 3, 24),
                join_columns_lines(
                    render_task_cards_lines(Streams, LeftWidth, MiddleHeight, Now),
                    render_transcript_lines(Focused, RightWidth, MiddleHeight),
                    LeftWidth,
                    RightWidth
                );
            false ->
                fit_head_lines(render_task_cards_lines(Streams, Width, MiddleHeight, Now), max(MiddleHeight div 2, 4))
                ++ [<<>>]
                ++ fit_tail_lines(render_transcript_lines(Focused, Width, MiddleHeight), max(MiddleHeight div 2, 6))
    end,
    BodyLines1 = pad_lines(BodyLines, MiddleHeight),
    join_lines(HeaderLines ++ [<<>>] ++ BodyLines1 ++ [<<>>] ++ FooterLines).

render_header_lines(State, Streams, Width) ->
    Active = length([Stream || Stream <- Streams, maps:get(status, Stream) =:= running]),
    Completed = length([Stream || Stream <- Streams, maps:get(status, Stream) =:= completed]),
    Failed = length([Stream || Stream <- Streams, maps:get(status, Stream) =:= failed]),
    Focus = focused_stream(State, Streams),
    Title =
        case Focus of
            undefined -> <<"Night Shift stream">>;
            FocusedStream ->
                <<"Night Shift stream | ", (maps:get(harness, FocusedStream))/binary, " ", (maps:get(phase, FocusedStream))/binary, " | ", (maps:get(label, FocusedStream))/binary>>
        end,
    StatsLine =
        <<"Active: ", (integer_to_binary(Active))/binary, "  Completed: ", (integer_to_binary(Completed))/binary, "  Failed: ", (integer_to_binary(Failed))/binary>>,
    PromptLine0 =
        case Focus of
            undefined -> <<"Prompt hidden; see stream prompt artifacts and logs.">>;
            FocusedPromptStream ->
                <<"Prompt hidden; see ", (display_path(maps:get(prompt_path, FocusedPromptStream), max(Width - 20, 24)))/binary>>
        end,
    [rule_line($=, Width)]
    ++ wrap_lines(Title, Width)
    ++ wrap_lines(StatsLine, Width)
    ++ wrap_lines(PromptLine0, Width).

render_footer_lines(State, Streams, Width) ->
    Spinner = spinner_frame(maps:get(spinner_index, State)),
    Focus = focused_stream(State, Streams),
    StatusLine =
        case Focus of
            undefined ->
                <<"Idle ", Spinner/binary, "  Waiting for streams...">>;
            FocusedStream ->
                <<"Thinking ", Spinner/binary, "  ", (maps:get(last_activity, FocusedStream))/binary>>
        end,
    InfoLine = <<"Logs are being written alongside raw .stream.jsonl artifacts.">>,
    [rule_line($-, Width)]
    ++ wrap_lines(StatusLine, Width)
    ++ wrap_lines(InfoLine, Width).

render_task_cards_lines(Streams, Width, Height, Now) ->
    Lines =
        case Streams of
            [] -> wrap_lines(<<"No active harness streams.">>, Width);
            _ ->
                lists:append(
                    [render_task_card_lines(Stream, Width, Now) ++ [<<>>] || Stream <- lists:sort(fun sort_streams/2, Streams)]
                )
        end,
    fit_head_lines(trim_trailing_blank_lines(Lines), Height).

render_task_card_lines(Stream, Width, Now) ->
    Status = status_badge(maps:get(status, Stream), true),
    Label = trim_binary(<<"> ", (maps:get(label, Stream))/binary, "  ", Status/binary>>),
    Summary =
        [
            pad_or_trim(Label, Width),
            rule_line($-, Width),
            <<"  provider  ", (maps:get(harness, Stream))/binary>>,
            <<"  phase     ", (maps:get(phase, Stream))/binary>>,
            <<"  elapsed   ", (elapsed_text(Stream, Now))/binary>>,
            <<"  latest">>
        ],
    Summary ++ indent_lines(wrap_lines(maps:get(last_activity, Stream), max(Width - 2, 12)), <<"  ">>).

sort_streams(A, B) ->
    maps:get(updated_at, A) >= maps:get(updated_at, B).

finished_stream(Stream) ->
    #{
        label => maps:get(label, Stream),
        status => maps:get(status, Stream),
        summary => maps:get(last_activity, Stream),
        log_path => maps:get(log_path, Stream)
    }.

elapsed_text(Stream, Now) ->
    StartedAt = maps:get(started_at, Stream),
    Milliseconds = max(Now - StartedAt, 0),
    TotalSeconds = Milliseconds div 1000,
    Minutes = TotalSeconds div 60,
    Seconds = TotalSeconds rem 60,
    Hours = Minutes div 60,
    RemainingMinutes = Minutes rem 60,
    case Hours > 0 of
        true ->
            <<(integer_to_binary(Hours))/binary, "h ", (integer_to_binary(RemainingMinutes))/binary, "m">>;
        false ->
            <<(integer_to_binary(Minutes))/binary, "m ", (integer_to_binary(Seconds))/binary, "s">>
    end.

render_transcript_entry(Line, Width) ->
    case classify_transcript_line(Line) of
        {assistant, Text} -> render_transcript_block(<<"AI">>, Text, Width);
        {tool_started, Text} -> render_transcript_block(<<"RUN">>, summarize_command(Text), Width);
        {tool_finished_ok, Text} -> render_transcript_block(<<"OK">>, summarize_tool_finish(Text, false), Width);
        {tool_finished_error, Text} -> render_transcript_block(<<"ERR">>, summarize_tool_finish(Text, true), Width);
        {warning, Text} -> render_transcript_block(<<"WARN">>, Text, Width);
        {error, Text} -> render_transcript_block(<<"ERR">>, Text, Width);
        {result, Text} -> render_transcript_block(<<"DONE">>, Text, Width);
        {session, Text} -> render_transcript_block(<<"SYS">>, Text, Width);
        {raw, Text} -> render_transcript_block(<<"OUT">>, compact_display(Text, max(Width * 2, 32)), Width);
        {plain, Text} -> render_transcript_block(<<"NOTE">>, Text, Width)
    end.

classify_transcript_line(Line) ->
    case strip_prefix(Line, <<"assistant: ">>) of
        {ok, Text} -> {assistant, Text};
        error ->
            case strip_prefix(Line, <<"tool: ">>) of
                {ok, Text} -> {tool_started, Text};
                error ->
                    case strip_prefix(Line, <<"tool finished (0): ">>) of
                        {ok, Text} -> {tool_finished_ok, Text};
                        error ->
                            case strip_prefix(Line, <<"tool finished (">>) of
                                {ok, _} -> {tool_finished_error, Line};
                                error ->
                                    case strip_prefix(Line, <<"warning: ">>) of
                                        {ok, Text} -> {warning, Text};
                                        error ->
                                            case strip_prefix(Line, <<"error: ">>) of
                                                {ok, Text} -> {error, Text};
                                                error ->
                                                    case strip_prefix(Line, <<"result: ">>) of
                                                        {ok, Text} -> {result, Text};
                                                        error ->
                                                            case strip_prefix(Line, <<"Session started">>) of
                                                                {ok, _} -> {session, Line};
                                                                error ->
                                                                    case strip_prefix(Line, <<"completed; see ">>) of
                                                                        {ok, _} -> {result, Line};
                                                                        error -> {raw, Line}
                                                                    end
                                                            end
                                                    end
                                            end
                                    end
                            end
                    end
            end
    end.

render_transcript_block(Tag, Text, Width) ->
    Prefix = <<"[", Tag/binary, "] ">>,
    BodyWidth = max(Width - visible_length(Prefix), 12),
    case wrap_lines(Text, BodyWidth) of
        [] ->
            [Prefix];
        [First | Rest] ->
            Continuation = from_chars(lists:duplicate(visible_length(Prefix), $\s)),
            [<<Prefix/binary, First/binary>> | indent_lines(Rest, Continuation)]
    end.

indent_lines(Lines, Prefix) ->
    [<<Prefix/binary, Line/binary>> || Line <- Lines].

fit_head_lines(_Lines, Height) when Height =< 0 ->
    [];
fit_head_lines(Lines, Height) ->
    case length(Lines) =< Height of
        true ->
            Lines;
        false when Height =:= 1 ->
            [<<"...">>];
        false ->
            lists:sublist(Lines, Height - 1) ++ [<<"...">>]
    end.

fit_tail_lines(_Lines, Height) when Height =< 0 ->
    [];
fit_tail_lines(Lines, Height) ->
    case length(Lines) =< Height of
        true ->
            Lines;
        false when Height =:= 1 ->
            [<<"...">>];
        false ->
            [<<"...">> | lists:nthtail(length(Lines) - (Height - 1), Lines)]
    end.

summarize_tool_finish(Text, IncludeOutput) ->
    case binary:split(Text, <<" => ">>) of
        [Command, Output] when IncludeOutput ->
            <<(summarize_command(Command))/binary, " | ", (compact_display(Output, 64))/binary>>;
        [Command, _Output] ->
            summarize_command(Command);
        [Command] ->
            summarize_command(Command)
    end.

summarize_command(Command) ->
    compact_display(trim_binary(Command), 80).

compact_display(Text, Limit) ->
    Chars = to_chars(trim_binary(Text)),
    case length(Chars) =< Limit of
        true ->
            from_chars(Chars);
        false ->
            from_chars(lists:sublist(Chars, max(Limit - 3, 1)) ++ "...")
    end.

strip_prefix(Text, Prefix) ->
    PrefixSize = byte_size(Prefix),
    case Text of
        <<Prefix:PrefixSize/binary, Rest/binary>> -> {ok, Rest};
        _ -> error
    end.

visible_length(Text) ->
    length(to_chars(strip_ansi(Text))).

rule_line(Char, Width) ->
    from_chars(lists:duplicate(max(Width, 1), Char)).

render_transcript_lines(undefined, Width, _Height) ->
    wrap_lines(<<"Waiting for a focused stream...">>, Width);
render_transcript_lines(Stream, Width, Height) ->
    BaseLines = [
        <<"ACTIVITY">>,
        rule_line($-, Width),
        <<"Focus  ", (maps:get(label, Stream))/binary, "  ", (maps:get(harness, Stream))/binary, "/", (maps:get(phase, Stream))/binary>>,
        <<"Log    ", (display_path(maps:get(log_path, Stream), max(Width - 7, 24)))/binary>>,
        <<>>
    ],
    TranscriptLines = lists:append([render_transcript_entry(Line, Width) || Line <- maps:get(transcript, Stream)]),
    Live =
        case trim_binary(maps:get(live_assistant, Stream)) of
            <<>> -> [];
            Text -> render_transcript_block(<<"LIVE">>, Text, Width)
        end,
    fit_tail_lines(BaseLines ++ TranscriptLines ++ Live, Height).

join_columns_lines(LeftLines0, RightLines0, LeftWidth, RightWidth) ->
    LeftLines = trim_trailing_blank_lines(LeftLines0),
    RightLines = trim_trailing_blank_lines(RightLines0),
    Height = max(length(LeftLines), length(RightLines)),
    PaddedLeft = pad_lines(LeftLines, Height),
    PaddedRight = pad_lines(RightLines, Height),
    [
        <<(pad_or_trim(L, LeftWidth))/binary, " | ", (pad_or_trim(R, RightWidth))/binary>>
     || {L, R} <- lists:zip(PaddedLeft, PaddedRight)
    ].

trim_trailing_blank_lines(Lines) ->
    lists:reverse(trim_leading_blank_lines(lists:reverse(Lines))).

trim_leading_blank_lines([<<>> | Rest]) ->
    trim_leading_blank_lines(Rest);
trim_leading_blank_lines(Lines) ->
    Lines.

join_lines([]) ->
    <<>>;
join_lines(Lines) ->
    lists:foldl(
        fun(Line, Acc) ->
            case Acc of
                <<>> -> Line;
                _ -> <<Acc/binary, "\n", Line/binary>>
            end
        end,
        <<>>,
        Lines
    ).

display_path(Path, Width) ->
    Chars = to_chars(Path),
    case length(Chars) =< Width of
        true ->
            Path;
        false ->
            PrefixWidth = max(4, (Width - 3) div 2),
            SuffixWidth = max(4, Width - PrefixWidth - 3),
            Prefix = lists:sublist(Chars, PrefixWidth),
            Suffix = lists:nthtail(length(Chars) - SuffixWidth, Chars),
            from_chars(Prefix ++ "..." ++ Suffix)
    end.

spinner_frame(Index) ->
    case Index rem 4 of
        0 -> <<"|">>;
        1 -> <<"/">>;
        2 -> <<"-">>;
        _ -> <<"\\">>
    end.

pad_lines(Lines, Height) when length(Lines) < Height ->
    pad_lines(Lines ++ [<<>>], Height);
pad_lines(Lines, _Height) ->
    Lines.

to_chars(Value) when is_binary(Value) ->
    unicode:characters_to_list(Value);
to_chars(Value) ->
    unicode:characters_to_list(Value).

from_chars(Value) ->
    unicode:characters_to_binary(Value).

strip_ansi(Text) ->
    strip_ansi_chars(to_chars(Text)).

strip_ansi_chars([27, $[ | Rest]) ->
    strip_ansi_chars(skip_csi(Rest));
strip_ansi_chars([Char | Rest]) ->
    [Char | strip_ansi_chars(Rest)];
strip_ansi_chars([]) ->
    [].

skip_csi([Char | Rest]) when
    (Char >= $A andalso Char =< $Z)
        orelse (Char >= $a andalso Char =< $z)
        orelse Char =:= $~ ->
    Rest;
skip_csi([_ | Rest]) ->
    skip_csi(Rest);
skip_csi([]) ->
    [].

focused_stream(State, Streams) ->
    FocusId =
        case maps:get(pinned, State) of
            undefined -> maps:get(focus, State);
            Pinned -> Pinned
        end,
    case FocusId of
        undefined ->
            case Streams of
                [] -> undefined;
                [Stream | _] -> Stream
            end;
        _ ->
            case [Stream || Stream <- Streams, maps:get(id, Stream) =:= FocusId] of
                [Stream | _] -> Stream;
                [] ->
                    case Streams of
                        [] -> undefined;
                        [Stream | _] -> Stream
                    end
            end
    end.

maybe_enter_alt(State = #{mode := tui, alt_active := false}) ->
    safe_put_chars(<<"\e[?1049h\e[?25l">>),
    State#{alt_active := true};
maybe_enter_alt(State) ->
    State.

maybe_leave_alt(State = #{alt_active := true}) ->
    safe_put_chars(<<"\e[?25h\e[?1049l">>),
    State#{alt_active := false};
maybe_leave_alt(State) ->
    State.

print_finished_summary(#{mode := plain}) ->
    ok;
print_finished_summary(State) ->
    Finished = lists:reverse(maps:get(finished, State)),
    case Finished of
        [] ->
            ok;
        _ ->
            Lines =
                lists:map(
                    fun(FinishedStream) ->
                        Label = maps:get(label, FinishedStream),
                        Status = atom_to_binary(maps:get(status, FinishedStream), utf8),
                        Summary = maps:get(summary, FinishedStream),
                        LogPath = maps:get(log_path, FinishedStream),
                        <<"[", Label/binary, "] ", Status/binary, ": ", Summary/binary, " (", LogPath/binary, ")\n">>
                    end,
                    Finished
                ),
            safe_put_chars(Lines)
    end.

ui_mode() ->
    case os:getenv("NIGHT_SHIFT_STREAM_UI") of
        "plain" -> plain;
        "tui" -> tui;
        _ ->
            case stdout_is_tty() of
                true -> tui;
                false -> plain
            end
    end.

stdout_is_tty() ->
    case catch begin
        ok = prim_tty:load(),
        prim_tty:isatty(stdout)
    end of
        true -> true;
        false -> false;
        _ -> false
    end.

terminal_width() ->
    case os:getenv("COLUMNS") of
        false -> 100;
        Value ->
            case string:to_integer(Value) of
                {Int, _} when Int > 0 -> Int;
                _ -> 100
            end
    end.

terminal_height() ->
    case os:getenv("LINES") of
        false -> 30;
        Value ->
            case string:to_integer(Value) of
                {Int, _} when Int > 0 -> Int;
                _ -> 30
            end
    end.

color_enabled() ->
    stdout_is_tty() andalso os:getenv("NO_COLOR") =:= false.

status_badge(running, ColorEnabled) ->
    maybe_color(<<"RUN">>, <<"33">>, ColorEnabled);
status_badge(completed, ColorEnabled) ->
    maybe_color(<<"DONE">>, <<"32">>, ColorEnabled);
status_badge(failed, ColorEnabled) ->
    maybe_color(<<"FAIL">>, <<"31">>, ColorEnabled);
status_badge(_, ColorEnabled) ->
    maybe_color(<<"WAIT">>, <<"36">>, ColorEnabled).

maybe_color(Text, _Code, false) ->
    Text;
maybe_color(Text, Code, true) ->
    <<"\e[", Code/binary, "m", Text/binary, "\e[0m">>.

format_done_text(completed, _ExitCode, LogPath) ->
    <<"completed; see ", LogPath/binary>>;
format_done_text(failed, ExitCode, LogPath) ->
    <<"failed (exit ", (integer_to_binary(ExitCode))/binary, "); see ", LogPath/binary>>;
format_done_text(_, ExitCode, LogPath) ->
    <<"stopped (exit ", (integer_to_binary(ExitCode))/binary, "); see ", LogPath/binary>>.

normalize_raw_text(Data) ->
    trim_binary(Data).

trim_binary(Value) when is_binary(Value) ->
    unicode:characters_to_binary(string:trim(to_chars(Value))).

should_suppress_line(Data) ->
    is_plugin_manifest_warning(Data)
        orelse is_featured_plugin_warning(Data)
        orelse is_shell_snapshot_warning(Data)
        orelse is_terminal_input_noise(Data).

is_warning_line(Data) ->
    binary:match(Data, <<" WARN ">>) =/= nomatch
        orelse binary:match(Data, <<"warning:">>) =/= nomatch.

is_plugin_manifest_warning(Data) ->
    binary:match(Data, <<"WARN codex_core::plugins::manifest: ignoring interface.defaultPrompt:">>) =/= nomatch.

is_featured_plugin_warning(Data) ->
    binary:match(Data, <<"WARN codex_core::plugins::manager: failed to warm featured plugin ids cache">>) =/= nomatch.

is_shell_snapshot_warning(Data) ->
    binary:match(Data, <<"WARN codex_core::shell_snapshot: Failed to delete shell snapshot">>) =/= nomatch.

is_terminal_input_noise(Data) ->
    Trimmed = trim_binary(Data),
    case Trimmed of
        <<>> ->
            false;
        _ ->
            contains_terminal_noise_sequence(Trimmed)
                orelse looks_like_terminal_noise(Trimmed)
    end.

contains_terminal_noise_sequence(Data) ->
    lists:any(
        fun(Pattern) -> binary:match(Data, Pattern) =/= nomatch end,
        [
            <<"^[[A">>,
            <<"^[[B">>,
            <<"^[[C">>,
            <<"^[[D">>,
            <<"^[OA">>,
            <<"^[OB">>,
            <<"^[OC">>,
            <<"^[OD">>,
            <<27, "[A">>,
            <<27, "[B">>,
            <<27, "[C">>,
            <<27, "[D">>,
            <<27, "OA">>,
            <<27, "OB">>,
            <<27, "OC">>,
            <<27, "OD">>
        ]
    ).

looks_like_terminal_noise(Data) ->
    Chars = to_chars(Data),
    length(Chars) >= 6
        andalso lists:all(
            fun(Char) ->
                lists:member(Char, "^[]ABCDOHFMPQRS~0123456789;")
                    orelse Char =:= 27
            end,
            Chars
        ).

append_file(Path, _Data) when Path =:= <<>> ->
    ok;
append_file(Path, Data) ->
    ok = file:write_file(binary_to_list(Path), Data, [append]).

ensure_log_path(LogPath) ->
    ok = filelib:ensure_dir(binary_to_list(LogPath)),
    ok.

make_stream_meta(Label, PromptPath, Harness, Phase, LogPath) ->
    #{
        id => unique_handle(),
        label => Label,
        prompt_path => PromptPath,
        harness => Harness,
        phase => Phase,
        log_path => LogPath,
        event_log_path => event_log_path(LogPath)
    }.

event_log_path(LogPath) ->
    case binary:match(LogPath, <<".log">>) of
        nomatch -> <<LogPath/binary, ".stream.jsonl">>;
        {Pos, _Len} ->
            Prefix = binary:part(LogPath, 0, Pos),
            Suffix = binary:part(LogPath, Pos + 4, byte_size(LogPath) - Pos - 4),
            <<Prefix/binary, ".stream.jsonl", Suffix/binary>>
    end.

unique_handle() ->
    integer_to_binary(erlang:unique_integer([positive, monotonic])).

wrap_lines(Text, Width) ->
    Width1 = max(Width, 1),
    Text1 = to_chars(trim_binary(Text)),
    case Text1 of
        [] -> [<<>>];
        _ ->
            RawLines = string:split(Text1, "\n", all),
            lists:append([wrap_line(Line, Width1) || Line <- RawLines])
    end.

wrap_line(Line, Width) ->
    case length(Line) =< Width of
        true -> [from_chars(Line)];
        false ->
            {Chunk, Rest} = split_at_width(Line, Width),
            case string:trim(Rest, leading) of
                [] -> [from_chars(Chunk)];
                Next -> [from_chars(Chunk) | wrap_line(Next, Width)]
            end
    end.

split_at_width(Line, Width) ->
    {lists:sublist(Line, Width), lists:nthtail(Width, Line)}.

pad_or_trim(Text, Width) ->
    Visible = to_chars(strip_ansi(Text)),
    case length(Visible) of
        Len when Len =:= Width -> Text;
        Len when Len < Width -> iolist_to_binary([Text, from_chars(lists:duplicate(Width - Len, $\s))]);
        _ -> from_chars(lists:sublist(Visible, Width))
    end.

maybe_append_raw_log(LogPath, none, Data) ->
    append_file(LogPath, Data);
maybe_append_raw_log(_LogPath, _StreamMeta, _Data) ->
    ok.

safe_put_chars(Data) ->
    _ = catch io:put_chars(Data),
    ok.

ensure_focus(undefined, Streams) ->
    latest_stream_id(Streams);
ensure_focus(Id, Streams) ->
    case maps:is_key(Id, Streams) of
        true -> Id;
        false -> latest_stream_id(Streams)
    end.

ensure_pinned(undefined, _Streams) ->
    undefined;
ensure_pinned(Id, Streams) ->
    case maps:is_key(Id, Streams) of
        true -> Id;
        false -> undefined
    end.

latest_stream_id(Streams) ->
    case maps:values(Streams) of
        [] ->
            undefined;
        [First | Rest] ->
            Latest =
                lists:foldl(
                    fun(Stream, Current) ->
                        case maps:get(updated_at, Stream) >= maps:get(updated_at, Current) of
                            true -> Stream;
                            false -> Current
                        end
                    end,
                    First,
                    Rest
                ),
            maps:get(id, Latest)
    end.
