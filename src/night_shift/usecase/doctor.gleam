import filepath
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/git
import night_shift/journal
import night_shift/project
import night_shift/repo_state_runtime
import night_shift/types
import night_shift/usecase/support/runs
import simplifile

pub fn execute(
  repo_root: String,
  selector: types.RunSelector,
  config: types.Config,
) -> Result(String, String) {
  use #(run, events) <- result.try(journal.load(repo_root, selector))
  let repo_state_view =
    repo_state_runtime.inspect(run, config.branch_prefix).view
  let active_lock = active_lock_state(repo_root, run.run_id)
  let assessments =
    run.tasks |> list.map(diagnose_task(repo_root, run.run_path, _))
  let recommendation =
    recommend_next_action(run, events, active_lock, assessments)

  Ok(render_doctor(
    run,
    repo_state_view,
    active_lock,
    recommendation,
    assessments,
  ))
}

type ActiveLockState {
  ActiveLockMissing
  ActiveLockMatched
  ActiveLockMismatch(run_id: String)
}

type TaskAssessment {
  TaskAssessment(
    task: types.Task,
    classification: types.RecoveryClassification,
    reasons: List(String),
  )
}

fn render_doctor(
  run: types.RunRecord,
  repo_state_view: Option(repo_state_runtime.RepoStateView),
  active_lock: ActiveLockState,
  recommendation: String,
  assessments: List(TaskAssessment),
) -> String {
  [
    "# Night Shift Recovery Doctor",
    "",
    "## Run",
    "- Run ID: " <> run.run_id,
    "- Status: " <> types.run_status_to_string(run.status),
    "- Active lock: " <> active_lock_label(active_lock),
    "- Recommendation: " <> recommendation,
    case repo_state_view {
      Some(view) ->
        "- Review drift: " <> repo_state_runtime.drift_label(view.drift)
      None -> ""
    },
    "",
    "## Task Assessments",
    render_task_assessments(assessments),
  ]
  |> list.filter(fn(line) { line != "" })
  |> string.join(with: "\n")
}

fn render_task_assessments(assessments: List(TaskAssessment)) -> String {
  case assessments {
    [] -> "- No tasks are recorded for this run."
    _ ->
      assessments
      |> list.map(fn(assessment) {
        "- "
        <> assessment.task.id
        <> " ["
        <> types.recovery_classification_to_string(assessment.classification)
        <> "] "
        <> assessment.task.title
        <> "\n  "
        <> string.join(assessment.reasons, with: "\n  ")
      })
      |> string.join(with: "\n")
  }
}

fn active_lock_state(repo_root: String, run_id: String) -> ActiveLockState {
  case simplifile.read(project.active_lock_path(repo_root)) {
    Ok(contents) ->
      case string.trim(contents) {
        value if value == run_id -> ActiveLockMatched
        value -> ActiveLockMismatch(value)
      }
    Error(_) -> ActiveLockMissing
  }
}

fn active_lock_label(state: ActiveLockState) -> String {
  case state {
    ActiveLockMatched -> "matched"
    ActiveLockMissing -> "missing"
    ActiveLockMismatch(run_id) -> "points at " <> run_id
  }
}

fn diagnose_task(
  repo_root: String,
  run_path: String,
  task: types.Task,
) -> TaskAssessment {
  let git_log = filepath.join(run_path, "logs/" <> task.id <> ".doctor.git.log")
  let execution_log = filepath.join(run_path, "logs/" <> task.id <> ".log")
  let worktree_exists = case task.worktree_path {
    "" -> False
    path -> directory_exists(path)
  }
  let mounted_worktree = case task.branch_name {
    "" -> Ok(None)
    _ -> git.mounted_worktree_path(repo_root, task.branch_name, git_log)
  }

  case task.state {
    types.Completed ->
      TaskAssessment(task: task, classification: types.SafeToResume, reasons: [
        "Task is already completed and does not need recovery work.",
      ])
    types.Ready | types.Queued ->
      TaskAssessment(task: task, classification: types.SafeToResume, reasons: [
        "Task has not started yet; resume would schedule it normally.",
      ])
    types.Blocked | types.ManualAttention ->
      TaskAssessment(
        task: task,
        classification: types.RecoveryManualAttention,
        reasons: [
          "Task already requires operator attention before Night Shift can continue.",
        ],
      )
    types.Failed ->
      TaskAssessment(
        task: task,
        classification: types.RecoveryManualAttention,
        reasons: [
          "Task is already failed; inspect its report and logs before retrying.",
        ],
      )
    types.Running ->
      diagnose_running_task(
        task,
        run_path,
        execution_log,
        worktree_exists,
        mounted_worktree,
      )
  }
}

