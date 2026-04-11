import filepath
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import night_shift/report
import night_shift/system
import night_shift/types
import simplifile

pub fn start_run(
  repo_root: String,
  brief_path: String,
  harness: types.Harness,
  max_workers: Int,
) -> Result(types.RunRecord, String) {
  let run_id = make_run_id()
  let repo_path = repo_state_path(repo_root)
  let run_path = filepath.join(repo_path, run_id)
  let brief_copy_path = filepath.join(run_path, "brief.md")
  let state_path = filepath.join(run_path, "state.json")
  let events_path = filepath.join(run_path, "events.jsonl")
  let report_path = filepath.join(run_path, "report.md")
  let lock_path = filepath.join(repo_path, "active.lock")

  use _ <- result.try(ensure_repo_ready(repo_path, lock_path))
  use _ <- result.try(create_run_directories(run_path))
  use _ <- result.try(copy_brief(brief_path, brief_copy_path))

  let timestamp = system.timestamp()
  let run =
    types.RunRecord(
      run_id: run_id,
      repo_root: repo_root,
      run_path: run_path,
      brief_path: brief_copy_path,
      state_path: state_path,
      events_path: events_path,
      report_path: report_path,
      lock_path: lock_path,
      harness: harness,
      max_workers: max_workers,
      status: types.RunActive,
      created_at: timestamp,
      updated_at: timestamp,
      tasks: [],
    )

  let event =
    types.RunEvent(
      kind: "run_started",
      at: timestamp,
      message: "Night Shift started.",
      task_id: None,
    )

  use _ <- result.try(save(run, [event]))
  use _ <- result.try(write_lock(lock_path, run_id))

  Ok(run)
}

