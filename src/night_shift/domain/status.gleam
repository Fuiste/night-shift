import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/domain/decisions
import night_shift/domain/summary as domain_summary
import night_shift/types

pub fn summary(
  run: types.RunRecord,
  events: List(types.RunEvent),
  next_action: String,
) -> String {
  case active_recovery_blocker(run) {
    Some(blocker) ->
      "Blocked before implementation: yes\n"
      <> "Setup recovery: "
      <> domain_summary.setup_recovery_intro(run)
      <> "\n"
      <> "Failed gate: "
      <> domain_summary.recovery_gate_label(blocker)
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
      case pending_recovery_bypass(run) {
        Some(blocker) ->
          "Retry armed: yes\n"
          <> "Setup recovery: "
          <> domain_summary.setup_recovery_intro(run)
          <> "\n"
          <> "Failed gate: "
          <> domain_summary.recovery_gate_label(blocker)
          <> "\n"
          <> "Waiver: The failed gate was waived once; `night-shift start` will retry from there.\n"
          <> "Failure: "
          <> blocker.message
          <> "\nLog: "
          <> blocker.log_path
          <> replacement_fragment(run)
          <> "\n"
          <> "Ready tasks: "
          <> int.to_string(ready_task_count(run.tasks))
          <> "\n"
          <> "Queued tasks: "
          <> int.to_string(queued_task_count(run.tasks))
          <> "\n"
          <> "Next action: "
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
                  <> int.to_string(event_count(
                    events,
                    "execution_payload_warning",
                  ))
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
                  <> int.to_string(event_count(
                    events,
                    "execution_payload_warning",
                  ))
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

fn pending_recovery_bypass(
  run: types.RunRecord,
) -> Option(types.RecoveryBlocker) {
  case run.recovery_blocker {
    Some(blocker) ->
      case blocker.disposition == types.RecoveryWaivedOnce {
        True -> Some(blocker)
        False -> None
      }
    _ -> None
  }
}

fn replacement_fragment(run: types.RunRecord) -> String {
  domain_summary.setup_recovery_outcome_lines(run)
  |> list.map(fn(line) { "\n" <> line })
  |> string.join(with: "")
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
