-module(night_shift_discord).

-export([post_webhook/3]).

post_webhook(Url, Payload, LogPath) ->
    ok = ensure_log_path(LogPath),
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    append_log(LogPath, <<"POST ", Url/binary, "\n">>),
    append_log(LogPath, <<Payload/binary, "\n">>),
    Request = {binary_to_list(Url), [], "application/json", binary_to_list(Payload)},
    HTTPOptions = [{timeout, 5000}],
    case httpc:request(post, Request, HTTPOptions, [{body_format, binary}]) of
        {ok, {{_, Status, _}, _Headers, Body}} when Status >= 200, Status < 300 ->
            append_log(LogPath, <<"OK ", (integer_to_binary(Status))/binary, "\n">>),
            {ok, Body};
        {ok, {{_, Status, _}, _Headers, Body}} ->
            append_log(
                LogPath,
                <<"ERROR ", (integer_to_binary(Status))/binary, ": ", Body/binary, "\n">>
            ),
            {error, <<(integer_to_binary(Status))/binary, ": ", Body/binary>>};
        {error, Reason} ->
            Message = unicode:characters_to_binary(io_lib:format("~p", [Reason])),
            append_log(LogPath, <<"ERROR ", Message/binary, "\n">>),
            {error, Message}
    end.

append_log(LogPath, Data) ->
    ok = file:write_file(binary_to_list(LogPath), Data, [append]).

ensure_log_path(LogPath) ->
    ok = filelib:ensure_dir(binary_to_list(LogPath)),
    ok.