pub fn load(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(#(types.RunRecord, List(types.RunEvent)), String) {
  let repo_path = repo_state_path(repo_root)

  use run_id <- result.try(case selector {
    types.LatestRun -> latest_run_id(repo_path)
    types.RunId(run_id) -> Ok(run_id)
  })

  let run_path = filepath.join(repo_path, run_id)
  let state_path = filepath.join(run_path, "state.json")
  let events_path = filepath.join(run_path, "events.jsonl")

  use run <- result.try(read_run(state_path))
  use events <- result.try(read_events(events_path))
  Ok(#(run, events))
}

pub fn list_runs(repo_root: String) -> Result(List(types.RunRecord), String) {
  let repo_path = repo_state_path(repo_root)
  use run_ids <- result.try(list_run_ids(repo_path))
  Ok(
    run_ids
    |> list.filter_map(fn(run_id) {
      let state_path =
        filepath.join(filepath.join(repo_path, run_id), "state.json")
      case read_run(state_path) {
        Ok(run) -> Ok(run)
        Error(_) -> Error(Nil)
      }
    }),
  )
}

pub fn save(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> Result(Nil, String) {
  use _ <- result.try(write_string(run.state_path, encode_run(run)))
  use _ <- result.try(write_events(run.events_path, events))
  write_string(run.report_path, report.render(run, events))
}

pub fn append_event(
  run: types.RunRecord,
  event: types.RunEvent,
) -> Result(types.RunRecord, String) {
  use existing_events <- result.try(read_events(run.events_path))
  let updated_run = types.RunRecord(..run, updated_at: event.at)
  use _ <- result.try(save(updated_run, list.append(existing_events, [event])))
  Ok(updated_run)
}

pub fn mark_status(
  run: types.RunRecord,
  status: types.RunStatus,
  message: String,
) -> Result(types.RunRecord, String) {
  let event =
    types.RunEvent(
      kind: status_event_kind(status),
      at: system.timestamp(),
      message: message,
      task_id: None,
    )

  let updated_run = types.RunRecord(..run, status: status, updated_at: event.at)

  use existing_events <- result.try(read_events(run.events_path))
  use _ <- result.try(save(updated_run, list.append(existing_events, [event])))
  case status {
    types.RunActive -> Ok(updated_run)
    _ -> {
      let _ = simplifile.delete_file(run.lock_path)
      Ok(updated_run)
    }
  }
}

pub fn read_report(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(String, String) {
  use #(run, _) <- result.try(load(repo_root, selector))
  read_string(run.report_path)
}

pub fn active_run_id(repo_root: String) -> Result(String, String) {
  let lock_path = filepath.join(repo_state_path(repo_root), "active.lock")
  case simplifile.read(lock_path) {
    Ok(run_id) -> Ok(string.trim(run_id))
    Error(_) ->
      Error("No active Night Shift run was found for this repository.")
  }
}

pub fn state_root() -> String {
  filepath.join(system.state_directory(), "night-shift")
}

pub fn repo_state_path_for(repo_root: String) -> String {
  repo_state_path(repo_root)
}

fn ensure_repo_ready(
  repo_path: String,
  lock_path: String,
) -> Result(Nil, String) {
  use _ <- result.try(create_directory(repo_path))
  case simplifile.read(lock_path) {
    Ok(existing_run) ->
      Error(
        "Night Shift already has an active run for this repo: "
        <> string.trim(existing_run),
      )
    Error(_) -> Ok(Nil)
  }
}

fn create_run_directories(run_path: String) -> Result(Nil, String) {
  use _ <- result.try(create_directory(run_path))
  create_directory(filepath.join(run_path, "logs"))
}

fn create_directory(path: String) -> Result(Nil, String) {
  case simplifile.create_directory_all(path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to create directory "
        <> path
        <> ": "
        <> simplifile.describe_error(error),
      )
  }
}

fn copy_brief(
  from source: String,
  to destination: String,
) -> Result(Nil, String) {
  case simplifile.copy_file(at: source, to: destination) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error("Unable to copy brief: " <> simplifile.describe_error(error))
  }
}

fn write_lock(lock_path: String, run_id: String) -> Result(Nil, String) {
  write_string(lock_path, run_id <> "\n")
}

fn write_string(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.write(contents, to: path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to write " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}

fn read_string(path: String) -> Result(String, String) {
  case simplifile.read(path) {
    Ok(contents) -> Ok(contents)
    Error(error) ->
      Error(
        "Unable to read " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}

fn write_events(
  path: String,
  events: List(types.RunEvent),
) -> Result(Nil, String) {
  let contents =
    events
    |> list.map(encode_event)
    |> string.join(with: "\n")

  write_string(path, case contents {
    "" -> ""
    _ -> contents <> "\n"
  })
}

fn read_events(path: String) -> Result(List(types.RunEvent), String) {
  case simplifile.read(path) {
    Ok(contents) ->
      case string.trim(contents) {
        "" -> Ok([])
        trimmed ->
          trimmed
          |> string.split("\n")
          |> list.try_map(decode_event)
      }
    Error(_) -> Ok([])
  }
}

fn latest_run_id(repo_path: String) -> Result(String, String) {
  use run_ids <- result.try(list_run_ids(repo_path))
  case run_ids {
    [latest, ..] -> Ok(latest)
    [] -> Error("No Night Shift runs were found for this repository.")
  }
}

fn list_run_ids(repo_path: String) -> Result(List(String), String) {
  case simplifile.read_directory(at: repo_path) {
    Ok(entries) ->
      Ok(
        entries
        |> list.filter(fn(entry) { entry != "active.lock" })
        |> list.sort(string.compare)
        |> list.reverse,
      )
    Error(_) -> Error("No Night Shift runs were found for this repository.")
  }
}

fn read_run(path: String) -> Result(types.RunRecord, String) {
  use contents <- result.try(read_string(path))
  json.parse(contents, run_decoder())
  |> result.map_error(fn(_) { "Unable to decode stored run state." })
}

fn make_run_id() -> String {
  system.timestamp()
  |> string.replace(each: ":", with: "-")
  |> string.replace(each: "T", with: "_")
  |> string.replace(each: "+", with: "_")
  |> string.replace(each: "Z", with: "")
  |> string.append("-")
  |> string.append(system.unique_id())
}

fn repo_state_path(repo_root: String) -> String {
  filepath.join(state_root(), sanitize_repo_root(repo_root))
}

fn sanitize_repo_root(repo_root: String) -> String {
  repo_root
  |> string.replace(each: "/", with: "__")
  |> string.replace(each: ":", with: "_")
  |> string.replace(each: " ", with: "_")
}

fn status_event_kind(status: types.RunStatus) -> String {
  case status {
    types.RunPending -> "run_pending"
    types.RunActive -> "run_started"
    types.RunCompleted -> "run_completed"
    types.RunBlocked -> "run_blocked"
    types.RunFailed -> "run_failed"
  }
}

fn encode_run(run: types.RunRecord) -> String {
  json.object([
    #("run_id", json.string(run.run_id)),
    #("repo_root", json.string(run.repo_root)),
    #("run_path", json.string(run.run_path)),
    #("brief_path", json.string(run.brief_path)),
    #("state_path", json.string(run.state_path)),
    #("events_path", json.string(run.events_path)),
    #("report_path", json.string(run.report_path)),
    #("lock_path", json.string(run.lock_path)),
    #("harness", json.string(types.harness_to_string(run.harness))),
    #("max_workers", json.int(run.max_workers)),
    #("status", json.string(types.run_status_to_string(run.status))),
    #("created_at", json.string(run.created_at)),
    #("updated_at", json.string(run.updated_at)),
    #("tasks", json.array(run.tasks, encode_task)),
  ])
  |> json.to_string
}

fn encode_task(task: types.Task) -> json.Json {
  json.object([
    #("id", json.string(task.id)),
    #("title", json.string(task.title)),
    #("description", json.string(task.description)),
    #("dependencies", json.array(task.dependencies, json.string)),
    #("acceptance", json.array(task.acceptance, json.string)),
    #("demo_plan", json.array(task.demo_plan, json.string)),
    #("parallel_safe", json.bool(task.parallel_safe)),
    #("state", json.string(types.task_state_to_string(task.state))),
    #("worktree_path", json.string(task.worktree_path)),
    #("branch_name", json.string(task.branch_name)),
    #("pr_number", json.string(task.pr_number)),
    #("summary", json.string(task.summary)),
  ])
}

fn encode_event(event: types.RunEvent) -> String {
  json.object([
    #("kind", json.string(event.kind)),
    #("at", json.string(event.at)),
    #("message", json.string(event.message)),
    #("task_id", json.nullable(from: event.task_id, of: json.string)),
  ])
  |> json.to_string
}

fn run_decoder() -> decode.Decoder(types.RunRecord) {
  use run_id <- decode.field("run_id", decode.string)
  use repo_root <- decode.field("repo_root", decode.string)
  use run_path <- decode.field("run_path", decode.string)
  use brief_path <- decode.field("brief_path", decode.string)
  use state_path <- decode.field("state_path", decode.string)
  use events_path <- decode.field("events_path", decode.string)
  use report_path <- decode.field("report_path", decode.string)
  use lock_path <- decode.field("lock_path", decode.string)
  use harness <- decode.field("harness", harness_decoder())
  use max_workers <- decode.field("max_workers", decode.int)
  use status <- decode.field("status", run_status_decoder())
  use created_at <- decode.field("created_at", decode.string)
  use updated_at <- decode.field("updated_at", decode.string)
  use tasks <- decode.field("tasks", decode.list(task_decoder()))
  decode.success(types.RunRecord(
    run_id: run_id,
    repo_root: repo_root,
    run_path: run_path,
    brief_path: brief_path,
    state_path: state_path,
    events_path: events_path,
    report_path: report_path,
    lock_path: lock_path,
    harness: harness,
    max_workers: max_workers,
    status: status,
    created_at: created_at,
    updated_at: updated_at,
    tasks: tasks,
  ))
}

fn task_decoder() -> decode.Decoder(types.Task) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use description <- decode.field("description", decode.string)
  use dependencies <- decode.field("dependencies", decode.list(decode.string))
  use acceptance <- decode.field("acceptance", decode.list(decode.string))
  use demo_plan <- decode.field("demo_plan", decode.list(decode.string))
  use parallel_safe <- decode.field("parallel_safe", decode.bool)
  use state <- decode.field("state", task_state_decoder())
  use worktree_path <- decode.field("worktree_path", decode.string)
  use branch_name <- decode.field("branch_name", decode.string)
  use pr_number <- decode.field("pr_number", decode.string)
  use summary <- decode.field("summary", decode.string)
  decode.success(types.Task(
    id: id,
    title: title,
    description: description,
    dependencies: dependencies,
    acceptance: acceptance,
    demo_plan: demo_plan,
    parallel_safe: parallel_safe,
    state: state,
    worktree_path: worktree_path,
    branch_name: branch_name,
    pr_number: pr_number,
    summary: summary,
  ))
}

fn decode_event(line: String) -> Result(types.RunEvent, String) {
  json.parse(line, event_decoder())
  |> result.map_error(fn(_) { "Unable to decode event journal." })
}

fn event_decoder() -> decode.Decoder(types.RunEvent) {
  use kind <- decode.field("kind", decode.string)
  use at <- decode.field("at", decode.string)
  use message <- decode.field("message", decode.string)
  use task_id <- decode.field("task_id", decode.optional(decode.string))
  decode.success(types.RunEvent(
    kind: kind,
    at: at,
    message: message,
    task_id: task_id,
  ))
}

fn harness_decoder() -> decode.Decoder(types.Harness) {
  use raw <- decode.then(decode.string)
  case types.harness_from_string(raw) {
    Ok(harness) -> decode.success(harness)
    Error(_) -> decode.failure(types.Codex, "Harness")
  }
}

fn run_status_decoder() -> decode.Decoder(types.RunStatus) {
  use raw <- decode.then(decode.string)
  case raw {
    "pending" -> decode.success(types.RunPending)
    "active" -> decode.success(types.RunActive)
    "completed" -> decode.success(types.RunCompleted)
    "blocked" -> decode.success(types.RunBlocked)
    "failed" -> decode.success(types.RunFailed)
    _ -> decode.failure(types.RunPending, "RunStatus")
  }
}

fn task_state_decoder() -> decode.Decoder(types.TaskState) {
  use raw <- decode.then(decode.string)
  case raw {
    "queued" -> decode.success(types.Queued)
    "ready" -> decode.success(types.Ready)
    "running" -> decode.success(types.Running)
    "blocked" -> decode.success(types.Blocked)
    "completed" -> decode.success(types.Completed)
    "failed" -> decode.success(types.Failed)
    "manual_attention" -> decode.success(types.ManualAttention)
    _ -> decode.failure(types.Queued, "TaskState")
  }
}
