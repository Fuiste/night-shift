import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/codec/shared
import night_shift/worktree_setup_model as model
import simplifile

type Section {
  RootSection
  EnvSection(name: String)
  PreflightSection(name: String)
  SetupSection(name: String)
  MaintenanceSection(name: String)
}

type ParseState {
  ParseState(config: model.WorktreeSetupConfig, section: Section)
}

pub fn default_template() -> String {
  render(model.default_config())
}

pub fn load(path: String) -> Result(Option(model.WorktreeSetupConfig), String) {
  case simplifile.read(path) {
    Ok(contents) -> parse(contents) |> result.map(Some)
    Error(_) -> Ok(None)
  }
}

pub fn parse(contents: String) -> Result(model.WorktreeSetupConfig, String) {
  case string.trim(contents) {
    "" -> Error("Worktree setup file is empty.")
    _ -> {
      let initial = ParseState(model.default_config(), RootSection)

      contents
      |> string.split("\n")
      // Collapse multiline list syntax before the line-oriented parser runs so
      // command arrays can be handled without a full TOML parser.
      |> collapse_multiline_values([], None)
      |> parse_lines(initial)
      |> result.map(fn(state) { state.config })
    }
  }
}

pub fn render(config: model.WorktreeSetupConfig) -> String {
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
  config: Option(model.WorktreeSetupConfig),
  requested: Option(String),
) -> Result(Option(model.WorktreeEnvironment), String) {
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
  config: model.WorktreeSetupConfig,
  name: String,
) -> Result(model.WorktreeEnvironment, String) {
  config.environments
  |> list.find(fn(environment) { environment.name == name })
  |> result.map_error(fn(_) {
    "Worktree environment " <> name <> " was not found."
  })
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
      // Preserve the accumulated list until we see the closing bracket so the
      // downstream parser only ever sees complete assignments.
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
        model.WorktreeSetupConfig(..config, version: version),
        state.section,
      ))
    }

    RootSection, "default_environment" ->
      Ok(ParseState(
        model.WorktreeSetupConfig(
          ..config,
          default_environment: shared.parse_string(raw_value),
        ),
        state.section,
      ))

    EnvSection(name), env_key ->
      Ok(ParseState(
        update_environment(config, name, fn(environment) {
          model.WorktreeEnvironment(
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
  config: model.WorktreeSetupConfig,
  name: String,
  script_key: String,
  raw_value: String,
  section_name: String,
  state: ParseState,
) -> Result(ParseState, String) {
  let commands = shared.parse_string_list(raw_value)
  let update = fn(command_set: model.CommandSet) {
    case script_key {
      "default" -> model.CommandSet(..command_set, default: commands)
      "macos" -> model.CommandSet(..command_set, macos: commands)
      "linux" -> model.CommandSet(..command_set, linux: commands)
      "windows" -> model.CommandSet(..command_set, windows: commands)
      _ -> command_set
    }
  }

  case script_key {
    "default" | "macos" | "linux" | "windows" ->
      Ok(ParseState(
        update_environment(config, name, fn(environment) {
          case section_name {
            "preflight" ->
              model.WorktreeEnvironment(
                ..environment,
                preflight: update(environment.preflight),
              )
            "setup" ->
              model.WorktreeEnvironment(
                ..environment,
                setup: update(environment.setup),
              )
            _ ->
              model.WorktreeEnvironment(
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
  config: model.WorktreeSetupConfig,
  name: String,
  update: fn(model.WorktreeEnvironment) -> model.WorktreeEnvironment,
) -> model.WorktreeSetupConfig {
  let environments = upsert_environment(config.environments, name, update)
  model.WorktreeSetupConfig(..config, environments: environments)
}

fn upsert_environment(
  environments: List(model.WorktreeEnvironment),
  name: String,
  update: fn(model.WorktreeEnvironment) -> model.WorktreeEnvironment,
) -> List(model.WorktreeEnvironment) {
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

fn blank_environment(name: String) -> model.WorktreeEnvironment {
  model.WorktreeEnvironment(
    name: name,
    env_vars: [],
    preflight: model.empty_command_set(),
    setup: model.empty_command_set(),
    maintenance: model.empty_command_set(),
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

fn render_environment(environment: model.WorktreeEnvironment) -> String {
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

fn render_command_set(command_set: model.CommandSet) -> String {
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
