import filepath
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/agent_config
import night_shift/cli
import night_shift/config
import night_shift/dashboard
import night_shift/demo
import night_shift/git
import night_shift/journal
import night_shift/orchestrator
import night_shift/provider
import night_shift/system
import night_shift/types
import simplifile

pub fn run(command: types.Command) -> Nil {
  case config.load(".night-shift.toml") {
    Error(message) -> io.println("Invalid .night-shift.toml: " <> message)
    Ok(config) -> {
      let repo_root = git.repo_root(system.cwd())

      case command {
        types.Help ->
          io.println(
            "Night Shift is ready.\n\n"
            <> cli.usage()
            <> "\n"
            <> crate_summary(config),
          )
        types.Plan(notes_path, doc_path, agent_overrides) ->
          io.println(case agent_config.resolve_plan_agent(config, agent_overrides) {
            Ok(planning_agent) -> plan(repo_root, notes_path, doc_path, planning_agent)
            Error(message) -> message
          })
        types.Start(brief_path, agent_overrides, max_workers, False) -> {
          let resolved_brief = resolve_start_brief_path(repo_root, brief_path)
          let resolved_workers = choose_max_workers(max_workers, config)

          io.println(case resolved_brief, agent_config.resolve_start_agents(
            config,
            agent_overrides,
          ) {
            Ok(path), Ok(#(planning_agent, execution_agent)) ->
              start(
                repo_root,
                path,
                planning_agent,
                execution_agent,
                resolved_workers,
                config,
              )
            Error(message), _ -> message
            _, Error(message) -> message
          })
        }
        types.Start(brief_path, agent_overrides, max_workers, True) -> {
          let resolved_brief = resolve_start_brief_path(repo_root, brief_path)
          let resolved_workers = choose_max_workers(max_workers, config)

          case resolved_brief, agent_config.resolve_start_agents(
            config,
            agent_overrides,
          ) {
            Ok(path), Ok(#(planning_agent, execution_agent)) ->
              case
                journal.start_run(
                  repo_root,
                  path,
                  planning_agent,
                  execution_agent,
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
            Error(message), _ -> io.println(message)
            _, Error(message) -> io.println(message)
          }
        }
        types.Status(run) -> io.println(status(repo_root, run))
        types.Report(run) -> io.println(report(repo_root, run))
        types.Resume(run, False) -> io.println(resume(repo_root, run, config))
        types.Resume(run, True) -> resume_with_ui(repo_root, run, config)
        types.Review(agent_overrides) ->
          io.println(review(repo_root, agent_overrides, config))
        types.Demo(ui) ->
          case demo.run(ui) {
            Ok(summary) -> io.println(summary)
            Error(message) -> io.println(message)
          }
      }
    }
  }
}

fn plan(
  repo_root: String,
  notes_path: String,
  doc_path: Option(String),
  planning_agent: types.ResolvedAgentConfig,
) -> String {
  let target_doc_path = resolve_doc_path(repo_root, doc_path)
  case
    provider.plan_document(
      planning_agent,
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
          <> "Planning profile: "
          <> agent_config.summary(planning_agent)
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
  planning_agent: types.ResolvedAgentConfig,
  execution_agent: types.ResolvedAgentConfig,
  max_workers: Int,
  config: types.Config,
) -> String {
  case
    journal.start_run(
      repo_root,
      brief_path,
      planning_agent,
      execution_agent,
      max_workers,
    )
  {
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
  "Default profile: "
  <> config.default_profile
  <> "\n"
  <> "Planning profile: "
  <> config.planning_profile
  <> "\n"
  <> "Execution profile: "
  <> config.execution_profile
  <> "\n"
  <> "Review profile: "
  <> config.review_profile
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
      <> "Planning: "
      <> agent_config.summary(saved_run.planning_agent)
      <> "\n"
      <> "Execution: "
      <> agent_config.summary(saved_run.execution_agent)
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
  agent_overrides: types.AgentOverrides,
  config: types.Config,
) -> String {
  case agent_config.resolve_review_agent(config, agent_overrides) {
    Ok(review_agent) ->
      case
        journal.start_run(
          repo_root,
          ".night-shift.toml",
          review_agent,
          review_agent,
          1,
        )
      {
        Ok(run) ->
          case orchestrator.review(run, config) {
            Ok(updated_run) -> render_run_summary(updated_run)
            Error(message) -> message
          }
        Error(message) -> message
      }
    Error(message) -> message
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
  <> "Planning: "
  <> agent_config.summary(run.planning_agent)
  <> "\n"
  <> "Execution: "
  <> agent_config.summary(run.execution_agent)
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
