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
import night_shift/project
import night_shift/provider_models
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
import night_shift/usecase/support/environment
import night_shift/usecase/support/repo_guard
import night_shift/usecase/support/runs
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
      resolve_init_provider,
      resolve_init_model,
      choose_setup_request,
    )
  {
    Ok(view) -> usecase_render.render_init(view)
    Error(message) -> message
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
                  [
                    "Yes, draft worktree-setup.toml",
                    "No, create the blank template",
                  ],
                  0,
                )
                == 0,
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
          case
            select_from_labels(
              "1. Which provider do you want to use?",
              options,
              default_index,
            )
          {
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
          use models <- result.try(provider_models.list_models(
            provider_name,
            repo_root,
          ))
          let labels = models |> list.map(fn(model) { model.label })
          let default_index =
            preferred_model_index(config, provider_name, models)
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
  list.find(config.profiles, fn(profile) {
    profile.name == config.default_profile
  })
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
    [model, ..], 0 -> Ok(model.id)
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
  case can_prompt_interactively() {
    False ->
      "night-shift resolve requires an interactive terminal so it can capture decision answers."
    True ->
      case
        resolve_usecase.execute(repo_root, selector, collect_recorded_decisions)
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

fn collect_recorded_decisions(
  run: types.RunRecord,
  tasks: List(types.Task),
) -> Result(#(List(types.RecordedDecision), List(types.RunEvent)), String) {
  let prompts = pending_decision_prompts(run.decisions, tasks)
  case prompts {
    [] ->
      Error("No unresolved manual-attention decisions were found for this run.")
    _ -> {
      io.println(usecase_render.render_resolve_prompt(run))
      collect_request_answers(prompts, [])
    }
  }
}

fn collect_request_answers(
  prompts: List(#(types.Task, types.DecisionRequest)),
  acc: List(types.RecordedDecision),
) -> Result(#(List(types.RecordedDecision), List(types.RunEvent)), String) {
  collect_request_answers_with_warnings(
    prompts,
    acc,
    [],
    1,
    list.length(prompts),
  )
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

fn reset(repo_root: String, assume_yes: Bool, force: Bool) -> String {
  case confirm_reset(repo_root, assume_yes) {
    Error(message) -> message
    Ok(Nil) ->
      case ensure_reset_is_safe(repo_root, force) {
        Error(message) -> message
        Ok(Nil) -> usecase_render.render_reset(reset_usecase.execute(repo_root))
      }
  }
}

fn confirm_reset(repo_root: String, assume_yes: Bool) -> Result(Nil, String) {
  case assume_yes {
    True -> Ok(Nil)
    False ->
      case can_prompt_interactively() {
        False ->
          Error(
            "night-shift reset requires --yes when not running in an interactive terminal.",
          )
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

fn start_with_ui(
  repo_root: String,
  selector: types.RunSelector,
  config: types.Config,
) -> Nil {
  case runs.load_start_run(repo_root, selector) {
    Ok(run) ->
      case repo_guard.ensure_clean_repo_for_start(repo_root) {
        Ok(warnings) ->
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
                  warnings |> list.each(io.println)
                  io.println(render_dashboard_summary(
                    session.url,
                    active_run.run_id,
                  ))
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
      case
        environment.ensure_saved_environment_is_valid(
          repo_root,
          saved_run.environment_name,
        )
      {
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
