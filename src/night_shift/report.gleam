import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/agent_config
import night_shift/types

pub fn render(run: types.RunRecord, events: List(types.RunEvent)) -> String {
  [
    "# Night Shift Report",
    "",
    "## Run",
    "- Run ID: " <> run.run_id,
    "- Status: " <> types.run_status_to_string(run.status),
    "- Repo: " <> run.repo_root,
    "- Planning: " <> agent_config.summary(run.planning_agent),
    "- Execution: " <> agent_config.summary(run.execution_agent),
    "- Environment: " <> render_environment_label(run.environment_name),
    "- Max workers: " <> int.to_string(run.max_workers),
    "- Planning sync pending: " <> render_bool(run.planning_dirty),
    "- Created at: " <> run.created_at,
    "- Updated at: " <> run.updated_at,
    "- Brief: " <> run.brief_path,
    "",
    "## Summary",
    render_summary(run.decisions, run.planning_dirty, run.tasks, events),
    render_failure_summary(run, events),
    "",
    "## Tasks",
    render_tasks(run.decisions, run.planning_dirty, run.tasks),
    "",
    "## Timeline",
    render_events(events),
  ]
  |> string.join(with: "\n")
}

fn render_summary(
  decisions: List(types.RecordedDecision),
  planning_dirty: Bool,
  tasks: List(types.Task),
  events: List(types.RunEvent),
) -> String {
  let completed_count =
    tasks
    |> list.filter(fn(task) { task.state == types.Completed })
    |> list.length
  let pr_count =
    tasks
    |> list.filter(fn(task) { task.pr_number != "" })
    |> list.length
  let manual_attention_count =
    tasks
    |> list.filter(fn(task) { task_requires_manual_attention(decisions, task) })
    |> list.length
  let blocked_count =
    tasks
    |> list.filter(fn(task) {
      task.kind == types.ImplementationTask && task.state == types.Blocked
    })
    |> list.length
  let derived_blocked_count = case planning_dirty && manual_attention_count == 0 && blocked_count == 0 {
    True -> 1
    False -> manual_attention_count + blocked_count
  }
  let failed_count =
    tasks
    |> list.filter(fn(task) { task.state == types.Failed })
    |> list.length
  let run_level_failure_count = case latest_environment_preflight_failure(events) {
    Some(_) -> 1
    None -> 0
  }
  let queued_count =
    tasks
    |> list.filter(fn(task) {
      task.state == types.Queued
      || {
        task.state == types.Ready && task.kind == types.ImplementationTask
      }
    })
    |> list.length
  let outstanding_decisions =
    tasks
    |> list.filter(fn(task) { types.task_requires_manual_attention(decisions, task) })
    |> list.map(fn(task) { list.length(types.unresolved_decision_requests(decisions, task)) })
    |> list.fold(0, fn(total, count) { total + count })

  [
    "- Completed tasks: " <> int.to_string(completed_count),
    "- Opened PRs: " <> int.to_string(pr_count),
    "- Blocked tasks: " <> int.to_string(derived_blocked_count),
    "- Manual-attention tasks: " <> int.to_string(manual_attention_count),
    "- Outstanding decisions: " <> int.to_string(outstanding_decisions),
    "- Run-level failures: " <> int.to_string(run_level_failure_count),
    "- Failed tasks: " <> int.to_string(failed_count),
    "- Queued tasks: " <> int.to_string(queued_count),
  ]
  |> string.join(with: "\n")
}

fn render_tasks(
  decisions: List(types.RecordedDecision),
  planning_dirty: Bool,
  tasks: List(types.Task),
) -> String {
  case tasks {
    [] -> "- No tasks have been planned yet."
    _ ->
      tasks
      |> list.map(render_task(decisions, planning_dirty, _))
      |> string.join(with: "\n")
  }
}

fn render_task(
  decisions: List(types.RecordedDecision),
  planning_dirty: Bool,
  task: types.Task,
) -> String {
  "- ["
  <> types.task_state_to_string(render_task_state(decisions, planning_dirty, task))
  <> "] "
  <> task.id
  <> ": "
  <> task.title
  <> render_task_details(decisions, planning_dirty, task)
}

