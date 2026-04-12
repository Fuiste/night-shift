-module(night_shift_provider_support).

-export([extract_balanced_json/1]).

extract_balanced_json(Payload) when is_binary(Payload) ->
    do_extract(Payload).

do_extract(<<>>) ->
    <<>>;
do_extract(Payload = <<First, _/binary>>) when First =:= ${; First =:= $[ ->
    find_json_prefix(Payload, 1, byte_size(Payload));
do_extract(<<_, Rest/binary>>) ->
    do_extract(Rest).

find_json_prefix(_Payload, Size, Max) when Size > Max ->
    <<>>;
find_json_prefix(Payload, Size, Max) ->
    Prefix = binary:part(Payload, 0, Size),
    case decode_json(Prefix) of
        {ok, _Json} -> Prefix;
        error -> find_json_prefix(Payload, Size + 1, Max)
    end.

decode_json(Data) ->
    try
        {ok, json:decode(Data)}
    catch
        _:_ -> error
    end.
