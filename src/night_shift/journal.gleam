import filepath
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/codec/artifact_path
import night_shift/codec/journal as journal_codec
import night_shift/project
import night_shift/report
import night_shift/system
import night_shift/types
import simplifile

pub fn start_run(
  repo_root: String,
  brief_path: String,
  planning_agent: types.ResolvedAgentConfig,
  execution_agent: types.ResolvedAgentConfig,
  environment_name: String,
  max_workers: Int,
) -> Result(types.RunRecord, String) {
  use run <- result.try(create_pending_run(
    repo_root,
    brief_path,
    planning_agent,
    execution_agent,
    environment_name,
    max_workers,
    None,
  ))
  activate_run(run)
}

pub fn create_pending_run(
  repo_root: String,
  brief_path: String,
  planning_agent: types.ResolvedAgentConfig,
  execution_agent: types.ResolvedAgentConfig,
  environment_name: String,
  max_workers: Int,
  notes_source: Option(types.NotesSource),
) -> Result(types.RunRecord, String) {
  let run_id = make_run_id()
  let project_home = repo_state_path(repo_root)
  let runs_path = runs_root(repo_root)
  let run_path = filepath.join(runs_path, run_id)
  let brief_copy_path = filepath.join(run_path, "brief.md")
  let state_path = filepath.join(run_path, "state.json")
  let events_path = filepath.join(run_path, "events.jsonl")
  let report_path = filepath.join(run_path, "report.md")
  let lock_path = project.active_lock_path(repo_root)

  use _ <- result.try(ensure_repo_home_ready(repo_root, project_home, runs_path))
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
      planning_agent: planning_agent,
      execution_agent: execution_agent,
      environment_name: environment_name,
      max_workers: max_workers,
      notes_source: notes_source,
      decisions: [],
      planning_dirty: False,
      status: types.RunPending,
      created_at: timestamp,
      updated_at: timestamp,
      tasks: [],
    )

  use _ <- result.try(save(run, []))
  Ok(run)
}

pub fn activate_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  use _ <- result.try(ensure_no_active_run(run.lock_path))
  use _ <- result.try(write_lock(run.lock_path, run.run_id))
  let event =
    types.RunEvent(
      kind: "run_started",
      at: system.timestamp(),
      message: "Night Shift started.",
      task_id: None,
    )
  let updated_run =
    types.RunRecord(..run, status: types.RunActive, updated_at: event.at)
  use existing_events <- result.try(read_events(run.events_path))
  use _ <- result.try(save(updated_run, list.append(existing_events, [event])))
  Ok(updated_run)
}

pub fn rewrite_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  use existing_events <- result.try(read_events(run.events_path))
  let updated_run = types.RunRecord(..run, updated_at: system.timestamp())
  use _ <- result.try(save(updated_run, existing_events))
  Ok(updated_run)
}

pub fn latest_reusable_run(
  repo_root: String,
) -> Result(Option(types.RunRecord), String) {
  case list_runs(repo_root) {
    Ok(runs) ->
      Ok(case list.find(runs, fn(run) { is_reusable_planning_run(run) }) {
        Ok(run) -> Some(run)
        Error(_) -> None
      })
    Error(_) -> Ok(None)
  }
}

pub fn load(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(#(types.RunRecord, List(types.RunEvent)), String) {
  let repo_path = runs_root(repo_root)

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
  let repo_path = runs_root(repo_root)
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
  use _ <- result.try(write_string(
    run.state_path,
    journal_codec.encode_run(run),
  ))
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
  let lock_path = project.active_lock_path(repo_root)
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

pub fn planning_root_for(repo_root: String) -> String {
  planning_root(repo_root)
}

fn ensure_repo_home_ready(
  repo_root: String,
  project_home: String,
  runs_path: String,
) -> Result(Nil, String) {
  use _ <- result.try(create_directory(project_home))
  use _ <- result.try(create_directory(runs_path))
  create_directory(planning_root(repo_root))
}

fn ensure_no_active_run(lock_path: String) -> Result(Nil, String) {
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
    |> list.map(journal_codec.encode_event)
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
        |> list.sort(fn(left, right) {
          string.compare(sortable_run_id(left), sortable_run_id(right))
        })
        |> list.reverse,
      )
    Error(_) -> Error("No Night Shift runs were found for this repository.")
  }
}

fn sortable_run_id(run_id: String) -> String {
  case list.reverse(string.split(run_id, "-")) {
    [suffix, ..rest] ->
      string.join(list.reverse(rest), "-") <> "-" <> left_pad_suffix(suffix, 8)
    [] -> run_id
  }
}

fn left_pad_suffix(value: String, width: Int) -> String {
  case string.length(value) >= width {
    True -> value
    False -> left_pad_suffix("0" <> value, width)
  }
}

fn read_run(path: String) -> Result(types.RunRecord, String) {
  use contents <- result.try(read_string(path))
  journal_codec.decode_run(contents)
}

fn make_run_id() -> String {
  artifact_path.timestamped_id()
}

fn repo_state_path(repo_root: String) -> String {
  project.home(repo_root)
}

fn runs_root(repo_root: String) -> String {
  project.runs_root(repo_root)
}

fn planning_root(repo_root: String) -> String {
  project.planning_root(repo_root)
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

fn is_reusable_planning_run(run: types.RunRecord) -> Bool {
  case run.status {
    types.RunPending | types.RunBlocked ->
      !list.any(run.tasks, fn(task) {
        task.state == types.Completed
        || task.state == types.Running
        || task.pr_number != ""
        || task.worktree_path != ""
      })
    _ -> False
  }
}

fn decode_event(line: String) -> Result(types.RunEvent, String) {
  journal_codec.decode_event(line)
}
