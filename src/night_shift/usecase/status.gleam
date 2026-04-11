import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import night_shift/domain/decisions as decision_domain
import night_shift/types
import night_shift/usecase/result as workflow
import night_shift/usecase/shared

pub fn execute(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(workflow.StatusResult, String) {
  use #(run, events) <- result.try(shared.load_display_run(repo_root, selector))
  Ok(workflow.StatusResult(
    run: run,
    events: events,
    summary: status_summary(run, events),
    next_action: shared.next_action_for_run(run),
  ))
}

fn status_summary(run: types.RunRecord, events: List(types.RunEvent)) -> String {
  case latest_environment_preflight_failure(events) {
    Some(message) ->
      "Environment bootstrap blocker: yes\n"
      <> "Failure: "
      <> message
      <> "\n"
      <> "Ready implementation tasks: "
      <> int.to_string(ready_implementation_task_count(run.tasks))
      <> "\n"
      <> "Queued tasks: "
      <> int.to_string(queued_task_count(run.tasks))
      <> "\n"
      <> "Next action: fix the worktree environment, then rerun `night-shift start` or `night-shift reset`"
    None ->
      case run.status {
        types.RunFailed ->
          "Completed tasks: "
          <> int.to_string(completed_task_count(run.tasks))
          <> "\n"
          <> "Opened PRs: "
          <> int.to_string(opened_pr_count(run.tasks))
          <> "\n"
          <> "Failed tasks: "
          <> int.to_string(failed_task_count(run.tasks))
          <> "\n"
          <> "Outstanding decisions: "
          <> int.to_string(decision_domain.outstanding_decision_count(run))
          <> "\n"
          <> "Queued tasks: "
          <> int.to_string(queued_task_count(run.tasks))
          <> "\n"
          <> "Failure: "
          <> latest_run_failed_message(events)
          <> "\n"
          <> "Next action: inspect the report, then rerun `night-shift plan --notes ...` when you're ready for the next pass."
        _ ->
          case run.status == types.RunBlocked || run.planning_dirty {
            True ->
              "Blocked tasks: "
              <> int.to_string(decision_domain.blocked_task_count(run))
              <> "\n"
              <> "Outstanding decisions: "
              <> int.to_string(decision_domain.outstanding_decision_count(run))
              <> "\n"
              <> "Planning sync pending: "
              <> bool_label(run.planning_dirty)
              <> "\n"
              <> "Ready implementation tasks: "
              <> int.to_string(ready_implementation_task_count(run.tasks))
              <> "\n"
              <> "Queued tasks: "
              <> int.to_string(queued_task_count(run.tasks))
              <> "\n"
              <> "Next action: "
              <> shared.next_action_for_run(run)
            False ->
              "Outstanding decisions: "
              <> int.to_string(decision_domain.outstanding_decision_count(run))
              <> "\n"
              <> "Ready tasks: "
              <> int.to_string(ready_task_count(run.tasks))
              <> "\n"
              <> "Queued tasks: "
              <> int.to_string(queued_task_count(run.tasks))
              <> "\n"
              <> "Next action: "
              <> shared.next_action_for_run(run)
          }
      }
  }
}

fn completed_task_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.state == types.Completed })
  |> list.length
}

fn opened_pr_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.pr_number != "" })
  |> list.length
}

fn failed_task_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.state == types.Failed })
  |> list.length
}

fn ready_task_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.state == types.Ready })
  |> list.length
}

fn ready_implementation_task_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) {
    task.state == types.Ready && task.kind == types.ImplementationTask
  })
  |> list.length
}

fn queued_task_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.state == types.Queued })
  |> list.length
}

fn bool_label(value: Bool) -> String {
  case value {
    True -> "yes"
    False -> "no"
  }
}

fn latest_environment_preflight_failure(
  events: List(types.RunEvent),
) -> Option(String) {
  latest_environment_preflight_failure_loop(list.reverse(events))
}

fn latest_environment_preflight_failure_loop(
  events: List(types.RunEvent),
) -> Option(String) {
  case events {
    [] -> None
    [event, ..rest] ->
      case event.kind == "environment_preflight_failed" {
        True -> Some(event.message)
        False -> latest_environment_preflight_failure_loop(rest)
      }
  }
}

fn latest_run_failed_message(events: List(types.RunEvent)) -> String {
  case latest_run_failed_message_loop(list.reverse(events)) {
    Some(message) -> message
    None -> "Night Shift stopped after an execution failure."
  }
}

fn latest_run_failed_message_loop(
  events: List(types.RunEvent),
) -> Option(String) {
  case events {
    [] -> None
    [event, ..rest] ->
      case event.kind == "run_failed" {
        True -> Some(event.message)
        False -> latest_run_failed_message_loop(rest)
      }
  }
}
