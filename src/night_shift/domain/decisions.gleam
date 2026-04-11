import gleam/list
import night_shift/domain/summary
import night_shift/types

pub fn apply_decision_states(
  tasks: List(types.Task),
  decisions: List(types.RecordedDecision),
) -> List(types.Task) {
  tasks
  |> list.map(fn(task) {
    case task.kind {
      types.ManualAttentionTask ->
        case types.task_requires_manual_attention(decisions, task) {
          True ->
            types.Task(
              ..task,
              state: types.ManualAttention,
              summary: summary.manual_attention_summary(task),
            )
          False ->
            types.Task(
              ..task,
              state: types.Completed,
              summary: summary.resolved_manual_attention_summary(task.summary),
            )
        }
      types.ImplementationTask -> task
    }
  })
}

pub fn decision_requesting_tasks(
  decisions: List(types.RecordedDecision),
  tasks: List(types.Task),
) -> List(types.Task) {
  tasks
  |> list.filter(fn(task) {
    types.task_requires_manual_attention(decisions, task)
  })
}

pub fn unresolved_decision_count(
  decisions: List(types.RecordedDecision),
  tasks: List(types.Task),
) -> Int {
  decision_requesting_tasks(decisions, tasks)
  |> list.map(fn(task) {
    list.length(types.unresolved_decision_requests(decisions, task))
  })
  |> list.fold(0, fn(total, count) { total + count })
}

pub fn planning_status(
  decisions: List(types.RecordedDecision),
  tasks: List(types.Task),
) -> types.RunStatus {
  case
    list.any(tasks, fn(task) {
      types.task_requires_manual_attention(decisions, task)
    })
  {
    True -> types.RunBlocked
    False -> types.RunPending
  }
}

pub fn planning_status_message(
  decisions: List(types.RecordedDecision),
  tasks: List(types.Task),
) -> String {
  let unresolved_count = unresolved_decision_count(decisions, tasks)
  case planning_status(decisions, tasks) {
    types.RunBlocked ->
      "Night Shift is awaiting manual review for "
      <> summary.pluralize(
        list.length(decision_requesting_tasks(decisions, tasks)),
        "task",
      )
      <> " across "
      <> summary.pluralize(unresolved_count, "decision")
      <> "."
    _ ->
      "Night Shift planned "
      <> summary.pluralize(list.length(tasks), "task")
      <> " and is ready to start."
  }
}

pub fn planning_event_suffix(unresolved_count: Int) -> String {
  case unresolved_count {
    0 -> ""
    _ -> " and " <> summary.pluralize(unresolved_count, "unresolved decision")
  }
}

pub fn unresolved_manual_attention_tasks(
  run: types.RunRecord,
) -> List(types.Task) {
  run.tasks
  |> list.filter(fn(task) {
    types.task_requires_manual_attention(run.decisions, task)
  })
}

pub fn outstanding_decision_count(run: types.RunRecord) -> Int {
  unresolved_manual_attention_tasks(run)
  |> list.map(types.unresolved_decision_requests(run.decisions, _))
  |> list.flatten
  |> list.length
}

pub fn blocked_task_count(run: types.RunRecord) -> Int {
  let unresolved_blockers =
    unresolved_manual_attention_tasks(run)
    |> list.length
  let implementation_blockers =
    run.tasks
    |> list.filter(fn(task) {
      task.kind == types.ImplementationTask
      && { task.state == types.Blocked || task.state == types.ManualAttention }
    })
    |> list.length
  case
    run.planning_dirty
    && unresolved_blockers == 0
    && implementation_blockers == 0
  {
    True -> 1
    False -> unresolved_blockers + implementation_blockers
  }
}

pub fn merge_recorded_decisions(
  existing: List(types.RecordedDecision),
  new_decisions: List(types.RecordedDecision),
) -> List(types.RecordedDecision) {
  case new_decisions {
    [] -> existing
    [decision, ..rest] -> {
      let filtered =
        existing
        |> list.filter(fn(current) { current.key != decision.key })
      merge_recorded_decisions(list.append(filtered, [decision]), rest)
    }
  }
}

pub fn pending_decision_prompts(
  decisions: List(types.RecordedDecision),
  tasks: List(types.Task),
) -> List(#(types.Task, types.DecisionRequest)) {
  tasks
  |> list.map(fn(task) {
    types.unresolved_decision_requests(decisions, task)
    |> list.map(fn(request) { #(task, request) })
  })
  |> list.flatten
}
