import filepath
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/agent_config
import night_shift/cli
import night_shift/config
import night_shift/dashboard
import night_shift/demo
import night_shift/git
import night_shift/journal
import night_shift/orchestrator
import night_shift/project
import night_shift/provider
import night_shift/system
import night_shift/types
import night_shift/worktree_setup
import simplifile

pub fn run(command: types.Command) -> Nil {
  let repo_root = git.repo_root(system.cwd())

  case load_repo_config(repo_root) {
    Error(message) -> io.println(message)
    Ok(config) -> {

      case command {
        types.Help ->
          io.println(
            "Night Shift is ready.\n\n"
            <> cli.usage()
            <> "\n"
            <> crate_summary(config),
          )
        types.Init(agent_overrides, generate_setup, assume_yes) ->
          io.println(init(repo_root, config, agent_overrides, generate_setup, assume_yes))
        types.Plan(notes_path, doc_path, agent_overrides) ->
          io.println(
            case agent_config.resolve_plan_agent(config, agent_overrides) {
              Ok(planning_agent) ->
                plan(repo_root, notes_path, doc_path, planning_agent)
              Error(message) -> message
            },
          )
        types.Start(
          brief_path,
          agent_overrides,
          environment_name,
          max_workers,
          False,
        ) -> {
          let resolved_brief = resolve_start_brief_path(repo_root, brief_path)
          let resolved_workers = choose_max_workers(max_workers, config)

          io.println(
            case
              resolved_brief,
              ensure_clean_repo_for_start(repo_root),
              resolve_environment_name(repo_root, environment_name),
              agent_config.resolve_start_agents(config, agent_overrides)
            {
              Ok(path), Ok(Nil), Ok(selected_environment), Ok(#(
                planning_agent,
                execution_agent,
              )) ->
                start(
                  repo_root,
                  path,
                  planning_agent,
                  execution_agent,
                  selected_environment,
                  resolved_workers,
                  config,
                )
              Error(message), _, _, _ -> message
              _, Error(message), _, _ -> message
              _, _, Error(message), _ -> message
              _, _, _, Error(message) -> message
            },
          )
        }
        types.Start(
          brief_path,
          agent_overrides,
          environment_name,
          max_workers,
          True,
        ) -> {
          let resolved_brief = resolve_start_brief_path(repo_root, brief_path)
          let resolved_workers = choose_max_workers(max_workers, config)

          case
            resolved_brief,
            ensure_clean_repo_for_start(repo_root),
            resolve_environment_name(repo_root, environment_name),
            agent_config.resolve_start_agents(config, agent_overrides)
          {
            Ok(path), Ok(Nil), Ok(selected_environment), Ok(#(
              planning_agent,
              execution_agent,
            )) ->
              case
                journal.start_run(
                  repo_root,
                  path,
                  planning_agent,
                  execution_agent,
                  selected_environment,
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
                      io.println(render_dashboard_summary(
                        session.url,
                        run.run_id,
                      ))
                      system.wait_forever()
                    }
                    Error(message) -> {
                      let _ = journal.mark_status(run, types.RunFailed, message)
                      io.println(message)
                    }
                  }
                Error(message) -> io.println(message)
              }
            Error(message), _, _, _ -> io.println(message)
            _, Error(message), _, _ -> io.println(message)
            _, _, Error(message), _ -> io.println(message)
            _, _, _, Error(message) -> io.println(message)
          }
        }
        types.Status(run) -> io.println(status(repo_root, run))
        types.Report(run) -> io.println(report(repo_root, run))
        types.Resume(run, False) -> io.println(resume(repo_root, run, config))
        types.Resume(run, True) -> resume_with_ui(repo_root, run, config)
        types.Review(agent_overrides, environment_name) ->
          io.println(review(repo_root, agent_overrides, environment_name, config))
        types.Demo(ui) ->
          case demo.run(ui) {
            Ok(summary) -> io.println(summary)
            Error(message) -> io.println(message)
          }
      }
    }
  }
}

fn load_repo_config(repo_root: String) -> Result(types.Config, String) {
  let config_path = project.config_path(repo_root)
  case config.load(config_path) {
    Ok(parsed) -> Ok(parsed)
    Error(message) -> Error("Invalid " <> config_path <> ": " <> message)
  }
}

