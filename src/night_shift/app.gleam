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
import night_shift/provider_models
import night_shift/system
import night_shift/types
import night_shift/worktree_setup
import simplifile

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
          io.println(
            init(repo_root, config, agent_overrides, generate_setup, assume_yes),
          )
      }
    types.Reset(assume_yes, force) -> io.println(reset(repo_root, assume_yes, force))
    _ ->
      case load_initialized_repo_config(repo_root) {
        Error(message) -> io.println(message)
        Ok(config) ->
          run_initialized_command(repo_root, config, command)
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

fn load_initialized_repo_config(repo_root: String) -> Result(types.Config, String) {
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
      io.println(
        case agent_config.resolve_plan_agent(config, agent_overrides) {
          Ok(planning_agent) ->
            plan(repo_root, notes_value, doc_path, planning_agent, config)
          Error(message) -> message
        },
      )
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
  let config_path = project.config_path(repo_root)
  let setup_path = project.worktree_setup_path(repo_root)
  let config_exists = file_exists(config_path)
  let setup_exists = file_exists(setup_path)

  case
    init_project_home(repo_root),
    choose_init_config(
      repo_root,
      config,
      agent_overrides,
      config_exists,
    ),
    choose_setup_request(generate_setup, assume_yes, setup_exists),
    ensure_file(project.gitignore_path(repo_root), project_gitignore_contents())
  {
    Ok(Nil), Ok(init_config), Ok(setup_requested), Ok(_gitignore_status) ->
      case
        ensure_file(config_path, config.render(init_config)),
        ensure_worktree_setup_file(
          repo_root,
          init_config,
          agent_overrides,
          setup_requested,
          setup_path,
        )
      {
        Ok(config_status), Ok(setup_status) ->
          "Initialized " <> project.home(repo_root) <> "\nConfig: " <> config_status
          <> "\nWorktree setup: " <> setup_status
        Error(message), _ -> message
        _, Error(message) -> message
      }
    Error(message), _, _, _ -> message
    _, Error(message), _, _ -> message
    _, _, Error(message), _ -> message
    _, _, _, Error(message) -> message
  }
}

fn choose_init_config(
  repo_root: String,
  config: types.Config,
  agent_overrides: types.AgentOverrides,
  config_exists: Bool,
) -> Result(types.Config, String) {
  case config_exists {
    True -> Ok(config)
    False -> {
      use selected_provider <- result.try(resolve_init_provider(config, agent_overrides))
      use _ <- result.try(validate_init_reasoning(
        selected_provider,
        agent_overrides.reasoning,
      ))
      use selected_model <- result.try(resolve_init_model(
        repo_root,
        config,
        selected_provider,
        agent_overrides,
      ))
      Ok(build_init_config(config, agent_overrides, selected_provider, selected_model))
    }
  }
}

fn choose_setup_request(
  generate_setup: Bool,
  assume_yes: Bool,
  setup_exists: Bool,
) -> Result(Bool, String) {
  case setup_exists {
    True -> Ok(False)
    False ->
      case generate_setup, assume_yes {
        True, _ -> Ok(True)
        False, True -> Ok(False)
        False, False ->
          case can_prompt_interactively() {
            True ->
              Ok(
                select_from_labels(
                  "3. Should Night Shift draft an initial worktree setup using that provider?",
                  ["Yes, draft worktree-setup.toml", "No, create the blank template"],
                  0,
                ) == 0,
              )
            False ->
              Error(
                "night-shift init needs either --generate-setup or --yes when not running in an interactive terminal.",
              )
          }
      }
  }
}

fn resolve_init_provider(
  config: types.Config,
  agent_overrides: types.AgentOverrides,
) -> Result(types.Provider, String) {
  case agent_overrides.provider {
    Some(provider_name) -> Ok(provider_name)
    None ->
      case can_prompt_interactively() {
        True -> {
          let options = [
            "codex - OpenAI Codex CLI",
            "cursor - Cursor Agent",
          ]
          let default_index = default_provider_index(config)
          case select_from_labels(
            "1. Which provider do you want to use?",
            options,
            default_index,
          ) {
            1 -> Ok(types.Cursor)
            _ -> Ok(types.Codex)
          }
        }
        False ->
          Error(
            "night-shift init needs --provider <codex|cursor> when not running in an interactive terminal.",
          )
      }
  }
}

fn resolve_init_model(
  repo_root: String,
  config: types.Config,
  provider_name: types.Provider,
  agent_overrides: types.AgentOverrides,
) -> Result(String, String) {
  case agent_overrides.model {
    Some(model) -> Ok(model)
    None ->
      case can_prompt_interactively() {
        True -> {
          use models <- result.try(provider_models.list_models(provider_name, repo_root))
          let labels = models |> list.map(fn(model) { model.label })
          let default_index = preferred_model_index(config, provider_name, models)
          let selected_index =
            select_from_labels(
              "2. Which "
              <> types.provider_to_string(provider_name)
              <> " model should be your default?",
              labels,
              default_index,
            )
          use selected <- result.try(model_id_at(models, selected_index))
          Ok(selected)
        }
        False ->
          Error(
            "night-shift init needs --model <id> when not running in an interactive terminal.",
          )
      }
  }
}

fn build_init_config(
  config: types.Config,
  agent_overrides: types.AgentOverrides,
  provider_name: types.Provider,
  model: String,
) -> types.Config {
  let profile_name = case agent_overrides.profile {
    Some(name) -> name
    None -> "default"
  }
  let profile =
    types.AgentProfile(
      name: profile_name,
      provider: provider_name,
      model: Some(model),
      reasoning: agent_overrides.reasoning,
      provider_overrides: [],
    )

  types.Config(
    ..config,
    default_profile: profile_name,
    planning_profile: "",
    execution_profile: "",
    review_profile: "",
    profiles: [profile],
  )
}

fn validate_init_reasoning(
  provider_name: types.Provider,
  reasoning: Option(types.ReasoningLevel),
) -> Result(Nil, String) {
  case provider_name, reasoning {
    types.Cursor, Some(_) ->
      Error(
        "Cursor does not support Night Shift's normalized reasoning control. Omit --reasoning or choose Codex.",
      )
    _, _ -> Ok(Nil)
  }
}

fn default_provider_index(config: types.Config) -> Int {
  case default_profile(config) {
    Ok(profile) ->
      case profile.provider {
        types.Cursor -> 1
        _ -> 0
      }
    Error(_) -> 0
  }
}

fn preferred_model_index(
  config: types.Config,
  provider_name: types.Provider,
  models: List(provider_models.ProviderModel),
) -> Int {
  case default_profile(config) {
    Ok(profile) if profile.provider == provider_name ->
      case profile.model {
        Some(model_id) -> find_model_index(models, model_id, 0)
        None -> provider_models.default_index(models)
      }
    _ -> provider_models.default_index(models)
  }
}

fn default_profile(config: types.Config) -> Result(types.AgentProfile, Nil) {
  list.find(config.profiles, fn(profile) { profile.name == config.default_profile })
}

fn find_model_index(
  models: List(provider_models.ProviderModel),
  target: String,
  index: Int,
) -> Int {
  case models {
    [] -> 0
    [model, ..rest] ->
      case model.id == target {
        True -> index
        False -> find_model_index(rest, target, index + 1)
      }
  }
}

fn model_id_at(
  models: List(provider_models.ProviderModel),
  index: Int,
) -> Result(String, String) {
  case models, index {
    [model, .._], 0 -> Ok(model.id)
    [_, ..rest], _ -> model_id_at(rest, index - 1)
    [], _ -> Error("The selected model was out of range.")
  }
}

fn select_from_labels(
  prompt: String,
  labels: List(String),
  default_index: Int,
) -> Int {
  system.select_option(prompt, labels, default_index)
}

fn can_prompt_interactively() -> Bool {
  case system.get_env("NIGHT_SHIFT_ASSUME_TTY") {
    "1" -> True
    _ -> system.stdin_is_tty() && system.stdout_is_tty()
  }
}

fn file_exists(path: String) -> Bool {
  case simplifile.read(path) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn plan(
  repo_root: String,
  notes_value: String,
  doc_path: Option(String),
  planning_agent: types.ResolvedAgentConfig,
  config: types.Config,
) -> String {
  let target_doc_path = resolve_doc_path(repo_root, doc_path)
  case
    resolve_notes_source(repo_root, notes_value),
    agent_config.resolve_start_agents(config, types.empty_agent_overrides()),
    resolve_environment_name(repo_root, None)
  {
            Ok(notes_source), Ok(#(_default_plan_agent, execution_agent)), Ok(
      selected_environment,
    ) ->
      case
        provider.plan_document(
          planning_agent,
          repo_root,
          notes_source,
          target_doc_path,
        )
      {
        Ok(#(document, artifact_path, resolved_notes_source)) ->
          case write_string(target_doc_path, document) {
            Ok(_) ->
              case
                prepare_planning_run(
                  repo_root,
                  target_doc_path,
                  planning_agent,
                  execution_agent,
                  selected_environment,
                  config.max_workers,
                  resolved_notes_source,
                )
              {
                Ok(#(seeded_run, replanning)) ->
                  case case replanning {
                    True -> orchestrator.replan(seeded_run)
                    False -> orchestrator.plan(seeded_run)
                  } {
                    Ok(planned_run) ->
                      render_planning_summary(
                        planned_run,
                        target_doc_path,
                        artifact_path,
                        resolved_notes_source,
                      )
                    Error(message) -> message
                  }
                Error(message) -> message
              }
            Error(message) -> message
          }
        Error(message) -> message
      }
    Error(message), _, _ -> message
    _, Error(message), _ -> message
    _, _, Error(message) -> message
  }
}

fn start(
  repo_root: String,
  run_selector: types.RunSelector,
  config: types.Config,
) -> String {
  case load_start_run(repo_root, run_selector) {
    Ok(run) ->
      case ensure_clean_repo_for_start(repo_root) {
        Ok(warning) ->
          case journal.activate_run(run) {
            Ok(active_run) ->
              render_active_run_outcome(
                active_run,
                warning,
                orchestrator.start(active_run, config),
              )
            Error(message) -> message
          }
        Error(message) -> message
      }
    Error(message) -> message
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

fn ensure_clean_repo_for_start(repo_root: String) -> Result(Option(String), String) {
  let log_path =
    filepath.join(system.state_directory(), "night-shift/start-clean.log")
  let changed_files = git.changed_files(repo_root, log_path)
  let source_changes =
    changed_files
    |> list.filter(fn(path) { !is_control_plane_path(path) })
  let control_changes =
    changed_files
    |> list.filter(is_control_plane_path)

  case source_changes, control_changes {
    [], [] -> Ok(None)
    [], _ ->
      Ok(Some(
        "Night Shift noticed repo-local control-plane changes under `.night-shift/` and will continue.\nChanged control files:\n"
        <> render_changed_paths(control_changes)
        <> "\nThese files stay in the source checkout and are not part of execution worktrees or delivery PRs.",
      ))
    _, _ ->
      Error(
        "Night Shift start requires a clean source repository so execution worktrees and delivery stay aligned.\nChanged files:\n"
        <> render_changed_paths(source_changes)
        <> start_clean_repo_suggestion(source_changes, repo_root),
      )
  }
}

fn default_brief_path(repo_root: String) -> String {
  project.default_brief_path(repo_root)
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
  case load_display_run(repo_root, run) {
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
      <> "Notes: "
      <> render_notes_source(saved_run.notes_source)
      <> "\n"
      <> status_summary(saved_run, events)
      <> "\n"
      <> "Events: "
      <> int.to_string(list.length(events))
      <> "\n"
      <> "Report: "
      <> saved_run.report_path
    Error(message) -> message
  }
}

fn resolve(
  repo_root: String,
  selector: types.RunSelector,
  _config: types.Config,
) -> String {
  case load_resolvable_run(repo_root, selector) {
    Ok(run) ->
      case can_prompt_interactively() {
        False ->
          "night-shift resolve requires an interactive terminal so it can capture decision answers."
        True -> resolve_loop(run)
      }
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
          render_active_run_outcome(
            saved_run,
            None,
            orchestrator.resume(saved_run, config),
          )
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
          render_active_run_outcome(
            run,
            None,
            orchestrator.review(run, config),
          )
        Error(message) -> message
      }
    Error(message), _ -> message
    _, Error(message) -> message
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
  <> "Notes: "
  <> render_notes_source(run.notes_source)
  <> "\n"
  <> "Report: "
  <> run.report_path
  <> "\n"
  <> "Journal: "
  <> run.run_path
}

fn render_active_run_outcome(
  active_run: types.RunRecord,
  warning: Option(String),
  outcome: Result(types.RunRecord, String),
) -> String {
  case outcome {
    Ok(updated_run) ->
      prefix_warning(warning, render_run_summary(updated_run))
    Error(message) ->
      case mark_latest_persisted_run_failed(active_run, message) {
        Ok(failed_run) ->
          prefix_warning(
            warning,
            message <> "\n" <> render_run_summary(failed_run),
          )
        Error(_) -> prefix_warning(warning, message)
      }
  }
}

fn mark_latest_persisted_run_failed(
  active_run: types.RunRecord,
  message: String,
) -> Result(types.RunRecord, String) {
  let latest_run = case journal.load(
    active_run.repo_root,
    types.RunId(active_run.run_id),
  ) {
    Ok(#(run, _)) -> recover_in_flight_tasks(run)
    Error(_) -> recover_in_flight_tasks(active_run)
  }
  journal.mark_status(latest_run, types.RunFailed, message)
}

fn recover_in_flight_tasks(run: types.RunRecord) -> types.RunRecord {
  let recovered_tasks =
    run.tasks
    |> list.map(recover_in_flight_task(run.run_path, _))
  types.RunRecord(..run, tasks: recovered_tasks)
}

fn recover_in_flight_task(run_path: String, task: types.Task) -> types.Task {
  case task.state {
    types.Running -> {
      let recovery_log = filepath.join(run_path, "logs/" <> task.id <> ".recovery.log")
      let has_worktree_changes =
        case task.worktree_path {
          "" -> False
          worktree_path -> git.has_changes(worktree_path, recovery_log)
        }
      let recovered_state = case has_worktree_changes {
        True -> types.ManualAttention
        False -> types.Failed
      }
      let recovered_summary =
        case string.trim(task.summary) {
          "" ->
            "Primary blocker: Night Shift stopped before this started task could be finalized.\n\nEnvironment notes: inspect the task log and worktree before retrying."
          existing ->
            existing
            <> "\n\nRecovery notes: Night Shift stopped before this started task could be finalized."
        }
      types.Task(..task, state: recovered_state, summary: recovered_summary)
    }
    _ -> task
  }
}

fn render_planning_summary(
  run: types.RunRecord,
  brief_path: String,
  artifact_path: String,
  notes_source: types.NotesSource,
) -> String {
  "Planned run "
  <> run.run_id
  <> " with status "
  <> types.run_status_to_string(run.status)
  <> "\n"
  <> "Brief: "
  <> brief_path
  <> "\n"
  <> "Notes: "
  <> types.notes_source_label(notes_source)
  <> "\n"
  <> "Planning: "
  <> agent_config.summary(run.planning_agent)
  <> "\n"
  <> "Artifacts: "
  <> artifact_path
  <> "\n"
  <> "Report: "
  <> run.report_path
}

fn resolve_notes_source(
  repo_root: String,
  notes_value: String,
) -> Result(types.NotesSource, String) {
  case simplifile.read(notes_value) {
    Ok(_) -> Ok(types.NotesFile(notes_value))
    Error(_) -> {
      let artifact_path = planning_artifact_path(repo_root)
      let saved_path = filepath.join(artifact_path, "inline-notes.md")
      use _ <- result.try(create_directory(artifact_path))
      use _ <- result.try(write_string(saved_path, notes_value))
      Ok(types.InlineNotes(saved_path))
    }
  }
}

fn prepare_planning_run(
  repo_root: String,
  brief_path: String,
  planning_agent: types.ResolvedAgentConfig,
  execution_agent: types.ResolvedAgentConfig,
  environment_name: String,
  max_workers: Int,
  notes_source: types.NotesSource,
) -> Result(#(types.RunRecord, Bool), String) {
  case journal.latest_reusable_run(repo_root) {
    Ok(Some(existing_run)) -> {
      use brief_contents <- result.try(simplifile.read(brief_path)
        |> result.map_error(fn(error) {
          "Unable to read " <> brief_path <> ": " <> simplifile.describe_error(error)
        }))
      use _ <- result.try(write_string(existing_run.brief_path, brief_contents))
      let updated_run =
        types.RunRecord(
          ..existing_run,
          planning_agent: planning_agent,
          execution_agent: execution_agent,
          environment_name: environment_name,
          max_workers: max_workers,
          notes_source: Some(notes_source),
          planning_dirty: True,
        )
      use rewritten_run <- result.try(journal.rewrite_run(updated_run))
      Ok(#(rewritten_run, True))
    }
    Ok(None) -> {
      use pending_run <- result.try(journal.create_pending_run(
        repo_root,
        brief_path,
        planning_agent,
        execution_agent,
        environment_name,
        max_workers,
        Some(notes_source),
      ))
      let updated_run = types.RunRecord(..pending_run, planning_dirty: True)
      journal.rewrite_run(updated_run)
      |> result.map(fn(run) { #(run, False) })
    }
    Error(message) -> Error(message)
  }
}

fn load_start_run(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(types.RunRecord, String) {
  case selector {
    types.RunId(_) -> {
      use #(run, _) <- result.try(journal.load(repo_root, selector))
      validate_startable_run(run)
    }
    types.LatestRun -> load_latest_start_run(repo_root)
  }
}

fn load_resolvable_run(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(types.RunRecord, String) {
  case selector {
    types.RunId(_) -> {
      use #(run, _) <- result.try(journal.load(repo_root, selector))
      validate_resolvable_run(run)
    }
    types.LatestRun -> load_latest_resolvable_run(repo_root)
  }
}

fn load_display_run(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(#(types.RunRecord, List(types.RunEvent)), String) {
  journal.load(repo_root, selector)
}

fn validate_startable_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  case run.status {
    types.RunPending ->
      case run.planning_dirty {
        True ->
          Error(
            "Run "
            <> run.run_id
            <> " has newer planning inputs than the current task graph. Run `night-shift resolve --run "
            <> run.run_id
            <> "` first.",
          )
        False -> Ok(run)
      }
    types.RunBlocked ->
      Error(start_guidance_for_run(run))
    types.RunActive ->
      Error("Run " <> run.run_id <> " is already active. Use `night-shift resume --run " <> run.run_id <> "` or inspect status/report.")
    types.RunCompleted ->
      Error("Run " <> run.run_id <> " is already completed. Run `night-shift plan --notes ...` to create or refresh a runnable plan.")
    types.RunFailed ->
      Error("Run " <> run.run_id <> " already failed. Run `night-shift plan --notes ...` to create a fresh or refreshed plan.")
  }
}

fn validate_resolvable_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  case run.status, run.planning_dirty, outstanding_decision_count(run) {
    types.RunBlocked, _, _ -> Ok(run)
    types.RunPending, True, _ -> Ok(run)
    types.RunPending, False, _ ->
      Error("Run " <> run.run_id <> " is already ready to start. Run `night-shift start --run " <> run.run_id <> "`.")
    types.RunActive, _, _ ->
      Error("Run " <> run.run_id <> " is active and cannot be resolved right now.")
    types.RunCompleted, _, _ ->
      Error("Run " <> run.run_id <> " is already completed.")
    types.RunFailed, _, _ ->
      Error("Run " <> run.run_id <> " failed and cannot be resolved in place.")
  }
}

fn load_latest_start_run(repo_root: String) -> Result(types.RunRecord, String) {
  case latest_open_run(repo_root) {
    Ok(run) -> validate_startable_run(run)
    Error(_) ->
      Error(
        "No open Night Shift run was found. Run `night-shift plan --notes ...` first.",
      )
  }
}

fn load_latest_resolvable_run(repo_root: String) -> Result(types.RunRecord, String) {
  case latest_open_run(repo_root) {
    Ok(run) -> validate_resolvable_run(run)
    Error(_) ->
      Error(
        "No blocked Night Shift run was found. Run `night-shift plan --notes ...` first.",
      )
  }
}

fn latest_open_run(repo_root: String) -> Result(types.RunRecord, String) {
  use runs <- result.try(journal.list_runs(repo_root))
  case list.find(runs, fn(run) {
    case run.status {
      types.RunPending | types.RunBlocked | types.RunActive -> True
      _ -> False
    }
  }) {
    Ok(run) -> Ok(run)
    Error(_) -> Error("No open Night Shift run was found.")
  }
}

fn render_notes_source(notes_source: Option(types.NotesSource)) -> String {
  case notes_source {
    Some(source) -> types.notes_source_label(source)
    None -> "(none)"
  }
}

fn status_summary(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> String {
  case latest_environment_preflight_failure(events) {
    Some(message) ->
      "Environment bootstrap blocker: yes\n"
      <> "Failure: "
      <> message
      <> "\n"
      <> "Ready implementation tasks: "
      <> int.to_string(ready_implementation_task_count(run.tasks))
      <> "\n"
      <> "Queued tasks: "
      <> int.to_string(queued_task_count(run.tasks))
      <> "\n"
      <> "Next action: fix the worktree environment, then rerun `night-shift start` or `night-shift reset`"
    None ->
      case run.status {
        types.RunFailed ->
          "Completed tasks: "
          <> int.to_string(completed_task_count(run.tasks))
          <> "\n"
          <> "Opened PRs: "
          <> int.to_string(opened_pr_count(run.tasks))
          <> "\n"
          <> "Failed tasks: "
          <> int.to_string(failed_task_count(run.tasks))
          <> "\n"
          <> "Outstanding decisions: "
          <> int.to_string(outstanding_decision_count(run))
          <> "\n"
          <> "Queued tasks: "
          <> int.to_string(queued_task_count(run.tasks))
          <> "\n"
          <> "Failure: "
          <> latest_run_failed_message(events)
          <> "\n"
          <> "Next action: inspect the report, then rerun `night-shift plan --notes ...` when you're ready for the next pass."
        _ ->
          case run.status == types.RunBlocked || run.planning_dirty {
            True ->
              "Blocked tasks: "
              <> int.to_string(blocked_task_count(run))
              <> "\n"
              <> "Outstanding decisions: "
              <> int.to_string(outstanding_decision_count(run))
              <> "\n"
              <> "Planning sync pending: "
              <> bool_label(run.planning_dirty)
              <> "\n"
              <> "Ready implementation tasks: "
              <> int.to_string(ready_implementation_task_count(run.tasks))
              <> "\n"
              <> "Queued tasks: "
              <> int.to_string(queued_task_count(run.tasks))
              <> "\n"
              <> "Next action: "
              <> next_action_label(run)
            False ->
              "Outstanding decisions: "
              <> int.to_string(outstanding_decision_count(run))
              <> "\n"
              <> "Ready tasks: "
              <> int.to_string(ready_task_count(run.tasks))
              <> "\n"
              <> "Queued tasks: "
              <> int.to_string(queued_task_count(run.tasks))
          }
      }
  }
}

fn completed_task_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.state == types.Completed })
  |> list.length
}

fn opened_pr_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.pr_number != "" })
  |> list.length
}

fn failed_task_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.state == types.Failed })
  |> list.length
}

fn outstanding_decision_count(run: types.RunRecord) -> Int {
  unresolved_manual_attention_tasks(run)
  |> list.map(types.unresolved_decision_requests(run.decisions, _))
  |> list.flatten
  |> list.length
}

fn ready_task_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.state == types.Ready })
  |> list.length
}

