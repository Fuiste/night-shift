//// Provider-facing orchestration helpers for planning and execution.
////
//// This module turns typed Night Shift state into provider prompts, command
//// invocations, and decoded payloads.

import filepath
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/codec/artifact_path
import night_shift/codec/provider_payload
import night_shift/infra/log_cleanup
import night_shift/journal
import night_shift/provider_command
import night_shift/provider_prompt
import night_shift/shell
import night_shift/types
import night_shift/worktree_setup
import simplifile

/// Handle and metadata for a task that is currently executing.
pub type TaskRun {
  TaskRun(
    task: types.Task,
    handle: shell.JobHandle,
    worktree_path: String,
    start_head: String,
    log_path: String,
    branch_name: String,
    base_ref: String,
    worktree_origin: WorktreeOrigin,
  )
}

/// How Night Shift obtained the worktree used for a task run.
pub type WorktreeOrigin {
  CreatedWorktree
  AttachedWorktree
  ReusedWorktree
}

/// Structured execution failure information returned by `await_task_detailed`.
pub type AwaitTaskError {
  ProviderCommandFailed(message: String)
  PayloadExtractionFailed(message: String)
  PayloadDecodeFailed(
    message: String,
    artifacts: provider_payload.PayloadArtifacts,
  )
}

/// Ask the planning provider to draft or refresh the execution brief.
pub fn plan_document(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  notes_source: types.NotesSource,
  doc_path: String,
) -> Result(#(String, String, types.NotesSource), String) {
  let artifact_path = planning_artifact_path(repo_root)
  use _ <- result.try(create_directory(artifact_path))
  use notes_contents <- result.try(read_notes_source(notes_source))
  let existing_doc_contents = read_existing_file_or_empty(doc_path)
  plan_document_attempt(
    agent,
    repo_root,
    notes_source,
    doc_path,
    artifact_path,
    notes_contents,
    existing_doc_contents,
    1,
    None,
  )
}

/// Ask the planning provider to generate a worktree setup file.
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

/// Ask the planning provider for a task graph.
pub fn plan_tasks(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  brief_path: String,
  run_path: String,
  decisions: List(types.RecordedDecision),
  completed_tasks: List(types.Task),
) -> Result(List(types.Task), String) {
  plan_tasks_attempt(
    agent,
    repo_root,
    brief_path,
    run_path,
    decisions,
    completed_tasks,
    1,
    None,
  )
}

/// Ask the planning provider for a task graph, optionally with retry feedback.
pub fn plan_tasks_attempt(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  brief_path: String,
  run_path: String,
  decisions: List(types.RecordedDecision),
  completed_tasks: List(types.Task),
  attempt: Int,
  retry_feedback: Option(String),
) -> Result(List(types.Task), String) {
  let canonical_prompt_path = filepath.join(run_path, "planner.prompt.md")
  let canonical_log_path = filepath.join(run_path, "logs/planner.log")
  let prompt_path =
    planning_attempt_path(canonical_prompt_path, attempt, ".prompt.md")
  let log_path = planning_attempt_path(canonical_log_path, attempt, ".log")
  use brief_contents <- result.try(read_file(brief_path))
  let prompt =
    provider_prompt.planner_prompt_with_feedback(
      brief_contents,
      decisions,
      completed_tasks,
      retry_feedback,
    )
  use _ <- result.try(write_file(prompt_path, prompt))
  use _ <- result.try(write_file(canonical_prompt_path, prompt))
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
  // Keep a canonical prompt and log path alongside attempt-specific artifacts
  // so the latest run is easy for operators to inspect.
  use _ <- result.try(sync_attempt_artifact(log_path, canonical_log_path))

  case shell.succeeded(command_result) {
    True -> {
      use _ <- result.try(log_cleanup.clean_operator_log(canonical_log_path))
      provider_payload.decode_planned_tasks(command_result.output)
    }
    False -> Error("Planner provider failed. See " <> canonical_log_path)
  }
}

/// Start provider execution for one task in its prepared worktree.
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
  worktree_origin: WorktreeOrigin,
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
    worktree_origin: worktree_origin,
  ))
}

/// Wait for a running task and collapse detailed failures into a string.
pub fn await_task(run: TaskRun) -> Result(types.ExecutionResult, String) {
  await_task_detailed(run) |> result.map_error(await_task_error_message)
}

/// Wait for a running task and preserve detailed payload failures.
pub fn await_task_detailed(
  run: TaskRun,
) -> Result(types.ExecutionResult, AwaitTaskError) {
  let command_result = shell.wait(run.handle)
  case shell.succeeded(command_result) {
    True -> {
      // Clean the log before decoding so transcript noise does not masquerade
      // as payload bytes.
      use _ <- result.try(
        log_cleanup.clean_operator_log(run.log_path)
        |> result.map_error(PayloadExtractionFailed),
      )
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
    }
    False ->
      Error(ProviderCommandFailed(
        "Provider execution failed for task "
        <> run.task.id
        <> ". See "
        <> run.log_path,
      ))
  }
}

