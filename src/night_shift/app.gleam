//// Top-level command dispatcher for Night Shift.
////
//// This module is where parsed CLI commands meet repo-local configuration and
//// the usecase layer.
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import night_shift/agent_config
import night_shift/cli
import night_shift/config
import night_shift/demo
import night_shift/git
import night_shift/infra/dashboard_session
import night_shift/infra/decision_prompt
import night_shift/infra/init_prompt
import night_shift/infra/reset_guard
import night_shift/infra/terminal_ui
import night_shift/journal
import night_shift/project
import night_shift/system
import night_shift/types
import night_shift/usecase/init as init_usecase
import night_shift/usecase/plan as plan_usecase
import night_shift/usecase/render as usecase_render
import night_shift/usecase/reset as reset_usecase
import night_shift/usecase/resolve as resolve_usecase
import night_shift/usecase/resume as resume_usecase
import night_shift/usecase/review as review_usecase
import night_shift/usecase/start as start_usecase
import night_shift/usecase/status as status_usecase
import simplifile

/// Execute a parsed CLI command against the current repository.
pub fn run(command: types.Command) -> Nil {
  let repo_root = current_repo_root()

  case command {
    types.Help ->
      io.println(
        "Night Shift is ready.\n\n"
        <> cli.usage()
        <> "\n"
        <> crate_summary(types.default_config()),
      )
    types.Demo(ui) ->
      case demo.run(ui) {
        Ok(summary) -> io.println(summary)
        Error(message) -> io.println(message)
      }
    types.Init(agent_overrides, generate_setup, assume_yes) ->
      case load_repo_config(repo_root) {
        Error(message) -> io.println(message)
        Ok(config) ->
          io.println(init(
            repo_root,
            config,
            agent_overrides,
            generate_setup,
            assume_yes,
          ))
      }
    types.Reset(assume_yes, force) ->
      io.println(reset(repo_root, assume_yes, force))
    _ ->
      case load_initialized_repo_config(repo_root) {
        Error(message) -> io.println(message)
        Ok(config) -> run_initialized_command(repo_root, config, command)
      }
  }
}

fn current_repo_root() -> String {
  case system.get_env("NIGHT_SHIFT_REPO_ROOT") {
    "" -> git.repo_root(system.cwd())
    repo_root -> repo_root
  }
}

fn load_repo_config(repo_root: String) -> Result(types.Config, String) {
  let config_path = project.config_path(repo_root)
  case config.load(config_path) {
    Ok(parsed) -> Ok(parsed)
    Error(message) -> Error("Invalid " <> config_path <> ": " <> message)
  }
}

fn load_initialized_repo_config(
  repo_root: String,
) -> Result(types.Config, String) {
  let config_path = project.config_path(repo_root)
  case simplifile.read(config_path) {
    Ok(contents) ->
      config.parse(contents)
      |> result.map_error(fn(message) {
        "Invalid " <> config_path <> ": " <> message
      })
    Error(_) ->
      Error(
        "Night Shift is not initialized for this repository. Run `night-shift init` from "
        <> repo_root
        <> " first.",
      )
  }
}

fn run_initialized_command(
  repo_root: String,
  config: types.Config,
  command: types.Command,
) -> Nil {
  case command {
    types.Plan(notes_value, doc_path, agent_overrides) ->
      io.println(case agent_config.resolve_plan_agent(config, agent_overrides) {
        Ok(planning_agent) ->
          plan(repo_root, notes_value, doc_path, planning_agent, config)
        Error(message) -> message
      })
    types.Start(run, False) -> io.println(start(repo_root, run, config))
    types.Start(run, True) -> start_with_ui(repo_root, run, config)
    types.Status(run) -> io.println(status(repo_root, run))
    types.Report(run) -> io.println(report(repo_root, run))
    types.Resolve(run) -> io.println(resolve(repo_root, run, config))
    types.Resume(run, False) -> io.println(resume(repo_root, run, config))
    types.Resume(run, True) -> resume_with_ui(repo_root, run, config)
    types.Review(agent_overrides, environment_name) ->
      io.println(review(repo_root, agent_overrides, environment_name, config))
    _ -> io.println("Unsupported command.")
  }
}

fn init(
  repo_root: String,
  config: types.Config,
  agent_overrides: types.AgentOverrides,
  generate_setup: Bool,
  assume_yes: Bool,
) -> String {
  case
    init_usecase.execute(
      repo_root,
      config,
      agent_overrides,
      generate_setup,
      assume_yes,
      init_prompt.resolve_provider,
      init_prompt.resolve_model,
      init_prompt.choose_setup_request,
    )
  {
    Ok(view) -> usecase_render.render_init(view)
    Error(message) -> message
  }
}

fn plan(
  repo_root: String,
  notes_value: String,
  doc_path: Option(String),
  planning_agent: types.ResolvedAgentConfig,
  config: types.Config,
) -> String {
  case
    plan_usecase.execute(
      repo_root,
      notes_value,
      doc_path,
      planning_agent,
      config,
    )
  {
    Ok(view) -> usecase_render.render_plan(view)
    Error(message) -> message
  }
}

fn start(
  repo_root: String,
  run_selector: types.RunSelector,
  config: types.Config,
) -> String {
  case start_usecase.execute(repo_root, run_selector, config) {
    Ok(view) -> usecase_render.render_start(view)
    Error(message) -> message
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
  <> project.default_brief_path(system.cwd())
}

fn status(repo_root: String, run: types.RunSelector) -> String {
  case status_usecase.execute(repo_root, run) {
    Ok(view) -> usecase_render.render_status(view)
    Error(message) -> message
  }
}

fn resolve(
  repo_root: String,
  selector: types.RunSelector,
  _config: types.Config,
) -> String {
  case terminal_ui.can_prompt_interactively() {
    False ->
      "night-shift resolve requires an interactive terminal so it can capture decision answers."
    True ->
      case
        resolve_usecase.execute(
          repo_root,
          selector,
          decision_prompt.collect_recorded_decisions,
        )
      {
        Ok(view) -> usecase_render.render_resolve(view)
        Error(message) -> message
      }
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
  case resume_usecase.execute(repo_root, run, config) {
    Ok(view) -> usecase_render.render_resume(view)
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
    review_usecase.execute(repo_root, agent_overrides, environment_name, config)
  {
    Ok(view) -> usecase_render.render_review(view)
    Error(message) -> message
  }
}

fn stringify_notifiers(notifiers: List(types.NotifierName)) -> String {
  notifiers
  |> list.map(types.notifier_to_string)
  |> string.join(with: ", ")
}

fn reset(repo_root: String, assume_yes: Bool, force: Bool) -> String {
  case
    reset_guard.confirm(
      repo_root,
      assume_yes,
      terminal_ui.can_prompt_interactively(),
    )
  {
    Error(message) -> message
    Ok(Nil) ->
      case reset_guard.ensure_safe(repo_root, force) {
        Error(message) -> message
        Ok(Nil) -> usecase_render.render_reset(reset_usecase.execute(repo_root))
      }
  }
}

fn start_with_ui(
  repo_root: String,
  selector: types.RunSelector,
  config: types.Config,
) -> Nil {
  case dashboard_session.start(repo_root, selector, config) {
    Ok(Nil) -> Nil
    Error(message) -> io.println(message)
  }
}

fn resume_with_ui(
  repo_root: String,
  run: types.RunSelector,
  config: types.Config,
) -> Nil {
  case dashboard_session.resume(repo_root, run, config) {
    Ok(Nil) -> Nil
    Error(message) -> io.println(message)
  }
}
