import gleam/int
import gleam/result
import night_shift/types

pub fn usage() -> String {
  "Night Shift\n"
  <> "\n"
  <> "Commands:\n"
  <> "  --demo [--ui]\n"
  <> "  start --brief <path> [--harness <codex|cursor>] [--max-workers <n>] [--ui]\n"
  <> "  status [--run <id>|latest]\n"
  <> "  report [--run <id>|latest]\n"
  <> "  resume [--run <id>|latest] [--ui]\n"
  <> "  review [--harness <codex|cursor>]\n"
}

pub fn parse(args: List(String)) -> Result(types.Command, String) {
  case contains_demo_flag(args) {
    True -> parse_demo(args, False)
    False ->
      case args {
        [] -> Ok(types.Help)
        ["help", .._] -> Ok(types.Help)
        ["start", ..rest] -> parse_start(rest)
        ["status", ..rest] -> parse_run_lookup(rest, types.Status)
        ["report", ..rest] -> parse_run_lookup(rest, types.Report)
        ["resume", ..rest] -> parse_resume(rest)
        ["review", ..rest] -> parse_review(rest)
        [command, .._] -> Error("Unknown command: " <> command)
      }
  }
}

fn contains_demo_flag(args: List(String)) -> Bool {
  case args {
    [] -> False
    ["--demo", .._] -> True
    [_, ..rest] -> contains_demo_flag(rest)
  }
}

fn parse_demo(args: List(String), ui_enabled: Bool) -> Result(types.Command, String) {
  case args {
    [] -> Ok(types.Demo(ui_enabled))
    ["--demo", ..rest] -> parse_demo(rest, ui_enabled)
    ["--ui", ..rest] -> parse_demo(rest, True)
    [_flag, .._] ->
      Error("--demo does not accept commands. Run `night-shift --demo [--ui]`.")
  }
}

fn parse_start(args: List(String)) -> Result(types.Command, String) {
  parse_start_flags(args, Error(Nil), Error(Nil), Error(Nil), False)
}

fn parse_start_flags(
  args: List(String),
  brief_path: Result(String, Nil),
  harness: Result(types.Harness, Nil),
  max_workers: Result(Int, Nil),
  ui_enabled: Bool,
) -> Result(types.Command, String) {
  case args {
    [] ->
      case brief_path {
        Ok(path) -> Ok(types.Start(path, harness, max_workers, ui_enabled))
        Error(Nil) -> Error("The start command requires --brief <path>.")
      }

    ["--brief", path, ..rest] ->
      parse_start_flags(rest, Ok(path), harness, max_workers, ui_enabled)

    ["--harness", raw_harness, ..rest] -> {
      use parsed_harness <- result.try(
        types.harness_from_string(raw_harness)
      )
      parse_start_flags(rest, brief_path, Ok(parsed_harness), max_workers, ui_enabled)
    }

    ["--max-workers", raw_count, ..rest] -> {
      use parsed_count <- result.try(parse_positive_int(raw_count))
      parse_start_flags(rest, brief_path, harness, Ok(parsed_count), ui_enabled)
    }

    ["--ui", ..rest] -> parse_start_flags(rest, brief_path, harness, max_workers, True)

    [flag, .._] -> Error("Unsupported start flag: " <> flag)
  }
}

fn parse_resume(args: List(String)) -> Result(types.Command, String) {
  parse_resume_flags(args, types.LatestRun, False)
}

fn parse_resume_flags(
  args: List(String),
  run: types.RunSelector,
  ui_enabled: Bool,
) -> Result(types.Command, String) {
  case args {
    [] -> Ok(types.Resume(run, ui_enabled))
    ["--run", "latest", ..rest] -> parse_resume_flags(rest, types.LatestRun, ui_enabled)
    ["--run", run_id, ..rest] -> parse_resume_flags(rest, types.RunId(run_id), ui_enabled)
    ["--ui", ..rest] -> parse_resume_flags(rest, run, True)
    [flag, .._] -> Error("Unsupported flag: " <> flag)
  }
}

fn parse_review(args: List(String)) -> Result(types.Command, String) {
  case args {
    [] -> Ok(types.Review(Error(Nil)))
    ["--harness", raw_harness] -> {
      use harness <- result.try(types.harness_from_string(raw_harness))
      Ok(types.Review(Ok(harness)))
    }
    [flag, .._] -> Error("Unsupported review flag: " <> flag)
  }
}

fn parse_run_lookup(
  args: List(String),
  constructor: fn(types.RunSelector) -> types.Command,
) -> Result(types.Command, String) {
  case args {
    [] -> Ok(constructor(types.LatestRun))
    ["--run", "latest"] -> Ok(constructor(types.LatestRun))
    ["--run", run_id] -> Ok(constructor(types.RunId(run_id)))
    [flag, .._] -> Error("Unsupported flag: " <> flag)
  }
}

fn parse_positive_int(raw_value: String) -> Result(Int, String) {
  case int.parse(raw_value) {
    Ok(value) if value > 0 -> Ok(value)
    Ok(_) -> Error("--max-workers must be a positive integer.")
    Error(Nil) -> Error("Expected integer but received: " <> raw_value)
  }
}
