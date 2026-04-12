import filepath
import gleam/int
import gleam/list
import gleam/result
import night_shift/domain/decisions as decision_domain
import night_shift/domain/run_state
import night_shift/git
import night_shift/journal
import night_shift/types

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

pub fn load_resolvable_run(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(types.RunRecord, String) {
  case selector {
    types.RunId(_) -> {
      use #(run, _) <- result.try(journal.load(repo_root, selector))
      validate_resolvable_run(run)
    }
    types.LatestRun -> load_latest_resolvable_run(repo_root)
  }
}

pub fn load_display_run(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(#(types.RunRecord, List(types.RunEvent)), String) {
  journal.load(repo_root, selector)
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

fn validate_startable_run(
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

fn validate_resolvable_run(
  run: types.RunRecord,
) -> Result(types.RunRecord, String) {
  case
    run.status,
    run.planning_dirty,
    decision_domain.outstanding_decision_count(run)
  {
    types.RunBlocked, _, _ -> Ok(run)
    types.RunPending, True, _ -> Ok(run)
    types.RunPending, False, _ ->
      Error(
        "Run "
        <> run.run_id
        <> " is already ready to start. Run `night-shift start --run "
        <> run.run_id
        <> "`.",
      )
    types.RunActive, _, _ ->
      Error(
        "Run " <> run.run_id <> " is active and cannot be resolved right now.",
      )
    types.RunCompleted, _, _ ->
      Error("Run " <> run.run_id <> " is already completed.")
    types.RunFailed, _, _ ->
      Error("Run " <> run.run_id <> " failed and cannot be resolved in place.")
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

fn load_latest_resolvable_run(
  repo_root: String,
) -> Result(types.RunRecord, String) {
  case latest_open_run(repo_root) {
    Ok(run) -> validate_resolvable_run(run)
    Error(_) ->
      Error(
        "No blocked Night Shift run was found. Run `night-shift plan --notes ...` first.",
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
