import filepath
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/domain/decisions as decision_domain
import night_shift/domain/run_state
import night_shift/git
import night_shift/journal
import night_shift/project
import night_shift/system
import night_shift/types
import night_shift/worktree_setup
import simplifile

pub fn resolve_doc_path(repo_root: String, doc_path: Option(String)) -> String {
  case doc_path {
    Some(path) -> path
    None -> project.default_brief_path(repo_root)
  }
}

pub fn resolve_environment_name(
  repo_root: String,
  requested: Option(String),
) -> Result(String, String) {
  use maybe_config <- result.try(
    worktree_setup.load(project.worktree_setup_path(repo_root)),
  )
  use selected <- result.try(worktree_setup.choose_environment(
    maybe_config,
    requested,
  ))
  case selected {
    Some(environment) -> Ok(environment.name)
    None -> Ok("")
  }
}

pub fn ensure_saved_environment_is_valid(
  repo_root: String,
  environment_name: String,
) -> Result(Nil, String) {
  case environment_name {
    "" -> Ok(Nil)
    name ->
      resolve_environment_name(repo_root, Some(name))
      |> result.map(fn(_) { Nil })
  }
}

pub fn ensure_clean_repo_for_start(
  repo_root: String,
) -> Result(List(String), String) {
  let log_path =
    filepath.join(system.state_directory(), "night-shift/start-clean.log")
  let changed_files = git.changed_files(repo_root, log_path)
  let source_changes =
    changed_files
    |> list.filter(fn(path) { !is_control_plane_path(path) })
  let control_changes =
    changed_files
    |> list.filter(is_control_plane_path)

  case source_changes, control_changes {
    [], [] -> Ok([])
    [], _ ->
      Ok([
        "Night Shift noticed repo-local control-plane changes under `.night-shift/` and will continue.\nChanged control files:\n"
        <> render_changed_paths(control_changes)
        <> "\nThese files stay in the source checkout and are not part of execution worktrees or delivery PRs.",
      ])
    _, _ ->
      Error(
        "Night Shift start requires a clean source repository so execution worktrees and delivery stay aligned.\nChanged files:\n"
        <> render_changed_paths(source_changes)
        <> start_clean_repo_suggestion(source_changes, repo_root),
      )
  }
}

pub fn resolve_notes_source(
  repo_root: String,
  notes_value: String,
) -> Result(types.NotesSource, String) {
  case simplifile.read(notes_value) {
    Ok(_) -> Ok(types.NotesFile(notes_value))
    Error(_) -> {
      let artifact_path =
        filepath.join(project.planning_root(repo_root), system.unique_id())
      let saved_path = filepath.join(artifact_path, "inline-notes.md")
      use _ <- result.try(create_directory(artifact_path))
      use _ <- result.try(write_string(saved_path, notes_value))
      Ok(types.InlineNotes(saved_path))
    }
  }
}

