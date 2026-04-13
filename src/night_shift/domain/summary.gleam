import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/domain/task_validation
import night_shift/types

pub type PayloadRepairSummary {
  PayloadRepairSummary(
    prompt_path: String,
    log_path: String,
    raw_payload_path: Option(String),
    sanitized_payload_path: Option(String),
  )
}

pub fn pluralize(count: Int, noun: String) -> String {
  case count == 1 {
    True -> "1 " <> noun
    False -> int.to_string(count) <> " " <> noun <> "s"
  }
}

pub fn manual_attention_summary(task: types.Task) -> String {
  "Primary blocker: "
  <> task.description
  <> "\n\nEnvironment notes: no worktree bootstrap or provider execution started because this task requires manual attention."
}

pub fn resolved_manual_attention_summary(existing_summary: String) -> String {
  case string.trim(existing_summary) {
    "" -> "Resolved during planning."
    summary -> summary
  }
}

pub fn blocked_run_message(tasks: List(types.Task)) -> String {
  let pr_count =
    tasks
    |> list.filter(fn(task) { task.pr_number != "" })
    |> list.length
  let manual_attention_count =
    tasks
    |> list.filter(fn(task) { task.state == types.ManualAttention })
    |> list.length
  let blocked_count =
    tasks
    |> list.filter(fn(task) { task.state == types.Blocked })
    |> list.length

  "Night Shift opened "
  <> pluralize(pr_count, "PR")
  <> " and is awaiting manual review for "
  <> pluralize(manual_attention_count, "task")
  <> blocked_suffix(blocked_count)
}

pub fn blocked_suffix(blocked_count: Int) -> String {
  case blocked_count {
    0 -> "."
    _ -> " while " <> pluralize(blocked_count, "task") <> " remain blocked."
  }
}

pub fn task_failure_summary(headline: String, details: String) -> String {
  "Primary blocker: " <> headline <> "\n\nEnvironment notes:\n" <> details
}

pub fn completion_failure_summary(message: String) -> String {
  case string.starts_with(message, "Primary blocker:") {
    True -> message
    False ->
      task_failure_summary("task completion failed unexpectedly.", message)
  }
}

pub fn planning_validation_summary(
  issues: List(task_validation.ValidationIssue),
) -> String {
  task_failure_summary(
    "Night Shift rejected the planner output before updating the task graph.",
    "Validation errors: " <> task_validation.render_issues(issues),
  )
}

pub fn follow_up_validation_summary(
  task: types.Task,
  issues: List(task_validation.ValidationIssue),
) -> String {
  task_failure_summary(
    "Night Shift captured implementation output, but the follow-up task graph was invalid.",
    "Task worktree: "
      <> task.worktree_path
      <> "\n"
      <> "Task branch: "
      <> task.branch_name
      <> "\n"
      <> "Validation errors: "
      <> task_validation.render_issues(issues),
  )
}

pub fn decode_manual_attention_summary(
  task: types.Task,
  log_path: String,
  raw_payload_path: String,
  sanitized_payload_path: Option(String),
  repair_summary: Option(PayloadRepairSummary),
) -> String {
  task_failure_summary(
    "Night Shift found candidate worktree changes, but could not trust the structured execution result.",
    "Task worktree: "
      <> task.worktree_path
      <> "\n"
      <> "Task branch: "
      <> task.branch_name
      <> "\n"
      <> "Task log: "
      <> log_path
      <> "\n"
      <> "Raw payload: "
      <> raw_payload_path
      <> case sanitized_payload_path {
      Some(path) -> "\nSanitized payload: " <> path
      None -> ""
    }
      <> case repair_summary {
      Some(summary) ->
        "\nPayload repair prompt: "
        <> summary.prompt_path
        <> "\nPayload repair log: "
        <> summary.log_path
        <> case summary.raw_payload_path {
          Some(path) -> "\nPayload repair raw payload: " <> path
          None -> ""
        }
        <> case summary.sanitized_payload_path {
          Some(path) -> "\nPayload repair sanitized payload: " <> path
          None -> ""
        }
      None -> ""
    },
  )
}
