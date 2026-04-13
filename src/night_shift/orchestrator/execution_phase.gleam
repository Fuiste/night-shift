import filepath
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/codec/provider_payload
import night_shift/domain/decisions as decision_domain
import night_shift/domain/run_state
import night_shift/domain/summary as domain_summary
import night_shift/domain/task_graph
import night_shift/domain/task_validation
import night_shift/git
import night_shift/infra/task_delivery
import night_shift/infra/task_verifier
import night_shift/journal
import night_shift/project
import night_shift/provider
import night_shift/system
import night_shift/types
import night_shift/worktree_setup
import night_shift/worktree_setup_model

pub type PreparedExecution {
  PreparedExecution(run: types.RunRecord, proceed: Bool)
}

pub type LaunchedBatch {
  LaunchedBatch(run: types.RunRecord, task_runs: List(provider.TaskRun))
}

pub fn prepare_run(run: types.RunRecord) -> Result(PreparedExecution, String) {
  let refreshed_run =
    types.RunRecord(..run, tasks: task_graph.refresh_ready_states(run.tasks))

  case run_state.has_blocking_attention(refreshed_run.tasks) {
    True ->
      append_manual_attention_events(refreshed_run)
      |> result.map(fn(updated_run) {
        PreparedExecution(run: updated_run, proceed: True)
      })
    False ->
      case
        task_graph.next_batch(refreshed_run.tasks, refreshed_run.max_workers)
      {
        [] -> Ok(PreparedExecution(run: refreshed_run, proceed: True))
        [task, ..] if task.kind == types.ManualAttentionTask ->
          append_manual_attention_events(refreshed_run)
          |> result.map(fn(updated_run) {
            PreparedExecution(run: updated_run, proceed: True)
          })
        _ -> {
          let preflight_log =
            filepath.join(
              refreshed_run.run_path,
              "logs/environment-preflight.log",
            )
          case
            worktree_setup.preflight_environment(
              refreshed_run.repo_root,
              refreshed_run.environment_name,
              project.worktree_setup_path(refreshed_run.repo_root),
              preflight_log,
            )
          {
            Ok(_) -> Ok(PreparedExecution(run: refreshed_run, proceed: True))
            Error(message) -> {
              let event =
                types.RunEvent(
                  kind: "environment_preflight_failed",
                  at: system.timestamp(),
                  message: message,
                  task_id: None,
                )
              use failed_run <- result.try(journal.append_event(
                refreshed_run,
                event,
              ))
              use marked_run <- result.try(journal.mark_status(
                failed_run,
                types.RunFailed,
                message,
              ))
              Ok(PreparedExecution(run: marked_run, proceed: False))
            }
          }
        }
      }
  }
}

pub fn launch_batch(
  config: types.Config,
  run: types.RunRecord,
  tasks: List(types.Task),
) -> Result(LaunchedBatch, String) {
  launch_batch_loop(config, run, tasks, [])
}

