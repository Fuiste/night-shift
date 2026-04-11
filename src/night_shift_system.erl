-module(night_shift_system).

-export([argv/0, cwd/0, home_directory/0, state_directory/0, get_env/1, set_env/2, unset_env/1, timestamp/0, unique_id/0, sleep/1, wait_forever/0, stdout_is_tty/0, stdin_is_tty/0, read_line/0, select_option/3, terminal_columns/0, color_enabled/0, os_name/0]).

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
    case catch begin
        ok = prim_tty:load(),
        prim_tty:isatty(stdout)
    end of
        true -> true;
        false -> false;
        _ -> false
    end.

stdin_is_tty() ->
    case catch begin
        ok = prim_tty:load(),
        prim_tty:isatty(stdin)
    end of
        true -> true;
        false -> false;
        _ -> false
    end.

read_line() ->
    case io:get_line("") of
        eof -> <<>>;
        Value -> to_binary(string:trim(Value))
    end.

select_option(Prompt, Options, DefaultIndex) ->
    NormalizedOptions = lists:map(fun to_binary/1, Options),
    OptionCount = length(NormalizedOptions),
    case stdin_is_tty() andalso stdout_is_tty() andalso OptionCount > 0 of
        false -> normalize_index(DefaultIndex, OptionCount);
        true ->
            case can_use_prim_tty() of
                false ->
                    select_option_fallback(Prompt, NormalizedOptions, DefaultIndex);
                true ->
                    ok = prim_tty:load(),
                    case catch prim_tty:init(#{input => raw, output => cooked, ofd => stdout}) of
                        {'EXIT', _} ->
                            select_option_fallback(Prompt, NormalizedOptions, DefaultIndex);
                        State ->
                            Index = normalize_index(DefaultIndex, OptionCount),
                            try
                                prim_tty:write(State, <<"\e[?25l">>),
                                select_option_loop(State, Prompt, NormalizedOptions, Index, 0)
                            after
                                prim_tty:write(State, <<"\e[?25h\r\n">>),
                                _ = catch prim_tty:reinit(State, #{input => cooked, output => cooked, ofd => stdout}),
                                ok
                            end
                    end
            end
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

os_name() ->
    case os:type() of
        {_, Name} -> atom_to_binary(Name, utf8)
    end.

normalize_index(_DefaultIndex, OptionCount) when OptionCount =< 0 ->
    0;
normalize_index(DefaultIndex, _OptionCount) when DefaultIndex < 0 ->
    0;
normalize_index(DefaultIndex, OptionCount) when DefaultIndex >= OptionCount ->
    OptionCount - 1;
normalize_index(DefaultIndex, _OptionCount) ->
    DefaultIndex.

select_option_loop(State, Prompt, Options, Index, PreviousLines) ->
    WindowSize = 10,
    Start = window_start(Index, length(Options), WindowSize),
    Visible = visible_options(Options, Start, WindowSize),
    Rendered = render_menu(Prompt, Visible, Index, Start, length(Options), PreviousLines),
    prim_tty:write(State, Rendered),
    LineCount = rendered_line_count(Visible),
    prim_tty:read(State, 8),
    case read_key(State) of
        up ->
            select_option_loop(
                State,
                Prompt,
                Options,
                clamp(Index - 1, 0, length(Options) - 1),
                LineCount
            );
        down ->
            select_option_loop(
                State,
                Prompt,
                Options,
                clamp(Index + 1, 0, length(Options) - 1),
                LineCount
            );
        enter ->
            Index;
        _ ->
            select_option_loop(State, Prompt, Options, Index, LineCount)
    end.

read_key(State) ->
    Handles = prim_tty:handles(State),
    ReadRef = maps:get(read, Handles),
    receive
        {ReadRef, {data, Data}} ->
            decode_key(Data);
        {ReadRef, eof} ->
            enter
    end.

decode_key(<<"\e[A", _/binary>>) ->
    up;
decode_key(<<"\eOA", _/binary>>) ->
    up;
decode_key(<<"k", _/binary>>) ->
    up;
decode_key(<<"\e[B", _/binary>>) ->
    down;
decode_key(<<"\eOB", _/binary>>) ->
    down;
decode_key(<<"j", _/binary>>) ->
    down;
decode_key(<<"\r", _/binary>>) ->
    enter;
decode_key(<<"\n", _/binary>>) ->
    enter;
decode_key(<<3, _/binary>>) ->
    erlang:error(interrupted);
decode_key(_) ->
    ignore.

render_menu(Prompt, VisibleOptions, Index, Start, TotalOptions, PreviousLines) ->
    Header = [clear_previous_lines(PreviousLines), <<"\r\e[2K">>, Prompt, <<"\r\n">>,
              <<"Use ↑/↓ and Enter to select.\r\n">>],
    OptionLines =
        lists:map(
          fun({Option, Offset}) ->
                  Prefix =
                      case Start + Offset =:= Index of
                          true -> <<"> ">>;
                          false -> <<"  ">>
                      end,
                  [<<"\r\e[2K">>, Prefix, Option, <<"\r\n">>]
          end,
          enumerate(VisibleOptions, 0)
        ),
    Footer =
        case TotalOptions > length(VisibleOptions) of
            true ->
                [<<"\r\e[2K">>,
                 io_lib:format("Showing ~B-~B of ~B\r\n",
                               [Start + 1, Start + length(VisibleOptions), TotalOptions])];
            false ->
                [<<"\r\e[2K">>]
        end,
    [Header, OptionLines, Footer].

clear_previous_lines(0) ->
    <<>>;
clear_previous_lines(Lines) ->
    [io_lib:format("\e[~BA", [Lines]), clear_lines(Lines)].

clear_lines(0) ->
    <<>>;
clear_lines(Lines) ->
    [<<"\r\e[2K">>, clear_lines_rest(Lines - 1)].

clear_lines_rest(0) ->
    <<>>;
clear_lines_rest(Lines) ->
    [<<"\e[1B\r\e[2K">>, clear_lines_rest(Lines - 1)].

rendered_line_count(VisibleOptions) ->
    case length(VisibleOptions) > 10 of
        true -> 3 + length(VisibleOptions);
        false -> 3 + length(VisibleOptions)
    end.

window_start(_Index, Total, WindowSize) when Total =< WindowSize ->
    0;
window_start(Index, Total, WindowSize) ->
    MaxStart = Total - WindowSize,
    clamp(Index - (WindowSize div 2), 0, MaxStart).

visible_options(Options, Start, WindowSize) ->
    lists:sublist(lists:nthtail(Start, Options), WindowSize).

enumerate([], _Index) ->
    [];
enumerate([Item | Rest], Index) ->
    [{Item, Index} | enumerate(Rest, Index + 1)].

clamp(Value, Min, _Max) when Value < Min ->
    Min;
clamp(Value, _Min, Max) when Value > Max ->
    Max;
clamp(Value, _Min, _Max) ->
    Value.

can_use_prim_tty() ->
    case process_info(self(), registered_name) of
        {registered_name, Name} when is_atom(Name) ->
            Name =/= [];
        _ ->
            false
    end.

select_option_fallback(Prompt, Options, DefaultIndex) ->
    Index = normalize_index(DefaultIndex, length(Options)),
    io:format("~ts~n", [Prompt]),
    render_fallback_options(Options, 0),
    io:format("Enter a number [default: ~B]: ", [Index + 1]),
    case io:get_line("") of
        eof ->
            Index;
        Value ->
            case string:to_integer(string:trim(Value)) of
                {Selection, _} when Selection >= 1, Selection =< length(Options) ->
                    Selection - 1;
                _ ->
                    Index
            end
    end.

render_fallback_options([], _Index) ->
    ok;
render_fallback_options([Option | Rest], Index) ->
    io:format("  ~B. ~ts~n", [Index + 1, Option]),
    render_fallback_options(Rest, Index + 1).

to_binary(Value) when is_binary(Value) ->
    Value;
to_binary(Value) ->
    unicode:characters_to_binary(Value).
