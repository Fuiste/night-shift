-module(night_shift_repo_state_ffi).

-export([sha256_hex/1]).

sha256_hex(Data) ->
    Binary = unicode:characters_to_binary(Data),
    Digest = crypto:hash(sha256, Binary),
    iolist_to_binary([io_lib:format("~2.16.0b", [Byte]) || Byte <- binary_to_list(Digest)]).
