import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/agent_config
import night_shift/config as config_codec
import night_shift/project
import night_shift/provider
import night_shift/shell
import night_shift/types
import night_shift/usecase/result as workflow
import night_shift/usecase/support/filesystem
import night_shift/worktree_setup
import simplifile

pub fn execute(
  repo_root: String,
  base_config: types.Config,
  agent_overrides: types.AgentOverrides,
  generate_setup: Bool,
  assume_yes: Bool,
  select_provider: fn(types.Config, types.AgentOverrides) ->
    Result(types.Provider, String),
  select_model: fn(String, types.Config, types.Provider, types.AgentOverrides) ->
    Result(String, String),
  select_setup_request: fn(Bool, Bool, Bool) -> Result(Bool, String),
) -> Result(workflow.InitResult, String) {
  let config_path = project.config_path(repo_root)
  let setup_path = project.worktree_setup_path(repo_root)
  let config_exists = file_exists(config_path)
  let setup_exists = file_exists(setup_path)

  use _ <- result.try(init_project_home(repo_root))
  use init_config <- result.try(choose_init_config(
    repo_root,
    base_config,
    agent_overrides,
    config_exists,
    select_provider,
    select_model,
  ))
  use setup_requested <- result.try(select_setup_request(
    generate_setup,
    assume_yes,
    setup_exists,
  ))
  use _ <- result.try(ensure_file(
    project.gitignore_path(repo_root),
    project_gitignore_contents(),
  ))
  use _ <- result.try(ensure_local_exclude(repo_root))
  use config_status <- result.try(ensure_file(
    config_path,
    config_codec.render(init_config),
  ))
  use setup_status <- result.try(ensure_worktree_setup_file(
    repo_root,
    init_config,
    agent_overrides,
    setup_requested,
    setup_path,
  ))

  Ok(workflow.InitResult(
    repo_root: repo_root,
    config_status: config_status,
    setup_status: setup_status,
    next_action: "night-shift plan --notes ...",
  ))
}

fn choose_init_config(
  repo_root: String,
  config: types.Config,
  agent_overrides: types.AgentOverrides,
  config_exists: Bool,
  select_provider: fn(types.Config, types.AgentOverrides) ->
    Result(types.Provider, String),
  select_model: fn(String, types.Config, types.Provider, types.AgentOverrides) ->
    Result(String, String),
) -> Result(types.Config, String) {
  case config_exists {
    True -> Ok(config)
    False -> {
      use selected_provider <- result.try(select_provider(
        config,
        agent_overrides,
      ))
      use _ <- result.try(validate_init_reasoning(
        selected_provider,
        agent_overrides.reasoning,
      ))
      use selected_model <- result.try(select_model(
        repo_root,
        config,
        selected_provider,
        agent_overrides,
      ))
      Ok(build_init_config(
        config,
        agent_overrides,
        selected_provider,
        selected_model,
      ))
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

fn init_project_home(repo_root: String) -> Result(Nil, String) {
  use _ <- result.try(filesystem.create_directory(project.home(repo_root)))
  use _ <- result.try(filesystem.create_directory(project.runs_root(repo_root)))
  filesystem.create_directory(project.planning_root(repo_root))
}

fn ensure_file(path: String, contents: String) -> Result(String, String) {
  case simplifile.read(path) {
    Ok(_) -> Ok("kept " <> path)
    Error(_) ->
      filesystem.write_string(path, contents)
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

fn write_and_verify_string(
  path: String,
  contents: String,
) -> Result(Nil, String) {
  use _ <- result.try(filesystem.write_string(path, contents))
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

fn file_exists(path: String) -> Bool {
  case simplifile.read(path) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn ensure_local_exclude(repo_root: String) -> Result(String, String) {
  let exclude_path = project.local_exclude_path(repo_root)
  let exclude_entry = "/.night-shift/"
  let existing = case simplifile.read(exclude_path) {
    Ok(contents) -> contents
    Error(_) -> ""
  }
  let lines =
    existing
    |> string.split("\n")
    |> list.filter(fn(line) { string.trim(line) != "" })
    |> list.filter(fn(line) { string.trim(line) != exclude_entry })
  let updated =
    list.append(lines, [exclude_entry])
    |> string.join(with: "\n")
    |> string.trim
    |> append_newline

  use _ <- result.try(write_and_verify_string(exclude_path, updated))
  let status_log = project.home(repo_root) <> "/init.exclude-status.log"
  let status =
    shell.run("git status --short", repo_root, status_log)
    |> shell.succeeded
  case status {
    True -> Ok("updated " <> exclude_path)
    False ->
      Error("Unable to confirm git status after updating " <> exclude_path)
  }
}

fn append_newline(contents: String) -> String {
  case contents {
    "" -> ""
    _ -> contents <> "\n"
  }
}

fn project_gitignore_contents() -> String {
  "*\n!config.toml\n!worktree-setup.toml\n!.gitignore\n"
}
