import gleam/option.{type Option, None, Some}
import gleam/result
import night_shift/shell
import night_shift/system
import night_shift/types

pub fn planner_command(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  prompt_path: String,
) -> Result(String, String) {
  case fake_provider_command() {
    Some(command) -> Ok(command <> " plan " <> shell.quote(prompt_path))
    None -> planning_command(agent, repo_root, prompt_path)
  }
}

pub fn plan_document_command(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  prompt_path: String,
) -> Result(String, String) {
  case fake_provider_command() {
    Some(command) -> Ok(command <> " plan-doc " <> shell.quote(prompt_path))
    None -> planning_command(agent, repo_root, prompt_path)
  }
}

pub fn run_planner_command(
  command: String,
  cwd: String,
  log_path: String,
  metadata: shell.StreamMetadata,
) -> shell.CommandResult {
  case fake_provider_command() {
    Some(_) -> shell.run(command, cwd, log_path)
    None -> shell.run_streaming(command, cwd, log_path, metadata)
  }
}

pub fn start_provider_command(
  command: String,
  cwd: String,
  log_path: String,
  metadata: shell.StreamMetadata,
) -> shell.JobHandle {
  case fake_provider_command() {
    Some(_) -> shell.start(command, cwd, log_path)
    None -> shell.start_streaming(command, cwd, log_path, metadata)
  }
}

pub fn run_provider_command(
  command: String,
  cwd: String,
  log_path: String,
  metadata: shell.StreamMetadata,
) -> shell.CommandResult {
  case fake_provider_command() {
    Some(_) -> shell.run(command, cwd, log_path)
    None -> shell.run_streaming(command, cwd, log_path, metadata)
  }
}

pub fn executor_command(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  worktree_path: String,
  prompt_path: String,
) -> Result(String, String) {
  case fake_provider_command() {
    Some(command) ->
      Ok(
        command
        <> " execute "
        <> shell.quote(prompt_path)
        <> " "
        <> shell.quote(worktree_path)
        <> " "
        <> shell.quote(repo_root),
      )
    None ->
      case agent.provider {
        types.Codex ->
          codex_exec_command(
            agent,
            "--skip-git-repo-check --dangerously-bypass-approvals-and-sandbox -C "
              <> shell.quote(worktree_path),
            prompt_path,
          )
        types.Cursor ->
          cursor_execute_command(agent, worktree_path, prompt_path)
      }
  }
}

fn fake_provider_command() -> Option(String) {
  case system.get_env("NIGHT_SHIFT_FAKE_PROVIDER") {
    "" -> None
    command -> Some(command)
  }
}

pub fn planning_command(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  prompt_path: String,
) -> Result(String, String) {
  case agent.provider {
    types.Codex ->
      codex_exec_command(
        agent,
        "--skip-git-repo-check --sandbox read-only -C "
          <> shell.quote(repo_root),
        prompt_path,
      )
    types.Cursor -> cursor_plan_command(agent, repo_root, prompt_path)
  }
}

fn codex_exec_command(
  agent: types.ResolvedAgentConfig,
  base_arguments: String,
  prompt_path: String,
) -> Result(String, String) {
  use extra_arguments <- result.try(codex_extra_arguments(agent))
  Ok(
    "codex exec --json --color never "
    <> base_arguments
    <> extra_arguments
    <> " - < "
    <> shell.quote(prompt_path),
  )
}

fn codex_extra_arguments(
  agent: types.ResolvedAgentConfig,
) -> Result(String, String) {
  case agent.provider_overrides {
    [] ->
      Ok(
        codex_model_argument(agent.model)
        <> codex_reasoning_argument(agent.reasoning),
      )
    _ ->
      Error(
        "Codex does not support `provider_overrides` in Night Shift yet. Remove the overrides from profile "
        <> agent.profile_name
        <> ".",
      )
  }
}

fn codex_model_argument(model: Option(String)) -> String {
  case model {
    Some(value) -> " -m " <> shell.quote(value)
    None -> ""
  }
}

fn codex_reasoning_argument(reasoning: Option(types.ReasoningLevel)) -> String {
  case reasoning {
    Some(value) ->
      " -c "
      <> shell.quote(
        "model_reasoning_effort=\"" <> types.reasoning_to_string(value) <> "\"",
      )
    None -> ""
  }
}

fn cursor_plan_command(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  prompt_path: String,
) -> Result(String, String) {
  use flags <- result.try(cursor_shared_arguments(
    agent,
    repo_root,
    Some("plan"),
  ))
  Ok(
    "PROMPT=$(cat "
    <> shell.quote(prompt_path)
    <> "); cursor-agent --print --output-format stream-json --stream-partial-output --force --trust"
    <> flags
    <> " \"$PROMPT\"",
  )
}

fn cursor_execute_command(
  agent: types.ResolvedAgentConfig,
  worktree_path: String,
  prompt_path: String,
) -> Result(String, String) {
  use flags <- result.try(cursor_shared_arguments(agent, worktree_path, None))
  Ok(
    "PROMPT=$(cat "
    <> shell.quote(prompt_path)
    <> "); cursor-agent --print --output-format stream-json --stream-partial-output --force --trust"
    <> flags
    <> " \"$PROMPT\"",
  )
}

fn cursor_shared_arguments(
  agent: types.ResolvedAgentConfig,
  workspace: String,
  default_mode: Option(String),
) -> Result(String, String) {
  use _ <- result.try(case agent.reasoning {
    Some(_) ->
      Error(
        "Cursor does not support Night Shift's normalized `reasoning` control. Remove `reasoning` from profile "
        <> agent.profile_name
        <> " or express provider-specific behavior with `[profiles."
        <> agent.profile_name
        <> ".provider_overrides]`.",
      )
    None -> Ok(Nil)
  })
  use mode <- result.try(cursor_mode(agent.provider_overrides, default_mode))

  let model_argument = case agent.model {
    Some(model) -> " --model " <> shell.quote(model)
    None -> ""
  }
  let mode_argument = case mode {
    Some(value) -> " --mode " <> shell.quote(value)
    None -> ""
  }

  Ok(
    model_argument <> mode_argument <> " --workspace " <> shell.quote(workspace),
  )
}

fn cursor_mode(
  overrides: List(types.ProviderOverride),
  default_mode: Option(String),
) -> Result(Option(String), String) {
  case overrides {
    [] -> Ok(default_mode)
    [override] if override.key == "mode" ->
      case override.value {
        "plan" -> Ok(Some("plan"))
        "ask" -> Ok(Some("ask"))
        value ->
          Error(
            "Unsupported Cursor override `mode = \""
            <> value
            <> "\"`. Expected `plan` or `ask`.",
          )
      }
    [override] ->
      Error(
        "Unsupported Cursor provider override: "
        <> override.key
        <> ". Supported keys: mode.",
      )
    _ ->
      Error(
        "Cursor accepts only a single `mode` provider override in Night Shift.",
      )
  }
}
