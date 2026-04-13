import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/agent_config
import night_shift/domain/decisions as decision_domain
import night_shift/domain/review_run_projection
import night_shift/repo_state_runtime
import night_shift/types
import night_shift/usecase/result

pub fn render_init(view: result.InitResult) -> String {
  "Initialized "
  <> view.repo_root
  <> "/.night-shift"
  <> "\nConfig: "
  <> view.config_status
  <> "\nWorktree setup: "
  <> view.setup_status
  <> "\nNext action: "
  <> view.next_action
}

pub fn render_plan(view: result.PlanResult) -> String {
  prefix_warnings(
    view.warnings,
    "Planned run "
      <> view.run.run_id
      <> " with status "
      <> types.run_status_to_string(view.run.status)
      <> "\nBrief: "
      <> view.brief_path
      <> "\nPlanning input: "
      <> types.planning_provenance_label(view.planning_provenance)
      <> "\nNotes: "
      <> render_notes_source(types.planning_provenance_notes_source(
      view.planning_provenance,
    ))
      <> "\nPlanning: "
      <> agent_config.summary(view.run.planning_agent)
      <> "\nArtifacts: "
      <> view.artifact_path
      <> "\nReport: "
      <> view.run.report_path
      <> "\nNext action: "
      <> view.next_action,
  )
}

pub fn render_status(view: result.StatusResult) -> String {
  "Run "
  <> view.run.run_id
  <> " is "
  <> types.run_status_to_string(view.run.status)
  <> "\nPlanning: "
  <> agent_config.summary(view.run.planning_agent)
  <> "\nExecution: "
  <> agent_config.summary(view.run.execution_agent)
  <> "\nNotes: "
  <> render_notes_source(view.run.notes_source)
  <> render_repo_state_fragment(view.run, view.repo_state_view)
  <> "\n"
  <> view.summary
  <> "\nEvents: "
  <> int.to_string(list.length(view.events))
  <> "\nReport: "
  <> view.run.report_path
}

pub fn render_resolve(view: result.ResolveResult) -> String {
  prefix_warnings(view.warnings, case view.summary {
    Some(message) -> message
    None -> render_run_outcome(view.run, view.next_action, None)
  })
}

pub fn render_start(view: result.StartResult) -> String {
  prefix_warnings(
    view.warnings,
    render_run_outcome(view.run, view.next_action, view.repo_state_view),
  )
}

pub fn render_resume(view: result.ResumeResult) -> String {
  prefix_warnings(
    view.warnings,
    render_run_outcome(view.run, view.next_action, view.repo_state_view),
  )
}

pub fn render_reset(view: result.ResetResult) -> String {
  [
    "Night Shift reset complete for " <> view.repo_root,
    "Removed worktrees: " <> int.to_string(list.length(view.removed_worktrees)),
    render_optional_list(view.removed_worktrees),
    view.prune_status,
    view.home_status,
    "Local Night Shift branches and remote PRs were not modified.",
    case view.failed_worktrees {
      [] -> ""
      _ ->
        "Worktree cleanup warnings:\n"
        <> string.join(
          view.failed_worktrees |> list.map(fn(entry) { "- " <> entry }),
          with: "\n",
        )
    },
    "Next action: " <> view.next_action,
  ]
  |> list.filter(fn(line) { string.trim(line) != "" })
  |> string.join(with: "\n")
}

pub fn render_resolve_prompt(run: types.RunRecord) -> String {
  "\nResolving run "
  <> run.run_id
  <> "\nBlocked tasks: "
  <> int.to_string(decision_domain.blocked_task_count(run))
  <> "\nOutstanding decisions: "
  <> int.to_string(decision_domain.outstanding_decision_count(run))
  <> "\nPlanning sync pending: "
  <> bool_label(run.planning_dirty)
  <> "\nNext action: answer the questions below to make this run ready to start."
}

fn render_run_outcome(
  run: types.RunRecord,
  next_action: String,
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> String {
  "Run "
  <> run.run_id
  <> " finished with status "
  <> types.run_status_to_string(run.status)
  <> "\nPlanning: "
  <> agent_config.summary(run.planning_agent)
  <> "\nExecution: "
  <> agent_config.summary(run.execution_agent)
  <> "\nPlanning input: "
  <> render_planning_provenance(run.planning_provenance)
  <> "\nNotes: "
  <> render_notes_source(run.notes_source)
  <> render_repo_state_fragment(run, repo_state_view)
  <> "\nReport: "
  <> run.report_path
  <> "\nJournal: "
  <> run.run_path
  <> "\nNext action: "
  <> next_action
}

fn render_notes_source(notes_source: Option(types.NotesSource)) -> String {
  case notes_source {
    Some(source) -> types.notes_source_label(source)
    None -> "(none)"
  }
}

fn render_planning_provenance(
  planning_provenance: Option(types.PlanningProvenance),
) -> String {
  case planning_provenance {
    Some(provenance) -> types.planning_provenance_label(provenance)
    None -> "(legacy)"
  }
}

fn render_optional_list(entries: List(String)) -> String {
  case entries {
    [] -> ""
    _ ->
      entries
      |> list.map(fn(entry) { "- " <> entry })
      |> string.join(with: "\n")
  }
}

fn render_repo_state_fragment(
  run: types.RunRecord,
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> String {
  case review_run_projection.repo_state_summary(run, repo_state_view) {
    Some(summary) -> "\n" <> review_run_projection.render_status_lines(summary)
    None ->
      case repo_state_view {
        Some(view) -> "\n" <> repo_state_runtime.render_summary(view)
        None -> ""
      }
  }
}

fn prefix_warnings(warnings: List(String), body: String) -> String {
  case warnings {
    [] -> body
    _ -> string.join(list.append(warnings, ["", body]), with: "\n")
  }
}

fn bool_label(value: Bool) -> String {
  case value {
    True -> "yes"
    False -> "no"
  }
}