fn render_events(events: List(types.RunEvent)) -> String {
  case events {
    [] -> "- No events recorded yet."
    _ ->
      events
      |> list.map(render_event)
      |> string.join(with: "\n")
  }
}

fn render_event(event: types.RunEvent) -> String {
  let task_label = case event.task_id {
    Some(task_id) -> " (" <> task_id <> ")"
    None -> ""
  }

  "- "
  <> event.at
  <> " `"
  <> event.kind
  <> "`"
  <> task_label
  <> " "
  <> event.message
}

fn render_task_details(
  decisions: List(types.RecordedDecision),
  planning_dirty: Bool,
  task: types.Task,
) -> String {
  let pr_fragment = case task.pr_number {
    "" -> ""
    pr_number -> " (PR #" <> pr_number <> ")"
  }

  let decision_fragment = case types.task_requires_manual_attention(decisions, task) {
    True ->
      "\n  Outstanding decisions:\n"
      <> {
        types.unresolved_decision_requests(decisions, task)
        |> list.map(fn(request) { "  - " <> request.question })
        |> string.join(with: "\n")
      }
    False -> ""
  }

  let planning_fragment = case task.kind == types.ManualAttentionTask && planning_dirty {
    True ->
      case types.task_requires_manual_attention(decisions, task) {
        True -> ""
        False -> "\n  Decision recorded; Night Shift still needs to replan this run."
      }
    False -> ""
  }

  let summary_fragment = case string.trim(task.summary) {
    "" -> ""
    summary -> "\n  " <> string.replace(in: summary, each: "\n", with: "\n  ")
  }

  pr_fragment <> decision_fragment <> planning_fragment <> summary_fragment
}

fn render_task_state(
  decisions: List(types.RecordedDecision),
  planning_dirty: Bool,
  task: types.Task,
) -> types.TaskState {
  case types.task_requires_manual_attention(decisions, task) {
    True -> types.ManualAttention
    False ->
      case task.state == types.ManualAttention {
        True -> types.ManualAttention
        False ->
          case task.kind == types.ManualAttentionTask && planning_dirty {
            True -> types.Blocked
            False -> task.state
          }
      }
  }
}

fn render_environment_label(environment_name: String) -> String {
  case environment_name {
    "" -> "(none)"
    value -> value
  }
}

fn render_bool(value: Bool) -> String {
  case value {
    True -> "yes"
    False -> "no"
  }
}

fn render_failure_summary(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> String {
  case latest_environment_preflight_failure(events) {
    Some(message) ->
      "\n## Failure\n- Type: environment bootstrap\n- Details: " <> message
    None ->
      case run.status, latest_run_failed_message(events) {
        types.RunFailed, Some(message) ->
          "\n## Failure\n- Type: "
          <> run_failure_type(run.tasks)
          <> "\n- Details: "
          <> message
        _, _ -> ""
      }
  }
}

fn task_requires_manual_attention(
  decisions: List(types.RecordedDecision),
  task: types.Task,
) -> Bool {
  task.state == types.ManualAttention
  || types.task_requires_manual_attention(decisions, task)
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

fn latest_run_failed_message(events: List(types.RunEvent)) -> Option(String) {
  latest_run_failed_message_loop(list.reverse(events))
}

fn latest_run_failed_message_loop(events: List(types.RunEvent)) -> Option(String) {
  case events {
    [] -> None
    [event, ..rest] ->
      case event.kind == "run_failed" {
        True -> Some(event.message)
        False -> latest_run_failed_message_loop(rest)
      }
  }
}

fn run_failure_type(tasks: List(types.Task)) -> String {
  let completed_count =
    tasks
    |> list.filter(fn(task) { task.state == types.Completed || task.pr_number != "" })
    |> list.length
  case completed_count > 0 {
    True -> "partial success"
    False -> "execution"
  }
}
