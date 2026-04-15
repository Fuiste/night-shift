import filepath
import gleam/result
import gleam/string
import night_shift/shell
import night_shift/system
import simplifile

pub const js_asset = "dash.js"

pub const css_asset = "dash.css"

pub fn asset_root() -> String {
  case system.get_env("NIGHT_SHIFT_DASH_ASSET_ROOT") {
    "" -> filepath.join(system.cwd(), "build/dash-assets")
    root -> root
  }
}

pub fn ensure_assets_ready() -> Result(String, String) {
  let root = asset_root()
  case assets_present(root) {
    True -> Ok(root)
    False -> build_assets(root)
  }
}

pub fn read_asset(path_segments: List(String)) -> Result(String, String) {
  use root <- result.try(ensure_assets_ready())
  use relative_path <- result.try(validate_relative_path(path_segments))
  let target_path = filepath.join(root, relative_path)
  case simplifile.read(target_path) {
    Ok(contents) -> Ok(contents)
    Error(error) ->
      Error(
        "Unable to read dashboard asset "
        <> target_path
        <> ": "
        <> simplifile.describe_error(error),
      )
  }
}

pub fn content_type(path_segments: List(String)) -> String {
  case list_reverse(path_segments) {
    [filename, ..] ->
      case
        string.ends_with(filename, ".css"),
        string.ends_with(filename, ".mjs") || string.ends_with(filename, ".js"),
        string.ends_with(filename, ".json")
      {
        True, _, _ -> "text/css; charset=utf-8"
        _, True, _ -> "text/javascript; charset=utf-8"
        _, _, True -> "application/json; charset=utf-8"
        _, _, _ -> "text/plain; charset=utf-8"
      }
    [] -> "text/plain; charset=utf-8"
  }
}

pub fn app_shell(initial_run_id: String) -> Result(String, String) {
  use _ <- result.try(ensure_assets_ready())
  Ok(
    "<!doctype html>\n"
    <> "<html lang=\"en\">\n"
    <> "<head>\n"
    <> "  <meta charset=\"utf-8\">\n"
    <> "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
    <> "  <title>Night Shift Dashboard</title>\n"
    <> "  <link rel=\"stylesheet\" href=\"/assets/dash.css\">\n"
    <> "</head>\n"
    <> "<body>\n"
    <> "  <div id=\"app\" data-initial-run=\""
    <> escape_attribute(initial_run_id)
    <> "\"></div>\n"
    <> "  <script type=\"module\" src=\"/assets/dash.js\"></script>\n"
    <> "</body>\n"
    <> "</html>\n",
  )
}

fn build_assets(root: String) -> Result(String, String) {
  let script_path = filepath.join(system.cwd(), "scripts/build_dash_assets.sh")
  case simplifile.read(script_path) {
    Ok(_) -> {
      use _ <- result.try(ensure_directory(log_directory()))
      let log_path = filepath.join(log_directory(), "dash-assets-build.log")
      let command = "sh " <> shell.quote(script_path)
      let outcome = shell.run(command, system.cwd(), log_path)
      case shell.succeeded(outcome) && assets_present(root) {
        True -> Ok(root)
        False ->
          Error(
            "Night Shift could not prepare dashboard assets. See " <> log_path,
          )
      }
    }
    Error(_) ->
      Error(
        "Night Shift dashboard assets are unavailable. Install a Night Shift CLI bundle that includes assets or build them with scripts/build_dash_assets.sh.",
      )
  }
}

fn assets_present(root: String) -> Bool {
  file_exists(filepath.join(root, js_asset))
  && file_exists(filepath.join(root, css_asset))
}

fn file_exists(path: String) -> Bool {
  case simplifile.read(path) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn validate_relative_path(path_segments: List(String)) -> Result(String, String) {
  case
    list_any(path_segments, fn(segment) {
      segment == ".." || segment == "." || segment == ""
    })
  {
    True -> Error("Invalid dashboard asset path.")
    False -> Ok(path_segments |> join_segments)
  }
}

fn join_segments(segments: List(String)) -> String {
  case segments {
    [] -> ""
    [segment] -> segment
    [segment, ..rest] -> filepath.join(segment, join_segments(rest))
  }
}

fn ensure_directory(path: String) -> Result(Nil, String) {
  case simplifile.create_directory_all(path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to prepare dashboard asset directory "
        <> path
        <> ": "
        <> simplifile.describe_error(error),
      )
  }
}

fn log_directory() -> String {
  filepath.join(system.state_directory(), "night-shift")
}

fn escape_attribute(value: String) -> String {
  value
  |> string_replace("&", "&amp;")
  |> string_replace("\"", "&quot;")
  |> string_replace("<", "&lt;")
  |> string_replace(">", "&gt;")
}

fn string_replace(
  value: String,
  each target: String,
  with replacement: String,
) -> String {
  case target {
    "" -> value
    _ -> string.replace(in: value, each: target, with: replacement)
  }
}

fn list_reverse(items: List(String)) -> List(String) {
  reverse(items, [])
}

fn reverse(items: List(String), acc: List(String)) -> List(String) {
  case items {
    [] -> acc
    [item, ..rest] -> reverse(rest, [item, ..acc])
  }
}

fn list_any(items: List(a), predicate: fn(a) -> Bool) -> Bool {
  case items {
    [] -> False
    [item, ..rest] ->
      case predicate(item) {
        True -> True
        False -> list_any(rest, predicate)
      }
  }
}
