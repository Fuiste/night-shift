import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/dash/session
import night_shift/journal
import night_shift/system
import night_shift/types

pub type Snapshot {
  Snapshot(
    run_id: String,
    run_updated_at: String,
    status: String,
    event_count: Int,
    task_signature: String,
    delivery_signature: String,
    repo_state_signature: String,
    command_signature: String,
  )
}

pub fn snapshot(
  repo_root: String,
  requested_run_id: Option(String),
) -> Result(Option(Snapshot), String) {
  use runs <- result.try(journal.list_runs(repo_root))
  let selected_run_id = choose_selected_run_id(runs, requested_run_id)
  case selected_run_id {
    None -> Ok(None)
    Some(run_id) -> {
      use #(run, events) <- result.try(journal.load(
        repo_root,
        types.RunId(run_id),
      ))
      Ok(
        Some(Snapshot(
          run_id: run.run_id,
          run_updated_at: run.updated_at,
          status: types.run_status_to_string(run.status),
          event_count: list.length(events),
          task_signature: task_signature(run.tasks),
          delivery_signature: delivery_signature(events),
          repo_state_signature: repo_state_signature(run),
          command_signature: command_signature(session.command_state(repo_root)),
        )),
      )
    }
  }
}

pub fn diff_events(
  previous: Option(Snapshot),
  current: Option(Snapshot),
) -> List(json.Json) {
  case previous, current {
    None, None -> [keepalive_event("")]
    None, Some(now) -> [
      event("workspace_updated", now.run_id),
      event("run_updated", now.run_id),
      event("dag_updated", now.run_id),
      event("timeline_appended", now.run_id),
    ]
    Some(_), None -> [keepalive_event("")]
    Some(before), Some(after) ->
      compact_events([
        maybe_event(
          before.command_signature != after.command_signature,
          after.run_id,
          case before.command_signature, after.command_signature {
            "", _ -> "command_started"
            _, "" -> "command_finished"
            _, _ -> "command_finished"
          },
        ),
        maybe_event(
          before.run_updated_at != after.run_updated_at
            || before.status != after.status,
          after.run_id,
          "run_updated",
        ),
        maybe_event(
          before.task_signature != after.task_signature,
          after.run_id,
          "dag_updated",
        ),
        maybe_event(
          before.event_count != after.event_count,
          after.run_id,
          "timeline_appended",
        ),
        maybe_event(
          before.delivery_signature != after.delivery_signature,
          after.run_id,
          "delivery_updated",
        ),
        maybe_event(
          before.repo_state_signature != after.repo_state_signature,
          after.run_id,
          "repo_state_updated",
        ),
      ])
      |> ensure_workspace_event(after.run_id)
  }
}

pub fn keepalive_json(run_id: String) -> String {
  keepalive_event(run_id) |> json.to_string
}

pub fn event_json(event_payload: json.Json) -> String {
  json.to_string(event_payload)
}

fn event(kind: String, run_id: String) -> json.Json {
  json.object([
    #("id", json.string(system.unique_id())),
    #("kind", json.string(kind)),
    #("run_id", json.string(run_id)),
    #("at", json.string(system.timestamp())),
    #("payload", json.object([])),
  ])
}

fn keepalive_event(run_id: String) -> json.Json {
  json.object([
    #("id", json.string(system.unique_id())),
    #("kind", json.string("stream_keepalive")),
    #("run_id", json.string(run_id)),
    #("at", json.string(system.timestamp())),
    #("payload", json.object([])),
  ])
}

fn maybe_event(enabled: Bool, run_id: String, kind: String) -> Option(json.Json) {
  case enabled {
    True -> Some(event(kind, run_id))
    False -> None
  }
}

fn ensure_workspace_event(
  events: List(json.Json),
  run_id: String,
) -> List(json.Json) {
  case events {
    [] -> [keepalive_event(run_id)]
    _ -> [event("workspace_updated", run_id), ..events]
  }
}

fn task_signature(tasks: List(types.Task)) -> String {
  tasks
  |> list.map(fn(task) {
    task.id
    <> ":"
    <> types.task_state_to_string(task.state)
    <> ":"
    <> task.pr_number
  })
  |> string.join(with: "|")
}

fn delivery_signature(events: List(types.RunEvent)) -> String {
  events
  |> list.filter(fn(event) { event.kind == "pr_opened" })
  |> list.map(fn(event) {
    event.task_id
    |> option_default("run")
    |> fn(task_id) { task_id <> ":" <> event.message }
  })
  |> string.join(with: "|")
}

fn repo_state_signature(run: types.RunRecord) -> String {
  case run.repo_state_snapshot {
    Some(snapshot) -> snapshot.captured_at
    None -> ""
  }
}

fn command_signature(command_state: Option(session.CommandState)) -> String {
  case command_state {
    Some(state) ->
      state.name
      <> ":"
      <> option_default(state.run_id, "")
      <> ":"
      <> state.started_at
    None -> ""
  }
}

fn option_default(value: Option(String), fallback: String) -> String {
  case value {
    Some(inner) -> inner
    None -> fallback
  }
}

fn choose_selected_run_id(
  runs: List(types.RunRecord),
  requested_run_id: Option(String),
) -> Option(String) {
  case requested_run_id {
    Some(run_id) ->
      case list.any(runs, fn(run) { run.run_id == run_id }) {
        True -> Some(run_id)
        False ->
          case runs {
            [run, ..] -> Some(run.run_id)
            [] -> None
          }
      }
    None ->
      case runs {
        [run, ..] -> Some(run.run_id)
        [] -> None
      }
  }
}

fn compact_events(values: List(Option(json.Json))) -> List(json.Json) {
  case values {
    [] -> []
    [Some(value), ..rest] -> [value, ..compact_events(rest)]
    [None, ..rest] -> compact_events(rest)
  }
}
