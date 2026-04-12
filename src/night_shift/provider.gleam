import filepath
import gleam/result
import gleam/string
import night_shift/codec/artifact_path
import night_shift/codec/provider_payload
import night_shift/journal
import night_shift/provider_command
import night_shift/provider_prompt
import night_shift/shell
import night_shift/types
import night_shift/worktree_setup
import simplifile

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

pub type AwaitTaskError {
  ProviderCommandFailed(message: String)
  PayloadExtractionFailed(message: String)
  PayloadDecodeFailed(
    message: String,
    artifacts: provider_payload.PayloadArtifacts,
  )
}

pub fn plan_document(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  notes_source: types.NotesSource,
  doc_path: String,
) -> Result(#(String, String, types.NotesSource), String) {
  let artifact_path = planning_artifact_path(repo_root)
  let prompt_path = filepath.join(artifact_path, "planner.prompt.md")
  let log_path = filepath.join(artifact_path, "planner.log")
  use _ <- result.try(create_directory(artifact_path))
  use notes_contents <- result.try(read_notes_source(notes_source))
  let existing_doc_contents = read_existing_file_or_empty(doc_path)
  use _ <- result.try(write_file(
    prompt_path,
    provider_prompt.planning_document_prompt(
      notes_contents: notes_contents,
      existing_doc_contents: existing_doc_contents,
      doc_path: doc_path,
    ),
  ))
  use command <- result.try(provider_command.plan_document_command(
    agent,
    repo_root,
    prompt_path,
  ))
  let command_result =
    provider_command.run_planner_command(
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
      use document <- result.try(provider_payload.extract_payload(
        command_result.output,
      ))
      case string.trim(document) {
        "" ->
          Error("Planning provider returned an empty brief. See " <> log_path)
        trimmed -> Ok(#(trimmed, artifact_path, notes_source))
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
    provider_prompt.worktree_setup_prompt(output_path),
  ))
  use command <- result.try(provider_command.planning_command(
    agent,
    repo_root,
    prompt_path,
  ))
  let command_result =
    provider_command.run_planner_command(
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
      use document <- result.try(provider_payload.extract_payload(
        command_result.output,
      ))
      let trimmed_document = string.trim(document)
      use _ <- result.try(write_file(generated_path, trimmed_document))
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
          "Generated worktree setup was invalid: "
          <> message
          <> ". See "
          <> log_path
          <> " and "
          <> generated_path
        }),
      )
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
  decisions: List(types.RecordedDecision),
  completed_tasks: List(types.Task),
) -> Result(List(types.Task), String) {
  let prompt_path = filepath.join(run_path, "planner.prompt.md")
  let log_path = filepath.join(run_path, "logs/planner.log")
  use brief_contents <- result.try(read_file(brief_path))
  use _ <- result.try(write_file(
    prompt_path,
    provider_prompt.planner_prompt(brief_contents, decisions, completed_tasks),
  ))
  use command <- result.try(provider_command.planner_command(
    agent,
    repo_root,
    prompt_path,
  ))
  let command_result =
    provider_command.run_planner_command(
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
    True -> provider_payload.decode_planned_tasks(command_result.output)
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
  use _ <- result.try(write_file(
    prompt_path,
    provider_prompt.execution_prompt(task),
  ))
  use command <- result.try(provider_command.executor_command(
    agent,
    repo_root,
    worktree_path,
    prompt_path,
  ))
  let handle =
    provider_command.start_provider_command(
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
  await_task_detailed(run) |> result.map_error(await_task_error_message)
}

pub fn await_task_detailed(
  run: TaskRun,
) -> Result(types.ExecutionResult, AwaitTaskError) {
  let command_result = shell.wait(run.handle)
  case shell.succeeded(command_result) {
    True ->
      provider_payload.decode_execution_result_detailed(
        command_result.output,
        run.log_path,
        "Unable to decode execution output for task " <> run.task.id <> ".",
      )
      |> result.map_error(fn(error) {
        case error {
          provider_payload.PayloadExtractionFailure(message) ->
            PayloadExtractionFailed(message)
          provider_payload.JsonDecodeFailure(message, artifacts) ->
            PayloadDecodeFailed(message, artifacts)
        }
      })
    False ->
      Error(ProviderCommandFailed(
        "Provider execution failed for task "
        <> run.task.id
        <> ". See "
        <> run.log_path,
      ))
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
    provider_prompt.repair_prompt(task, verification_output),
  ))
  use command <- result.try(provider_command.executor_command(
    agent,
    repo_root,
    worktree_path,
    prompt_path,
  ))
  let command_result =
    provider_command.run_provider_command(
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
    True ->
      provider_payload.decode_execution_result(
        command_result.output,
        log_path,
        "Unable to decode repair output for task " <> task.id <> ".",
      )
    False ->
      Error(
        "Repair provider failed for task " <> task.id <> ". See " <> log_path,
      )
  }
}

pub fn extract_payload(output: String) -> Result(String, String) {
  provider_payload.extract_payload(output)
}

pub fn extract_json_payload(output: String) -> Result(String, String) {
  provider_payload.extract_json_payload(output)
}

pub fn sanitize_json_payload(payload: String) -> Result(String, String) {
  provider_payload.sanitize_json_payload(payload)
}

fn planning_artifact_path(repo_root: String) -> String {
  artifact_path.timestamped_directory(journal.planning_root_for(repo_root))
}

fn await_task_error_message(error: AwaitTaskError) -> String {
  case error {
    ProviderCommandFailed(message) -> message
    PayloadExtractionFailed(message) -> message
    PayloadDecodeFailed(message, _) -> message
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

fn read_notes_source(source: types.NotesSource) -> Result(String, String) {
  case source {
    types.NotesFile(path) -> read_file(path)
    types.InlineNotes(path) -> read_file(path)
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
