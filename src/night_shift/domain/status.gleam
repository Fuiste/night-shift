import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/domain/decisions
import night_shift/types

pub fn summary(
  run: types.RunRecord,
  events: List(types.RunEvent),
  next_action: String,
) -> String {
  case active_recovery_blocker(run) {
    Some(blocker) ->
      "Blocked before implementation: yes\n"
      <> "Failed gate: "
      <> types.recovery_blocker_phase_to_string(blocker.phase)
      <> " "
      <> types.recovery_blocker_kind_to_string(blocker.kind)
      <> "\n"
      <> "Failure: "
      <> blocker.message
      <> "\nLog: "
      <> blocker.log_path
      <> replacement_fragment(run)
      <> "\n"
      <> "Ready implementation tasks: "
      <> int.to_string(ready_implementation_task_count(run.tasks))
      <> "\n"
      <> "Queued tasks: "
      <> int.to_string(queued_task_count(run.tasks))
      <> "\n"
      <> "\nNext action: "
      <> next_action
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
          <> int.to_string(decisions.outstanding_decision_count(run))
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
              <> int.to_string(decisions.blocked_task_count(run))
              <> "\n"
              <> "Outstanding decisions: "
              <> int.to_string(decisions.outstanding_decision_count(run))
              <> "\n"
              <> "Planning sync pending: "
              <> bool_label(run.planning_dirty)
              <> planning_validation_fragment(events)
              <> "\n"
              <> "Retained worktrees: "
              <> int.to_string(retained_worktree_count(run.tasks))
              <> "\n"
              <> "Runtime identities: "
              <> int.to_string(runtime_identity_count(run.tasks))
              <> "\n"
              <> "Pruned superseded worktrees: "
              <> int.to_string(event_count(events, "worktree_pruned"))
              <> "\n"
              <> "Execution recovery warnings: "
              <> int.to_string(event_count(events, "execution_payload_warning"))
              <> "\n"
              <> "Payload repair attempts: "
              <> int.to_string(event_count(
                events,
                "execution_payload_repair_started",
              ))
              <> "\n"
              <> "Payload repair successes: "
              <> int.to_string(event_count(
                events,
                "execution_payload_repair_succeeded",
              ))
              <> "\n"
              <> "Payload repair failures: "
              <> int.to_string(event_count(
                events,
                "execution_payload_repair_failed",
              ))
              <> "\n"
              <> "Ready implementation tasks: "
              <> int.to_string(ready_implementation_task_count(run.tasks))
              <> "\n"
              <> "Queued tasks: "
              <> int.to_string(queued_task_count(run.tasks))
              <> "\n"
              <> "Next action: "
              <> next_action
            False ->
              "Outstanding decisions: "
              <> int.to_string(decisions.outstanding_decision_count(run))
              <> "\n"
              <> "Retained worktrees: "
              <> int.to_string(retained_worktree_count(run.tasks))
              <> "\n"
              <> "Runtime identities: "
              <> int.to_string(runtime_identity_count(run.tasks))
              <> "\n"
              <> "Pruned superseded worktrees: "
              <> int.to_string(event_count(events, "worktree_pruned"))
              <> "\n"
              <> "Execution recovery warnings: "
              <> int.to_string(event_count(events, "execution_payload_warning"))
              <> "\n"
              <> "Payload repair attempts: "
              <> int.to_string(event_count(
                events,
                "execution_payload_repair_started",
              ))
              <> "\n"
              <> "Payload repair successes: "
              <> int.to_string(event_count(
                events,
                "execution_payload_repair_succeeded",
              ))
              <> "\n"
              <> "Payload repair failures: "
              <> int.to_string(event_count(
                events,
                "execution_payload_repair_failed",
              ))
              <> "\n"
              <> "Ready tasks: "
              <> int.to_string(ready_task_count(run.tasks))
              <> "\n"
              <> "Queued tasks: "
              <> int.to_string(queued_task_count(run.tasks))
              <> "\n"
              <> "Next action: "
              <> next_action
          }
      }
  }
}

fn active_recovery_blocker(
  run: types.RunRecord,
) -> Option(types.RecoveryBlocker) {
  case run.recovery_blocker {
    Some(blocker) ->
      case blocker.disposition == types.RecoveryBlocking {
        True -> Some(blocker)
        False -> None
      }
    _ -> None
  }
}

fn replacement_fragment(run: types.RunRecord) -> String {
  let pr_numbers =
    run.tasks
    |> list.flat_map(fn(task) { task.superseded_pr_numbers })
    |> unique_pr_numbers([])
  case pr_numbers {
    [] -> "\nNo new commits or PR updates were produced yet."
    _ ->
      "\nIntended replacement PRs remain pending: #"
      <> string.join(pr_numbers |> list.map(int.to_string), with: ", #")
      <> "\nExisting reviewed PRs remain unchanged until replacement delivery succeeds."
  }
}

fn unique_pr_numbers(values: List(Int), acc: List(Int)) -> List(Int) {
  case values {
    [] -> list.reverse(acc)
    [value, ..rest] ->
      case list.contains(acc, value) {
        True -> unique_pr_numbers(rest, acc)
        False -> unique_pr_numbers(rest, [value, ..acc])
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

fn retained_worktree_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.worktree_path != "" })
  |> list.length
}

fn runtime_identity_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.runtime_context != None })
  |> list.length
}

fn bool_label(value: Bool) -> String {
  case value {
    True -> "yes"
    False -> "no"
  }
}

fn latest_run_failed_message(events: List(types.RunEvent)) -> String {
  case latest_run_failed_message_loop(list.reverse(events)) {
    Some(message) -> message
    None -> "Night Shift stopped after an execution failure."
  }
}

fn planning_validation_fragment(events: List(types.RunEvent)) -> String {
  case latest_event_message(events, "planning_validation_failed") {
    Some(message) -> "\nPlanning validation: " <> message
    None -> ""
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

fn latest_event_message(
  events: List(types.RunEvent),
  kind: String,
) -> Option(String) {
  latest_event_message_loop(list.reverse(events), kind)
}

fn latest_event_message_loop(
  events: List(types.RunEvent),
  kind: String,
) -> Option(String) {
  case events {
    [] -> None
    [event, ..rest] ->
      case event.kind == kind {
        True -> Some(event.message)
        False -> latest_event_message_loop(rest, kind)
      }
  }
}

fn event_count(events: List(types.RunEvent), kind: String) -> Int {
  events
  |> list.filter(fn(event) { event.kind == kind })
  |> list.length
}
