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
import night_shift/domain/review_lineage
import night_shift/domain/run_state
import night_shift/domain/summary as domain_summary
import night_shift/domain/task_graph
import night_shift/domain/task_validation
import night_shift/git
import night_shift/github
import night_shift/infra/task_delivery
import night_shift/infra/task_verifier
import night_shift/journal
import night_shift/project
import night_shift/provider
import night_shift/system
import night_shift/types
import night_shift/worktree_setup
import night_shift/worktree_setup_model
import simplifile

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
      run.repo_state_snapshot,
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
                  case finalize_planned_tasks(run, normalized_tasks) {
                    Ok(finalized_tasks) ->
                      Ok(#(
                        finalized_tasks,
                        warnings,
                        retry_events(attempt, retry_feedback),
                      ))
                    Error(issues) -> {
                      let message =
                        domain_summary.planning_validation_summary(issues)
                      case attempt < 2 && retryable_planning_issue(message) {
                        True ->
                          load_planned_tasks(
                            run,
                            attempt + 1,
                            Some(corrective_retry_feedback(
                              message,
                              retry_feedback,
                            )),
                          )
                        False -> {
                          use _ <- result.try(reject_invalid_plan(run, issues))
                          Error(message)
                        }
                      }
                    }
                  }
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

  use finalized_run <- result.try(journal.mark_status(run, status, message))
  case status {
    types.RunCompleted -> finalize_review_supersessions(finalized_run)
    _ -> Ok(finalized_run)
  }
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
        Error(error) -> handle_await_task_error(run, task_run, error)
      }

      use updated_run <- result.try(next_run_result)
      await_batch(config, updated_run, rest)
    }
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

fn finalize_planned_tasks(
  run: types.RunRecord,
  planned_tasks: List(types.Task),
) -> Result(List(types.Task), List(task_validation.ValidationIssue)) {
  use brief_contents <- result.try(load_brief_for_validation(run.brief_path))
  use _ <- result.try(task_validation.validate_explicit_serial_requirements(
    brief_contents,
    planned_tasks,
  ))
  derive_review_lineage_if_needed(run, planned_tasks)
}

fn load_brief_for_validation(
  brief_path: String,
) -> Result(String, List(task_validation.ValidationIssue)) {
  case simplifile.read(brief_path) {
    Ok(contents) -> Ok(contents)
    Error(error) ->
      Error([
        task_validation.UnreadablePlanningBrief(
          path: brief_path,
          reason: simplifile.describe_error(error),
        ),
      ])
  }
}

