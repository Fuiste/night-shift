-module(night_shift_runtime_identity_ffi).

-export([normalize_port_name/1, sanitize_task_slug/1, sha256_hex/1, sha256_mod/2]).

sha256_hex(Data) ->
    Binary = unicode:characters_to_binary(Data),
    Digest = crypto:hash(sha256, Binary),
    list_to_binary([io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Digest]).

sha256_mod(Data, Modulus) when is_integer(Modulus), Modulus > 0 ->
    Digest = crypto:hash(sha256, unicode:characters_to_binary(Data)),
    binary:decode_unsigned(Digest) rem Modulus.

normalize_port_name(Value) ->
    Normalized = normalize(Value, $_),
    case Normalized of
        <<>> -> <<>>;
        <<First, _/binary>> when First >= $a, First =< $z -> Normalized;
        _ -> <<>>
    end.

sanitize_task_slug(Value) ->
    case normalize(Value, $-) of
        <<>> -> <<"task">>;
        Slug -> Slug
    end.

normalize(Value, Separator) ->
    Lowered = string:lowercase(unicode:characters_to_binary(Value)),
    trim_separator(collapse_non_alnum(Lowered, Separator, false, <<>>), Separator).

collapse_non_alnum(<<>>, _Separator, _LastWasSeparator, Acc) ->
    Acc;
collapse_non_alnum(<<Char/utf8, Rest/binary>>, Separator, LastWasSeparator, Acc) ->
    case is_lower_alnum(Char) of
        true ->
            collapse_non_alnum(Rest, Separator, false, <<Acc/binary, Char/utf8>>);
        false when LastWasSeparator ->
            collapse_non_alnum(Rest, Separator, true, Acc);
        false ->
            collapse_non_alnum(Rest, Separator, true, <<Acc/binary, Separator>>)
    end.

trim_separator(Binary, Separator) ->
    trim_leading(trim_trailing(Binary, Separator), Separator).

trim_leading(<<Separator, Rest/binary>>, Separator) ->
    trim_leading(Rest, Separator);
trim_leading(Binary, _Separator) ->
    Binary.

trim_trailing(Binary, Separator) ->
    case Binary of
        <<>> -> <<>>;
        _ ->
            Size = byte_size(Binary) - 1,
            case Binary of
                <<Prefix:Size/binary, Separator>> -> trim_trailing(Prefix, Separator);
                _ -> Binary
            end
    end.

is_lower_alnum(Char) ->
    (Char >= $a andalso Char =< $z) orelse (Char >= $0 andalso Char =< $9).
