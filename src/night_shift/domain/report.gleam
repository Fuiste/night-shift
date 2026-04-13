import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/agent_config
import night_shift/domain/repo_state
import night_shift/domain/review_run_projection
import night_shift/repo_state_runtime
import night_shift/types

pub fn render(
  run: types.RunRecord,
  events: List(types.RunEvent),
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> String {
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
    render_repo_state_section(run, repo_state_view),
    "",
    "## Summary",
    render_summary(run.decisions, run.planning_dirty, run.tasks, events),
    render_planning_validation_summary(events),
    render_failure_summary(run, events),
    render_review_replacement_section(run, events),
    render_worktree_hygiene_section(run, events),
    render_execution_recovery_section(events),
    "",
    "## Tasks",
    render_tasks(run.decisions, run.planning_dirty, run.tasks),
    "",
    "## Timeline",
    render_events(events),
  ]
  |> string.join(with: "\n")
}

fn render_repo_state_section(
  run: types.RunRecord,
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> String {
  case review_run_projection.repo_state_summary(run, repo_state_view) {
    None -> ""
    Some(summary) ->
      "\n## Repo State\n"
      <> "- Captured open PRs: "
      <> int.to_string(summary.captured_open_pr_count)
      <> "\n- Captured actionable PRs: "
      <> int.to_string(summary.captured_actionable_pr_count)
      <> "\n- Snapshot captured: "
      <> summary.snapshot_captured_at
      <> render_live_repo_state(summary)
      <> render_repo_snapshot_group(
        "Actionable PRs",
        summary.actionable_pull_requests
          |> list.map(render_repo_pull_request_snapshot),
      )
      <> render_repo_snapshot_group(
        "Impacted PRs",
        summary.impacted_pull_requests
          |> list.map(render_repo_pull_request_snapshot),
      )
  }
}

fn render_live_repo_state(
  summary: review_run_projection.RepoStateSummary,
) -> String {
  case summary.current_open_pr_count, summary.current_actionable_pr_count {
    Some(open_pr_count), Some(actionable_pr_count) ->
      "\n- Current open PRs: "
      <> int.to_string(open_pr_count)
      <> "\n- Current actionable PRs: "
      <> int.to_string(actionable_pr_count)
      <> "\n- Drift: "
      <> case summary.drift {
        Some(drift) -> drift
        None -> "unknown"
      }
      <> case summary.drift_details {
        Some(details) -> "\n- Drift details: " <> details
        None -> ""
      }
    _, _ -> ""
  }
}

fn render_repo_pull_request_snapshot(
  pr: repo_state.RepoPullRequestSnapshot,
) -> String {
  "- #"
  <> int.to_string(pr.number)
  <> " "
  <> pr.title
  <> " (base: "
  <> pr.base_ref_name
  <> ", head: "
  <> pr.head_ref_name
  <> ")"
}

fn render_repo_snapshot_group(title: String, entries: List(String)) -> String {
  case entries {
    [] -> "\n### " <> title <> "\n- none"
    _ -> "\n### " <> title <> "\n" <> string.join(entries, with: "\n")
  }
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
  let derived_blocked_count = case
    planning_dirty && manual_attention_count == 0 && blocked_count == 0
  {
    True -> 1
    False -> manual_attention_count + blocked_count
  }
  let failed_count =
    tasks
    |> list.filter(fn(task) { task.state == types.Failed })
    |> list.length
  let run_level_failure_count = case
    latest_environment_preflight_failure(events)
  {
    Some(_) -> 1
    None -> 0
  }
  let queued_count =
    tasks
    |> list.filter(fn(task) {
      task.state == types.Queued
      || { task.state == types.Ready && task.kind == types.ImplementationTask }
    })
    |> list.length
  let outstanding_decisions =
    tasks
    |> list.filter(fn(task) {
      types.task_requires_manual_attention(decisions, task)
    })
    |> list.map(fn(task) {
      list.length(types.unresolved_decision_requests(decisions, task))
    })
    |> list.fold(0, fn(total, count) { total + count })
  let retained_worktrees =
    tasks
    |> list.filter(fn(task) { task.worktree_path != "" })
    |> list.length

  [
    "- Completed tasks: " <> int.to_string(completed_count),
    "- Opened PRs: " <> int.to_string(pr_count),
    "- Blocked tasks: " <> int.to_string(derived_blocked_count),
    "- Manual-attention tasks: " <> int.to_string(manual_attention_count),
    "- Outstanding decisions: " <> int.to_string(outstanding_decisions),
    "- Run-level failures: " <> int.to_string(run_level_failure_count),
    "- Failed tasks: " <> int.to_string(failed_count),
    "- Queued tasks: " <> int.to_string(queued_count),
    "- Retained worktrees: " <> int.to_string(retained_worktrees),
    "- Pruned superseded worktrees: "
      <> int.to_string(event_count(events, "worktree_pruned")),
    "- Execution recovery warnings: "
      <> int.to_string(event_count(events, "execution_payload_warning")),
    "- Payload repair attempts: "
      <> int.to_string(event_count(events, "execution_payload_repair_started")),
    "- Payload repair successes: "
      <> int.to_string(event_count(events, "execution_payload_repair_succeeded")),
    "- Payload repair failures: "
      <> int.to_string(event_count(events, "execution_payload_repair_failed")),
  ]
  |> string.join(with: "\n")
}

fn render_review_replacement_section(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> String {
  case review_run_projection.build(run, events, None) {
    Some(projection) ->
      "\n## Review-Driven Replacement\n"
      <> render_review_lineage(
        projection.lineage_entries
        |> list.map(review_run_projection.render_lineage_entry),
      )
      <> render_event_group(
        "Supersession Outcome",
        projection.supersession_outcomes,
      )
      <> render_event_group(
        "Supersession Warnings",
        projection.supersession_warnings,
      )
    None -> ""
  }
}

fn render_review_lineage(lines: List(String)) -> String {
  case lines {
    [] -> "\n### Replacement Mapping\n- none"
    _ -> "\n### Replacement Mapping\n" <> string.join(lines, with: "\n")
  }
}

fn render_worktree_hygiene_section(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> String {
  let prune_messages = event_messages(events, "worktree_pruned")
  let prune_warnings = event_messages(events, "worktree_prune_warning")
  let retained_count =
    run.tasks
    |> list.filter(fn(task) { task.worktree_path != "" })
    |> list.length

  case retained_count, prune_messages, prune_warnings {
    0, [], [] -> ""
    _, _, _ ->
      "\n## Worktree Hygiene\n"
      <> "- Retained current-run worktrees: "
      <> int.to_string(retained_count)
      <> "\n- Pruned superseded worktrees: "
      <> int.to_string(list.length(prune_messages))
      <> render_event_group("Pruned Worktrees", prune_messages)
      <> render_event_group("Prune Warnings", prune_warnings)
  }
}

fn render_execution_recovery_section(events: List(types.RunEvent)) -> String {
  let warnings = event_messages(events, "execution_payload_warning")
  let repair_attempts =
    event_messages(events, "execution_payload_repair_started")
  let repair_successes =
    event_messages(events, "execution_payload_repair_succeeded")
  let repair_failures =
    event_messages(events, "execution_payload_repair_failed")
  case warnings, repair_attempts, repair_successes, repair_failures {
    [], [], [], [] -> ""
    _, _, _, _ ->
      "\n## Execution Recovery\n"
      <> "- Accepted recovered execution payloads: "
      <> int.to_string(list.length(warnings))
      <> "\n- Payload repair attempts: "
      <> int.to_string(list.length(repair_attempts))
      <> "\n- Payload repair successes: "
      <> int.to_string(list.length(repair_successes))
      <> "\n- Payload repair failures: "
      <> int.to_string(list.length(repair_failures))
      <> render_event_group("Payload Repair Attempts", repair_attempts)
      <> render_event_group("Payload Repair Successes", repair_successes)
      <> render_event_group("Payload Repair Failures", repair_failures)
      <> render_event_group("Recovery Warnings", warnings)
  }
}

fn render_event_group(title: String, messages: List(String)) -> String {
  case messages {
    [] -> ""
    _ -> "\n### " <> title <> "\n" <> render_bullet_lines(messages)
  }
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
  <> types.task_state_to_string(render_task_state(
    decisions,
    planning_dirty,
    task,
  ))
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

  let decision_fragment = case
    types.task_requires_manual_attention(decisions, task)
  {
    True ->
      "\n  Outstanding decisions:\n"
      <> {
        types.unresolved_decision_requests(decisions, task)
        |> list.map(fn(request) { "  - " <> request.question })
        |> string.join(with: "\n")
      }
    False -> ""
  }

  let planning_fragment = case
    task.kind == types.ManualAttentionTask && planning_dirty
  {
    True ->
      case types.task_requires_manual_attention(decisions, task) {
        True -> ""
        False ->
          "\n  Decision recorded; Night Shift still needs to replan this run."
      }
    False -> ""
  }

  let summary_fragment = case string.trim(task.summary) {
    "" -> ""
    summary -> "\n  " <> string.replace(in: summary, each: "\n", with: "\n  ")
  }

  let lineage_fragment = case task.superseded_pr_numbers {
    [] -> ""
    pr_numbers -> "\n  Supersedes: " <> render_pr_numbers(pr_numbers)
  }

  pr_fragment
  <> lineage_fragment
  <> decision_fragment
  <> planning_fragment
  <> summary_fragment
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

fn render_planning_validation_summary(events: List(types.RunEvent)) -> String {
  case latest_event_message(events, "planning_validation_failed") {
    Some(message) -> "\n## Planning\n- Validation: " <> message
    None -> ""
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

fn event_messages(events: List(types.RunEvent), kind: String) -> List(String) {
  events
  |> list.filter(fn(event) { event.kind == kind })
  |> list.map(fn(event) { event.message })
}

fn event_count(events: List(types.RunEvent), kind: String) -> Int {
  event_messages(events, kind)
  |> list.length
}

fn render_bullet_lines(messages: List(String)) -> String {
  messages
  |> list.map(fn(message) {
    "- " <> string.replace(in: message, each: "\n", with: "\n  ")
  })
  |> string.join(with: "\n")
}

fn render_pr_numbers(pr_numbers: List(Int)) -> String {
  pr_numbers
  |> list.map(fn(pr_number) { "#" <> int.to_string(pr_number) })
  |> string.join(with: ", ")
}

fn run_failure_type(tasks: List(types.Task)) -> String {
  let completed_count =
    tasks
    |> list.filter(fn(task) {
      task.state == types.Completed || task.pr_number != ""
    })
    |> list.length
  case completed_count > 0 {
    True -> "partial success"
    False -> "execution"
  }
}
