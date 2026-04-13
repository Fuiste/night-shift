import filepath
import gleam/int
import gleam/option.{type Option, None, Some}
import night_shift/domain/repo_state
import night_shift/github
import night_shift/system
import night_shift/types

pub type RepoStateDrift {
  RepoStateStable
  RepoStateDrifted
  RepoStateDriftUnknown(message: String)
}

pub type RepoStateView {
  RepoStateView(
    snapshot_captured_at: String,
    open_pr_count: Int,
    actionable_pr_count: Int,
    drift: RepoStateDrift,
  )
}

pub type Inspection {
  Inspection(
    view: Option(RepoStateView),
    warnings: List(String),
    events: List(types.RunEvent),
  )
}

pub fn inspect(run: types.RunRecord, branch_prefix: String) -> Inspection {
  case run.repo_state_snapshot {
    None -> Inspection(view: None, warnings: [], events: [])
    Some(stored_snapshot) -> {
      let log_path =
        filepath.join(
          run.run_path,
          "logs/repo-state-" <> system.unique_id() <> ".log",
        )

      case github.repo_state_snapshot(run.repo_root, branch_prefix, log_path) {
        Ok(live_snapshot) -> {
          let drift = case repo_state.drifted(stored_snapshot, live_snapshot) {
            True -> RepoStateDrifted
            False -> RepoStateStable
          }
          let view =
            RepoStateView(
              snapshot_captured_at: stored_snapshot.captured_at,
              open_pr_count: repo_state.open_pr_count(live_snapshot),
              actionable_pr_count: repo_state.actionable_pr_count(live_snapshot),
              drift: drift,
            )
          Inspection(
            view: Some(view),
            warnings: drift_warnings(view),
            events: drift_events(view),
          )
        }
        Error(message) -> {
          let view =
            RepoStateView(
              snapshot_captured_at: stored_snapshot.captured_at,
              open_pr_count: repo_state.open_pr_count(stored_snapshot),
              actionable_pr_count: repo_state.actionable_pr_count(stored_snapshot),
              drift: RepoStateDriftUnknown(message),
            )
          Inspection(
            view: Some(view),
            warnings: drift_warnings(view),
            events: drift_events(view),
          )
        }
      }
    }
  }
}

pub fn render_summary(view: RepoStateView) -> String {
  "Open PRs: "
  <> int.to_string(view.open_pr_count)
  <> "\nActionable PRs: "
  <> int.to_string(view.actionable_pr_count)
  <> "\nSnapshot captured: "
  <> view.snapshot_captured_at
  <> "\nDrift: "
  <> drift_label(view.drift)
}

pub fn drift_label(drift: RepoStateDrift) -> String {
  case drift {
    RepoStateStable -> "no"
    RepoStateDrifted -> "yes"
    RepoStateDriftUnknown(_) -> "unknown"
  }
}

fn drift_warnings(view: RepoStateView) -> List(String) {
  case view.drift {
    RepoStateStable -> []
    RepoStateDrifted ->
      [
        "Repo state drift detected: open Night Shift PRs changed since planning. Consider `night-shift plan --from-reviews` before continuing execution.",
      ]
    RepoStateDriftUnknown(message) ->
      [
        "Repo state warning: unable to refresh open Night Shift PRs; using the snapshot captured at "
        <> view.snapshot_captured_at
        <> ". "
        <> message,
      ]
  }
}

fn drift_events(view: RepoStateView) -> List(types.RunEvent) {
  case view.drift {
    RepoStateStable -> []
    RepoStateDrifted ->
      [
        types.RunEvent(
          kind: "repo_state_drift",
          at: system.timestamp(),
          message: "Open Night Shift PRs drifted since planning. Snapshot captured at "
            <> view.snapshot_captured_at
            <> " now differs from the live PR tree (open: "
            <> int.to_string(view.open_pr_count)
            <> ", actionable: "
            <> int.to_string(view.actionable_pr_count)
            <> "). Consider `night-shift plan --from-reviews` before continuing.",
          task_id: None,
        ),
      ]
    RepoStateDriftUnknown(message) ->
      [
        types.RunEvent(
          kind: "repo_state_warning",
          at: system.timestamp(),
          message: "Unable to refresh open Night Shift PR snapshot captured at "
            <> view.snapshot_captured_at
            <> ": "
            <> message,
          task_id: None,
        ),
      ]
  }
}