fn ready_implementation_task_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) {
    task.state == types.Ready && task.kind == types.ImplementationTask
  })
  |> list.length
}

fn blocked_task_count(run: types.RunRecord) -> Int {
  let unresolved_blockers =
    unresolved_manual_attention_tasks(run)
    |> list.length
  let implementation_blockers =
    run.tasks
    |> list.filter(fn(task) {
      task.kind == types.ImplementationTask
      && {
        task.state == types.Blocked || task.state == types.ManualAttention
      }
    })
    |> list.length
  case run.planning_dirty && unresolved_blockers == 0 && implementation_blockers == 0 {
    True -> 1
    False -> unresolved_blockers + implementation_blockers
  }
}

fn queued_task_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.state == types.Queued })
  |> list.length
}

fn unresolved_manual_attention_tasks(run: types.RunRecord) -> List(types.Task) {
  run.tasks
  |> list.filter(fn(task) { types.task_requires_manual_attention(run.decisions, task) })
}

fn collect_recorded_decisions(
  run: types.RunRecord,
  tasks: List(types.Task),
) -> Result(#(List(types.RecordedDecision), List(types.RunEvent)), String) {
  let prompts = pending_decision_prompts(run.decisions, tasks)
  case prompts {
    [] -> Error("No unresolved manual-attention decisions were found for this run.")
    _ -> collect_request_answers(prompts, [])
  }
}

