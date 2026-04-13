import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/domain/repo_state
import night_shift/repo_state_runtime
import night_shift/types

pub type RepoStateSummary {
  RepoStateSummary(
    captured_open_pr_count: Int,
    captured_actionable_pr_count: Int,
    snapshot_captured_at: String,
    current_open_pr_count: Option(Int),
    current_actionable_pr_count: Option(Int),
    drift: Option(String),
    drift_details: Option(String),
    actionable_pull_requests: List(repo_state.RepoPullRequestSnapshot),
    impacted_pull_requests: List(repo_state.RepoPullRequestSnapshot),
  )
}

pub type ReplacementLineageEntry {
  ReplacementLineageEntry(
    task_id: String,
    superseded_pr_numbers: List(Int),
    replacement_pr_number: Option(String),
  )
}

pub type ReviewRunProjection {
  ReviewRunProjection(
    repo_state: RepoStateSummary,
    lineage_entries: List(ReplacementLineageEntry),
    supersession_outcomes: List(String),
    supersession_warnings: List(String),
  )
}

pub fn build(
  run: types.RunRecord,
  events: List(types.RunEvent),
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> Option(ReviewRunProjection) {
  case repo_state_summary(run, repo_state_view) {
    Some(summary) ->
      Some(ReviewRunProjection(
        repo_state: summary,
        lineage_entries: lineage_entries(run.tasks),
        supersession_outcomes: event_messages(events, "pr_superseded"),
        supersession_warnings: event_messages(
          events,
          "review_supersession_warning",
        ),
      ))
    None -> None
  }
}

pub fn repo_state_summary(
  run: types.RunRecord,
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> Option(RepoStateSummary) {
  case run.repo_state_snapshot {
    Some(snapshot) ->
      Some(RepoStateSummary(
        captured_open_pr_count: repo_state.open_pr_count(snapshot),
        captured_actionable_pr_count: repo_state.actionable_pr_count(snapshot),
        snapshot_captured_at: snapshot.captured_at,
        current_open_pr_count: current_open_pr_count(repo_state_view),
        current_actionable_pr_count: current_actionable_pr_count(
          repo_state_view,
        ),
        drift: current_drift(repo_state_view),
        drift_details: current_drift_details(repo_state_view),
        actionable_pull_requests: list.filter(
          snapshot.open_pull_requests,
          fn(pr) { pr.actionable },
        ),
        impacted_pull_requests: list.filter(snapshot.open_pull_requests, fn(pr) {
          pr.impacted
        }),
      ))
    None -> None
  }
}

pub fn render_status_lines(summary: RepoStateSummary) -> String {
  [
    "Open PRs: " <> int.to_string(current_or_captured_open_count(summary)),
    "Actionable PRs: "
      <> int.to_string(current_or_captured_actionable_count(summary)),
    "Snapshot captured: " <> summary.snapshot_captured_at,
    "Drift: " <> unwrap_or(summary.drift, "unknown"),
  ]
  |> list.append(case summary.drift_details {
    Some(details) -> ["Drift details: " <> details]
    None -> []
  })
  |> string.join(with: "\n")
}

pub fn current_or_captured_open_count(summary: RepoStateSummary) -> Int {
  unwrap_or(summary.current_open_pr_count, summary.captured_open_pr_count)
}

pub fn current_or_captured_actionable_count(summary: RepoStateSummary) -> Int {
  unwrap_or(
    summary.current_actionable_pr_count,
    summary.captured_actionable_pr_count,
  )
}

fn current_open_pr_count(
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> Option(Int) {
  case repo_state_view {
    Some(view) -> Some(view.open_pr_count)
    None -> None
  }
}

fn current_actionable_pr_count(
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> Option(Int) {
  case repo_state_view {
    Some(view) -> Some(view.actionable_pr_count)
    None -> None
  }
}

fn current_drift(
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> Option(String) {
  case repo_state_view {
    Some(view) -> Some(repo_state_runtime.drift_label(view.drift))
    None -> None
  }
}

fn current_drift_details(
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> Option(String) {
  case repo_state_view {
    Some(view) ->
      case view.drift {
        repo_state_runtime.RepoStateDriftUnknown(message) -> Some(message)
        _ -> None
      }
    None -> None
  }
}

fn lineage_entries(tasks: List(types.Task)) -> List(ReplacementLineageEntry) {
  tasks
  |> list.filter_map(fn(task) {
    case task.superseded_pr_numbers {
      [] -> Error(Nil)
      superseded_pr_numbers ->
        Ok(ReplacementLineageEntry(
          task_id: task.id,
          superseded_pr_numbers: superseded_pr_numbers,
          replacement_pr_number: parse_replacement_pr_number(task.pr_number),
        ))
    }
  })
}

fn parse_replacement_pr_number(pr_number: String) -> Option(String) {
  case string.trim(pr_number) {
    "" -> None
    value -> Some(value)
  }
}

fn unwrap_or(value: Option(a), fallback: a) -> a {
  case value {
    Some(inner) -> inner
    None -> fallback
  }
}

fn event_messages(events: List(types.RunEvent), kind: String) -> List(String) {
  events
  |> list.filter(fn(event) { event.kind == kind })
  |> list.map(fn(event) { event.message })
}

pub fn render_lineage_entry(entry: ReplacementLineageEntry) -> String {
  let replacement_fragment = case entry.replacement_pr_number {
    Some(pr_number) -> "replacement PR #" <> pr_number
    None -> "replacement PR pending"
  }
  "- "
  <> entry.task_id
  <> " -> supersedes "
  <> render_pr_numbers(entry.superseded_pr_numbers)
  <> " ("
  <> replacement_fragment
  <> ")"
}

fn render_pr_numbers(pr_numbers: List(Int)) -> String {
  pr_numbers
  |> list.map(fn(pr_number) { "#" <> int.to_string(pr_number) })
  |> string.join(with: ", ")
}
