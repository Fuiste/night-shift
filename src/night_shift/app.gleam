import gleam/int
import gleam/list
import gleam/result
import gleam/string
import night_shift/cli
import night_shift/config
import night_shift/git
import night_shift/journal
import night_shift/orchestrator
import night_shift/system
import night_shift/types

pub fn run(command: types.Command) -> String {
  let config = config.load(".night-shift.toml") |> result.unwrap(or: types.default_config())
  let repo_root = git.repo_root(system.cwd())

  case command {
    types.Help -> "Night Shift is ready.\n\n" <> cli.usage() <> "\n" <> crate_summary(config)
    types.Start(brief_path, harness, max_workers) -> {
      let resolved_harness = choose_harness(harness, config)
      let resolved_workers = choose_max_workers(max_workers, config)

      case journal.start_run(repo_root, brief_path, resolved_harness, resolved_workers) {
        Ok(run) ->
          case orchestrator.start(run, config) {
            Ok(completed_run) -> render_run_summary(completed_run)
            Error(message) -> message
          }
        Error(message) -> message
      }
    }
    types.Status(run) -> status(repo_root, run)
    types.Report(run) -> report(repo_root, run)
    types.Resume(run) -> resume(repo_root, run, config)
    types.Review(harness) -> review(repo_root, harness, config)
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

fn status(repo_root: String, run: types.RunSelector) -> String {
  case journal.load(repo_root, run) {
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

fn report(repo_root: String, run: types.RunSelector) -> String {
  case journal.read_report(repo_root, run) {
    Ok(contents) -> contents
    Error(message) -> message
  }
}

fn resume(repo_root: String, run: types.RunSelector, config: types.Config) -> String {
  case journal.load(repo_root, run) {
    Ok(#(saved_run, _)) ->
      case orchestrator.resume(saved_run, config) {
        Ok(updated_run) -> render_run_summary(updated_run)
        Error(message) -> message
      }
    Error(message) -> message
  }
}

fn review(
  repo_root: String,
  harness: Result(types.Harness, Nil),
  config: types.Config,
) -> String {
  let review_harness = choose_harness(harness, config)
  let review_run =
    journal.start_run(
      repo_root,
      ".night-shift.toml",
      review_harness,
      1,
    )

  case review_run {
    Ok(run) ->
      case orchestrator.review(run, config) {
        Ok(updated_run) -> render_run_summary(updated_run)
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

fn stringify_notifiers(notifiers: List(types.NotifierName)) -> String {
  notifiers
  |> list.map(types.notifier_to_string)
  |> string.join(with: ", ")
}

fn render_run_summary(run: types.RunRecord) -> String {
  "Run "
  <> run.run_id
  <> " finished with status "
  <> types.run_status_to_string(run.status)
  <> "\n"
  <> "Report: "
  <> run.report_path
  <> "\n"
  <> "Journal: "
  <> run.run_path
}
