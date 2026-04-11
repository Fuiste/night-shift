import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/codec/shared
import night_shift/shell
import night_shift/system
import simplifile

type Section {
  RootSection
  EnvSection(name: String)
  PreflightSection(name: String)
  SetupSection(name: String)
  MaintenanceSection(name: String)
}

type ParseState {
  ParseState(config: WorktreeSetupConfig, section: Section)
}

pub type BootstrapPhase {
  SetupPhase
  MaintenancePhase
}

pub type CommandSet {
  CommandSet(
    default: List(String),
    macos: List(String),
    linux: List(String),
    windows: List(String),
  )
}

pub type WorktreeEnvironment {
  WorktreeEnvironment(
    name: String,
    env_vars: List(#(String, String)),
    preflight: CommandSet,
    setup: CommandSet,
    maintenance: CommandSet,
  )
}

pub type WorktreeSetupConfig {
  WorktreeSetupConfig(
    version: Int,
    default_environment: String,
    environments: List(WorktreeEnvironment),
  )
}

pub fn default_config() -> WorktreeSetupConfig {
  WorktreeSetupConfig(version: 1, default_environment: "default", environments: [
    WorktreeEnvironment(
      name: "default",
      env_vars: [],
      preflight: empty_command_set(),
      setup: empty_command_set(),
      maintenance: empty_command_set(),
    ),
  ])
}

pub fn default_template() -> String {
  render(default_config())
}

pub fn load(path: String) -> Result(Option(WorktreeSetupConfig), String) {
  case simplifile.read(path) {
    Ok(contents) -> parse(contents) |> result.map(Some)
    Error(_) -> Ok(None)
  }
}

pub fn parse(contents: String) -> Result(WorktreeSetupConfig, String) {
  case string.trim(contents) {
    "" -> Error("Worktree setup file is empty.")
    _ -> {
      let initial = ParseState(default_config(), RootSection)

      contents
      |> string.split("\n")
      |> collapse_multiline_values([], None)
      |> parse_lines(initial)
      |> result.map(fn(state) { state.config })
    }
  }
}

pub fn render(config: WorktreeSetupConfig) -> String {
  let root_lines = [
    "version = " <> int.to_string(config.version),
    "default_environment = " <> shared.render_string(config.default_environment),
    "",
  ]

  let environment_lines =
    config.environments
    |> list.map(render_environment)
    |> string.join(with: "\n\n")

  string.join(root_lines, with: "\n") <> environment_lines <> "\n"
}

pub fn choose_environment(
  config: Option(WorktreeSetupConfig),
  requested: Option(String),
) -> Result(Option(WorktreeEnvironment), String) {
  case config, requested {
    None, None -> Ok(None)
    None, Some(name) ->
      Error(
        "No worktree setup configuration exists for this repository, so environment "
        <> name
        <> " cannot be selected.",
      )
    Some(config), None ->
      find_environment(config, config.default_environment) |> result.map(Some)
    Some(config), Some(name) ->
      find_environment(config, name) |> result.map(Some)
  }
}

pub fn find_environment(
  config: WorktreeSetupConfig,
  name: String,
) -> Result(WorktreeEnvironment, String) {
  config.environments
  |> list.find(fn(environment) { environment.name == name })
  |> result.map_error(fn(_) {
    "Worktree environment " <> name <> " was not found."
  })
}

pub fn commands_for_phase(
  environment: WorktreeEnvironment,
  phase: BootstrapPhase,
) -> List(String) {
  let command_set = case phase {
    SetupPhase -> environment.setup
    MaintenancePhase -> environment.maintenance
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
) -> Result(List(#(String, String)), String) {
  use selected <- result.try(load_selected_environment(
    repo_root,
    environment_name,
    setup_path,
  ))
  case selected {
    Some(environment) -> Ok(environment.env_vars)
    None -> Ok([])
  }
}

pub fn prepare_worktree(
  repo_root: String,
  environment_name: String,
  setup_path: String,
  worktree_path: String,
  branch_name: String,
  phase: BootstrapPhase,
  log_path: String,
) -> Result(Nil, String) {
  use selected <- result.try(load_selected_environment(
    repo_root,
    environment_name,
    setup_path,
  ))

  let phase_name = case phase {
    SetupPhase -> "setup"
    MaintenancePhase -> "maintenance"
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
        "env_vars=" <> redacted_env_names(selected),
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
        environment.env_vars,
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
            "env_vars=" <> redacted_env_names(Some(environment)),
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

pub fn empty_command_set() -> CommandSet {
  CommandSet(default: [], macos: [], linux: [], windows: [])
}

fn collapse_multiline_values(
  lines: List(String),
  acc: List(String),
  pending: Option(String),
) -> List(String) {
  case lines, pending {
    [], None -> list.reverse(acc)
    [], Some(current) -> list.reverse([current, ..acc])
    [line, ..rest], None -> {
      let cleaned = shared.strip_comments(line) |> string.trim
      case begins_multiline_list(cleaned) {
        True -> collapse_multiline_values(rest, acc, Some(cleaned))
        False -> collapse_multiline_values(rest, [cleaned, ..acc], None)
      }
    }
    [line, ..rest], Some(current) -> {
      let cleaned = shared.strip_comments(line) |> string.trim
      let next = case cleaned {
        "" -> current
        _ -> current <> " " <> cleaned
      }
      case string.ends_with(cleaned, "]") {
        True -> collapse_multiline_values(rest, [next, ..acc], None)
        False -> collapse_multiline_values(rest, acc, Some(next))
      }
    }
  }
}

fn begins_multiline_list(line: String) -> Bool {
  case string.split_once(line, "=") {
    Ok(#(_, value)) -> {
      let trimmed_value = string.trim(value)
      string.starts_with(trimmed_value, "[")
      && !string.ends_with(trimmed_value, "]")
    }
    Error(Nil) -> False
  }
}

fn parse_lines(
  lines: List(String),
  state: ParseState,
) -> Result(ParseState, String) {
  case lines {
    [] -> Ok(state)
    [line, ..rest] -> {
      use next_state <- result.try(parse_line(line, state))
      parse_lines(rest, next_state)
    }
  }
}

fn parse_line(line: String, state: ParseState) -> Result(ParseState, String) {
  let cleaned =
    line
    |> shared.strip_comments
    |> string.trim

  case cleaned {
    "" -> Ok(state)
    _ ->
      case string.starts_with(cleaned, "["), string.ends_with(cleaned, "]") {
        True, True ->
          parse_section(cleaned)
          |> result.map(fn(section) { ParseState(state.config, section) })
        _, _ -> parse_assignment(cleaned, state)
      }
  }
}

fn parse_section(section: String) -> Result(Section, String) {
  let inner =
    section
    |> string.drop_start(1)
    |> string.drop_end(1)

  case string.split(inner, ".") {
    ["environments", name, "env"] -> Ok(EnvSection(name))
    ["environments", name, "preflight"] -> Ok(PreflightSection(name))
    ["environments", name, "setup"] -> Ok(SetupSection(name))
    ["environments", name, "maintenance"] -> Ok(MaintenanceSection(name))
    _ -> Error("Unsupported worktree setup section: " <> section)
  }
}

fn parse_assignment(
  assignment: String,
  state: ParseState,
) -> Result(ParseState, String) {
  case string.split_once(assignment, "=") {
    Ok(#(key, value)) ->
      apply_value(string.trim(key), string.trim(value), state)
    Error(Nil) -> Error("Invalid worktree setup line: " <> assignment)
  }
}

fn apply_value(
  key: String,
  raw_value: String,
  state: ParseState,
) -> Result(ParseState, String) {
  let config = state.config

  case state.section, key {
    RootSection, "version" -> {
      use version <- result.try(shared.parse_int(raw_value, "worktree setup"))
      Ok(ParseState(
        WorktreeSetupConfig(..config, version: version),
        state.section,
      ))
    }

    RootSection, "default_environment" ->
      Ok(ParseState(
        WorktreeSetupConfig(
          ..config,
          default_environment: shared.parse_string(raw_value),
        ),
        state.section,
      ))

    EnvSection(name), env_key ->
      Ok(ParseState(
        update_environment(config, name, fn(environment) {
          WorktreeEnvironment(
            ..environment,
            env_vars: upsert_env_var(
              environment.env_vars,
              env_key,
              shared.parse_string(raw_value),
            ),
          )
        }),
        state.section,
      ))

    PreflightSection(name), script_key ->
      update_command_set(
        config,
        name,
        script_key,
        raw_value,
        "preflight",
        state,
      )

    SetupSection(name), script_key ->
      update_command_set(config, name, script_key, raw_value, "setup", state)

    MaintenanceSection(name), script_key ->
      update_command_set(
        config,
        name,
        script_key,
        raw_value,
        "maintenance",
        state,
      )

    _, _ -> Error("Unsupported worktree setup key: " <> key)
  }
}

fn update_command_set(
  config: WorktreeSetupConfig,
  name: String,
  script_key: String,
  raw_value: String,
  section_name: String,
  state: ParseState,
) -> Result(ParseState, String) {
  let commands = shared.parse_string_list(raw_value)
  let update = fn(command_set: CommandSet) {
    case script_key {
      "default" -> CommandSet(..command_set, default: commands)
      "macos" -> CommandSet(..command_set, macos: commands)
      "linux" -> CommandSet(..command_set, linux: commands)
      "windows" -> CommandSet(..command_set, windows: commands)
      _ -> command_set
    }
  }

  case script_key {
    "default" | "macos" | "linux" | "windows" ->
      Ok(ParseState(
        update_environment(config, name, fn(environment) {
          case section_name {
            "preflight" ->
              WorktreeEnvironment(
                ..environment,
                preflight: update(environment.preflight),
              )
            "setup" ->
              WorktreeEnvironment(
                ..environment,
                setup: update(environment.setup),
              )
            _ ->
              WorktreeEnvironment(
                ..environment,
                maintenance: update(environment.maintenance),
              )
          }
        }),
        state.section,
      ))
    _ -> Error("Unsupported worktree setup script key: " <> script_key)
  }
}

fn update_environment(
  config: WorktreeSetupConfig,
  name: String,
  update: fn(WorktreeEnvironment) -> WorktreeEnvironment,
) -> WorktreeSetupConfig {
  let environments = upsert_environment(config.environments, name, update)
  WorktreeSetupConfig(..config, environments: environments)
}

fn upsert_environment(
  environments: List(WorktreeEnvironment),
  name: String,
  update: fn(WorktreeEnvironment) -> WorktreeEnvironment,
) -> List(WorktreeEnvironment) {
  case environments {
    [] -> [update(blank_environment(name))]
    [environment, ..rest] if environment.name == name -> [
      update(environment),
      ..rest
    ]
    [environment, ..rest] -> [
      environment,
      ..upsert_environment(rest, name, update)
    ]
  }
}

fn blank_environment(name: String) -> WorktreeEnvironment {
  WorktreeEnvironment(
    name: name,
    env_vars: [],
    preflight: empty_command_set(),
    setup: empty_command_set(),
    maintenance: empty_command_set(),
  )
}

fn upsert_env_var(
  env_vars: List(#(String, String)),
  key: String,
  value: String,
) -> List(#(String, String)) {
  case env_vars {
    [] -> [#(key, value)]
    [entry, ..rest] if entry.0 == key -> [#(key, value), ..rest]
    [entry, ..rest] -> [entry, ..upsert_env_var(rest, key, value)]
  }
}

fn render_environment(environment: WorktreeEnvironment) -> String {
  let env_block = case environment.env_vars {
    [] -> ""
    _ ->
      "[environments."
      <> environment.name
      <> ".env]\n"
      <> render_env_vars(environment.env_vars)
      <> "\n\n"
  }

  env_block
  <> "[environments."
  <> environment.name
  <> ".preflight]\n"
  <> render_command_set(environment.preflight)
  <> "\n\n[environments."
  <> environment.name
  <> ".setup]\n"
  <> render_command_set(environment.setup)
  <> "\n\n[environments."
  <> environment.name
  <> ".maintenance]\n"
  <> render_command_set(environment.maintenance)
}

fn render_env_vars(env_vars: List(#(String, String))) -> String {
  env_vars
  |> list.map(fn(entry) { entry.0 <> " = " <> shared.render_string(entry.1) })
  |> string.join(with: "\n")
}

fn render_command_set(command_set: CommandSet) -> String {
  [
    "default = " <> render_string_list(command_set.default),
    "macos = " <> render_string_list(command_set.macos),
    "linux = " <> render_string_list(command_set.linux),
    "windows = " <> render_string_list(command_set.windows),
  ]
  |> string.join(with: "\n")
}

fn render_string_list(values: List(String)) -> String {
  shared.render_string_list(values)
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
) -> Result(Option(WorktreeEnvironment), String) {
  case environment_name {
    "" -> Ok(None)
    name -> {
      use maybe_config <- result.try(
        load(setup_path)
        |> result.map_error(fn(message) {
          "Invalid " <> setup_path <> ": " <> message
        }),
      )
      case choose_environment(maybe_config, Some(name)) {
        Ok(selected) -> Ok(selected)
        Error(message) -> Error(message <> " Fix " <> setup_path <> ".")
      }
    }
  }
}

fn redacted_env_names(selected: Option(WorktreeEnvironment)) -> String {
  case selected {
    None -> "(none)"
    Some(environment) ->
      case environment.env_vars {
        [] -> "(none)"
        env_vars ->
          env_vars
          |> list.map(fn(entry) { entry.0 })
          |> string.join(with: ", ")
      }
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

fn preflight_requirements_for(environment: WorktreeEnvironment) -> List(String) {
  let configured = commands_for_platform(environment.preflight)
  case configured {
    [] -> default_preflight_requirements(environment)
    _ -> configured
  }
}

fn default_preflight_requirements(
  environment: WorktreeEnvironment,
) -> List(String) {
  let from_setup =
    commands_for_phase(environment, SetupPhase)
    |> first_detected_executable
  case from_setup {
    [] ->
      commands_for_phase(environment, MaintenancePhase)
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

fn commands_for_platform(command_set: CommandSet) -> List(String) {
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
  command
  |> string.trim
  |> string.split(" ")
  |> skip_env_assignments
}

fn skip_env_assignments(tokens: List(String)) -> Option(String) {
  case tokens {
    [] -> None
    [token, ..rest] ->
      case string.trim(token) {
        "" -> skip_env_assignments(rest)
        value ->
          case
            looks_like_env_assignment(value) || starts_with_shell_meta(value)
          {
            True -> skip_env_assignments(rest)
            False -> Some(value)
          }
      }
  }
}

fn looks_like_env_assignment(token: String) -> Bool {
  string.contains(does: token, contain: "=")
}

fn starts_with_shell_meta(token: String) -> Bool {
  string.starts_with(token, "\"")
  || string.starts_with(token, "'")
  || string.starts_with(token, "(")
  || string.starts_with(token, "{")
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
    Ok(current) -> current
    Error(_) -> ""
  }
  write_log(path, existing <> contents)
}
