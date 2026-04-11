import filepath
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/journal
import night_shift/shell
import night_shift/system
import night_shift/types
import night_shift/worktree_setup
import simplifile

const start_marker = "NIGHT_SHIFT_RESULT_START"

const end_marker = "NIGHT_SHIFT_RESULT_END"

pub type TaskRun {
  TaskRun(
    task: types.Task,
    handle: shell.JobHandle,
    worktree_path: String,
    start_head: String,
    log_path: String,
    branch_name: String,
    base_ref: String,
  )
}

pub fn plan_document(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  notes_path: String,
  doc_path: String,
) -> Result(#(String, String), String) {
  let artifact_path = planning_artifact_path(repo_root)
  let prompt_path = filepath.join(artifact_path, "planner.prompt.md")
  let log_path = filepath.join(artifact_path, "planner.log")
  use _ <- result.try(create_directory(artifact_path))
  use notes_contents <- result.try(read_file(notes_path))
  let existing_doc_contents = read_existing_file_or_empty(doc_path)
  use _ <- result.try(write_file(
    prompt_path,
    planning_document_prompt(
      notes_contents: notes_contents,
      existing_doc_contents: existing_doc_contents,
      doc_path: doc_path,
    ),
  ))
  use command <- result.try(plan_document_command(agent, repo_root, prompt_path))
  let command_result =
    run_planner_command(
      command,
      repo_root,
      log_path,
      shell.stream_metadata(
        label: "brief",
        prompt_path: prompt_path,
        harness: types.provider_to_string(agent.provider),
        phase: "plan_document",
      ),
    )

  case shell.succeeded(command_result) {
    True -> {
      use document <- result.try(extract_payload(command_result.output))
      case string.trim(document) {
        "" ->
          Error("Planning provider returned an empty brief. See " <> log_path)
        trimmed -> Ok(#(trimmed, artifact_path))
      }
    }
    False -> Error("Planning provider failed. See " <> log_path)
  }
}

pub fn generate_worktree_setup(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  output_path: String,
) -> Result(#(String, String), String) {
  let artifact_path = planning_artifact_path(repo_root)
  let prompt_path = filepath.join(artifact_path, "worktree-setup.prompt.md")
  let log_path = filepath.join(artifact_path, "worktree-setup.log")
  let generated_path =
    filepath.join(artifact_path, "worktree-setup.generated.toml")
  use _ <- result.try(create_directory(artifact_path))
  use _ <- result.try(write_file(
    prompt_path,
    worktree_setup_prompt(output_path),
  ))
  use command <- result.try(planning_command(agent, repo_root, prompt_path))
  let command_result =
    run_planner_command(
      command,
      repo_root,
      log_path,
      shell.stream_metadata(
        label: "worktree-setup",
        prompt_path: prompt_path,
        harness: types.provider_to_string(agent.provider),
        phase: "generate_worktree_setup",
      ),
    )

  case shell.succeeded(command_result) {
    True -> {
      use document <- result.try(extract_payload(command_result.output))
      let trimmed_document = string.trim(document)
      use _ <- result.try(case trimmed_document {
        "" ->
          Error(
            "Worktree setup provider returned an empty file. See " <> log_path,
          )
        _ -> Ok(Nil)
      })
      use _ <- result.try(
        worktree_setup.parse(trimmed_document)
        |> result.map_error(fn(message) {
          "Generated worktree setup was invalid: " <> message <> ". See " <> log_path
        }),
      )
      use _ <- result.try(write_file(generated_path, trimmed_document))
      Ok(#(trimmed_document, artifact_path))
    }
    False -> Error("Worktree setup generation failed. See " <> log_path)
  }
}

pub fn plan_tasks(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  brief_path: String,
  run_path: String,
) -> Result(List(types.Task), String) {
  let prompt_path = filepath.join(run_path, "planner.prompt.md")
  let log_path = filepath.join(run_path, "logs/planner.log")
  use brief_contents <- result.try(read_file(brief_path))
  use _ <- result.try(write_file(prompt_path, planner_prompt(brief_contents)))
  use command <- result.try(planner_command(agent, repo_root, prompt_path))
  let command_result =
    run_planner_command(
      command,
      repo_root,
      log_path,
      shell.stream_metadata(
        label: "planner",
        prompt_path: prompt_path,
        harness: types.provider_to_string(agent.provider),
        phase: "plan_tasks",
      ),
    )

  case shell.succeeded(command_result) {
    True -> {
      use payload <- result.try(extract_json_payload(command_result.output))
      json.parse(payload, planner_decoder())
      |> result.map_error(fn(_) { "Unable to decode planner output." })
    }
    False -> Error("Planner provider failed. See " <> log_path)
  }
}

pub fn start_task(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  run_path: String,
  task: types.Task,
  worktree_path: String,
  env_vars: List(#(String, String)),
  start_head: String,
  branch_name: String,
  base_ref: String,
) -> Result(TaskRun, String) {
  let prompt_path = filepath.join(run_path, "logs/" <> task.id <> ".prompt.md")
  let log_path = filepath.join(run_path, "logs/" <> task.id <> ".log")
  use _ <- result.try(write_file(prompt_path, execution_prompt(task)))
  use command <- result.try(executor_command(
    agent,
    repo_root,
    worktree_path,
    prompt_path,
  ))
  let handle =
    start_provider_command(
      shell.with_env(command, env_vars),
      worktree_path,
      log_path,
      shell.stream_metadata(
        label: task.id,
        prompt_path: prompt_path,
        harness: types.provider_to_string(agent.provider),
        phase: "execute",
      ),
    )

  Ok(TaskRun(
    task: task,
    handle: handle,
    worktree_path: worktree_path,
    start_head: start_head,
    log_path: log_path,
    branch_name: branch_name,
    base_ref: base_ref,
  ))
}

pub fn await_task(run: TaskRun) -> Result(types.ExecutionResult, String) {
  let command_result = shell.wait(run.handle)
  case shell.succeeded(command_result) {
    True -> {
      use payload <- result.try(extract_json_payload(command_result.output))
      json.parse(payload, execution_decoder())
      |> result.map_error(fn(_) {
        "Unable to decode execution output for task " <> run.task.id <> "."
      })
    }
    False ->
      Error(
        "Provider execution failed for task "
        <> run.task.id
        <> ". See "
        <> run.log_path,
      )
  }
}

pub fn repair_task(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  worktree_path: String,
  env_vars: List(#(String, String)),
  run_path: String,
  task: types.Task,
  verification_output: String,
) -> Result(types.ExecutionResult, String) {
  let prompt_path =
    filepath.join(run_path, "logs/" <> task.id <> ".repair.prompt.md")
  let log_path = filepath.join(run_path, "logs/" <> task.id <> ".repair.log")
  use _ <- result.try(write_file(
    prompt_path,
    repair_prompt(task, verification_output),
  ))
  use command <- result.try(executor_command(
    agent,
    repo_root,
    worktree_path,
    prompt_path,
  ))
  let command_result =
    run_provider_command(
      shell.with_env(command, env_vars),
      worktree_path,
      log_path,
      shell.stream_metadata(
        label: task.id <> " repair",
        prompt_path: prompt_path,
        harness: types.provider_to_string(agent.provider),
        phase: "repair",
      ),
    )

  case shell.succeeded(command_result) {
    True -> {
      use payload <- result.try(extract_json_payload(command_result.output))
      json.parse(payload, execution_decoder())
      |> result.map_error(fn(_) {
        "Unable to decode repair output for task " <> task.id <> "."
      })
    }
    False ->
      Error(
        "Repair provider failed for task " <> task.id <> ". See " <> log_path,
      )
  }
}

fn planner_command(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  prompt_path: String,
) -> Result(String, String) {
  case fake_provider_command() {
    Some(command) -> Ok(command <> " plan " <> shell.quote(prompt_path))
    None -> planning_command(agent, repo_root, prompt_path)
  }
}

fn plan_document_command(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  prompt_path: String,
) -> Result(String, String) {
  case fake_provider_command() {
    Some(command) -> Ok(command <> " plan-doc " <> shell.quote(prompt_path))
    None -> planning_command(agent, repo_root, prompt_path)
  }
}

fn run_planner_command(
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

fn start_provider_command(
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

fn run_provider_command(
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

fn fake_provider_command() -> Option(String) {
  case system.get_env("NIGHT_SHIFT_FAKE_PROVIDER") {
    "" -> None
    command -> Some(command)
  }
}

fn executor_command(
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

fn planning_command(
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

fn planner_prompt(brief_contents: String) -> String {
  "You are Night Shift's planning provider.\n"
  <> "Break the supplied brief into a task DAG.\n"
  <> "Do not write files, apply patches, or make any repository changes.\n"
  <> "Read only the files you need to plan the work.\n"
  <> "Stay strictly within the brief. Do not create adjacent scope.\n"
  <> "If ambiguity would change public behavior, create a single task whose description asks for manual attention.\n"
  <> "Return only one JSON object between the exact sentinel markers below.\n"
  <> "Each task must include: id, title, description, dependencies, acceptance, demo_plan, execution_mode.\n"
  <> "Use execution_mode = parallel for independent low-conflict work, serial for normal implementation work that may share context, and exclusive only when the task must run alone.\n"
  <> "Use lowercase kebab-case ids.\n"
  <> "\n"
  <> start_marker
  <> "\n"
  <> "{\"tasks\":[...]}\n"
  <> end_marker
  <> "\n"
  <> "\n"
  <> "Brief:\n"
  <> brief_contents
}

fn planning_document_prompt(
  notes_contents notes_contents: String,
  existing_doc_contents existing_doc_contents: String,
  doc_path doc_path: String,
) -> String {
  "You are Night Shift's planning provider.\n"
  <> "Update the repository's cumulative Night Shift brief.\n"
  <> "Do not write files, apply patches, or make any repository changes.\n"
  <> "Read only the files needed to ground the brief.\n"
  <> "Inspect the repository as needed to understand the work being added.\n"
  <> "Preserve valid prior brief content unless the new notes supersede it.\n"
  <> "If the new notes conflict with the prior brief, the new notes win.\n"
  <> "Stay within supplied scope and repository facts. Do not invent adjacent work.\n"
  <> "Return only the full Markdown brief between the exact sentinel markers below.\n"
  <> "The brief will later be passed directly to `night-shift start`.\n"
  <> "Use exactly these top-level sections in order:\n"
  <> "# Night Shift Brief\n"
  <> "## Objective\n"
  <> "## Scope\n"
  <> "## Constraints\n"
  <> "## Deliverables\n"
  <> "## Acceptance Criteria\n"
  <> "## Risks and Open Questions\n"
  <> "\n"
  <> start_marker
  <> "\n"
  <> "# Night Shift Brief\n"
  <> "## Objective\n"
  <> "...\n"
  <> end_marker
  <> "\n"
  <> "\n"
  <> "Destination path:\n"
  <> doc_path
  <> "\n"
  <> "\n"
  <> "Existing brief:\n"
  <> case string.trim(existing_doc_contents) {
    "" -> "(none)\n"
    _ -> existing_doc_contents
  }
  <> "\n"
  <> "\n"
  <> "New notes:\n"
  <> notes_contents
}

fn execution_prompt(task: types.Task) -> String {
  "You are Night Shift's execution provider.\n"
  <> "Implement the task in the current git worktree.\n"
  <> "Run your own validation before responding.\n"
  <> "Do not exceed the task scope.\n"
  <> "Return only one JSON object between the exact sentinel markers below.\n"
  <> "Status must be one of: completed, blocked, failed, manual_attention.\n"
  <> "The JSON shape is:\n"
  <> start_marker
  <> "\n"
  <> "{\"status\":\"completed\",\"summary\":\"...\",\"files_touched\":[\"...\"],\"demo_evidence\":[\"...\"],\"pr\":{\"title\":\"...\",\"summary\":\"...\",\"demo\":[\"...\"],\"risks\":[\"...\"]},\"follow_up_tasks\":[{\"id\":\"...\",\"title\":\"...\",\"description\":\"...\",\"dependencies\":[\"...\"],\"acceptance\":[\"...\"],\"demo_plan\":[\"...\"],\"execution_mode\":\"serial\"}]}\n"
  <> end_marker
  <> "\n"
  <> "\n"
  <> "Task:\n"
  <> render_task(task)
}

fn worktree_setup_prompt(output_path: String) -> String {
  "You are Night Shift's project setup provider.\n"
  <> "Draft a repo-scoped worktree environment file for Night Shift.\n"
  <> "Inspect the repository to infer likely setup and maintenance commands, but stay conservative.\n"
  <> "Prefer explicit, reproducible commands that prepare a fresh worktree for coding and verification.\n"
  <> "Do not include secrets. Do not write files or execute mutating commands.\n"
  <> "Return only TOML between the exact sentinel markers below.\n"
  <> "The TOML must parse against this v1 schema:\n"
  <> "version = 1\n"
  <> "default_environment = \"default\"\n"
  <> "[environments.<name>.env]\n"
  <> "KEY = \"value\"\n"
  <> "[environments.<name>.setup]\n"
  <> "default = [\"...\"]\n"
  <> "macos = []\n"
  <> "linux = []\n"
  <> "windows = []\n"
  <> "[environments.<name>.maintenance]\n"
  <> "default = [\"...\"]\n"
  <> "macos = []\n"
  <> "linux = []\n"
  <> "windows = []\n"
  <> "\n"
  <> "If you are unsure, keep commands empty instead of guessing.\n"
  <> "\n"
  <> start_marker
  <> "\n"
  <> worktree_setup.default_template()
  <> end_marker
  <> "\n\n"
  <> "Destination path:\n"
  <> output_path
}

fn repair_prompt(task: types.Task, verification_output: String) -> String {
  execution_prompt(task)
  <> "\n\n"
  <> "Repair this task using the failing verification output below.\n"
  <> verification_output
}

fn render_task(task: types.Task) -> String {
  "- ID: "
  <> task.id
  <> "\n- Title: "
  <> task.title
  <> "\n- Description: "
  <> task.description
  <> "\n- Acceptance:\n"
  <> render_lines(task.acceptance)
  <> "\n- Demo plan:\n"
  <> render_lines(task.demo_plan)
}

fn render_lines(lines: List(String)) -> String {
  case lines {
    [] -> "  - None supplied"
    _ ->
      lines
      |> list.map(fn(line) { "  - " <> line })
      |> string.join(with: "\n")
  }
}

pub fn extract_payload(output: String) -> Result(String, String) {
  case extract_structured_output(output) {
    Ok(structured_output) -> extract_marker_payload(structured_output)
    Error(_) -> extract_marker_payload(output)
  }
}

pub fn extract_json_payload(output: String) -> Result(String, String) {
  extract_payload(output)
}

fn extract_marker_payload(output: String) -> Result(String, String) {
  let sections =
    output
    |> string.split(start_marker)
    |> list.reverse

  use after_start <- result.try(case sections {
    [_] -> Error("Provider output did not contain the start marker.")
    [last_payload, ..] -> Ok(last_payload)
    [] -> Error("Provider output did not contain the start marker.")
  })

  use #(payload, _) <- result.try(
    string.split_once(after_start, end_marker)
    |> result.map_error(fn(_) {
      "Provider output did not contain the end marker."
    }),
  )

  Ok(string.trim(payload))
}

fn extract_structured_output(output: String) -> Result(String, String) {
  let messages =
    output
    |> string.split("\n")
    |> list.filter_map(fn(line) {
      case string.trim(line) {
        "" -> Error(Nil)
        trimmed ->
          case json.parse(trimmed, structured_output_decoder()) {
            Ok(text) -> Ok(text)
            Error(_) -> Error(Nil)
          }
      }
    })

  case messages {
    [] -> Error("Harness output did not contain a structured assistant result.")
    _ -> Ok(string.join(messages, with: "\n"))
  }
}

fn structured_output_decoder() -> decode.Decoder(String) {
  decode.one_of(cursor_result_decoder(), or: [codex_agent_message_decoder()])
}

fn codex_agent_message_decoder() -> decode.Decoder(String) {
  use event_type <- decode.field("type", decode.string)
  case event_type {
    "item.completed" -> {
      use item <- decode.field("item", {
        use item_type <- decode.field("type", decode.string)
        use text <- decode.field("text", decode.string)
        case item_type {
          "agent_message" -> decode.success(text)
          _ -> decode.failure("", "CodexAgentMessage")
        }
      })
      decode.success(item)
    }
    _ -> decode.failure("", "CodexAgentMessage")
  }
}

fn cursor_result_decoder() -> decode.Decoder(String) {
  use event_type <- decode.field("type", decode.string)
  case event_type {
    "result" -> {
      use result <- decode.field("result", decode.string)
      decode.success(result)
    }
    _ -> decode.failure("", "CursorResult")
  }
}

fn planner_decoder() -> decode.Decoder(List(types.Task)) {
  use tasks <- decode.field("tasks", decode.list(planned_task_decoder()))
  decode.success(tasks)
}

fn planned_task_decoder() -> decode.Decoder(types.Task) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use description <- decode.field("description", decode.string)
  use dependencies <- decode.field("dependencies", decode.list(decode.string))
  use acceptance <- decode.field("acceptance", decode.list(decode.string))
  use demo_plan <- decode.field("demo_plan", decode.list(decode.string))
  use execution_mode <- decode.then(execution_mode_decoder())
  decode.success(types.Task(
    id: id,
    title: title,
    description: description,
    dependencies: dependencies,
    acceptance: acceptance,
    demo_plan: demo_plan,
    execution_mode: execution_mode,
    state: types.Queued,
    worktree_path: "",
    branch_name: "",
    pr_number: "",
    summary: "",
  ))
}

fn execution_decoder() -> decode.Decoder(types.ExecutionResult) {
  use status <- decode.field("status", execution_status_decoder())
  use summary <- decode.field("summary", decode.string)
  use files_touched <- decode.field("files_touched", decode.list(decode.string))
  use demo_evidence <- decode.field("demo_evidence", decode.list(decode.string))
  use pr <- decode.field("pr", pr_decoder())
  use follow_up_tasks <- decode.field(
    "follow_up_tasks",
    decode.list(follow_up_task_decoder()),
  )
  decode.success(types.ExecutionResult(
    status: status,
    summary: summary,
    files_touched: files_touched,
    demo_evidence: demo_evidence,
    pr: pr,
    follow_up_tasks: follow_up_tasks,
  ))
}

fn pr_decoder() -> decode.Decoder(types.PrPlan) {
  use title <- decode.field("title", decode.string)
  use summary <- decode.field("summary", decode.string)
  use demo <- decode.field("demo", decode.list(decode.string))
  use risks <- decode.field("risks", decode.list(decode.string))
  decode.success(types.PrPlan(
    title: title,
    summary: summary,
    demo: demo,
    risks: risks,
  ))
}

fn follow_up_task_decoder() -> decode.Decoder(types.FollowUpTask) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use description <- decode.field("description", decode.string)
  use dependencies <- decode.field("dependencies", decode.list(decode.string))
  use acceptance <- decode.field("acceptance", decode.list(decode.string))
  use demo_plan <- decode.field("demo_plan", decode.list(decode.string))
  use execution_mode <- decode.then(execution_mode_decoder())
  decode.success(types.FollowUpTask(
    id: id,
    title: title,
    description: description,
    dependencies: dependencies,
    acceptance: acceptance,
    demo_plan: demo_plan,
    execution_mode: execution_mode,
  ))
}

fn execution_status_decoder() -> decode.Decoder(types.TaskState) {
  use status <- decode.then(decode.string)
  case status {
    "completed" -> decode.success(types.Completed)
    "blocked" -> decode.success(types.Blocked)
    "failed" -> decode.success(types.Failed)
    "manual_attention" -> decode.success(types.ManualAttention)
    _ -> decode.failure(types.Failed, "ExecutionStatus")
  }
}

fn execution_mode_decoder() -> decode.Decoder(types.ExecutionMode) {
  decode.one_of(field_execution_mode_decoder(), or: [legacy_parallel_safe_decoder()])
}

fn field_execution_mode_decoder() -> decode.Decoder(types.ExecutionMode) {
  use raw <- decode.field("execution_mode", decode.string)
  case types.execution_mode_from_string(raw) {
    Ok(mode) -> decode.success(mode)
    Error(_) -> decode.failure(types.Serial, "ExecutionMode")
  }
}

fn legacy_parallel_safe_decoder() -> decode.Decoder(types.ExecutionMode) {
  use parallel_safe <- decode.field("parallel_safe", decode.bool)
  case parallel_safe {
    True -> decode.success(types.Parallel)
    False -> decode.success(types.Exclusive)
  }
}

fn planning_artifact_path(repo_root: String) -> String {
  filepath.join(
    journal.planning_root_for(repo_root),
    system.timestamp()
      |> string.replace(each: ":", with: "-")
      |> string.replace(each: "T", with: "_")
      |> string.replace(each: "+", with: "_")
      |> string.replace(each: "Z", with: "")
      |> string.append("-")
      |> string.append(system.unique_id()),
  )
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

fn read_file(path: String) -> Result(String, String) {
  case simplifile.read(path) {
    Ok(contents) -> Ok(contents)
    Error(error) ->
      Error(
        "Unable to read " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}

fn read_existing_file_or_empty(path: String) -> String {
  case simplifile.read(path) {
    Ok(contents) -> contents
    Error(_) -> ""
  }
}

fn write_file(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.write(contents, to: path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to write " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}
