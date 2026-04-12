import gleam/int
import gleam/list
import gleam/string
import night_shift/types

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
