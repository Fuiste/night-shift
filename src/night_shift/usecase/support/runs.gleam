import filepath
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import night_shift/domain/decisions as decision_domain
import night_shift/domain/run_state
import night_shift/git
import night_shift/journal
import night_shift/types

type BlockedRunReason {
  BlockedOnSetupRecovery(blocker: types.RecoveryBlocker)
  BlockedOnOutstandingDecisions(count: Int)
  BlockedOnPlanningSync
  BlockedOnImplementationRecovery(count: Int)
  BlockedOther
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
    types.RunBlocked -> blocked_next_action(run)
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
    decision_domain.outstanding_decision_count(run),
    decision_domain.implementation_blocking_task_count(run),
    active_recovery_blocker(run)
  {
    types.RunBlocked,
      planning_dirty,
      outstanding,
      implementation_blockers,
      blocker
    ->
      case
        outstanding > 0
        || planning_dirty
        || implementation_blockers > 0
        || blocker != None
      {
        True -> Ok(run)
        False -> Error(resolve_guidance_for_run(run))
      }
    types.RunPending, True, _, _, _ -> Ok(run)
    types.RunPending, False, _, _, _ ->
      Error(
        "Run "
        <> run.run_id
        <> " is already ready to start. Run `night-shift start --run "
        <> run.run_id
        <> "`.",
      )
    types.RunActive, _, _, _, _ ->
      Error(
        "Run " <> run.run_id <> " is active and cannot be resolved right now.",
      )
    types.RunCompleted, _, _, _, _ ->
      Error("Run " <> run.run_id <> " is already completed.")
    types.RunFailed, _, _, _, _ ->
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

fn blocked_next_action(run: types.RunRecord) -> String {
  case blocked_run_reason(run) {
    BlockedOnSetupRecovery(_) -> "night-shift resolve"
    BlockedOnOutstandingDecisions(_) -> "night-shift resolve"
    BlockedOnPlanningSync -> "night-shift resolve"
    BlockedOnImplementationRecovery(_) ->
      "inspect the report and retained worktree"
    BlockedOther -> "inspect the report"
  }
}

fn start_guidance_for_run(run: types.RunRecord) -> String {
  case blocked_run_reason(run) {
    BlockedOnSetupRecovery(blocker) ->
      "Run "
      <> run.run_id
      <> " is blocked before implementation could begin. Review-driven planning succeeded, but Night Shift stopped during "
      <> types.recovery_blocker_phase_to_string(blocker.phase)
      <> " "
      <> types.recovery_blocker_kind_to_string(blocker.kind)
      <> ". Inspect "
      <> blocker.log_path
      <> " and run `night-shift resolve --run "
      <> run.run_id
      <> "`."
    BlockedOnOutstandingDecisions(outstanding) ->
      "Run "
      <> run.run_id
      <> " is blocked on "
      <> int.to_string(outstanding)
      <> " unresolved decision(s). Run `night-shift resolve --run "
      <> run.run_id
      <> "` first."
    BlockedOnPlanningSync ->
      "Run "
      <> run.run_id
      <> " recorded new planning answers or notes but has not been replanned yet. Run `night-shift resolve --run "
      <> run.run_id
      <> "` first."
    BlockedOnImplementationRecovery(count) ->
      "Run "
      <> run.run_id
      <> " is blocked because "
      <> int.to_string(count)
      <> " interrupted implementation task"
      <> plural_suffix(count)
      <> " now require"
      <> verb_suffix(count)
      <> " manual recovery. Inspect "
      <> run.report_path
      <> " and the retained worktree before replanning or continuing manually."
    BlockedOther ->
      "Run "
      <> run.run_id
      <> " is blocked. Inspect "
      <> run.report_path
      <> " before deciding whether to replan or recover manually."
  }
}

fn resolve_guidance_for_run(run: types.RunRecord) -> String {
  case blocked_run_reason(run) {
    BlockedOnSetupRecovery(_) ->
      "Run "
      <> run.run_id
      <> " still needs `night-shift resolve` before it can continue past the saved setup blocker."
    BlockedOnOutstandingDecisions(_) | BlockedOnPlanningSync ->
      "Run "
      <> run.run_id
      <> " still needs `night-shift resolve` before it can start."
    BlockedOnImplementationRecovery(_) ->
      "Run "
      <> run.run_id
      <> " is blocked by interrupted implementation work, not unresolved planning questions. Inspect "
      <> run.report_path
      <> " and the retained worktree before replanning or continuing manually."
    BlockedOther ->
      "Run "
      <> run.run_id
      <> " is blocked, but `night-shift resolve` cannot clear it. Inspect "
      <> run.report_path
      <> " before deciding whether to replan or recover manually."
  }
}

pub fn recovery_recommendation_for_run(run: types.RunRecord) -> String {
  case blocked_run_reason(run) {
    BlockedOnSetupRecovery(_) ->
      "Inspect the saved setup blocker first; `resolve` can explain the failed gate and either continue with a one-shot waiver or abandon the run."
    BlockedOnOutstandingDecisions(_) ->
      "Resolve the outstanding planning decisions first; `resume` would not safely clear them."
    BlockedOnPlanningSync ->
      "Run `night-shift resolve` first so Night Shift can replan with the saved answers or notes."
    BlockedOnImplementationRecovery(_) ->
      "Inspect the report and retained worktree for the interrupted implementation task before replanning or continuing manually."
    BlockedOther ->
      "Inspect the report and task logs before deciding whether to replan or recover manually."
  }
}

fn blocked_run_reason(run: types.RunRecord) -> BlockedRunReason {
  let outstanding = decision_domain.outstanding_decision_count(run)
  let implementation_blockers =
    decision_domain.implementation_blocking_task_count(run)

  case active_recovery_blocker(run) {
    Some(blocker) -> BlockedOnSetupRecovery(blocker)
    None ->
      case outstanding > 0 {
        True -> BlockedOnOutstandingDecisions(outstanding)
        False ->
          case run.planning_dirty {
            True -> BlockedOnPlanningSync
            False ->
              case implementation_blockers > 0 {
                True -> BlockedOnImplementationRecovery(implementation_blockers)
                False -> BlockedOther
              }
          }
      }
  }
}

pub fn active_recovery_blocker(
  run: types.RunRecord,
) -> Option(types.RecoveryBlocker) {
  case run.recovery_blocker {
    Some(blocker) ->
      case blocker.disposition == types.RecoveryBlocking {
        True -> Some(blocker)
        False -> None
      }
    _ -> None
  }
}

pub fn run_has_pending_recovery_bypass(run: types.RunRecord) -> Bool {
  case run.recovery_blocker {
    Some(blocker) -> blocker.disposition == types.RecoveryWaivedOnce
    None -> False
  }
}

pub fn recovery_blocker_task_id(run: types.RunRecord) -> Option(String) {
  case run.recovery_blocker {
    Some(blocker) -> blocker.task_id
    None -> None
  }
}

pub fn recovery_blocker_for_task(
  run: types.RunRecord,
  task_id: String,
) -> Option(types.RecoveryBlocker) {
  case run.recovery_blocker {
    Some(blocker) if blocker.task_id == Some(task_id) -> Some(blocker)
    _ -> None
  }
}

pub fn clear_recovery_blocker(run: types.RunRecord) -> types.RunRecord {
  types.RunRecord(..run, recovery_blocker: None)
}

pub fn with_recovery_blocker(
  run: types.RunRecord,
  blocker: types.RecoveryBlocker,
) -> types.RunRecord {
  types.RunRecord(..run, recovery_blocker: Some(blocker))
}

pub fn with_pending_recovery_bypass(
  run: types.RunRecord,
  blocker: types.RecoveryBlocker,
) -> types.RunRecord {
  types.RunRecord(
    ..run,
    recovery_blocker: Some(
      types.RecoveryBlocker(..blocker, disposition: types.RecoveryWaivedOnce),
    ),
  )
}

pub fn consume_recovery_bypass(
  run: types.RunRecord,
  kind: types.RecoveryBlockerKind,
  phase: types.RecoveryBlockerPhase,
  task_id: Option(String),
) -> types.RunRecord {
  case run.recovery_blocker {
    Some(blocker)
      if blocker.kind == kind
      && blocker.phase == phase
      && blocker.task_id == task_id
      && blocker.disposition == types.RecoveryWaivedOnce
    -> types.RunRecord(..run, recovery_blocker: None)
    _ -> run
  }
}

pub fn recovery_bypass_matches(
  run: types.RunRecord,
  kind: types.RecoveryBlockerKind,
  phase: types.RecoveryBlockerPhase,
  task_id: Option(String),
) -> Bool {
  case run.recovery_blocker {
    Some(blocker) ->
      blocker.kind == kind
      && blocker.phase == phase
      && blocker.task_id == task_id
      && blocker.disposition == types.RecoveryWaivedOnce
    None -> False
  }
}

fn plural_suffix(count: Int) -> String {
  case count == 1 {
    True -> ""
    False -> "s"
  }
}

fn verb_suffix(count: Int) -> String {
  case count == 1 {
    True -> "s"
    False -> ""
  }
}