fn derive_review_lineage_if_needed(
  run: types.RunRecord,
  planned_tasks: List(types.Task),
) -> Result(List(types.Task), List(task_validation.ValidationIssue)) {
  case run.planning_provenance {
    Some(provenance) ->
      case types.planning_provenance_uses_reviews(provenance) {
        True ->
          case run.repo_state_snapshot {
            Some(snapshot) ->
              review_lineage.derive_superseded_pr_numbers(
                snapshot,
                planned_tasks,
              )
              |> result.map_error(fn(message) {
                [task_validation.ReviewSupersessionMappingMismatch(message)]
              })
            None ->
              Error([
                task_validation.ReviewSupersessionMappingMismatch(
                  "Review-driven replacement planning requires a repo-state snapshot.",
                ),
              ])
          }
        False -> Ok(planned_tasks)
      }
    None -> Ok(planned_tasks)
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
  || string.contains(does: lowered, contain: "strict serial")
  || string.contains(does: lowered, contain: "exactly ")
  || string.contains(does: lowered, contain: "superseded pull request")
  || string.contains(does: lowered, contain: "impacted pr subtree shape")
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
  <> "\nRetry once. Return only a valid Night Shift plan between the sentinel markers, reuse prior decision keys when they still apply, keep tiny docs-only work to the minimum meaningful number of implementation tasks, respect any explicit strict serial chain requirements, and leave superseded_pr_numbers empty because Night Shift derives review lineage after planning."
}

fn finalize_review_supersessions(
  run: types.RunRecord,
) -> Result(types.RunRecord, String) {
  case run.planning_provenance {
    Some(provenance) ->
      case types.planning_provenance_uses_reviews(provenance) {
        True -> {
          let mappings = collect_superseded_replacements(run.tasks)
          use superseded_run <- result.try(close_superseded_pull_requests(
            run,
            mappings,
          ))
          prune_superseded_successful_worktrees(
            superseded_run,
            collect_superseded_pr_numbers(mappings),
          )
        }
        False -> Ok(run)
      }
    None -> Ok(run)
  }
}

fn collect_superseded_replacements(
  tasks: List(types.Task),
) -> List(#(Int, List(Int))) {
  tasks
  |> list.fold([], fn(acc, task) {
    case task.state == types.Completed, parse_pr_number(task.pr_number) {
      True, Ok(replacement_pr_number) ->
        task.superseded_pr_numbers
        |> list.fold(acc, fn(acc, superseded_pr_number) {
          record_superseded_replacement(
            acc,
            superseded_pr_number,
            replacement_pr_number,
          )
        })
      _, _ -> acc
    }
  })
}

fn record_superseded_replacement(
  mappings: List(#(Int, List(Int))),
  superseded_pr_number: Int,
  replacement_pr_number: Int,
) -> List(#(Int, List(Int))) {
  case mappings {
    [] -> [#(superseded_pr_number, [replacement_pr_number])]
    [#(existing_pr_number, replacements), ..rest] ->
      case existing_pr_number == superseded_pr_number {
        True -> [
          #(
            existing_pr_number,
            append_unique_int(replacements, replacement_pr_number),
          ),
          ..rest
        ]
        False -> [
          #(existing_pr_number, replacements),
          ..record_superseded_replacement(
            rest,
            superseded_pr_number,
            replacement_pr_number,
          )
        ]
      }
  }
}

fn close_superseded_pull_requests(
  run: types.RunRecord,
  mappings: List(#(Int, List(Int))),
) -> Result(types.RunRecord, String) {
  case mappings {
    [] -> Ok(run)
    [#(superseded_pr_number, replacement_pr_numbers), ..rest] -> {
      let log_path =
        filepath.join(
          run.run_path,
          "logs/review-supersession-"
            <> int.to_string(superseded_pr_number)
            <> ".log",
        )
      let replacement_summary = render_pr_numbers(replacement_pr_numbers)
      let event = case
        github.mark_pull_request_superseded(
          run.repo_root,
          superseded_pr_number,
          replacement_pr_numbers,
          log_path,
        )
      {
        Ok(_) ->
          types.RunEvent(
            kind: "pr_superseded",
            at: system.timestamp(),
            message: "Closed superseded PR #"
              <> int.to_string(superseded_pr_number)
              <> " after opening replacement PRs "
              <> replacement_summary
              <> ".",
            task_id: None,
          )
        Error(message) ->
          types.RunEvent(
            kind: "review_supersession_warning",
            at: system.timestamp(),
            message: "Replacement PRs "
              <> replacement_summary
              <> " were created, but Night Shift could not close superseded PR #"
              <> int.to_string(superseded_pr_number)
              <> ": "
              <> message,
            task_id: None,
          )
      }
      use updated_run <- result.try(journal.append_event(run, event))
      close_superseded_pull_requests(updated_run, rest)
    }
  }
}

fn append_unique_int(values: List(Int), candidate: Int) -> List(Int) {
  case list.contains(values, candidate) {
    True -> values
    False -> list.append(values, [candidate])
  }
}

fn parse_pr_number(pr_number: String) -> Result(Int, Nil) {
  int.parse(pr_number)
}

fn render_pr_numbers(pr_numbers: List(Int)) -> String {
  pr_numbers
  |> list.map(fn(pr_number) { "#" <> int.to_string(pr_number) })
  |> string.join(with: ", ")
}

fn collect_superseded_pr_numbers(mappings: List(#(Int, List(Int)))) -> List(Int) {
  mappings
  |> list.map(fn(mapping) { mapping.0 })
}

fn prune_superseded_successful_worktrees(
  run: types.RunRecord,
  superseded_pr_numbers: List(Int),
) -> Result(types.RunRecord, String) {
  case superseded_pr_numbers {
    [] -> Ok(run)
    _ ->
      case journal.list_runs(run.repo_root) {
        Ok(prior_runs) -> {
          let candidates =
            prior_runs
            |> list.filter(fn(candidate) {
              run_is_prune_candidate(run, candidate, superseded_pr_numbers)
            })
          use #(pruned_run, pruned_any) <- result.try(prune_candidate_runs(
            run,
            candidates,
          ))
          case pruned_any {
            True ->
              finalize_worktree_prune_metadata(
                pruned_run,
                filepath.join(pruned_run.run_path, "logs/worktree-prune.log"),
              )
            False -> Ok(pruned_run)
          }
        }
        Error(message) ->
          append_worktree_prune_warning(
            run,
            "Night Shift completed review supersession cleanup, but could not inspect prior runs for safe worktree pruning: "
              <> message,
          )
      }
  }
}

fn run_is_prune_candidate(
  current_run: types.RunRecord,
  candidate: types.RunRecord,
  superseded_pr_numbers: List(Int),
) -> Bool {
  candidate.run_id != current_run.run_id
  && candidate.status == types.RunCompleted
  && run_pr_numbers_fully_superseded(candidate, superseded_pr_numbers)
}

fn run_pr_numbers_fully_superseded(
  run: types.RunRecord,
  superseded_pr_numbers: List(Int),
) -> Bool {
  let candidate_pr_numbers =
    run.tasks
    |> list.filter_map(fn(task) {
      case task.state == types.Completed && task.worktree_path != "" {
        True ->
          case parse_pr_number(task.pr_number) {
            Ok(pr_number) -> Ok(pr_number)
            Error(_) -> Error(Nil)
          }
        False -> Error(Nil)
      }
    })

  case candidate_pr_numbers {
    [] -> False
    _ ->
      list.all(candidate_pr_numbers, fn(pr_number) {
        list.contains(superseded_pr_numbers, pr_number)
      })
  }
}

fn prune_candidate_runs(
  run: types.RunRecord,
  candidates: List(types.RunRecord),
) -> Result(#(types.RunRecord, Bool), String) {
  case candidates {
    [] -> Ok(#(run, False))
    [candidate, ..rest] -> {
      use #(updated_run, candidate_pruned) <- result.try(prune_run_worktrees(
        run,
        candidate,
      ))
      use #(final_run, rest_pruned) <- result.try(prune_candidate_runs(
        updated_run,
        rest,
      ))
      Ok(#(final_run, candidate_pruned || rest_pruned))
    }
  }
}

fn prune_run_worktrees(
  run: types.RunRecord,
  candidate: types.RunRecord,
) -> Result(#(types.RunRecord, Bool), String) {
  prune_run_worktrees_loop(run, candidate, candidate.tasks, False)
}

fn prune_run_worktrees_loop(
  run: types.RunRecord,
  candidate: types.RunRecord,
  tasks: List(types.Task),
  pruned_any: Bool,
) -> Result(#(types.RunRecord, Bool), String) {
  case tasks {
    [] -> Ok(#(run, pruned_any))
    [task, ..rest] -> {
      use #(updated_run, task_pruned) <- result.try(prune_worktree_if_safe(
        run,
        candidate,
        task,
      ))
      prune_run_worktrees_loop(
        updated_run,
        candidate,
        rest,
        pruned_any || task_pruned,
      )
    }
  }
}