fn diagnose_running_task(
  task: types.Task,
  run_path: String,
  execution_log: String,
  worktree_exists: Bool,
  mounted_worktree: Result(Option(String), String),
) -> TaskAssessment {
  case task.worktree_path {
    "" ->
      TaskAssessment(
        task: task,
        classification: types.RecoveryIrrecoverable,
        reasons: [
          "Task was running, but no worktree path was recorded.",
        ],
      )
    _ ->
      case worktree_exists {
        False ->
          TaskAssessment(
            task: task,
            classification: types.RecoveryIrrecoverable,
            reasons: [
              "Recorded worktree path no longer exists on disk.",
            ],
          )
        True -> {
          let doctor_git_log =
            filepath.join(
              run_path,
              "logs/" <> task.id <> ".doctor.has-changes.log",
            )
          case git.has_changes(task.worktree_path, doctor_git_log) {
            True ->
              TaskAssessment(
                task: task,
                classification: types.RecoveryManualAttention,
                reasons: [
                  "Worktree has uncommitted changes; `resume` would convert this task into manual attention.",
                ],
              )
            False ->
              diagnose_clean_running_task(task, execution_log, mounted_worktree)
          }
        }
      }
  }
}

fn diagnose_clean_running_task(
  task: types.Task,
  execution_log: String,
  mounted_worktree: Result(Option(String), String),
) -> TaskAssessment {
  case mounted_worktree {
    Error(message) ->
      TaskAssessment(
        task: task,
        classification: types.ResumeWithWarning,
        reasons: [
          "Night Shift could not confirm the mounted worktree for this branch.",
          message,
        ],
      )
    Ok(Some(mounted_path)) ->
      case mounted_path == task.worktree_path, file_exists(execution_log) {
        False, _ ->
          TaskAssessment(
            task: task,
            classification: types.ResumeWithWarning,
            reasons: [
              "Branch is mounted at a different path than the run journal recorded.",
              "Recorded path: " <> task.worktree_path,
              "Mounted path: " <> mounted_path,
            ],
          )
        True, False ->
          TaskAssessment(
            task: task,
            classification: types.ResumeWithWarning,
            reasons: [
              "Execution log is missing, so recovery evidence is incomplete.",
              "Expected log: " <> execution_log,
            ],
          )
        True, True ->
          TaskAssessment(
            task: task,
            classification: types.SafeToResume,
            reasons: [
              "Worktree is mounted, clean, and matches the recorded branch.",
              "`resume` should requeue this interrupted task safely.",
            ],
          )
      }
    Ok(None) ->
      TaskAssessment(
        task: task,
        classification: types.ResumeWithWarning,
        reasons: [
          "Branch is not mounted in git worktree metadata; Night Shift may need to reattach it during recovery.",
        ],
      )
  }
}

fn recommend_next_action(
  run: types.RunRecord,
  _events: List(types.RunEvent),
  active_lock: ActiveLockState,
  assessments: List(TaskAssessment),
) -> String {
  case active_recovery_blocker(run) {
    Some(blocker) ->
      "Inspect the blocked-before-implementation setup gate first: "
      <> types.recovery_blocker_phase_to_string(blocker.phase)
      <> " "
      <> types.recovery_blocker_kind_to_string(blocker.kind)
      <> ". Review "
      <> blocker.log_path
      <> " and use `night-shift resolve` to inspect, continue, or abandon the run."
    None ->
      case runs.pending_recovery_bypass(run) {
        Some(blocker) ->
          "A one-shot setup retry is armed for "
          <> types.recovery_blocker_phase_to_string(blocker.phase)
          <> " "
          <> types.recovery_blocker_kind_to_string(blocker.kind)
          <> ". Run `night-shift start` to retry from the waived gate."
        None ->
          case run.status {
            types.RunCompleted ->
              "This run is already completed; inspect the report and retained worktrees instead of resuming."
            _ ->
              case
                has_classification(assessments, types.RecoveryIrrecoverable)
              {
                True ->
                  "At least one task is irrecoverable from saved state; inspect the journal and replan rather than resuming."
                False ->
                  case
                    has_classification(
                      assessments,
                      types.RecoveryManualAttention,
                    )
                  {
                    True -> runs.recovery_recommendation_for_run(run)
                    False ->
                      case active_lock {
                        ActiveLockMismatch(other_run_id) ->
                          "Another run lock is active ("
                          <> other_run_id
                          <> "); clear that ambiguity before resuming."
                        _ ->
                          case
                            has_classification(
                              assessments,
                              types.ResumeWithWarning,
                            )
                          {
                            True ->
                              "Resume is possible, but review the warnings above before you let Night Shift continue."
                            False ->
                              "Resume should be safe from the saved run state."
                          }
                      }
                  }
              }
          }
      }
  }
}

fn has_classification(
  assessments: List(TaskAssessment),
  target: types.RecoveryClassification,
) -> Bool {
  list.any(assessments, fn(assessment) { assessment.classification == target })
}

fn active_recovery_blocker(
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

fn directory_exists(path: String) -> Bool {
  case simplifile.read_directory(at: path) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn file_exists(path: String) -> Bool {
  case simplifile.read(path) {
    Ok(_) -> True
    Error(_) -> False
  }
}
