import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
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
    "## Shipped Work",
    render_completed_tasks(run.tasks, events),
    "",
    "## Attention Needed",
    render_attention_tasks(run.tasks),
    "",
    "## Open Questions And Follow-Up",
    render_outstanding_tasks(run.tasks),
    "",
    "## Manual Setup Remaining",
    render_manual_setup(events),
    "",
    "## Recommended Next Steps",
    render_next_steps(run.tasks, events),
    "",
    "## Tasks",
    render_tasks(run.tasks),
    "",
    "## Timeline",
    render_events(events),
  ]
  |> string.join(with: "\n")
}

fn render_completed_tasks(
  tasks: List(types.Task),
  events: List(types.RunEvent),
) -> String {
  let completed =
    tasks
    |> list.filter(fn(task) { task.state == types.Completed })

  case completed {
    [] -> "- No completed tasks yet."
    _ ->
      completed
      |> list.map(fn(task) { render_completed_task(task, events) })
      |> string.join(with: "\n")
  }
}

fn render_completed_task(task: types.Task, events: List(types.RunEvent)) -> String {
  let pr_details =
    case task.pr_number {
      "" -> "no PR recorded"
      number ->
        case pr_url_for_task(events, task.id) {
          Ok(url) -> "PR #" <> number <> " (" <> url <> ")"
          Error(Nil) -> "PR #" <> number
        }
    }

  "- "
  <> task.title
  <> " (`"
  <> task.id
  <> "`): "
  <> pr_details
  <> " via `"
  <> task.branch_name
  <> "`.\n"
  <> "  "
  <> fallback_text(task.summary, "No completion summary recorded.")
}

fn render_attention_tasks(tasks: List(types.Task)) -> String {
  let attention =
    tasks
    |> list.filter(fn(task) {
      task.state == types.Blocked
      || task.state == types.ManualAttention
      || task.state == types.Failed
    })

  case attention {
    [] -> "- No blockers or manual-attention items were recorded."
    _ ->
      attention
      |> list.map(render_attention_task)
      |> string.join(with: "\n")
  }
}

fn render_attention_task(task: types.Task) -> String {
  "- ["
  <> types.task_state_to_string(task.state)
  <> "] "
  <> task.title
  <> " (`"
  <> task.id
  <> "`)\n"
  <> "  "
  <> fallback_text(task.summary, task.description)
}

fn render_outstanding_tasks(tasks: List(types.Task)) -> String {
  let outstanding =
    tasks
    |> list.filter(fn(task) {
      task.state == types.Queued
      || task.state == types.Ready
      || task.state == types.Running
    })

  case outstanding {
    [] -> "- No queued follow-up tasks or open questions were recorded."
    _ ->
      outstanding
      |> list.map(render_outstanding_task)
      |> string.join(with: "\n")
  }
}

fn render_outstanding_task(task: types.Task) -> String {
  let description = fallback_text(task.description, "No follow-up details recorded.")
  let acceptance =
    case task.acceptance {
      [] -> ""
      _ -> " Acceptance: " <> string.join(task.acceptance, "; ")
    }

  "- ["
  <> types.task_state_to_string(task.state)
  <> "] "
  <> task.title
  <> " (`"
  <> task.id
  <> "`)\n"
  <> "  "
  <> description
  <> acceptance
}

fn render_manual_setup(events: List(types.RunEvent)) -> String {
  let setup_messages =
    events
    |> list.filter_map(fn(event) {
      case event.kind {
        "discord_notification_skipped" -> Ok(event.message)
        "discord_notification_failed" -> Ok(event.message)
        _ -> Error(Nil)
      }
    })
    |> unique_strings

  case setup_messages {
    [] -> "- No manual setup gaps were recorded."
    _ ->
      setup_messages
      |> list.map(fn(message) { "- " <> message })
      |> string.join(with: "\n")
  }
}

fn render_next_steps(
  tasks: List(types.Task),
  events: List(types.RunEvent),
) -> String {
  let setup_steps =
    events
    |> list.filter_map(fn(event) {
      case event.kind {
        "discord_notification_skipped" ->
          Ok("Set the Discord webhook env var referenced in the skipped notification and rerun or resume as needed.")
        "discord_notification_failed" ->
          Ok("Inspect the Discord delivery error and retry once the webhook endpoint is reachable.")
        _ -> Error(Nil)
      }
    })

  let task_steps =
    tasks
    |> list.filter_map(fn(task) {
      case task.state {
        types.Completed ->
          case task.pr_number {
            "" -> Error(Nil)
            _ -> Ok("Review the open PR stack before merging anything into main.")
          }
        types.Blocked | types.ManualAttention | types.Failed ->
          Ok("Resolve the blocked or manual-attention tasks listed above.")
        types.Queued | types.Ready | types.Running ->
          Ok("Finish the outstanding follow-up tasks or answer the open questions listed above.")
      }
    })

  let steps = unique_strings(list.append(setup_steps, task_steps))

  case steps {
    [] -> "- No additional next steps recorded."
    _ ->
      steps
      |> list.map(fn(step) { "- " <> step })
      |> string.join(with: "\n")
  }
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

fn pr_url_for_task(events: List(types.RunEvent), task_id: String) -> Result(String, Nil) {
  events
  |> list.reverse
  |> list.find(fn(event) {
    event.kind == "pr_opened"
    && event.task_id == Some(task_id)
  })
  |> result.map(fn(event) { event.message })
}

fn unique_strings(values: List(String)) -> List(String) {
  values
  |> list.fold([], fn(acc, value) {
    case list.contains(acc, value) {
      True -> acc
      False -> [value, ..acc]
    }
  })
  |> list.reverse
}

fn fallback_text(primary: String, fallback: String) -> String {
  case string.trim(primary) {
    "" -> fallback
    value -> value
  }
}