/// Ask the execution provider to repair a task after local verification fails.
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
    True -> {
      use _ <- result.try(log_cleanup.clean_operator_log(log_path))
      provider_payload.decode_execution_result(
        command_result.output,
        log_path,
        "Unable to decode repair output for task " <> task.id <> ".",
      )
    }
    False ->
      Error(
        "Repair provider failed for task " <> task.id <> ". See " <> log_path,
      )
  }
}

/// Extract the sentinel-delimited provider payload from raw command output.
pub fn extract_payload(output: String) -> Result(String, String) {
  provider_payload.extract_payload(output)
}

/// Extract and normalize a JSON payload from raw command output.
pub fn extract_json_payload(output: String) -> Result(String, String) {
  provider_payload.extract_json_payload(output)
}

/// Clean a JSON payload before decoding it into Night Shift types.
pub fn sanitize_json_payload(payload: String) -> Result(String, String) {
  provider_payload.sanitize_json_payload(payload)
}

fn planning_artifact_path(repo_root: String) -> String {
  artifact_path.timestamped_directory(journal.planning_root_for(repo_root))
}

fn plan_document_attempt(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  notes_source: types.NotesSource,
  doc_path: String,
  artifact_path: String,
  notes_contents: String,
  existing_doc_contents: String,
  attempt: Int,
  retry_feedback: Option(String),
) -> Result(#(String, String, types.NotesSource), String) {
  let canonical_prompt_path = filepath.join(artifact_path, "planner.prompt.md")
  let canonical_log_path = filepath.join(artifact_path, "planner.log")
  let prompt_path =
    planning_attempt_path(canonical_prompt_path, attempt, ".prompt.md")
  let log_path = planning_attempt_path(canonical_log_path, attempt, ".log")
  let prompt =
    provider_prompt.planning_document_prompt_with_feedback(
      notes_contents: notes_contents,
      existing_doc_contents: existing_doc_contents,
      doc_path: doc_path,
      retry_feedback: retry_feedback,
    )
  use _ <- result.try(write_file(prompt_path, prompt))
  use _ <- result.try(write_file(canonical_prompt_path, prompt))
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
  // Mirror the latest attempt into stable file names so humans and later phases
  // can inspect the current prompt and log without guessing the retry count.
  use _ <- result.try(sync_attempt_artifact(log_path, canonical_log_path))

  case shell.succeeded(command_result) {
    True -> {
      use _ <- result.try(log_cleanup.clean_operator_log(canonical_log_path))
      case provider_payload.extract_payload(command_result.output) {
        Ok(document) ->
          case string.trim(document) {
            "" ->
              maybe_retry_plan_document(
                agent,
                repo_root,
                notes_source,
                doc_path,
                artifact_path,
                notes_contents,
                existing_doc_contents,
                attempt,
                "The previous attempt returned an empty brief. Retry once and return only the complete brief between the sentinel markers.",
                canonical_log_path,
              )
            trimmed -> Ok(#(trimmed, artifact_path, notes_source))
          }
        Error(message) ->
          maybe_retry_plan_document(
            agent,
            repo_root,
            notes_source,
            doc_path,
            artifact_path,
            notes_contents,
            existing_doc_contents,
            attempt,
            message,
            canonical_log_path,
          )
      }
    }
    False -> Error("Planning provider failed. See " <> canonical_log_path)
  }
}

fn maybe_retry_plan_document(
  agent: types.ResolvedAgentConfig,
  repo_root: String,
  notes_source: types.NotesSource,
  doc_path: String,
  artifact_path: String,
  notes_contents: String,
  existing_doc_contents: String,
  attempt: Int,
  message: String,
  canonical_log_path: String,
) -> Result(#(String, String, types.NotesSource), String) {
  case attempt < 2 && retryable_planning_failure(message) {
    True ->
      plan_document_attempt(
        agent,
        repo_root,
        notes_source,
        doc_path,
        artifact_path,
        notes_contents,
        existing_doc_contents,
        attempt + 1,
        Some(retry_guidance(message)),
      )
    False -> Error(message <> " See " <> canonical_log_path)
  }
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

fn planning_attempt_path(
  canonical_path: String,
  attempt: Int,
  suffix: String,
) -> String {
  filepath.join(
    filepath.directory_name(canonical_path),
    attempt_filename(filepath.base_name(canonical_path), attempt, suffix),
  )
}

fn attempt_filename(filename: String, attempt: Int, suffix: String) -> String {
  string.replace(
    in: filename,
    each: suffix,
    with: ".attempt-" <> int.to_string(attempt) <> suffix,
  )
}

fn sync_attempt_artifact(
  path: String,
  canonical_path: String,
) -> Result(Nil, String) {
  use contents <- result.try(read_file(path))
  write_file(canonical_path, contents)
}

fn retryable_planning_failure(message: String) -> Bool {
  let lowered = string.lowercase(message)
  string.contains(does: lowered, contain: "start marker")
  || string.contains(does: lowered, contain: "end marker")
  || string.contains(does: lowered, contain: "unable to decode")
  || string.contains(does: lowered, contain: "empty brief")
  || string.contains(does: lowered, contain: "planning provider returned")
}

fn retry_guidance(message: String) -> String {
  "The previous planning attempt failed because:\n"
  <> message
  <> "\nReturn only the required content between the sentinel markers, with no prose before or after the markers."
}