pub fn prepare_planning_run(
  repo_root: String,
  brief_path: String,
  planning_agent: types.ResolvedAgentConfig,
  execution_agent: types.ResolvedAgentConfig,
  environment_name: String,
  max_workers: Int,
  notes_source: types.NotesSource,
) -> Result(#(types.RunRecord, Bool), String) {
  case journal.latest_reusable_run(repo_root) {
    Ok(Some(existing_run)) -> {
      use brief_contents <- result.try(
        simplifile.read(brief_path)
        |> result.map_error(fn(error) {
          "Unable to read "
          <> brief_path
          <> ": "
          <> simplifile.describe_error(error)
        }),
      )
      use _ <- result.try(write_string(existing_run.brief_path, brief_contents))
      let updated_run =
        types.RunRecord(
          ..existing_run,
          planning_agent: planning_agent,
          execution_agent: execution_agent,
          environment_name: environment_name,
          max_workers: max_workers,
          notes_source: Some(notes_source),
          planning_dirty: True,
        )
      use rewritten_run <- result.try(journal.rewrite_run(updated_run))
      Ok(#(rewritten_run, True))
    }
    Ok(None) -> {
      use pending_run <- result.try(journal.create_pending_run(
        repo_root,
        brief_path,
        planning_agent,
        execution_agent,
        environment_name,
        max_workers,
        Some(notes_source),
      ))
      let updated_run = types.RunRecord(..pending_run, planning_dirty: True)
      journal.rewrite_run(updated_run)
      |> result.map(fn(run) { #(run, False) })
    }
    Error(message) -> Error(message)
  }
}

pub fn load_start_run(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(types.RunRecord, String) {
  case selector {
    types.RunId(_) -> {
      use #(run, _) <- result.try(journal.load(repo_root, selector))
      validate_startable_run(run)
    }
    types.LatestRun -> load_latest_start_run(repo_root)
  }
}

pub fn load_display_run(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(#(types.RunRecord, List(types.RunEvent)), String) {
  journal.load(repo_root, selector)
}

pub fn validate_startable_run(
  run: types.RunRecord,
) -> Result(types.RunRecord, String) {
  case run.status {
    types.RunPending ->
      case run.planning_dirty {
        True ->
          Error(
            "Run "
            <> run.run_id
            <> " has newer planning inputs than the current task graph. Run `night-shift resolve --run "
            <> run.run_id
            <> "` first.",
          )
        False -> Ok(run)
      }
    types.RunBlocked -> Error(start_guidance_for_run(run))
    types.RunActive ->
      Error(
        "Run "
        <> run.run_id
        <> " is already active. Use `night-shift resume --run "
        <> run.run_id
        <> "` or inspect status/report.",
      )
    types.RunCompleted ->
      Error(
        "Run "
        <> run.run_id
        <> " is already completed. Run `night-shift plan --notes ...` to create or refresh a runnable plan.",
      )
    types.RunFailed ->
      Error(
        "Run "
        <> run.run_id
        <> " already failed. Run `night-shift plan --notes ...` to create a fresh or refreshed plan.",
      )
  }
}

pub fn next_action_for_run(run: types.RunRecord) -> String {
  case run.status {
    types.RunBlocked -> "night-shift resolve"
    types.RunPending ->
      case run.planning_dirty {
        True -> "night-shift resolve"
        False -> "night-shift start"
      }
    types.RunCompleted -> "inspect report"
    types.RunFailed -> "inspect report"
    types.RunActive -> "night-shift status"
  }
}

pub fn mark_latest_persisted_run_failed(
  active_run: types.RunRecord,
  message: String,
) -> Result(types.RunRecord, String) {
  let latest_run = case
    journal.load(active_run.repo_root, types.RunId(active_run.run_id))
  {
    Ok(#(run, _)) -> recover_in_flight_tasks(run)
    Error(_) -> recover_in_flight_tasks(active_run)
  }
  journal.mark_status(latest_run, types.RunFailed, message)
}

pub fn render_changed_paths(paths: List(String)) -> String {
  paths
  |> list.map(fn(path) { "- " <> path })
  |> string.join(with: "\n")
}

pub fn create_directory(path: String) -> Result(Nil, String) {
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

pub fn write_string(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.write(contents, to: path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to write " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}

fn load_latest_start_run(repo_root: String) -> Result(types.RunRecord, String) {
  case latest_open_run(repo_root) {
    Ok(run) -> validate_startable_run(run)
    Error(_) ->
      Error(
        "No open Night Shift run was found. Run `night-shift plan --notes ...` first.",
      )
  }
}

fn latest_open_run(repo_root: String) -> Result(types.RunRecord, String) {
  use runs <- result.try(journal.list_runs(repo_root))
  case
    list.find(runs, fn(run) {
      case run.status {
        types.RunPending | types.RunBlocked | types.RunActive -> True
        _ -> False
      }
    })
  {
    Ok(run) -> Ok(run)
    Error(_) -> Error("No open Night Shift run was found.")
  }
}

fn recover_in_flight_tasks(run: types.RunRecord) -> types.RunRecord {
  let recovered_tasks =
    run.tasks
    |> list.map(fn(task) {
      case task.worktree_path {
        "" -> run_state.recover_in_flight_task(task, False)
        worktree_path ->
          run_state.recover_in_flight_task(
            task,
            git.has_changes(
              worktree_path,
              filepath.join(run.run_path, "logs/" <> task.id <> ".recovery.log"),
            ),
          )
      }
    })
  types.RunRecord(..run, tasks: recovered_tasks)
}

fn start_guidance_for_run(run: types.RunRecord) -> String {
  let outstanding = decision_domain.outstanding_decision_count(run)
  case outstanding > 0 {
    True ->
      "Run "
      <> run.run_id
      <> " is blocked on "
      <> int.to_string(outstanding)
      <> " unresolved decision(s). Run `night-shift resolve --run "
      <> run.run_id
      <> "` first."
    False ->
      case run.planning_dirty {
        True ->
          "Run "
          <> run.run_id
          <> " recorded new planning answers or notes but has not been replanned yet. Run `night-shift resolve --run "
          <> run.run_id
          <> "` first."
        False ->
          "Run "
          <> run.run_id
          <> " is blocked. Run `night-shift resolve --run "
          <> run.run_id
          <> "` first."
      }
  }
}

fn is_control_plane_path(path: String) -> Bool {
  path == ".night-shift" || string.starts_with(path, ".night-shift/")
}

fn start_clean_repo_suggestion(paths: List(String), repo_root: String) -> String {
  let only_night_shift =
    list.all(paths, fn(path) {
      path == ".night-shift" || string.starts_with(path, ".night-shift/")
    })
  case only_night_shift {
    True ->
      "\nCommit or discard those .night-shift changes before rerunning `night-shift start`, or run `night-shift reset` from "
      <> repo_root
      <> " to eject and reinitialize Night Shift."
    False ->
      "\nCommit, stash, or move those changes out of "
      <> repo_root
      <> " and rerun `night-shift start`."
  }
}