fn prune_worktree_if_safe(
  run: types.RunRecord,
  candidate: types.RunRecord,
  task: types.Task,
) -> Result(#(types.RunRecord, Bool), String) {
  case task.worktree_path {
    "" -> Ok(#(run, False))
    worktree_path -> {
      let log_path =
        filepath.join(
          run.run_path,
          "logs/worktree-prune-" <> candidate.run_id <> "-" <> task.id <> ".log",
        )
      case simplifile.read_directory(at: worktree_path) {
        Error(_) ->
          append_worktree_prune_warning(
            run,
            "Night Shift skipped pruning superseded worktree for run "
              <> candidate.run_id
              <> " task "
              <> task.id
              <> " because the path no longer exists: "
              <> worktree_path,
          )
          |> result.map(fn(updated_run) { #(updated_run, False) })
        Ok(_) ->
          case git.has_changes(worktree_path, log_path) {
            True ->
              append_worktree_prune_warning(
                run,
                "Night Shift retained superseded worktree for run "
                  <> candidate.run_id
                  <> " task "
                  <> task.id
                  <> " because it still has local changes: "
                  <> worktree_path,
              )
              |> result.map(fn(updated_run) { #(updated_run, False) })
            False ->
              case git.remove_worktree(run.repo_root, worktree_path, log_path) {
                Ok(_) ->
                  journal.append_event(
                    run,
                    types.RunEvent(
                      kind: "worktree_pruned",
                      at: system.timestamp(),
                      message: "Pruned clean superseded worktree for run "
                        <> candidate.run_id
                        <> " task "
                        <> task.id
                        <> " at "
                        <> worktree_path
                        <> ".",
                      task_id: None,
                    ),
                  )
                  |> result.map(fn(updated_run) { #(updated_run, True) })
                Error(message) ->
                  append_worktree_prune_warning(
                    run,
                    "Night Shift could not prune superseded worktree for run "
                      <> candidate.run_id
                      <> " task "
                      <> task.id
                      <> ": "
                      <> message,
                  )
                  |> result.map(fn(updated_run) { #(updated_run, False) })
              }
          }
      }
    }
  }
}

fn finalize_worktree_prune_metadata(
  run: types.RunRecord,
  log_path: String,
) -> Result(types.RunRecord, String) {
  case git.prune_worktrees(run.repo_root, log_path) {
    Ok(_) -> Ok(run)
    Error(message) ->
      append_worktree_prune_warning(
        run,
        "Night Shift pruned clean superseded worktrees, but `git worktree prune` reported a warning: "
          <> message,
      )
  }
}

fn append_worktree_prune_warning(
  run: types.RunRecord,
  message: String,
) -> Result(types.RunRecord, String) {
  journal.append_event(
    run,
    types.RunEvent(
      kind: "worktree_prune_warning",
      at: system.timestamp(),
      message: message,
      task_id: None,
    ),
  )
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
