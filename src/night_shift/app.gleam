import filepath
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/cli
import night_shift/config
import night_shift/dashboard
import night_shift/demo
import night_shift/git
import night_shift/harness
import night_shift/journal
import night_shift/orchestrator
import night_shift/system
import night_shift/types
import simplifile

pub fn run(command: types.Command) -> Nil {
  let config =
    config.load(".night-shift.toml")
    |> result.unwrap(or: types.default_config())
  let repo_root = git.repo_root(system.cwd())

  case command {
    types.Help ->
      io.println(
        "Night Shift is ready.\n\n"
        <> cli.usage()
        <> "\n"
        <> crate_summary(config),
      )
    types.Plan(notes_path, doc_path, harness) -> {
      let resolved_harness = choose_harness(harness, config)
      io.println(plan(repo_root, notes_path, doc_path, resolved_harness))
    }
    types.Start(brief_path, harness, max_workers, False) -> {
      let resolved_brief = resolve_start_brief_path(repo_root, brief_path)
      let resolved_harness = choose_harness(harness, config)
      let resolved_workers = choose_max_workers(max_workers, config)

      io.println(case resolved_brief {
        Ok(path) ->
          start(repo_root, path, resolved_harness, resolved_workers, config)
        Error(message) -> message
      })
    }
    types.Start(brief_path, harness, max_workers, True) -> {
      let resolved_brief = resolve_start_brief_path(repo_root, brief_path)
      let resolved_harness = choose_harness(harness, config)
      let resolved_workers = choose_max_workers(max_workers, config)

      case resolved_brief {
        Ok(path) ->
          case
            journal.start_run(
              repo_root,
              path,
              resolved_harness,
              resolved_workers,
            )
          {
            Ok(run) ->
              case
                dashboard.start_start_session(
                  repo_root,
                  run.run_id,
                  run,
                  config,
                )
              {
                Ok(session) -> {
                  io.println(render_dashboard_summary(session.url, run.run_id))
                  system.wait_forever()
                }
                Error(message) -> {
                  let _ = journal.mark_status(run, types.RunFailed, message)
                  io.println(message)
                }
              }
            Error(message) -> io.println(message)
          }
        Error(message) -> io.println(message)
      }
    }
    types.Status(run) -> io.println(status(repo_root, run))
    types.Report(run) -> io.println(report(repo_root, run))
    types.Resume(run, False) -> io.println(resume(repo_root, run, config))
    types.Resume(run, True) -> resume_with_ui(repo_root, run, config)
    types.Review(harness) -> io.println(review(repo_root, harness, config))
    types.Demo(ui) ->
      case demo.run(ui) {
        Ok(summary) -> io.println(summary)
        Error(message) -> io.println(message)
      }
  }
}

fn plan(
  repo_root: String,
  notes_path: String,
  doc_path: Option(String),
  resolved_harness: types.Harness,
) -> String {
  let target_doc_path = resolve_doc_path(repo_root, doc_path)
  case
    harness.plan_document(
      resolved_harness,
      repo_root,
      notes_path,
      target_doc_path,
    )
  {
    Ok(#(document, artifact_path)) ->
      case write_string(target_doc_path, document) {
        Ok(_) ->
          "Updated planning brief: "
          <> target_doc_path
          <> "\n"
          <> "Artifacts: "
          <> artifact_path
        Error(message) -> message
      }
    Error(message) -> message
  }
}

fn start(
  repo_root: String,
  brief_path: String,
  harness: types.Harness,
  max_workers: Int,
  config: types.Config,
) -> String {
  case journal.start_run(repo_root, brief_path, harness, max_workers) {
    Ok(run) ->
      case orchestrator.start(run, config) {
        Ok(completed_run) -> render_run_summary(completed_run)
        Error(message) -> message
      }
    Error(message) -> message
  }
}

fn resolve_start_brief_path(
  repo_root: String,
  brief_path: Option(String),
) -> Result(String, String) {
  case brief_path {
    Some(path) -> Ok(path)
    None -> {
      let path = default_brief_path(repo_root)
      case simplifile.read(path) {
        Ok(_) -> Ok(path)
        Error(_) ->
          Error(
            "No default brief was found at "
            <> path
            <> ". Run `night-shift plan --notes <path>` to create it or pass `--brief <path>`.",
          )
      }
    }
  }
}

fn resolve_doc_path(repo_root: String, doc_path: Option(String)) -> String {
  case doc_path {
    Some(path) -> path
    None -> default_brief_path(repo_root)
  }
}

fn default_brief_path(repo_root: String) -> String {
  filepath.join(repo_root, types.default_brief_filename)
}

fn write_string(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.write(contents, to: path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to write " <> path <> ": " <> simplifile.describe_error(error),
      )
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
  <> "\n"
  <> "Default brief: "
  <> types.default_brief_filename
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

fn resume(
  repo_root: String,
  run: types.RunSelector,
  config: types.Config,
) -> String {
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
    journal.start_run(repo_root, ".night-shift.toml", review_harness, 1)

  case review_run {
    Ok(run) ->
      case orchestrator.review(run, config) {
        Ok(updated_run) -> render_run_summary(updated_run)
        Error(message) -> message
      }
    Error(message) -> message
  }
}

fn choose_harness(
  candidate: Result(types.Harness, Nil),
  config: types.Config,
) -> types.Harness {
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

fn resume_with_ui(
  repo_root: String,
  run: types.RunSelector,
  config: types.Config,
) -> Nil {
  case journal.load(repo_root, run) {
    Ok(#(saved_run, _)) ->
      case
        dashboard.start_resume_session(
          repo_root,
          saved_run.run_id,
          saved_run,
          config,
        )
      {
        Ok(session) -> {
          io.println(render_dashboard_summary(session.url, saved_run.run_id))
          system.wait_forever()
        }
        Error(message) -> io.println(message)
      }
    Error(message) -> io.println(message)
  }
}

fn render_dashboard_summary(url: String, run_id: String) -> String {
  "Dashboard: " <> url <> "\n" <> "Run: " <> run_id
}
