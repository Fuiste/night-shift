import gleam/int
import gleam/list
import gleam/string
import night_shift/config
import night_shift/system
import night_shift/types

pub fn run(command: types.Command) -> String {
  let config = config.load(".night-shift.toml") |> unwrap(types.default_config())

  case command {
    types.Help -> "Night Shift is ready.\n\n" <> crate_summary(config)
    types.Start(brief_path, harness, max_workers) ->
      "Starting Night Shift in "
      <> system.cwd()
      <> "\n"
      <> "Brief: "
      <> brief_path
      <> "\n"
      <> "Harness: "
      <> resolve_harness(harness, config)
      <> "\n"
      <> "Max workers: "
      <> resolve_max_workers(max_workers, config)
      <> "\n"
      <> "Run journal root: "
      <> system.home_directory()
      <> "/.local/state/night-shift"
    types.Status(run) -> "Status lookup is wired for " <> describe_run(run)
    types.Report(run) -> "Report lookup is wired for " <> describe_run(run)
    types.Resume(run) -> "Resume is wired for " <> describe_run(run)
    types.Review(harness) ->
      "Review loop is wired with harness "
      <> resolve_harness(harness, config)
  }
}

fn crate_summary(config: types.Config) -> String {
  "Default harness: "
  <> types.harness_to_string(config.default_harness)
  <> "\n"
  <> "Max workers: "
  <> int.to_string(config.max_workers)
  <> "\n"
  <> "Notifiers: "
  <> stringify_notifiers(config.notifiers)
}

fn describe_run(run: types.RunSelector) -> String {
  case run {
    types.LatestRun -> "latest run"
    types.RunId(run_id) -> "run " <> run_id
  }
}

fn resolve_harness(
  candidate: Result(types.Harness, Nil),
  config: types.Config,
) -> String {
  case candidate {
    Ok(harness) -> types.harness_to_string(harness)
    Error(Nil) -> types.harness_to_string(config.default_harness)
  }
}

fn resolve_max_workers(
  candidate: Result(Int, Nil),
  config: types.Config,
) -> String {
  case candidate {
    Ok(worker_count) -> int.to_string(worker_count)
    Error(Nil) -> int.to_string(config.max_workers)
  }
}

fn stringify_notifiers(notifiers: List(types.NotifierName)) -> String {
  notifiers
  |> list.map(types.notifier_to_string)
  |> string.join(with: ", ")
}

fn unwrap(result: Result(a, b), default: a) -> a {
  case result {
    Ok(value) -> value
    Error(_) -> default
  }
}
