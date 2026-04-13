import gleam/list
import gleam/result
import gleam/string

pub fn main() -> Nil {
  let options = [
    Verbose,
    NoTty,
    Report(#(GleeunitProgress, [Colored(True)])),
    ScaleTimeouts(30),
  ]

  let result =
    find_test_files(matching: "**/*.{erl,gleam}", in: "test")
    |> list.map(gleam_to_erlang_module_name)
    |> list.map(dangerously_convert_string_to_atom(_, Utf8))
    |> run_eunit(options)

  let code = case result {
    Ok(_) -> 0
    Error(_) -> 1
  }
  halt(code)
}

type Atom

type Encoding {
  Utf8
}

type ReportModuleName {
  GleeunitProgress
}

type GleeunitProgressOption {
  Colored(Bool)
}

type EunitOption {
  Verbose
  NoTty
  Report(#(ReportModuleName, List(GleeunitProgressOption)))
  ScaleTimeouts(Int)
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "erlang", "binary_to_atom")
fn dangerously_convert_string_to_atom(value: String, encoding: Encoding) -> Atom

@external(erlang, "gleeunit_ffi", "find_files")
fn find_test_files(matching matching: String, in in: String) -> List(String)

@external(erlang, "gleeunit_ffi", "run_eunit")
fn run_eunit(modules: List(Atom), options: List(EunitOption)) -> Result(Nil, a)

fn gleam_to_erlang_module_name(path: String) -> String {
  case string.ends_with(path, ".gleam") {
    True ->
      path
      |> string.replace(".gleam", "")
      |> string.replace("/", "@")

    False ->
      path
      |> string.split("/")
      |> list.last
      |> result.unwrap(path)
      |> string.replace(".erl", "")
  }
}
