import gleam/int
import gleam/list
import gleam/result
import gleam/string
import night_shift/journal
import night_shift/config
import night_shift/system
import night_shift/types

pub fn run(command: types.Command) -> String {
  let config = config.load(".night-shift.toml") |> result.unwrap(or: types.default_config())

  case command {
    types.Help -> "Night Shift is ready.\n\n" <> crate_summary(config)
    types.Start(brief_path, harness, max_workers) -> {
      let resolved_harness = choose_harness(harness, config)
      let resolved_workers = choose_max_workers(max_workers, config)

      case journal.start_run(system.cwd(), brief_path, resolved_harness, resolved_workers) {
        Ok(run) ->
          "Started run "
          <> run.run_id
          <> "\n"
          <> "Report: "
          <> run.report_path
          <> "\n"
          <> "Journal: "
          <> run.run_path
        Error(message) -> message
      }
    }
    types.Status(run) -> status(run)
    types.Report(run) -> report(run)
    types.Resume(run) -> resume(run)
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

fn status(run: types.RunSelector) -> String {
  case journal.load(system.cwd(), run) {
    Ok(#(saved_run, events)) ->
      "Run "
      <> saved_run.run_id
      <> " is "
      <> types.run_status_to_string(saved_run.status)
      <> "\n"
      <> "Events: "
      <> int.to_string(list.length(events))
      <> "\n"
      <> "Report: "
      <> saved_run.report_path
    Error(message) -> message
  }
}

fn report(run: types.RunSelector) -> String {
  case journal.read_report(system.cwd(), run) {
    Ok(contents) -> contents
    Error(message) -> message
  }
}

fn resume(run: types.RunSelector) -> String {
  case journal.load(system.cwd(), run) {
    Ok(#(saved_run, _)) ->
      case journal.mark_status(
        saved_run,
        types.RunBlocked,
        "Run resumed into audit mode; orchestration will continue in the next implementation slice.",
      ) {
        Ok(updated_run) ->
          "Run "
          <> updated_run.run_id
          <> " marked as "
          <> types.run_status_to_string(updated_run.status)
          <> "."
        Error(message) -> message
      }
    Error(message) -> message
  }
}

fn choose_harness(candidate: Result(types.Harness, Nil), config: types.Config) -> types.Harness {
  case candidate {
    Ok(harness) -> harness
    Error(Nil) -> config.default_harness
  }
}

fn choose_max_workers(candidate: Result(Int, Nil), config: types.Config) -> Int {
  case candidate {
    Ok(worker_count) -> worker_count
    Error(Nil) -> config.max_workers
  }
}

fn resolve_harness(
  candidate: Result(types.Harness, Nil),
  config: types.Config,
) -> String {
  choose_harness(candidate, config) |> types.harness_to_string
}

fn stringify_notifiers(notifiers: List(types.NotifierName)) -> String {
  notifiers
  |> list.map(types.notifier_to_string)
  |> string.join(with: ", ")
}
