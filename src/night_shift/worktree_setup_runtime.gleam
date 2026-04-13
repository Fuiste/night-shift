import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/codec/worktree_setup
import night_shift/runtime_identity
import night_shift/shell
import night_shift/system
import night_shift/types
import night_shift/worktree_setup_model as model
import simplifile

pub fn commands_for_phase(
  environment: model.WorktreeEnvironment,
  phase: model.BootstrapPhase,
) -> List(String) {
  let command_set = case phase {
    model.SetupPhase -> environment.setup
    model.MaintenancePhase -> environment.maintenance
  }

  let platform_commands = case current_platform() {
    "macos" -> command_set.macos
    "linux" -> command_set.linux
    "windows" -> command_set.windows
    _ -> []
  }

  case platform_commands {
    [] -> command_set.default
    _ -> platform_commands
  }
}

pub fn env_vars_for(
  repo_root: String,
  environment_name: String,
  setup_path: String,
  runtime_context: Option(types.RuntimeContext),
) -> Result(List(#(String, String)), String) {
  use selected <- result.try(load_selected_environment(
    repo_root,
    environment_name,
    setup_path,
  ))
  case selected {
    Some(environment) ->
      Ok(merge_runtime_env_vars(environment.env_vars, runtime_context))
    None -> Ok(runtime_env_vars(runtime_context))
  }
}

pub fn prepare_worktree(
  repo_root: String,
  environment_name: String,
  setup_path: String,
  worktree_path: String,
  branch_name: String,
  phase: model.BootstrapPhase,
  log_path: String,
  runtime_context: Option(types.RuntimeContext),
) -> Result(Nil, String) {
  use selected <- result.try(load_selected_environment(
    repo_root,
    environment_name,
    setup_path,
  ))

  let phase_name = case phase {
    model.SetupPhase -> "setup"
    model.MaintenancePhase -> "maintenance"
  }

  let environment_label = case selected {
    Some(environment) -> environment.name
    None -> "(none)"
  }

  use _ <- result.try(write_log(
    log_path,
    string.join(
      [
        "[environment]",
        "phase=" <> phase_name,
        "repo_root=" <> repo_root,
        "pwd=" <> worktree_path,
        "worktree=" <> worktree_path,
        "branch=" <> branch_name,
        "environment=" <> environment_label,
        "env_vars=" <> redacted_env_names(selected, runtime_context),
        "",
      ],
      with: "\n",
    ),
  ))

  case selected {
    None ->
      append_log(
        log_path,
        "[environment] no worktree setup configuration selected\n",
      )
    Some(environment) ->
      run_environment_commands(
        commands_for_phase(environment, phase),
        phase_name,
        merge_runtime_env_vars(environment.env_vars, runtime_context),
        worktree_path,
        log_path,
        1,
      )
  }
}

pub fn preflight_environment(
  repo_root: String,
  environment_name: String,
  setup_path: String,
  log_path: String,
) -> Result(Nil, String) {
  use selected <- result.try(load_selected_environment(
    repo_root,
    environment_name,
    setup_path,
  ))

  case selected {
    None -> {
      use _ <- result.try(write_log(
        log_path,
        "[environment-preflight]\nenvironment=(none)\nstatus=skipped\n",
      ))
      Ok(Nil)
    }
    Some(environment) -> {
      let required_executables = preflight_requirements_for(environment)
      use _ <- result.try(write_log(
        log_path,
        string.join(
          [
            "[environment-preflight]",
            "repo_root=" <> repo_root,
            "environment=" <> environment.name,
            "env_vars=" <> redacted_env_names(Some(environment), None),
            "path=" <> system.get_env("PATH"),
            "",
          ],
          with: "\n",
        ),
      ))
      use missing <- result.try(
        preflight_required_executables(
          required_executables,
          environment.env_vars,
          repo_root,
          log_path,
          [],
        ),
      )
      case missing {
        [] -> Ok(Nil)
        _ ->
          Error(
            "Environment preflight failed for "
            <> environment.name
            <> ". Missing required executable"
            <> plural_suffix(list.length(missing))
            <> ": "
            <> string.join(list.reverse(missing), with: ", ")
            <> ". See "
            <> log_path
            <> ".",
          )
      }
    }
  }
}

fn current_platform() -> String {
  case system.os_name() {
    "darwin" -> "macos"
    "linux" -> "linux"
    "win32" -> "windows"
    value -> value
  }
}

fn load_selected_environment(
  _repo_root: String,
  environment_name: String,
  setup_path: String,
) -> Result(Option(model.WorktreeEnvironment), String) {
  case environment_name {
    "" -> Ok(None)
    name -> {
      use maybe_config <- result.try(
        worktree_setup.load(setup_path)
        |> result.map_error(fn(message) {
          "Invalid " <> setup_path <> ": " <> message
        }),
      )
      case worktree_setup.choose_environment(maybe_config, Some(name)) {
        Ok(selected) -> Ok(selected)
        Error(message) -> Error(message <> " Fix " <> setup_path <> ".")
      }
    }
  }
}

fn redacted_env_names(
  selected: Option(model.WorktreeEnvironment),
  runtime_context: Option(types.RuntimeContext),
) -> String {
  let environment_names = case selected {
    None -> []
    Some(environment) -> environment.env_vars |> list.map(fn(entry) { entry.0 })
  }
  let runtime_names =
    runtime_env_vars(runtime_context)
    |> list.map(fn(entry) { entry.0 })

  case list.append(environment_names, runtime_names) {
    [] -> "(none)"
    names -> string.join(names, with: ", ")
  }
}

fn merge_runtime_env_vars(
  env_vars: List(#(String, String)),
  runtime_context: Option(types.RuntimeContext),
) -> List(#(String, String)) {
  list.append(env_vars, runtime_env_vars(runtime_context))
}

fn runtime_env_vars(
  runtime_context: Option(types.RuntimeContext),
) -> List(#(String, String)) {
  case runtime_context {
    Some(context) -> runtime_identity.env_vars(context)
    None -> []
  }
}

fn run_environment_commands(
  commands: List(String),
  phase_name: String,
  env_vars: List(#(String, String)),
  cwd: String,
  log_path: String,
  index: Int,
) -> Result(Nil, String) {
  case commands {
    [] -> Ok(Nil)
    [command, ..rest] -> {
      let step_log = log_path <> ".step-" <> int.to_string(index) <> ".log"
      let command_result =
        shell.run(shell.with_env(command, env_vars), cwd, step_log)
      use _ <- result.try(append_log(
        log_path,
        "$ "
          <> command
          <> "\n(exit "
          <> int.to_string(command_result.exit_code)
          <> ")\n"
          <> command_result.output
          <> "\n",
      ))
      case shell.succeeded(command_result) {
        True ->
          run_environment_commands(
            rest,
            phase_name,
            env_vars,
            cwd,
            log_path,
            index + 1,
          )
        False ->
          Error(
            "Worktree "
            <> phase_name
            <> " phase failed while running `"
            <> command
            <> "`. See "
            <> log_path
            <> ".",
          )
      }
    }
  }
}

fn preflight_requirements_for(
  environment: model.WorktreeEnvironment,
) -> List(String) {
  let configured = commands_for_platform(environment.preflight)
  case configured {
    [] -> default_preflight_requirements(environment)
    _ -> configured
  }
}

fn default_preflight_requirements(
  environment: model.WorktreeEnvironment,
) -> List(String) {
  let from_setup =
    commands_for_phase(environment, model.SetupPhase)
    |> first_detected_executable
  case from_setup {
    [] ->
      commands_for_phase(environment, model.MaintenancePhase)
      |> first_detected_executable
    _ -> from_setup
  }
}

fn first_detected_executable(commands: List(String)) -> List(String) {
  case commands {
    [] -> []
    [command, ..rest] ->
      case extract_executable(command) {
        Some(executable) -> [executable]
        None -> first_detected_executable(rest)
      }
  }
}

fn commands_for_platform(command_set: model.CommandSet) -> List(String) {
  let platform_commands = case current_platform() {
    "macos" -> command_set.macos
    "linux" -> command_set.linux
    "windows" -> command_set.windows
    _ -> []
  }

  case platform_commands {
    [] -> command_set.default
    _ -> platform_commands
  }
}

fn preflight_required_executables(
  executables: List(String),
  env_vars: List(#(String, String)),
  cwd: String,
  log_path: String,
  missing: List(String),
) -> Result(List(String), String) {
  case executables {
    [] -> {
      use _ <- result.try(append_log(
        log_path,
        "[preflight] no required executables configured\n",
      ))
      Ok(missing)
    }
    [executable, ..rest] -> {
      let next_missing = case list.contains(missing, executable) {
        True -> missing
        False ->
          case executable_exists(executable, env_vars, cwd, log_path) {
            True -> missing
            False -> [executable, ..missing]
          }
      }
      use _ <- result.try(append_log(
        log_path,
        "[preflight] executable=" <> executable <> "\n",
      ))
      preflight_required_executables(
        rest,
        env_vars,
        cwd,
        log_path,
        next_missing,
      )
    }
  }
}

fn executable_exists(
  executable: String,
  env_vars: List(#(String, String)),
  cwd: String,
  log_path: String,
) -> Bool {
  let result =
    shell.run(
      shell.with_env("command -v " <> shell.quote(executable), env_vars),
      cwd,
      log_path <> ".preflight-" <> executable <> ".log",
    )
  shell.succeeded(result)
}

fn extract_executable(command: String) -> Option(String) {
  let trimmed = string.trim(command)
  case trimmed == "" || starts_with_shell_meta(trimmed) {
    True -> None
    False -> skip_env_assignments(string.split(trimmed, " "))
  }
}

fn skip_env_assignments(tokens: List(String)) -> Option(String) {
  case tokens {
    [] -> None
    [token, ..rest] ->
      case string.trim(token) {
        "" -> skip_env_assignments(rest)
        trimmed ->
          case looks_like_env_assignment(trimmed) {
            True -> skip_env_assignments(rest)
            False -> Some(trimmed)
          }
      }
  }
}

fn looks_like_env_assignment(token: String) -> Bool {
  string.contains(does: token, contain: "=") && !string.starts_with(token, "\"")
}

fn starts_with_shell_meta(token: String) -> Bool {
  string.starts_with(token, "(")
  || string.starts_with(token, "{")
  || string.starts_with(token, "if ")
  || string.starts_with(token, "for ")
}

fn plural_suffix(count: Int) -> String {
  case count == 1 {
    True -> ""
    False -> "s"
  }
}

fn write_log(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.write(contents, to: path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to write " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}

fn append_log(path: String, contents: String) -> Result(Nil, String) {
  let existing = case simplifile.read(path) {
    Ok(value) -> value
    Error(_) -> ""
  }
  write_log(path, existing <> contents)
}