fn launch_batch_loop(
  config: types.Config,
  run: types.RunRecord,
  tasks: List(types.Task),
  acc: List(provider.TaskRun),
) -> Result(LaunchedBatch, String) {
  case tasks {
    [] -> Ok(LaunchedBatch(run: run, task_runs: list.reverse(acc)))
    [task, ..rest] -> {
      case task.kind {
        types.ManualAttentionTask -> {
          use blocked_run <- result.try(mark_task_with_event(
            run,
            task,
            types.ManualAttention,
            domain_summary.manual_attention_summary(task),
            "task_manual_attention",
          ))
          Ok(LaunchedBatch(run: blocked_run, task_runs: list.reverse(acc)))
        }
        types.ImplementationTask -> {
          let branch_name = case task.branch_name {
            "" ->
              task_graph.build_branch_name(
                config.branch_prefix,
                run.run_id,
                task.id,
              )
            existing_branch -> existing_branch
          }
          let is_existing_worktree = task.branch_name != ""
          let default_worktree_path =
            filepath.join(run.run_path, "worktrees/" <> task.id)
          let base_ref = case task.branch_name {
            "" -> task_graph.task_base_ref(task, run.tasks, config.base_branch)
            existing_branch -> existing_branch
          }
          let git_log =
            filepath.join(run.run_path, "logs/" <> task.id <> ".git.log")
          let env_log =
            filepath.join(run.run_path, "logs/" <> task.id <> ".env.log")
          case
            prepare_task_worktree(
              run.repo_root,
              default_worktree_path,
              branch_name,
              base_ref,
              is_existing_worktree,
              git_log,
            )
          {
            Ok(#(worktree_path, worktree_origin)) -> {
              let running_task =
                types.Task(
                  ..task,
                  state: types.Running,
                  worktree_path: worktree_path,
                  branch_name: branch_name,
                )
              let updated_run =
                types.RunRecord(
                  ..run,
                  tasks: task_graph.replace_task(run.tasks, running_task),
                )
              let event =
                types.RunEvent(
                  kind: "task_started",
                  at: system.timestamp(),
                  message: "Started task " <> task.title,
                  task_id: Some(task.id),
                )
              let bootstrap_phase = case worktree_origin {
                provider.ReusedWorktree -> worktree_setup_model.MaintenancePhase
                _ ->
                  case is_existing_worktree {
                    True -> worktree_setup_model.MaintenancePhase
                    False -> worktree_setup_model.SetupPhase
                  }
              }

              use persisted_run <- result.try(journal.append_event(
                updated_run,
                event,
              ))
              use announced_run <- result.try(append_worktree_origin_event(
                persisted_run,
                running_task,
                worktree_origin,
                worktree_path,
              ))
              case
                start_task_run(
                  announced_run,
                  running_task,
                  worktree_path,
                  branch_name,
                  base_ref,
                  bootstrap_phase,
                  git_log,
                  env_log,
                  worktree_origin,
                )
              {
                Ok(#(started_run, task_run)) ->
                  launch_batch_loop(config, started_run, rest, [task_run, ..acc])

                Error(message) -> {
                  use failed_run <- result.try(mark_task_with_event(
                    announced_run,
                    running_task,
                    types.Failed,
                    message,
                    "task_failed",
                  ))
                  launch_batch_loop(config, failed_run, rest, acc)
                }
              }
            }
            Error(message) -> {
              let failed_task =
                types.Task(..task, state: types.Failed, summary: message)
              let failed_run =
                types.RunRecord(
                  ..run,
                  tasks: task_graph.replace_task(run.tasks, failed_task),
                )
              let event =
                types.RunEvent(
                  kind: "task_failed",
                  at: system.timestamp(),
                  message: message,
                  task_id: Some(task.id),
                )
              use persisted_run <- result.try(journal.append_event(
                failed_run,
                event,
              ))
              launch_batch_loop(config, persisted_run, rest, acc)
            }
          }
        }
      }
    }
  }
}

pub fn await_batch(
  config: types.Config,
  run: types.RunRecord,
  task_runs: List(provider.TaskRun),
) -> Result(types.RunRecord, String) {
  case task_runs {
    [] -> Ok(run)
    [task_run, ..rest] -> {
      let next_run_result = case provider.await_task_detailed(task_run) {
        Ok(awaited_execution) ->
          case
            append_execution_payload_warning(run, task_run, awaited_execution)
          {
            Ok(warned_run) ->
              case
                complete_task(
                  config,
                  warned_run,
                  task_run,
                  awaited_execution.execution_result,
                )
              {
                Ok(updated_run) -> Ok(updated_run)
                Error(message) ->
                  mark_task_with_event(
                    warned_run,
                    task_run.task,
                    types.Failed,
                    domain_summary.completion_failure_summary(message),
                    "task_failed",
                  )
              }
            Error(message) -> Error(message)
          }
        Error(error) -> handle_await_task_error(config, run, task_run, error)
      }

      use updated_run <- result.try(next_run_result)
      await_batch(config, updated_run, rest)
    }
  }
}

fn prepare_task_worktree(
  repo_root: String,
  default_worktree_path: String,
  branch_name: String,
  base_ref: String,
  is_existing_worktree: Bool,
  git_log: String,
) -> Result(#(String, provider.WorktreeOrigin), String) {
  case is_existing_worktree {
    False -> {
      use _ <- result.try(git.create_worktree(
        repo_root,
        default_worktree_path,
        branch_name,
        base_ref,
        git_log,
      ))
      Ok(#(default_worktree_path, provider.CreatedWorktree))
    }
    True ->
      case git.mounted_worktree_path(repo_root, branch_name, git_log) {
        Ok(Some(existing_path)) -> Ok(#(existing_path, provider.ReusedWorktree))
        Ok(None) -> {
          use _ <- result.try(git.attach_worktree(
            repo_root,
            default_worktree_path,
            branch_name,
            git_log,
          ))
          Ok(#(default_worktree_path, provider.AttachedWorktree))
        }
        Error(message) -> Error(message)
      }
  }
}

fn append_worktree_origin_event(
  run: types.RunRecord,
  task: types.Task,
  worktree_origin: provider.WorktreeOrigin,
  worktree_path: String,
) -> Result(types.RunRecord, String) {
  case worktree_origin {
    provider.ReusedWorktree ->
      journal.append_event(
        run,
        types.RunEvent(
          kind: "task_progress",
          at: system.timestamp(),
          message: "Reused existing worktree for branch "
            <> task.branch_name
            <> " at "
            <> worktree_path
            <> ".",
          task_id: Some(task.id),
        ),
      )
    _ -> Ok(run)
  }
}

fn append_execution_payload_warning(
  run: types.RunRecord,
  task_run: provider.TaskRun,
  awaited_execution: provider.AwaitedExecution,
) -> Result(types.RunRecord, String) {
  case provider.execution_trust_warning(awaited_execution, task_run.task.id) {
    Some(message) ->
      journal.append_event(
        run,
        types.RunEvent(
          kind: "execution_payload_warning",
          at: system.timestamp(),
          message: message,
          task_id: Some(task_run.task.id),
        ),
      )
    None -> Ok(run)
  }
}

fn complete_task(
  config: types.Config,
  run: types.RunRecord,
  task_run: provider.TaskRun,
  execution_result: types.ExecutionResult,
) -> Result(types.RunRecord, String) {
  case validate_follow_up_tasks(run, task_run, execution_result) {
    Ok(Some(updated_run)) -> Ok(updated_run)
    Ok(None) ->
      case execution_result.status {
        types.Completed ->
          finalize_success(config, run, task_run, execution_result)
        types.Blocked | types.ManualAttention | types.Failed ->
          finalize_non_success(run, task_run.task, execution_result)
        _ -> finalize_non_success(run, task_run.task, execution_result)
      }
    Error(message) -> Error(message)
  }
}

fn finalize_non_success(
  run: types.RunRecord,
  task: types.Task,
  execution_result: types.ExecutionResult,
) -> Result(types.RunRecord, String) {
  let event_kind = run_state.event_kind_for_state(execution_result.status)
  mark_task_with_event(
    run,
    task,
    execution_result.status,
    execution_result.summary,
    event_kind,
  )
}

fn finalize_success(
  config: types.Config,
  run: types.RunRecord,
  task_run: provider.TaskRun,
  execution_result: types.ExecutionResult,
) -> Result(types.RunRecord, String) {
  case
    task_verifier.verify_completed_task(config, run, task_run, execution_result)
  {
    Ok(verified) ->
      case
        task_delivery.deliver_completed_task(
          run,
          task_run,
          verified.execution_result,
          verified.verification_output,
        )
      {
        Ok(task_delivery.NoDeliveredChanges(_)) ->
          mark_task_with_event(
            run,
            task_run.task,
            types.ManualAttention,
            "Primary blocker: provider reported completion but the task worktree produced no committed or uncommitted changes.\n\nEnvironment notes: verification completed, but there was nothing new to deliver.",
            "task_manual_attention",
          )
        Ok(task_delivery.Delivered(pr_number, pr_url, delivered_files)) -> {
          let completed_task =
            types.Task(
              ..task_run.task,
              state: types.Completed,
              worktree_path: task_run.worktree_path,
              branch_name: task_run.branch_name,
              pr_number: pr_number,
              summary: verified.execution_result.summary,
            )

          let merged_tasks =
            decision_domain.apply_decision_states(
              task_graph.merge_follow_up_tasks(
                task_graph.replace_task(run.tasks, completed_task),
                verified.execution_result.follow_up_tasks,
              ),
              run.decisions,
            )
            |> task_graph.refresh_ready_states
          let updated_run = types.RunRecord(..run, tasks: merged_tasks)
          let verified_event =
            types.RunEvent(
              kind: "task_verified",
              at: system.timestamp(),
              message: "Verification passed for " <> task_run.task.title,
              task_id: Some(task_run.task.id),
            )
          use verified_run <- result.try(journal.append_event(
            updated_run,
            verified_event,
          ))
          journal.append_event(
            types.RunRecord(
              ..verified_run,
              tasks: task_graph.replace_task(
                verified_run.tasks,
                types.Task(
                  ..completed_task,
                  summary: verified.execution_result.summary
                    <> " Changed files: "
                    <> string.join(delivered_files, ", "),
                ),
              ),
            ),
            types.RunEvent(
              kind: "pr_opened",
              at: system.timestamp(),
              message: pr_url,
              task_id: Some(task_run.task.id),
            ),
          )
        }
        Error(message) -> Error(message)
      }
    Error(output) -> {
      mark_task_with_event(
        run,
        task_run.task,
        types.Failed,
        "Primary blocker: verification failed.\n\nEnvironment notes:\n"
          <> output,
        "task_failed",
      )
    }
  }
}

fn append_manual_attention_events(
  run: types.RunRecord,
) -> Result(types.RunRecord, String) {
  run.tasks
  |> list.filter(fn(task) { task.state == types.ManualAttention })
  |> append_manual_attention_events_for_tasks(run)
}

fn append_manual_attention_events_for_tasks(
  tasks: List(types.Task),
  run: types.RunRecord,
) -> Result(types.RunRecord, String) {
  case tasks {
    [] -> Ok(run)
    [task, ..rest] -> {
      use updated_run <- result.try(journal.append_event(
        run,
        types.RunEvent(
          kind: "task_manual_attention",
          at: system.timestamp(),
          message: domain_summary.manual_attention_summary(task),
          task_id: Some(task.id),
        ),
      ))
      append_manual_attention_events_for_tasks(rest, updated_run)
    }
  }
}

fn start_task_run(
  run: types.RunRecord,
  task: types.Task,
  worktree_path: String,
  branch_name: String,
  base_ref: String,
  bootstrap_phase: worktree_setup.BootstrapPhase,
  git_log: String,
  env_log: String,
  worktree_origin: provider.WorktreeOrigin,
) -> Result(#(types.RunRecord, provider.TaskRun), String) {
  use _ <- result.try(worktree_setup.prepare_worktree(
    run.repo_root,
    run.environment_name,
    project.worktree_setup_path(run.repo_root),
    worktree_path,
    branch_name,
    bootstrap_phase,
    env_log,
  ))
  use env_vars <- result.try(worktree_setup.env_vars_for(
    run.repo_root,
    run.environment_name,
    project.worktree_setup_path(run.repo_root),
  ))
  use start_head <- result.try(git.head_commit(worktree_path, git_log))
  use task_run <- result.try(provider.start_task(
    run.execution_agent,
    run.repo_root,
    run.run_path,
    task,
    worktree_path,
    env_vars,
    start_head,
    branch_name,
    base_ref,
    worktree_origin,
  ))
  Ok(#(run, task_run))
}

fn mark_task_with_event(
  run: types.RunRecord,
  task: types.Task,
  state: types.TaskState,
  summary: String,
  event_kind: String,
) -> Result(types.RunRecord, String) {
  let updated_task = types.Task(..task, state: state, summary: summary)
  let updated_run =
    types.RunRecord(
      ..run,
      tasks: task_graph.replace_task(run.tasks, updated_task),
    )
  journal.append_event(
    updated_run,
    types.RunEvent(
      kind: event_kind,
      at: system.timestamp(),
      message: summary,
      task_id: Some(task.id),
    ),
  )
}

fn validate_follow_up_tasks(
  run: types.RunRecord,
  task_run: provider.TaskRun,
  execution_result: types.ExecutionResult,
) -> Result(Option(types.RunRecord), String) {
  case
    task_validation.validate_follow_up_tasks(
      run.tasks,
      task_run.task.id,
      execution_result.follow_up_tasks,
    )
  {
    Ok(_) -> Ok(None)
    Error(issues) ->
      mark_task_with_event(
        run,
        task_run.task,
        types.ManualAttention,
        domain_summary.follow_up_validation_summary(task_run.task, issues),
        "task_manual_attention",
      )
      |> result.map(Some)
  }
}

fn handle_await_task_error(
  config: types.Config,
  run: types.RunRecord,
  task_run: provider.TaskRun,
  error: provider.AwaitTaskError,
) -> Result(types.RunRecord, String) {
  case error {
    provider.PayloadDecodeFailed(message, artifacts) ->
      case task_run_has_candidate_changes(run, task_run) {
        True ->
          attempt_payload_repair(config, run, task_run, message, artifacts)
        False ->
          mark_task_with_event(
            run,
            task_run.task,
            types.Failed,
            message,
            "task_failed",
          )
      }
    _ ->
      mark_task_with_event(
        run,
        task_run.task,
        types.Failed,
        await_task_error_message(error),
        "task_failed",
      )
  }
}

fn attempt_payload_repair(
  config: types.Config,
  run: types.RunRecord,
  task_run: provider.TaskRun,
  decode_failure_message: String,
  original_artifacts: provider_payload.PayloadArtifacts,
) -> Result(types.RunRecord, String) {
  use started_run <- result.try(journal.append_event(
    run,
    types.RunEvent(
      kind: "execution_payload_repair_started",
      at: system.timestamp(),
      message: "Attempting JSON-only payload repair for task "
        <> task_run.task.id
        <> ".\nOriginal raw payload: "
        <> original_artifacts.raw_payload_path,
      task_id: Some(task_run.task.id),
    ),
  ))

  let repair_result = case
    worktree_setup.env_vars_for(
      run.repo_root,
      run.environment_name,
      project.worktree_setup_path(run.repo_root),
    )
  {
    Ok(env_vars) ->
      provider.repair_execution_payload(
        run.execution_agent,
        run.repo_root,
        task_run.worktree_path,
        env_vars,
        run.run_path,
        task_run.task,
        decode_failure_message,
      )
    Error(message) ->
      Error(provider.PayloadRepairFailure(
        "Unable to prepare the payload-repair environment for task "
          <> task_run.task.id
          <> ". "
          <> message,
        provider.PayloadRepairArtifacts(
          prompt_path: filepath.join(
            run.run_path,
            "logs/" <> task_run.task.id <> ".payload-repair.prompt.md",
          ),
          log_path: filepath.join(
            run.run_path,
            "logs/" <> task_run.task.id <> ".payload-repair.log",
          ),
          raw_payload_path: None,
          sanitized_payload_path: None,
        ),
      ))
  }

  case repair_result {
    Ok(awaited_execution) -> {
      use repaired_run <- result.try(journal.append_event(
        started_run,
        types.RunEvent(
          kind: "execution_payload_repair_succeeded",
          at: system.timestamp(),
          message: payload_repair_success_message(
            task_run.task.id,
            original_artifacts,
            awaited_execution,
          ),
          task_id: Some(task_run.task.id),
        ),
      ))
      use warned_run <- result.try(append_execution_payload_warning(
        repaired_run,
        task_run,
        awaited_execution,
      ))
      case
        complete_task(
          config,
          warned_run,
          task_run,
          awaited_execution.execution_result,
        )
      {
        Ok(updated_run) -> Ok(updated_run)
        Error(message) ->
          mark_task_with_event(
            warned_run,
            task_run.task,
            types.Failed,
            domain_summary.completion_failure_summary(message),
            "task_failed",
          )
      }
    }
    Error(repair_failure) -> {
      use repair_failed_run <- result.try(journal.append_event(
        started_run,
        types.RunEvent(
          kind: "execution_payload_repair_failed",
          at: system.timestamp(),
          message: payload_repair_failure_message(
            task_run.task.id,
            original_artifacts,
            repair_failure,
          ),
          task_id: Some(task_run.task.id),
        ),
      ))
      mark_task_with_event(
        repair_failed_run,
        task_run.task,
        types.ManualAttention,
        domain_summary.decode_manual_attention_summary(
          task_run.task,
          task_run.log_path,
          original_artifacts.raw_payload_path,
          original_artifacts.sanitized_payload_path,
          Some(payload_repair_summary(repair_failure.artifacts)),
        ),
        "task_manual_attention",
      )
    }
  }
}

fn task_run_has_candidate_changes(
  run: types.RunRecord,
  task_run: provider.TaskRun,
) -> Bool {
  let git_log =
    filepath.join(
      run.run_path,
      "logs/" <> task_run.task.id <> ".recover.git.log",
    )

  let has_dirty_worktree = git.has_changes(task_run.worktree_path, git_log)
  let has_new_commit = case git.head_commit(task_run.worktree_path, git_log) {
    Ok(head) -> head != task_run.start_head
    Error(_) -> False
  }

  has_dirty_worktree || has_new_commit
}

fn payload_repair_success_message(
  task_id: String,
  original_artifacts: provider_payload.PayloadArtifacts,
  awaited_execution: provider.AwaitedExecution,
) -> String {
  "Accepted a repaired execution payload for task "
  <> task_id
  <> " with "
  <> provider_payload.payload_trust_label(awaited_execution.trust)
  <> " trust.\nOriginal raw payload: "
  <> original_artifacts.raw_payload_path
  <> "\nPayload repair raw payload: "
  <> awaited_execution.artifacts.raw_payload_path
  <> case awaited_execution.artifacts.sanitized_payload_path {
    Some(path) -> "\nPayload repair sanitized payload: " <> path
    None -> ""
  }
}

fn payload_repair_failure_message(
  task_id: String,
  original_artifacts: provider_payload.PayloadArtifacts,
  repair_failure: provider.PayloadRepairFailure,
) -> String {
  "Payload repair failed for task "
  <> task_id
  <> ".\nOriginal raw payload: "
  <> original_artifacts.raw_payload_path
  <> "\nPayload repair prompt: "
  <> repair_failure.artifacts.prompt_path
  <> "\nPayload repair log: "
  <> repair_failure.artifacts.log_path
  <> case repair_failure.artifacts.raw_payload_path {
    Some(path) -> "\nPayload repair raw payload: " <> path
    None -> ""
  }
  <> case repair_failure.artifacts.sanitized_payload_path {
    Some(path) -> "\nPayload repair sanitized payload: " <> path
    None -> ""
  }
  <> "\nFailure: "
  <> repair_failure.message
}

fn payload_repair_summary(
  artifacts: provider.PayloadRepairArtifacts,
) -> domain_summary.PayloadRepairSummary {
  domain_summary.PayloadRepairSummary(
    prompt_path: artifacts.prompt_path,
    log_path: artifacts.log_path,
    raw_payload_path: artifacts.raw_payload_path,
    sanitized_payload_path: artifacts.sanitized_payload_path,
  )
}

fn await_task_error_message(error: provider.AwaitTaskError) -> String {
  case error {
    provider.ProviderCommandFailed(message) -> message
    provider.PayloadExtractionFailed(message) -> message
    provider.PayloadDecodeFailed(message, _) -> message
  }
}
