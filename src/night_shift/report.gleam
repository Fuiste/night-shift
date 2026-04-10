import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import night_shift/types

pub fn render(run: types.RunRecord, events: List(types.RunEvent)) -> String {
  [
    "# Night Shift Report",
    "",
    "## Run",
    "- Run ID: " <> run.run_id,
    "- Status: " <> types.run_status_to_string(run.status),
    "- Repo: " <> run.repo_root,
    "- Harness: " <> types.harness_to_string(run.harness),
    "- Max workers: " <> int.to_string(run.max_workers),
    "- Created at: " <> run.created_at,
    "- Updated at: " <> run.updated_at,
    "- Brief: " <> run.brief_path,
    "",
    "## Tasks",
    render_tasks(run.tasks),
    "",
    "## Timeline",
    render_events(events),
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
  let task_label =
    case event.task_id {
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
