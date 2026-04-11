-module(night_shift_system).

-export([argv/0, cwd/0, home_directory/0, state_directory/0, get_env/1, set_env/2, unset_env/1, timestamp/0, unique_id/0, sleep/1, wait_forever/0, stdout_is_tty/0, terminal_columns/0, color_enabled/0]).

argv() ->
    lists:map(fun to_binary/1, init:get_plain_arguments()).

cwd() ->
    {ok, Dir} = file:get_cwd(),
    to_binary(Dir).

home_directory() ->
    case os:getenv("HOME") of
        false -> cwd();
        Dir -> to_binary(Dir)
    end.

state_directory() ->
    case os:getenv("XDG_STATE_HOME") of
        false -> to_binary(filename:join(binary_to_list(home_directory()), ".local/state"));
        Dir -> to_binary(Dir)
    end.

get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> <<>>;
        Value -> to_binary(Value)
    end.

set_env(Name, Value) ->
    true = os:putenv(binary_to_list(Name), binary_to_list(Value)),
    nil.

unset_env(Name) ->
    true = os:unsetenv(binary_to_list(Name)),
    nil.

timestamp() ->
    to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}])).

unique_id() ->
    to_binary(integer_to_list(erlang:unique_integer([positive, monotonic]))).

sleep(Milliseconds) ->
    timer:sleep(Milliseconds),
    nil.

wait_forever() ->
    receive
    after infinity ->
        nil
    end.

stdout_is_tty() ->
    case os:cmd("test -t 1 && printf true || printf false") of
        "true" -> true;
        _ -> false
    end.

terminal_columns() ->
    case os:getenv("COLUMNS") of
        false -> 100;
        Value ->
            case string:to_integer(Value) of
                {Int, _} when Int > 0 -> Int;
                _ -> 100
            end
    end.

color_enabled() ->
    stdout_is_tty() andalso os:getenv("NO_COLOR") =:= false.

to_binary(Value) when is_binary(Value) ->
    Value;
to_binary(Value) ->
    unicode:characters_to_binary(Value).