fn collect_request_answers(
  prompts: List(#(types.Task, types.DecisionRequest)),
  acc: List(types.RecordedDecision),
) -> Result(#(List(types.RecordedDecision), List(types.RunEvent)), String) {
  collect_request_answers_with_warnings(prompts, acc, [], 1, list.length(prompts))
}

fn collect_request_answers_with_warnings(
  prompts: List(#(types.Task, types.DecisionRequest)),
  acc: List(types.RecordedDecision),
  warnings: List(types.RunEvent),
  index: Int,
  total: Int,
) -> Result(#(List(types.RecordedDecision), List(types.RunEvent)), String) {
  case prompts {
    [] -> Ok(#(list.reverse(acc), list.reverse(warnings)))
    [#(task, request), ..rest] -> {
      use #(answer, warning) <- result.try(prompt_for_decision(
        task,
        request,
        index,
        total,
      ))
      let recorded =
        types.RecordedDecision(
          key: request.key,
          question: request.question,
          answer: answer,
          answered_at: system.timestamp(),
        )
      let updated_warnings = case warning {
        Some(event) -> [event, ..warnings]
        None -> warnings
      }
      collect_request_answers_with_warnings(
        rest,
        [recorded, ..acc],
        updated_warnings,
        index + 1,
        total,
      )
    }
  }
}

fn pending_decision_prompts(
  decisions: List(types.RecordedDecision),
  tasks: List(types.Task),
) -> List(#(types.Task, types.DecisionRequest)) {
  tasks
  |> list.map(fn(task) {
    types.unresolved_decision_requests(decisions, task)
    |> list.map(fn(request) { #(task, request) })
  })
  |> list.flatten
}

fn prompt_for_decision(
  task: types.Task,
  request: types.DecisionRequest,
  index: Int,
  total: Int,
) -> Result(#(String, Option(types.RunEvent)), String) {
  io.println("")
  io.println("Question " <> int.to_string(index) <> "/" <> int.to_string(total))
  io.println("Task: " <> task.title)
  io.println("Question: " <> request.question)
  case string.trim(request.rationale) {
    "" -> Nil
    rationale -> io.println("Why this matters: " <> rationale)
  }

  case request.options {
    [] -> {
      let warning = case request.allow_freeform {
        True -> None
        False -> Some(decision_contract_warning_event(task, request))
      }
      use answer <- result.try(prompt_for_freeform_answer(
        request,
        request.recommended_option,
      ))
      Ok(#(answer, warning))
    }
    options -> {
      let labels =
        options
        |> list.map(fn(option) {
          case request.recommended_option {
            Some(recommended) if recommended == option.label ->
              option.label <> " (recommended) - " <> option.description
            _ -> option.label <> " - " <> option.description
          }
        })
      let final_labels = case request.allow_freeform {
        True -> list.append(labels, ["Enter a custom answer"])
        False -> labels
      }
      let selected =
        select_from_labels(
          "Choose an answer:",
          final_labels,
          recommended_option_index(options, request.recommended_option),
        )
      case request.allow_freeform && selected == list.length(final_labels) - 1 {
        True ->
          prompt_for_freeform_answer(request, request.recommended_option)
          |> result.map(fn(answer) { #(answer, None) })
        False ->
          case list.drop(options, selected) {
            [choice, ..] -> Ok(#(choice.label, None))
            [] -> Error("The selected decision option was out of range.")
          }
      }
    }
  }
}

fn prompt_for_freeform_answer(
  request: types.DecisionRequest,
  default_answer: Option(String),
) -> Result(String, String) {
  case default_answer {
    Some(answer) -> {
      io.println("Answer [default: " <> answer <> "]:")
      case string.trim(system.read_line()) {
        "" -> Ok(answer)
        custom -> Ok(custom)
      }
    }
    None -> {
      io.println("Answer:")
      case string.trim(system.read_line()) {
        "" ->
          Error(
            "Night Shift needs a non-empty answer for `" <> request.key <> "`.",
          )
        answer -> Ok(answer)
      }
    }
  }
}

fn recommended_option_index(
  options: List(types.DecisionOption),
  recommended_option: Option(String),
) -> Int {
  case recommended_option {
    Some(recommended) -> find_option_index(options, recommended, 0)
    None -> 0
  }
}

fn find_option_index(
  options: List(types.DecisionOption),
  target: String,
  index: Int,
) -> Int {
  case options {
    [] -> 0
    [option, ..rest] ->
      case option.label == target {
        True -> index
        False -> find_option_index(rest, target, index + 1)
      }
  }
}

fn decision_contract_warning_event(
  task: types.Task,
  request: types.DecisionRequest,
) -> types.RunEvent {
  types.RunEvent(
    kind: "decision_contract_warning",
    at: system.timestamp(),
    message: "Coerced `"
      <> request.key
      <> "` into a freeform prompt because the planner returned no options and disallowed freeform input.",
    task_id: Some(task.id),
  )
}

fn resolve_loop(run: types.RunRecord) -> String {
  let blocked_tasks = unresolved_manual_attention_tasks(run)
  case blocked_tasks, run.planning_dirty {
    [], True -> continue_resolve_run(run)
    [], False ->
      case run.status {
        types.RunPending -> render_run_summary(run)
        _ ->
          "Run "
          <> run.run_id
          <> " is blocked but has no unresolved decisions left to collect. Inspect "
          <> run.report_path
          <> " or rerun `night-shift plan --notes ...`."
      }
    _, _ -> {
      io.println(render_resolve_summary(run, blocked_tasks))
      case collect_recorded_decisions(run, blocked_tasks) {
        Ok(#(new_decisions, warning_events)) -> {
          let updated_run =
            types.RunRecord(
              ..run,
              decisions: merge_recorded_decisions(run.decisions, new_decisions),
              planning_dirty: True,
            )
          case journal.rewrite_run(updated_run) {
            Ok(rewritten_run) ->
              case append_run_events(rewritten_run, warning_events) {
                Ok(warned_run) ->
                  case append_decision_recorded_events(warned_run, new_decisions) {
                    Ok(signaled_run) ->
                      case append_run_events(signaled_run, [planning_sync_pending_event()]) {
                        Ok(dirty_run) -> continue_resolve_run(dirty_run)
                        Error(message) -> message
                      }
                    Error(message) -> message
                  }
                Error(message) -> message
              }
            Error(message) -> message
          }
        }
        Error(message) -> message
      }
    }
  }
}

fn continue_resolve_run(run: types.RunRecord) -> String {
  case orchestrator.replan(run) {
    Ok(replanned_run) ->
      case replanned_run.status {
        types.RunBlocked -> resolve_loop(replanned_run)
        _ -> render_run_summary(replanned_run)
      }
    Error(message) -> message
  }
}

fn render_resolve_summary(
  run: types.RunRecord,
  _blocked_tasks: List(types.Task),
) -> String {
  "\nResolving run "
  <> run.run_id
  <> "\nBlocked tasks: "
  <> int.to_string(blocked_task_count(run))
  <> "\nOutstanding decisions: "
  <> int.to_string(outstanding_decision_count(run))
  <> "\nPlanning sync pending: "
  <> bool_label(run.planning_dirty)
  <> "\nNext action: answer the questions below to make this run ready to start."
}

fn merge_recorded_decisions(
  existing: List(types.RecordedDecision),
  new_decisions: List(types.RecordedDecision),
) -> List(types.RecordedDecision) {
  case new_decisions {
    [] -> existing
    [decision, ..rest] -> {
      let filtered =
        existing
        |> list.filter(fn(current) { current.key != decision.key })
      merge_recorded_decisions(list.append(filtered, [decision]), rest)
    }
  }
}

fn append_decision_recorded_events(
  run: types.RunRecord,
  decisions: List(types.RecordedDecision),
) -> Result(types.RunRecord, String) {
  case decisions {
    [] -> Ok(run)
    [decision, ..rest] -> {
      use updated_run <- result.try(journal.append_event(
        run,
        types.RunEvent(
          kind: "decision_recorded",
          at: decision.answered_at,
          message: decision.question <> " -> " <> decision.answer,
          task_id: None,
        ),
      ))
      append_decision_recorded_events(updated_run, rest)
    }
  }
}

fn append_run_events(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> Result(types.RunRecord, String) {
  case events {
    [] -> Ok(run)
    [event, ..rest] -> {
      use updated_run <- result.try(journal.append_event(run, event))
      append_run_events(updated_run, rest)
    }
  }
}

fn planning_sync_pending_event() -> types.RunEvent {
  types.RunEvent(
    kind: "planning_sync_pending",
    at: system.timestamp(),
    message: "Recorded new planning answers; Night Shift must replan before this run can start.",
    task_id: None,
  )
}

fn start_guidance_for_run(run: types.RunRecord) -> String {
  let outstanding = outstanding_decision_count(run)
  case outstanding > 0 {
    True ->
      "Run "
      <> run.run_id
      <> " is blocked on "
      <> int.to_string(outstanding)
      <> " unresolved decision(s). Run `night-shift resolve --run "
      <> run.run_id
      <> "` first."
    False ->
      case run.planning_dirty {
        True ->
          "Run "
          <> run.run_id
          <> " recorded new planning answers or notes but has not been replanned yet. Run `night-shift resolve --run "
          <> run.run_id
          <> "` first."
        False ->
          "Run "
          <> run.run_id
          <> " is blocked. Run `night-shift resolve --run "
          <> run.run_id
          <> "` first."
      }
  }
}

fn next_action_label(run: types.RunRecord) -> String {
  case outstanding_decision_count(run) > 0 || run.planning_dirty {
    True -> "night-shift resolve"
    False ->
      case run.status {
        types.RunPending -> "night-shift start"
        _ -> "inspect report"
      }
  }
}

fn bool_label(value: Bool) -> String {
  case value {
    True -> "yes"
    False -> "no"
  }
}

fn render_changed_paths(paths: List(String)) -> String {
  paths
  |> list.map(fn(path) { "- " <> path })
  |> string.join(with: "\n")
}

fn is_control_plane_path(path: String) -> Bool {
  path == ".night-shift" || string.starts_with(path, ".night-shift/")
}

fn start_clean_repo_suggestion(paths: List(String), repo_root: String) -> String {
  let only_night_shift =
    list.all(paths, fn(path) {
      path == ".night-shift" || string.starts_with(path, ".night-shift/")
    })
  case only_night_shift {
    True ->
      "\nCommit or discard those .night-shift changes before rerunning `night-shift start`, or run `night-shift reset` from "
      <> repo_root
      <> " to eject and reinitialize Night Shift."
    False ->
      "\nCommit, stash, or move those changes out of "
      <> repo_root
      <> " and rerun `night-shift start`."
  }
}

fn prefix_warning(warning: Option(String), body: String) -> String {
  case warning {
    Some(message) -> message <> "\n\n" <> body
    None -> body
  }
}

fn latest_environment_preflight_failure(
  events: List(types.RunEvent),
) -> Option(String) {
  latest_environment_preflight_failure_loop(list.reverse(events))
}

fn latest_environment_preflight_failure_loop(
  events: List(types.RunEvent),
) -> Option(String) {
  case events {
    [] -> None
    [event, ..rest] ->
      case event.kind == "environment_preflight_failed" {
        True -> Some(event.message)
        False -> latest_environment_preflight_failure_loop(rest)
      }
  }
}

fn latest_run_failed_message(events: List(types.RunEvent)) -> String {
  case latest_run_failed_message_loop(list.reverse(events)) {
    Some(message) -> message
    None -> "Night Shift stopped after an execution failure."
  }
}

fn latest_run_failed_message_loop(events: List(types.RunEvent)) -> Option(String) {
  case events {
    [] -> None
    [event, ..rest] ->
      case event.kind == "run_failed" {
        True -> Some(event.message)
        False -> latest_run_failed_message_loop(rest)
      }
  }
}

fn reset(repo_root: String, assume_yes: Bool, force: Bool) -> String {
  case confirm_reset(repo_root, assume_yes) {
    Error(message) -> message
    Ok(Nil) ->
      case ensure_reset_is_safe(repo_root, force) {
        Error(message) -> message
        Ok(Nil) -> perform_reset(repo_root)
      }
  }
}

fn confirm_reset(repo_root: String, assume_yes: Bool) -> Result(Nil, String) {
  case assume_yes {
    True -> Ok(Nil)
    False ->
      case can_prompt_interactively() {
        False ->
          Error("night-shift reset requires --yes when not running in an interactive terminal.")
        True -> {
          io.println(
            "Reset Night Shift for "
            <> repo_root
            <> "? This removes "
            <> project.home(repo_root)
            <> " and all recorded Night Shift worktrees. Type `reset` to continue:",
          )
          case string.trim(system.read_line()) {
            "reset" -> Ok(Nil)
            _ -> Error("Night Shift reset aborted.")
          }
        }
      }
  }
}

fn ensure_reset_is_safe(repo_root: String, force: Bool) -> Result(Nil, String) {
  case journal.active_run_id(repo_root) {
    Ok(run_id) ->
      case force {
        True -> Ok(Nil)
        False ->
          Error(
            "Night Shift run "
            <> run_id
            <> " is still active for this repository. Stop it first or rerun `night-shift reset --force`.",
          )
      }
    Error(_) -> Ok(Nil)
  }
}

fn perform_reset(repo_root: String) -> String {
  let runs = journal.list_runs(repo_root) |> result.unwrap(or: [])
  let worktrees = collect_worktree_paths(runs, [])
  let reset_log = filepath.join(system.state_directory(), "night-shift/reset.log")
  let #(removed_worktrees, failed_worktrees) =
    remove_worktrees(repo_root, worktrees, reset_log, [], [])
  let prune_result = git.prune_worktrees(repo_root, reset_log)
  let home_path = project.home(repo_root)
  let home_deleted = case simplifile.delete(file_or_dir_at: home_path) {
    Ok(_) -> Ok(home_path)
    Error(error) ->
      case project.home_exists(repo_root) {
        False -> Ok("(already absent) " <> home_path)
        True ->
          Error(
            "Unable to remove "
            <> home_path
            <> ": "
            <> simplifile.describe_error(error),
          )
      }
  }

  [
    "Night Shift reset complete for " <> repo_root,
    "Removed worktrees: " <> int.to_string(list.length(removed_worktrees)),
    render_optional_list(removed_worktrees),
    case prune_result {
      Ok(_) -> "Pruned git worktree metadata."
      Error(message) -> "Worktree prune warning: " <> message
    },
    case home_deleted {
      Ok(message) -> "Removed state: " <> message
      Error(message) -> message
    },
    case failed_worktrees {
      [] -> ""
      _ ->
        "Worktree cleanup warnings:\n"
        <> {
          failed_worktrees
          |> list.map(fn(entry) { "- " <> entry })
          |> string.join(with: "\n")
        }
    },
  ]
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> string.join(with: "\n")
}

fn collect_worktree_paths(
  runs: List(types.RunRecord),
  acc: List(String),
) -> List(String) {
  case runs {
    [] -> acc
    [run, ..rest] -> {
      let next =
        run.tasks
        |> list.fold(acc, fn(paths, task) {
          case task.worktree_path, list.contains(paths, task.worktree_path) {
            "", _ -> paths
            _, True -> paths
            path, False -> [path, ..paths]
          }
        })
      collect_worktree_paths(rest, next)
    }
  }
}

fn remove_worktrees(
  repo_root: String,
  worktrees: List(String),
  log_path: String,
  removed: List(String),
  failed: List(String),
) -> #(List(String), List(String)) {
  case worktrees {
    [] -> #(list.reverse(removed), list.reverse(failed))
    [path, ..rest] ->
      case git.remove_worktree(repo_root, path, log_path) {
        Ok(_) ->
          remove_worktrees(repo_root, rest, log_path, [path, ..removed], failed)
        Error(message) ->
          remove_worktrees(
            repo_root,
            rest,
            log_path,
            removed,
            [path <> ": " <> message, ..failed],
          )
      }
  }
}

fn render_optional_list(entries: List(String)) -> String {
  case entries {
    [] -> ""
    _ ->
      entries
      |> list.map(fn(entry) { "- " <> entry })
      |> string.join(with: "\n")
  }
}

fn planning_artifact_path(repo_root: String) -> String {
  filepath.join(
    project.planning_root(repo_root),
    system.timestamp()
      |> string.replace(each: ":", with: "-")
      |> string.replace(each: "T", with: "_")
      |> string.replace(each: "+", with: "_")
      |> string.replace(each: "Z", with: "")
      |> string.append("-")
      |> string.append(system.unique_id()),
  )
}

fn start_with_ui(
  repo_root: String,
  selector: types.RunSelector,
  config: types.Config,
) -> Nil {
  case load_start_run(repo_root, selector) {
    Ok(run) ->
      case ensure_clean_repo_for_start(repo_root) {
        Ok(warning) ->
          case journal.activate_run(run) {
            Ok(active_run) ->
              case
                dashboard.start_start_session(
                  repo_root,
                  active_run.run_id,
                  active_run,
                  config,
                )
              {
                Ok(session) -> {
                  case warning {
                    Some(message) -> io.println(message)
                    None -> Nil
                  }
                  io.println(render_dashboard_summary(session.url, active_run.run_id))
                  system.wait_forever()
                }
                Error(message) -> io.println(message)
              }
            Error(message) -> io.println(message)
          }
        Error(message) -> io.println(message)
      }
    Error(message) -> io.println(message)
  }
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
