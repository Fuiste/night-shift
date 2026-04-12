//// Core planning and execution state machine for Night Shift runs.
////
//// This module owns the impure edges between persisted run state, provider
//// execution, verification, and task delivery.
import filepath
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/domain/decision_contract
import night_shift/domain/decisions as decision_domain
import night_shift/domain/plan_hygiene
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

/// Start executing a run from its current persisted state.
pub fn start(
  run: types.RunRecord,
  config: types.Config,
) -> Result(types.RunRecord, String) {
  continue_run(run, config)
}

/// Continue a run that may already have planned or running tasks.
pub fn continue_run(
  run: types.RunRecord,
  config: types.Config,
) -> Result(types.RunRecord, String) {
  use #(prepared_run, proceed) <- result.try(prepare_run_for_execution(run))
  case proceed {
    True -> scheduler_loop(config, prepared_run)
    False -> Ok(prepared_run)
  }
}

/// Ask the planning provider to produce the initial task graph for a run.
pub fn plan(run: types.RunRecord) -> Result(types.RunRecord, String) {
  plan_with_event(run, "run_planned", "Planner produced ")
}

/// Re-run planning after decisions or follow-up work changed the graph.
pub fn replan(run: types.RunRecord) -> Result(types.RunRecord, String) {
  plan_with_event(run, "run_replanned", "Replanner produced ")
}

fn plan_with_event(
  run: types.RunRecord,
  event_kind: String,
  message_prefix: String,
) -> Result(types.RunRecord, String) {
  use #(planned_tasks, contract_warnings, retry_events) <- result.try(
    load_planned_tasks(run, 1, None),
  )

  let normalized_tasks = task_graph.normalize_tasks(planned_tasks)
  let merged_tasks =
    task_graph.merge_planned_tasks(run.tasks, normalized_tasks)
    |> decision_domain.apply_decision_states(run.decisions)
    |> task_graph.refresh_ready_states
  let status = decision_domain.planning_status(run.decisions, merged_tasks)
  let updated_run =
    types.RunRecord(
      ..run,
      tasks: merged_tasks,
      planning_dirty: False,
      status: status,
    )
  let unresolved_count =
    decision_domain.unresolved_decision_count(run.decisions, merged_tasks)
  let plan_event =
    types.RunEvent(
      kind: event_kind,
      at: system.timestamp(),
      message: message_prefix
        <> int.to_string(list.length(normalized_tasks))
        <> " tasks"
        <> decision_domain.planning_event_suffix(unresolved_count)
        <> ".",
      task_id: None,
    )

  use rewritten_run <- result.try(journal.rewrite_run(updated_run))
  use warned_run <- result.try(append_run_events(rewritten_run, retry_events))
  use reconciled_run <- result.try(append_decision_contract_events(
    warned_run,
    contract_warnings,
  ))
  use planned_run <- result.try(journal.append_event(reconciled_run, plan_event))
  use signaled_run <- result.try(append_decision_request_events(
    planned_run,
    decision_domain.decision_requesting_tasks(run.decisions, merged_tasks),
  ))
  journal.mark_status(
    signaled_run,
    status,
    decision_domain.planning_status_message(run.decisions, merged_tasks),
  )
}

fn load_planned_tasks(
  run: types.RunRecord,
  attempt: Int,
  retry_feedback: Option(String),
) -> Result(
  #(
    List(types.Task),
    List(decision_contract.ReconciliationWarning),
    List(types.RunEvent),
  ),
  String,
) {
  let completed_tasks = task_graph.completed_tasks(run.tasks)
  case
    provider.plan_tasks_attempt(
      run.planning_agent,
      run.repo_root,
      run.brief_path,
      run.run_path,
      run.decisions,
      completed_tasks,
      attempt,
      retry_feedback,
    )
  {
    Error(message) ->
      maybe_retry_planned_tasks(run, attempt, retry_feedback, message)
    Ok(planned_tasks) ->
      case validate_planned_tasks(run, planned_tasks) {
        Ok(_) ->
          case
            decision_contract.reconcile_decision_requests(
              run.decisions,
              planned_tasks,
            )
          {
            Ok(#(reconciled_tasks, warnings)) ->
              case plan_hygiene.normalize_planned_tasks(reconciled_tasks) {
                Ok(normalized_tasks) ->
                  Ok(#(
                    normalized_tasks,
                    warnings,
                    retry_events(attempt, retry_feedback),
                  ))
                // Give the planner one corrective retry when the shape is close
                // enough to explain what invariant it violated.
                Error(message) ->
                  maybe_retry_planned_tasks(
                    run,
                    attempt,
                    retry_feedback,
                    message,
                  )
              }
            Error(message) ->
              maybe_retry_planned_tasks(run, attempt, retry_feedback, message)
          }
        Error(issues) -> {
          let message = domain_summary.planning_validation_summary(issues)
          case attempt < 2 && retryable_planning_issue(message) {
            True ->
              // Feed validation failures back into the next attempt so the
              // planner can repair the task graph without losing prior context.
              load_planned_tasks(
                run,
                attempt + 1,
                Some(corrective_retry_feedback(message, retry_feedback)),
              )
            False -> {
              use _ <- result.try(reject_invalid_plan(run, issues))
              Error(message)
            }
          }
        }
      }
  }
}

