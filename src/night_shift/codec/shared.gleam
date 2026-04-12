import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub fn strip_comments(line: String) -> String {
  case string.split(line, "#") {
    [first, ..] -> first
    [] -> line
  }
}

pub fn parse_int(raw_value: String, context: String) -> Result(Int, String) {
  case int.parse(string.trim(raw_value)) {
    Ok(value) -> Ok(value)
    Error(_) -> Error("Invalid integer in " <> context <> ": " <> raw_value)
  }
}

pub fn parse_string(raw_value: String) -> String {
  let trimmed = string.trim(raw_value)
  case string.starts_with(trimmed, "\""), string.ends_with(trimmed, "\"") {
    True, True ->
      trimmed
      |> string.drop_start(1)
      |> string.drop_end(1)
    _, _ -> trimmed
  }
}

pub fn parse_optional_string(raw_value: String) -> Option(String) {
  case parse_string(raw_value) {
    "" -> None
    value -> Some(value)
  }
}

pub fn parse_string_list(raw_value: String) -> List(String) {
  let trimmed = string.trim(raw_value)
  case trimmed {
    "[]" -> []
    _ ->
      trimmed
      |> string.drop_start(1)
      |> string.drop_end(1)
      |> string.split(",")
      |> list.filter_map(fn(item) {
        case string.trim(item) {
          "" -> Error(Nil)
          value -> Ok(parse_string(value))
        }
      })
  }
}

pub fn render_string(value: String) -> String {
  "\"" <> string.replace(in: value, each: "\"", with: "\\\"") <> "\""
}

pub fn render_string_list(values: List(String)) -> String {
  case values {
    [] -> "[]"
    _ ->
      "["
      <> {
        values
        |> list.map(render_string)
        |> string.join(with: ", ")
      }
      <> "]"
  }
}
