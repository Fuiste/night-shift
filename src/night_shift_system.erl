-module(night_shift_system).

-export([argv/0, cwd/0, home_directory/0, timestamp/0, unique_id/0]).

argv() ->
    init:get_plain_arguments().

cwd() ->
    {ok, Dir} = file:get_cwd(),
    unicode:characters_to_list(Dir).

home_directory() ->
    case os:getenv("HOME") of
        false -> cwd();
        Dir -> Dir
    end.

timestamp() ->
    calendar:system_time_to_rfc3339(erlang:system_time(second), [{unit, second}]).

unique_id() ->
    integer_to_list(erlang:unique_integer([positive, monotonic])).
