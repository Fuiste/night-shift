import gleam/int
import gleam/list
import gleam/option.{None, Some}
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
    "- Created at: " <> run.created_at,
    "- Updated at: " <> run.updated_at,
    "- Brief: " <> run.brief_path,
    "",
    "## Summary",
    render_summary(run.tasks),
    "",
    "## Tasks",
    render_tasks(run.tasks),
    "",
    "## Timeline",
    render_events(events),
  ]
  |> string.join(with: "\n")
}

fn render_summary(tasks: List(types.Task)) -> String {
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
    |> list.filter(fn(task) { task.state == types.ManualAttention })
    |> list.length
  let failed_count =
    tasks
    |> list.filter(fn(task) { task.state == types.Failed })
    |> list.length
  let queued_count =
    tasks
    |> list.filter(fn(task) {
      task.state == types.Queued || task.state == types.Ready
    })
    |> list.length

  [
    "- Completed tasks: " <> int.to_string(completed_count),
    "- Opened PRs: " <> int.to_string(pr_count),
    "- Manual-attention tasks: " <> int.to_string(manual_attention_count),
    "- Failed tasks: " <> int.to_string(failed_count),
    "- Queued tasks: " <> int.to_string(queued_count),
  ]
  |> string.join(with: "\n")
}

fn render_tasks(tasks: List(types.Task)) -> String {
  case tasks {
    [] -> "- No tasks have been planned yet."
    _ ->
      tasks
      |> list.map(render_task)
      |> string.join(with: "\n")
  }
}

fn render_task(task: types.Task) -> String {
  "- ["
  <> types.task_state_to_string(task.state)
  <> "] "
  <> task.id
  <> ": "
  <> task.title
  <> render_task_details(task)
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

fn render_task_details(task: types.Task) -> String {
  let pr_fragment = case task.pr_number {
    "" -> ""
    pr_number -> " (PR #" <> pr_number <> ")"
  }

  let summary_fragment = case string.trim(task.summary) {
    "" -> ""
    summary -> "\n  " <> string.replace(in: summary, each: "\n", with: "\n  ")
  }

  pr_fragment <> summary_fragment
}

fn render_environment_label(environment_name: String) -> String {
  case environment_name {
    "" -> "(none)"
    value -> value
  }
}
