import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/domain/decision_contract
import night_shift/domain/decisions as decision_domain
import night_shift/domain/plan_hygiene
import night_shift/domain/review_lineage
import night_shift/domain/summary as domain_summary
import night_shift/domain/task_graph
import night_shift/domain/task_validation
import night_shift/journal
import night_shift/provider
import night_shift/system
import night_shift/types
import simplifile

pub type LoadedPlan {
  LoadedPlan(
    tasks: List(types.Task),
    contract_warnings: List(decision_contract.ReconciliationWarning),
    retry_events: List(types.RunEvent),
  )
}

pub fn plan(run: types.RunRecord) -> Result(types.RunRecord, String) {
  plan_with_event(run, "run_planned", "Planner produced ")
}

pub fn replan(run: types.RunRecord) -> Result(types.RunRecord, String) {
  plan_with_event(run, "run_replanned", "Replanner produced ")
}

fn plan_with_event(
  run: types.RunRecord,
  event_kind: String,
  message_prefix: String,
) -> Result(types.RunRecord, String) {
  use loaded_plan <- result.try(load_planned_tasks(run, 1, None))

  let normalized_tasks = task_graph.normalize_tasks(loaded_plan.tasks)
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
  use warned_run <- result.try(append_run_events(
    rewritten_run,
    loaded_plan.retry_events,
  ))
  use reconciled_run <- result.try(append_decision_contract_events(
    warned_run,
    loaded_plan.contract_warnings,
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
) -> Result(LoadedPlan, String) {
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
                      Ok(LoadedPlan(
                        tasks: finalized_tasks,
                        contract_warnings: warnings,
                        retry_events: retry_events(attempt, retry_feedback),
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
) -> Result(LoadedPlan, String) {
  case attempt < 2 && retryable_planning_issue(message) {
    True ->
      load_planned_tasks(
        run,
        attempt + 1,
        Some(corrective_retry_feedback(message, retry_feedback)),
      )
    False -> Error(message)
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