fn maybe_retry_planned_tasks(
  run: types.RunRecord,
  attempt: Int,
  retry_feedback: Option(String),
  message: String,
) -> Result(
  #(
    List(types.Task),
    List(decision_contract.ReconciliationWarning),
    List(types.RunEvent),
  ),
  String,
) {
  case attempt < 2 && retryable_planning_issue(message) {
    True ->
      // Retrying only once keeps the state machine predictable while still
      // letting providers self-correct common contract mistakes.
      load_planned_tasks(
        run,
        attempt + 1,
        Some(corrective_retry_feedback(message, retry_feedback)),
      )
    False -> Error(message)
  }
}

fn prepare_run_for_execution(
  run: types.RunRecord,
) -> Result(#(types.RunRecord, Bool), String) {
  let refreshed_run =
    types.RunRecord(..run, tasks: task_graph.refresh_ready_states(run.tasks))

  case run_state.has_blocking_attention(refreshed_run.tasks) {
    True ->
      append_manual_attention_events(refreshed_run)
      |> result.map(fn(updated_run) { #(updated_run, True) })
    False ->
      case
        task_graph.next_batch(refreshed_run.tasks, refreshed_run.max_workers)
      {
        [] -> Ok(#(refreshed_run, True))
        [task, ..] if task.kind == types.ManualAttentionTask ->
          append_manual_attention_events(refreshed_run)
          |> result.map(fn(updated_run) { #(updated_run, True) })
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
            Ok(_) -> Ok(#(refreshed_run, True))
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
              Ok(#(marked_run, False))
            }
          }
        }
      }
  }
}

fn scheduler_loop(
  config: types.Config,
  run: types.RunRecord,
) -> Result(types.RunRecord, String) {
  let refreshed_run =
    types.RunRecord(..run, tasks: task_graph.refresh_ready_states(run.tasks))
  case run_state.has_blocking_attention(refreshed_run.tasks) {
    True -> finish_run(refreshed_run)
    False -> {
      let batch =
        task_graph.next_batch(refreshed_run.tasks, refreshed_run.max_workers)

      case batch {
        [] -> finish_run(refreshed_run)
        _ -> {
          use #(running_run, task_runs) <- result.try(launch_batch(
            config,
            refreshed_run,
            batch,
          ))
          use completed_run <- result.try(await_batch(
            config,
            running_run,
            task_runs,
          ))
          scheduler_loop(config, completed_run)
        }
      }
    }
  }
}

fn finish_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  let status = run_state.final_status(run.tasks)
  let message = case status {
    types.RunCompleted -> "Night Shift completed all queued work."
    types.RunFailed -> "Night Shift encountered failed tasks."
    types.RunBlocked -> domain_summary.blocked_run_message(run.tasks)
    _ -> "Night Shift stopped."
  }

  journal.mark_status(run, status, message)
}

fn launch_batch(
  config: types.Config,
  run: types.RunRecord,
  tasks: List(types.Task),
) -> Result(#(types.RunRecord, List(provider.TaskRun)), String) {
  launch_batch_loop(config, run, tasks, [])
}

fn launch_batch_loop(
  config: types.Config,
  run: types.RunRecord,
  tasks: List(types.Task),
  acc: List(provider.TaskRun),
) -> Result(#(types.RunRecord, List(provider.TaskRun)), String) {
  case tasks {
    [] -> Ok(#(run, list.reverse(acc)))
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
          Ok(#(blocked_run, list.reverse(acc)))
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

fn await_batch(
  config: types.Config,
  run: types.RunRecord,
  task_runs: List(provider.TaskRun),
) -> Result(types.RunRecord, String) {
  case task_runs {
    [] -> Ok(run)
    [task_run, ..rest] -> {
      let next_run_result = case provider.await_task_detailed(task_run) {
        Ok(execution_result) ->
          case complete_task(config, run, task_run, execution_result) {
            Ok(updated_run) -> Ok(updated_run)
            Error(message) ->
              mark_task_with_event(
                run,
                task_run.task,
                types.Failed,
                domain_summary.completion_failure_summary(message),
                "task_failed",
              )
          }
        Error(error) -> handle_await_task_error(run, task_run, error)
      }

      use updated_run <- result.try(next_run_result)
      await_batch(config, updated_run, rest)
    }
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

fn append_decision_request_events(
  run: types.RunRecord,
  tasks: List(types.Task),
) -> Result(types.RunRecord, String) {
  case tasks {
    [] -> Ok(run)
    [task, ..rest] -> {
      let requests = types.unresolved_decision_requests(run.decisions, task)
      let message = case requests {
        [] -> task.description
        unresolved_requests ->
          unresolved_requests
          |> list.map(fn(request) { request.question })
          |> string.join(with: " | ")
      }
      use updated_run <- result.try(journal.append_event(
        run,
        types.RunEvent(
          kind: "decision_requested",
          at: system.timestamp(),
          message: message,
          task_id: Some(task.id),
        ),
      ))
      append_decision_request_events(updated_run, rest)
    }
  }
}

fn append_run_events(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> Result(types.RunRecord, String) {
  case events {
    [] -> Ok(run)
    [event, ..rest] -> {
      use updated_run <- result.try(journal.append_event(run, event))
      append_run_events(updated_run, rest)
    }
  }
}

fn append_decision_contract_events(
  run: types.RunRecord,
  warnings: List(decision_contract.ReconciliationWarning),
) -> Result(types.RunRecord, String) {
  case warnings {
    [] -> Ok(run)
    [warning, ..rest] -> {
      use updated_run <- result.try(journal.append_event(
        run,
        types.RunEvent(
          kind: "decision_contract_warning",
          at: system.timestamp(),
          message: "Reused recorded decision key `"
            <> warning.new_key
            <> "` for planner request `"
            <> warning.previous_key
            <> "` ("
            <> warning.question
            <> ").",
          task_id: Some(warning.task_id),
        ),
      ))
      append_decision_contract_events(updated_run, rest)
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

fn validate_planned_tasks(
  run: types.RunRecord,
  planned_tasks: List(types.Task),
) -> Result(Nil, List(task_validation.ValidationIssue)) {
  case
    task_validation.validate_planned_tasks(
      task_graph.completed_tasks(run.tasks),
      planned_tasks,
    )
  {
    Ok(_) -> Ok(Nil)
    Error(issues) -> Error(issues)
  }
}

fn reject_invalid_plan(
  run: types.RunRecord,
  issues: List(task_validation.ValidationIssue),
) -> Result(Nil, String) {
  let message = domain_summary.planning_validation_summary(issues)
  use _ <- result.try(journal.append_event(
    run,
    types.RunEvent(
      kind: "planning_validation_failed",
      at: system.timestamp(),
      message: message,
      task_id: None,
    ),
  ))
  Error(message)
}

fn retry_events(
  attempt: Int,
  retry_feedback: Option(String),
) -> List(types.RunEvent) {
  case attempt, retry_feedback {
    1, _ -> []
    _, Some(feedback) -> [
      types.RunEvent(
        kind: "planning_retry",
        at: system.timestamp(),
        message: feedback,
        task_id: None,
      ),
    ]
    _, None -> []
  }
}

fn retryable_planning_issue(message: String) -> Bool {
  let lowered = string.lowercase(message)
  string.contains(does: lowered, contain: "start marker")
  || string.contains(does: lowered, contain: "end marker")
  || string.contains(does: lowered, contain: "unable to decode")
  || string.contains(does: lowered, contain: "fragmented tiny plan")
  || string.contains(does: lowered, contain: "reuse the recorded decision key")
  || string.contains(does: lowered, contain: "dependencies")
}

fn corrective_retry_feedback(
  message: String,
  prior_feedback: Option(String),
) -> String {
  let prefix = case prior_feedback {
    Some(existing) -> existing <> "\n\n"
    None -> ""
  }

  prefix
  <> "The previous planning attempt failed because:\n"
  <> message
  <> "\nRetry once. Return only a valid Night Shift plan between the sentinel markers, reuse prior decision keys when they still apply, and keep tiny docs-only work to the minimum meaningful number of implementation tasks."
}

fn handle_await_task_error(
  run: types.RunRecord,
  task_run: provider.TaskRun,
  error: provider.AwaitTaskError,
) -> Result(types.RunRecord, String) {
  case error {
    provider.PayloadDecodeFailed(message, artifacts) ->
      case task_run_has_candidate_changes(run, task_run) {
        True ->
          mark_task_with_event(
            run,
            task_run.task,
            types.ManualAttention,
            domain_summary.decode_manual_attention_summary(
              task_run.task,
              task_run.log_path,
              artifacts.raw_payload_path,
              artifacts.sanitized_payload_path,
            ),
            "task_manual_attention",
          )
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

fn await_task_error_message(error: provider.AwaitTaskError) -> String {
  case error {
    provider.ProviderCommandFailed(message) -> message
    provider.PayloadExtractionFailed(message) -> message
    provider.PayloadDecodeFailed(message, _) -> message
  }
}
