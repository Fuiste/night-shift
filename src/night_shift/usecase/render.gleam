import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/agent_config
import night_shift/types
import night_shift/usecase/result

pub fn render_plan(view: result.PlanResult) -> String {
  prefix_warnings(
    view.warnings,
    "Planned run "
      <> view.run.run_id
      <> " with status "
      <> types.run_status_to_string(view.run.status)
      <> "\nBrief: "
      <> view.brief_path
      <> "\nNotes: "
      <> types.notes_source_label(view.notes_source)
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
  <> "\n"
  <> view.summary
  <> "\nEvents: "
  <> int.to_string(list.length(view.events))
  <> "\nReport: "
  <> view.run.report_path
}

pub fn render_start(view: result.StartResult) -> String {
  prefix_warnings(view.warnings, render_run_outcome(view.run, view.next_action))
}

pub fn render_resume(view: result.ResumeResult) -> String {
  prefix_warnings(view.warnings, render_run_outcome(view.run, view.next_action))
}

pub fn render_review(view: result.ReviewResult) -> String {
  prefix_warnings(view.warnings, render_run_outcome(view.run, view.next_action))
}

pub fn render_reset(view: result.ResetResult) -> String {
  [
    "Night Shift reset complete for " <> view.repo_root,
    "Removed worktrees: " <> int.to_string(list.length(view.removed_worktrees)),
    render_optional_list(view.removed_worktrees),
    view.prune_status,
    view.home_status,
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

fn render_run_outcome(run: types.RunRecord, next_action: String) -> String {
  "Run "
  <> run.run_id
  <> " finished with status "
  <> types.run_status_to_string(run.status)
  <> "\nPlanning: "
  <> agent_config.summary(run.planning_agent)
  <> "\nExecution: "
  <> agent_config.summary(run.execution_agent)
  <> "\nNotes: "
  <> render_notes_source(run.notes_source)
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

fn render_optional_list(entries: List(String)) -> String {
  case entries {
    [] -> ""
    _ ->
      entries
      |> list.map(fn(entry) { "- " <> entry })
      |> string.join(with: "\n")
  }
}

fn prefix_warnings(warnings: List(String), body: String) -> String {
  case warnings {
    [] -> body
    _ -> string.join(list.append(warnings, ["", body]), with: "\n")
  }
}
