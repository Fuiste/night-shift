-module(night_shift_system).

-export([argv/0, cwd/0, home_directory/0, state_directory/0, get_env/1, set_env/2, timestamp/0, unique_id/0]).

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

timestamp() ->
    to_binary(calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}])).

unique_id() ->
    to_binary(integer_to_list(erlang:unique_integer([positive, monotonic]))).

to_binary(Value) when is_binary(Value) ->
    Value;
to_binary(Value) ->
    unicode:characters_to_binary(Value).
