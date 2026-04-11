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
  system.stdin_is_tty() && system.stdout_is_tty()
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
  case load_pending_run(repo_root, run_selector) {
    Ok(run) ->
      case ensure_clean_repo_for_start(repo_root) {
        Ok(Nil) ->
          case journal.activate_run(run) {
            Ok(active_run) ->
              case orchestrator.start(active_run, config) {
                Ok(completed_run) -> render_run_summary(completed_run)
                Error(message) -> message
              }
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
      <> "Outstanding decisions: "
      <> int.to_string(outstanding_decision_count(saved_run))
      <> "\n"
      <> "Ready tasks: "
      <> int.to_string(ready_task_count(saved_run.tasks))
      <> "\n"
      <> "Queued tasks: "
      <> int.to_string(queued_task_count(saved_run.tasks))
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
  case load_blocked_run(repo_root, selector) {
    Ok(run) ->
      case can_prompt_interactively() {
        False ->
          "night-shift resolve requires an interactive terminal so it can capture decision answers."
        True ->
          case collect_recorded_decisions(run, unresolved_manual_attention_tasks(run)) {
            Ok(new_decisions) -> {
              let updated_run =
                types.RunRecord(
                  ..run,
                  decisions: merge_recorded_decisions(run.decisions, new_decisions),
                )
              case journal.rewrite_run(updated_run) {
                Ok(rewritten_run) ->
                  case append_decision_recorded_events(rewritten_run, new_decisions) {
                    Ok(signaled_run) ->
                      case orchestrator.replan(signaled_run) {
                        Ok(replanned_run) -> render_run_summary(replanned_run)
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
        )
      use rewritten_run <- result.try(journal.rewrite_run(updated_run))
      Ok(#(rewritten_run, True))
    }
    Ok(None) ->
      journal.create_pending_run(
        repo_root,
        brief_path,
        planning_agent,
        execution_agent,
        environment_name,
        max_workers,
        Some(notes_source),
      )
      |> result.map(fn(run) { #(run, False) })
    Error(message) -> Error(message)
  }
}

fn load_pending_run(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(types.RunRecord, String) {
  case selector {
    types.RunId(_) -> {
      use #(run, _) <- result.try(journal.load(repo_root, selector))
      validate_pending_run(run)
    }
    types.LatestRun ->
      case latest_run_with_status(repo_root, types.RunPending) {
        Ok(run) -> Ok(run)
        Error(_) ->
          case latest_run_with_status(repo_root, types.RunBlocked) {
            Ok(_) ->
              Error(
                "Night Shift's latest open run is blocked. Run `night-shift resolve` first.",
              )
            Error(_) ->
              Error(
                "No pending Night Shift run was found. Run `night-shift plan --notes ...` first.",
              )
          }
      }
  }
}

fn load_blocked_run(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(types.RunRecord, String) {
  case selector {
    types.RunId(_) -> {
      use #(run, _) <- result.try(journal.load(repo_root, selector))
      validate_blocked_run(run)
    }
    types.LatestRun ->
      case latest_run_with_status(repo_root, types.RunBlocked) {
        Ok(run) -> Ok(run)
        Error(_) ->
          case latest_run_with_status(repo_root, types.RunPending) {
            Ok(_) ->
              Error(
                "Night Shift's latest open run is already ready to start. Run `night-shift start`.",
              )
            Error(_) ->
              Error(
                "No blocked Night Shift run was found. Run `night-shift plan --notes ...` first.",
              )
          }
      }
  }
}

fn load_display_run(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(#(types.RunRecord, List(types.RunEvent)), String) {
  journal.load(repo_root, selector)
}

fn validate_pending_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  case run.status {
    types.RunPending -> Ok(run)
    types.RunBlocked ->
      Error("Run " <> run.run_id <> " is blocked. Run `night-shift resolve --run " <> run.run_id <> "` first.")
    types.RunActive ->
      Error("Run " <> run.run_id <> " is already active. Use `night-shift resume --run " <> run.run_id <> "` or inspect status/report.")
    types.RunCompleted ->
      Error("Run " <> run.run_id <> " is already completed. Run `night-shift plan --notes ...` to create or refresh a runnable plan.")
    types.RunFailed ->
      Error("Run " <> run.run_id <> " already failed. Run `night-shift plan --notes ...` to create a fresh or refreshed plan.")
  }
}

fn validate_blocked_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  case run.status {
    types.RunBlocked -> Ok(run)
    types.RunPending ->
      Error("Run " <> run.run_id <> " is already ready to start. Run `night-shift start --run " <> run.run_id <> "`.")
    types.RunActive ->
      Error("Run " <> run.run_id <> " is active and cannot be resolved right now.")
    types.RunCompleted ->
      Error("Run " <> run.run_id <> " is already completed.")
    types.RunFailed ->
      Error("Run " <> run.run_id <> " failed and cannot be resolved in place.")
  }
}

fn latest_run_with_status(
  repo_root: String,
  status: types.RunStatus,
) -> Result(types.RunRecord, String) {
  use runs <- result.try(journal.list_runs(repo_root))
  case list.find(runs, fn(run) { run.status == status }) {
    Ok(run) -> Ok(run)
    Error(_) -> Error("No matching Night Shift run was found.")
  }
}

fn render_notes_source(notes_source: Option(types.NotesSource)) -> String {
  case notes_source {
    Some(source) -> types.notes_source_label(source)
    None -> "(none)"
  }
}

fn outstanding_decision_count(run: types.RunRecord) -> Int {
  unresolved_manual_attention_tasks(run)
  |> list.map(unresolved_decision_requests(run.decisions, _))
  |> list.flatten
  |> list.length
}

fn ready_task_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.state == types.Ready })
  |> list.length
}

fn queued_task_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.state == types.Queued })
  |> list.length
}

fn unresolved_manual_attention_tasks(run: types.RunRecord) -> List(types.Task) {
  run.tasks
  |> list.filter(fn(task) {
    task.kind == types.ManualAttentionTask
    && task.state != types.Completed
    && has_unresolved_requests(run.decisions, task)
  })
}

fn unresolved_decision_requests(
  decisions: List(types.RecordedDecision),
  task: types.Task,
) -> List(types.DecisionRequest) {
  case task.decision_requests {
    [] ->
      [
        types.DecisionRequest(
          key: "task:" <> task.id,
          question: task.title,
          rationale: task.description,
          options: [],
          recommended_option: None,
          allow_freeform: True,
        ),
      ]
    requests ->
      requests
      |> list.filter(fn(request) { !decision_recorded(decisions, request.key) })
  }
}

fn has_unresolved_requests(
  decisions: List(types.RecordedDecision),
  task: types.Task,
) -> Bool {
  unresolved_decision_requests(decisions, task) != []
}

fn decision_recorded(
  decisions: List(types.RecordedDecision),
  key: String,
) -> Bool {
  list.any(decisions, fn(decision) { decision.key == key })
}

fn collect_recorded_decisions(
  run: types.RunRecord,
  tasks: List(types.Task),
) -> Result(List(types.RecordedDecision), String) {
  case tasks {
    [] -> Error("No unresolved manual-attention decisions were found for this run.")
    [task, ..rest] -> {
      use current <- result.try(collect_task_decisions(run.decisions, task))
      use remaining <- result.try(collect_recorded_decisions_or_empty(
        run.decisions,
        rest,
      ))
      Ok(list.append(current, remaining))
    }
  }
}

fn collect_recorded_decisions_or_empty(
  existing: List(types.RecordedDecision),
  tasks: List(types.Task),
) -> Result(List(types.RecordedDecision), String) {
  case tasks {
    [] -> Ok([])
    [task, ..rest] -> {
      use current <- result.try(collect_task_decisions(existing, task))
      use remaining <- result.try(collect_recorded_decisions_or_empty(existing, rest))
      Ok(list.append(current, remaining))
    }
  }
}

fn collect_task_decisions(
  existing: List(types.RecordedDecision),
  task: types.Task,
) -> Result(List(types.RecordedDecision), String) {
  let requests = unresolved_decision_requests(existing, task)
  case requests {
    [] -> Ok([])
    _ -> {
      io.println("")
      io.println("Resolving " <> task.id <> ": " <> task.title)
      io.println(task.description)
      collect_request_answers(task, requests, [])
    }
  }
}

fn collect_request_answers(
  task: types.Task,
  requests: List(types.DecisionRequest),
  acc: List(types.RecordedDecision),
) -> Result(List(types.RecordedDecision), String) {
  case requests {
    [] -> Ok(list.reverse(acc))
    [request, ..rest] -> {
      use answer <- result.try(prompt_for_decision(task, request))
      let recorded =
        types.RecordedDecision(
          key: request.key,
          question: request.question,
          answer: answer,
          answered_at: system.timestamp(),
        )
      collect_request_answers(task, rest, [recorded, ..acc])
    }
  }
}

fn prompt_for_decision(
  task: types.Task,
  request: types.DecisionRequest,
) -> Result(String, String) {
  io.println("")
  io.println("Task: " <> task.title)
  io.println("Question: " <> request.question)
  case string.trim(request.rationale) {
    "" -> Nil
    rationale -> io.println("Why this matters: " <> rationale)
  }

  case request.options {
    [] ->
      case request.allow_freeform {
        True -> prompt_for_freeform_answer(request)
        False ->
          Error(
            "Night Shift could not collect an answer for `"
            <> request.key
            <> "` because the planner returned no options and disallowed freeform input.",
          )
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
      let selected = select_from_labels("Choose an answer:", final_labels, 0)
      case request.allow_freeform && selected == list.length(final_labels) - 1 {
        True -> prompt_for_freeform_answer(request)
        False ->
          case list.drop(options, selected) {
            [choice, ..] -> Ok(choice.label)
            [] -> Error("The selected decision option was out of range.")
          }
      }
    }
  }
}

fn prompt_for_freeform_answer(
  request: types.DecisionRequest,
) -> Result(String, String) {
  io.println("Answer:")
  case string.trim(system.read_line()) {
    "" -> Error("Night Shift needs a non-empty answer for `" <> request.key <> "`.")
    answer -> Ok(answer)
  }
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
  case load_pending_run(repo_root, selector) {
    Ok(run) ->
      case ensure_clean_repo_for_start(repo_root) {
        Ok(Nil) ->
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
