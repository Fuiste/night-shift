import gleam/list
import gleam/result
import gleam/string
import simplifile

pub fn clean_operator_log(log_path: String) -> Result(Nil, String) {
  use contents <- result.try(read_file(log_path))
  let #(cleaned, filtered) = filter_noise(contents)

  case filtered {
    False -> Ok(Nil)
    True -> {
      let raw_path = raw_log_path(log_path)
      use _ <- result.try(write_file(raw_path, contents))
      write_file(
        log_path,
        "[warning] Suppressed non-fatal harness noise; see "
          <> raw_path
          <> "\n"
          <> cleaned,
      )
    }
  }
}

fn filter_noise(contents: String) -> #(String, Bool) {
  filter_lines(string.split(contents, "\n"), [], False, False)
}

fn filter_lines(
  lines: List(String),
  kept: List(String),
  filtered: Bool,
  in_html_block: Bool,
) -> #(String, Bool) {
  case lines {
    [] -> #(string.join(list.reverse(kept), with: "\n"), filtered)
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      let starts_html =
        string.contains(does: trimmed, contain: "<!DOCTYPE html")
        || string.contains(does: trimmed, contain: "<html")
      let ends_html = string.contains(does: trimmed, contain: "</html>")
      let noisy_line =
        string.contains(does: line, contain: "rmcp::transport::worker")
        || string.contains(does: line, contain: "stitch.googleapis.com")
        || string.contains(does: line, contain: "exec_command failed")
        || string.contains(does: line, contain: "Attention Required!")

      case in_html_block || starts_html || noisy_line {
        True ->
          filter_lines(
            rest,
            kept,
            True,
            { in_html_block || starts_html } && !ends_html,
          )
        False -> filter_lines(rest, [line, ..kept], filtered, False)
      }
    }
  }
}

fn raw_log_path(log_path: String) -> String {
  string.replace(in: log_path, each: ".log", with: ".raw.log")
}

fn read_file(path: String) -> Result(String, String) {
  case simplifile.read(path) {
    Ok(contents) -> Ok(contents)
    Error(error) ->
      Error(
        "Unable to read " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}

fn write_file(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.write(contents, to: path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to write " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}