fn init(
  repo_root: String,
  config: types.Config,
  agent_overrides: types.AgentOverrides,
  generate_setup: Bool,
  assume_yes: Bool,
) -> String {
  let config_path = project.config_path(repo_root)
  let setup_path = project.worktree_setup_path(repo_root)
  let setup_requested = case generate_setup, assume_yes {
    True, _ -> True
    False, True -> False
    False, False ->
      prompt_yes_no("Draft worktree-setup.toml with the configured provider?")
  }

  case
    init_project_home(repo_root),
    ensure_file(config_path, config.render(config)),
    ensure_file(project.gitignore_path(repo_root), project_gitignore_contents()),
    ensure_worktree_setup_file(
      repo_root,
      config,
      agent_overrides,
      setup_requested,
      setup_path,
    )
  {
    Ok(Nil), Ok(config_status), Ok(_gitignore_status), Ok(setup_status) ->
      "Initialized " <> project.home(repo_root) <> "\nConfig: " <> config_status
      <> "\nWorktree setup: " <> setup_status
    Error(message), _, _, _ -> message
    _, Error(message), _, _ -> message
    _, _, Error(message), _ -> message
    _, _, _, Error(message) -> message
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
  environment_name: String,
  max_workers: Int,
  config: types.Config,
) -> String {
  case
    journal.start_run(
      repo_root,
      brief_path,
      planning_agent,
      execution_agent,
      environment_name,
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

fn resolve_environment_name(
  repo_root: String,
  requested: Option(String),
) -> Result(String, String) {
  use maybe_config <- result.try(worktree_setup.load(
    project.worktree_setup_path(repo_root),
  ))
  use selected <- result.try(worktree_setup.choose_environment(
    maybe_config,
    requested,
  ))
  case selected {
    Some(environment) -> Ok(environment.name)
    None -> Ok("")
  }
}

fn ensure_saved_environment_is_valid(
  repo_root: String,
  environment_name: String,
) -> Result(Nil, String) {
  case environment_name {
    "" -> Ok(Nil)
    name -> resolve_environment_name(repo_root, Some(name)) |> result.map(fn(_) { Nil })
  }
}

fn ensure_clean_repo_for_start(repo_root: String) -> Result(Nil, String) {
  let log_path =
    filepath.join(system.state_directory(), "night-shift/start-clean.log")
  case git.has_changes(repo_root, log_path) {
    True ->
      Error(
        "Night Shift start requires a clean source repository so execution worktrees and delivery stay aligned. Commit, stash, or move the existing changes out of "
        <> repo_root
        <> " and rerun `night-shift start`.",
      )
    False -> Ok(Nil)
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

fn write_and_verify_string(path: String, contents: String) -> Result(Nil, String) {
  use _ <- result.try(write_string(path, contents))
  case simplifile.read(path) {
    Ok(saved_contents) ->
      case saved_contents == contents {
        True -> Ok(Nil)
        False ->
          Error(
            "Night Shift wrote "
            <> path
            <> " but the saved contents did not match the generated result. Remove the file and retry `night-shift init`.",
          )
      }
    Error(error) ->
      Error(
        "Night Shift generated "
        <> path
        <> " but could not read it back after writing: "
        <> simplifile.describe_error(error),
      )
  }
}

fn init_project_home(repo_root: String) -> Result(Nil, String) {
  use _ <- result.try(create_directory(project.home(repo_root)))
  use _ <- result.try(create_directory(project.runs_root(repo_root)))
  create_directory(project.planning_root(repo_root))
}

fn ensure_file(path: String, contents: String) -> Result(String, String) {
  case simplifile.read(path) {
    Ok(_) -> Ok("kept " <> path)
    Error(_) ->
      write_string(path, contents)
      |> result.map(fn(_) { "created " <> path })
  }
}

fn ensure_worktree_setup_file(
  repo_root: String,
  config: types.Config,
  agent_overrides: types.AgentOverrides,
  setup_requested: Bool,
  path: String,
) -> Result(String, String) {
  case simplifile.read(path) {
    Ok(_) -> Ok("kept " <> path)
    Error(_) ->
      case setup_requested {
        True ->
          case agent_config.resolve_plan_agent(config, agent_overrides) {
            Ok(agent) ->
              case provider.generate_worktree_setup(agent, repo_root, path) {
                Ok(#(contents, artifact_path)) ->
                  write_and_verify_string(path, contents)
                  |> result.map(fn(_) {
                    "generated " <> path <> " from " <> artifact_path
                  })
                Error(message) ->
                  Error(
                    message
                    <> "\nA generated copy is kept under "
                    <> project.planning_root(repo_root)
                    <> ".",
                  )
              }
            Error(message) -> Error(message)
          }
        False ->
          write_and_verify_string(path, worktree_setup.default_template())
          |> result.map(fn(_) { "created " <> path })
      }
  }
}

fn create_directory(path: String) -> Result(Nil, String) {
  case simplifile.create_directory_all(path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to create directory "
        <> path
        <> ": "
        <> simplifile.describe_error(error),
      )
  }
}

fn project_gitignore_contents() -> String {
  "*\n!config.toml\n!worktree-setup.toml\n!.gitignore\n"
}

fn prompt_yes_no(prompt: String) -> Bool {
  io.print(prompt <> " [y/N]: ")
  case string.lowercase(string.trim(system.read_line())) {
    "y" | "yes" -> True
    _ -> False
  }
}

fn crate_summary(config: types.Config) -> String {
  "Default profile: "
  <> config.default_profile
  <> "\n"
  <> "Planning profile: "
  <> agent_config.effective_phase_profile_name(config.planning_profile, config)
  <> "\n"
  <> "Execution profile: "
  <> agent_config.effective_phase_profile_name(config.execution_profile, config)
  <> "\n"
  <> "Review profile: "
  <> agent_config.effective_phase_profile_name(config.review_profile, config)
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
      case ensure_saved_environment_is_valid(
        repo_root,
        saved_run.environment_name,
      ) {
        Ok(Nil) ->
          case orchestrator.resume(saved_run, config) {
            Ok(updated_run) -> render_run_summary(updated_run)
            Error(message) -> message
          }
        Error(message) -> message
      }
    Error(message) -> message
  }
}

fn review(
  repo_root: String,
  agent_overrides: types.AgentOverrides,
  environment_name: Option(String),
  config: types.Config,
) -> String {
  case
    resolve_environment_name(repo_root, environment_name),
    agent_config.resolve_review_agent(config, agent_overrides)
  {
    Ok(selected_environment), Ok(review_agent) ->
      case
        journal.start_run(
          repo_root,
          project.config_path(repo_root),
          review_agent,
          review_agent,
          selected_environment,
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
    Error(message), _ -> message
    _, Error(message) -> message
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
      case ensure_saved_environment_is_valid(
        repo_root,
        saved_run.environment_name,
      ) {
        Ok(Nil) ->
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
    Error(message) -> io.println(message)
  }
}

fn render_dashboard_summary(url: String, run_id: String) -> String {
  "Dashboard: " <> url <> "\n" <> "Run: " <> run_id
}
