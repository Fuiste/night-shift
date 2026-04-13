import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/domain/repo_state
import night_shift/types

pub const body_start_marker = "<!-- night-shift:handoff-body:start -->"
pub const body_end_marker = "<!-- night-shift:handoff-body:end -->"

pub type Snippets {
  Snippets(
    body_prefix: Option(String),
    body_suffix: Option(String),
    comment_prefix: Option(String),
    comment_suffix: Option(String),
  )
}

pub type RepoStateStatus {
  RepoStateStatus(drift: String, open_pr_count: Int, actionable_pr_count: Int)
}

pub fn empty_snippets() -> Snippets {
  Snippets(
    body_prefix: None,
    body_suffix: None,
    comment_prefix: None,
    comment_suffix: None,
  )
}

pub fn verification_digest(output: String) -> String {
  repo_state.text_digest(output)
}

pub fn body_region_enabled(handoff: types.HandoffConfig) -> Bool {
  handoff.enabled && handoff.pr_body_mode != types.HandoffBodyOff
}

pub fn wrap_body_region(content: String) -> String {
  body_start_marker <> "\n" <> content <> "\n" <> body_end_marker
}

pub fn comment_marker(task_id: String) -> String {
  "<!-- night-shift:handoff-comment:task=" <> task_id <> " -->"
}

pub fn render_body_region(
  handoff: types.HandoffConfig,
  run: types.RunRecord,
  task: types.Task,
  execution_result: types.ExecutionResult,
  verification_output: String,
  snippets: Snippets,
) -> String {
  let sections =
    [
      render_optional(snippets.body_prefix),
      "## Context\n" <> render_context(run, task),
      render_scope(handoff, task, execution_result),
      "## Summary\n" <> fallback_text(execution_result.pr.summary),
      render_evidence(handoff, execution_result, verification_output),
      "## Known Risks\n" <> bullet_list(execution_result.pr.risks),
      render_provenance(handoff.provenance, run, task, execution_result, verification_output),
      render_optional(snippets.body_suffix),
    ]
    |> list.filter(fn(section) { string.trim(section) != "" })
    |> string.join(with: "\n\n")

  wrap_body_region(sections)
}

pub fn render_managed_comment(
  run: types.RunRecord,
  task: types.Task,
  execution_result: types.ExecutionResult,
  verification_output: String,
  previous_state: Option(types.TaskHandoffState),
  repo_state_status: Option(RepoStateStatus),
  snippets: Snippets,
) -> String {
  [
    render_optional(snippets.comment_prefix),
    "## Since Last Review\n"
      <> render_delta(previous_state, execution_result, verification_output),
    "## Review Feedback Status\n" <> render_review_feedback_status(run),
    render_stack_status(task, repo_state_status),
    render_optional(snippets.comment_suffix),
    comment_marker(task.id),
  ]
  |> list.filter(fn(section) { string.trim(section) != "" })
  |> string.join(with: "\n\n")
}

fn render_context(run: types.RunRecord, task: types.Task) -> String {
  let origin = case run.planning_provenance {
    Some(provenance) ->
      case types.planning_provenance_uses_reviews(provenance) {
        True -> "Review-driven replacement from open PR feedback."
        False -> "Planned from the Night Shift brief."
      }
    None -> "Planned from the Night Shift brief."
  }

  bullet_list([
    "Reason: " <> origin,
    "Run: " <> run.run_id,
    "Task: " <> task.id,
    "Brief: " <> run.brief_path,
  ])
}

fn render_scope(
  handoff: types.HandoffConfig,
  task: types.Task,
  execution_result: types.ExecutionResult,
) -> String {
  let scope_lines = []
  let scope_lines = case handoff.include_files_touched {
    True -> list.append(scope_lines, ["Files touched: " <> inline_list(execution_result.files_touched)])
    False -> scope_lines
  }
  let scope_lines = case handoff.include_acceptance {
    True -> list.append(scope_lines, ["Acceptance: " <> inline_list(task.acceptance)])
    False -> scope_lines
  }
  let scope_lines = case handoff.include_stack_context {
    True ->
      list.append(scope_lines, [
        "Branch: " <> fallback_scalar(task.branch_name),
        "PR: " <> fallback_scalar(task.pr_number),
        "Supersedes: " <> render_pr_numbers(task.superseded_pr_numbers),
      ])
    False -> scope_lines
  }

  "## Scope\n" <> bullet_list(scope_lines)
}

fn render_evidence(
  handoff: types.HandoffConfig,
  execution_result: types.ExecutionResult,
  verification_output: String,
) -> String {
  let sections = ["Demo evidence:\n" <> bullet_list(execution_result.demo_evidence)]
  let sections = case handoff.include_verification_summary {
    True -> list.append(sections, [
      "Verification digest: "
        <> verification_digest(verification_output)
        <> "\n\n```text\n"
        <> verification_output
        <> "\n```",
    ])
    False -> sections
  }

  "## Evidence\n" <> string.join(sections, with: "\n\n")
}

fn render_provenance(
  level: types.HandoffProvenance,
  run: types.RunRecord,
  task: types.Task,
  execution_result: types.ExecutionResult,
  verification_output: String,
) -> String {
  let base_lines = [
    "Planning provenance: " <> planning_label(run.planning_provenance),
    "Execution summary source: model-authored",
  ]

  let lines = case level {
    types.HandoffProvenanceMinimal -> base_lines
    types.HandoffProvenanceLight ->
      list.append(base_lines, [
        "Execution provider: " <> agent_summary(run.execution_agent),
      ])
    types.HandoffProvenanceStructured ->
      list.append(base_lines, [
        "Planning agent: " <> agent_summary(run.planning_agent),
        "Execution agent: " <> agent_summary(run.execution_agent),
        "Deterministic evidence: run id, task id, files touched, verification output, superseded lineage",
        "Inferred/model-authored: PR summary, risks, demo narrative",
        "Verification digest: " <> verification_digest(verification_output),
        "Task status: " <> types.task_state_to_string(execution_result.status),
        "Task ref: " <> task.id,
      ])
  }

  "## Provenance\n" <> bullet_list(lines)
}

fn render_delta(
  previous_state: Option(types.TaskHandoffState),
  execution_result: types.ExecutionResult,
  verification_output: String,
) -> String {
  let current_files = execution_result.files_touched
  let current_risks = execution_result.pr.risks
  let current_digest = verification_digest(verification_output)

  case previous_state {
    None ->
      bullet_list([
        "Initial Night Shift handoff for this PR.",
        "Files in this delivery: " <> inline_list(current_files),
        "Verification changed: baseline",
        "Known risks: " <> inline_list(current_risks),
      ])
    Some(state) ->
      bullet_list([
        "Added files: "
          <> inline_list(list_difference(current_files, state.last_handoff_files)),
        "Removed files: "
          <> inline_list(list_difference(state.last_handoff_files, current_files)),
        "Verification changed: " <> bool_label(state.last_verification_digest != current_digest),
        "Risks changed: " <> bool_label(string.join(state.last_risks, with: "\n") != string.join(current_risks, with: "\n")),
      ])
  }
}

fn render_review_feedback_status(run: types.RunRecord) -> String {
  case run.planning_provenance {
    Some(provenance) ->
      case types.planning_provenance_uses_reviews(provenance), run.repo_state_snapshot {
        True, Some(snapshot) -> {
          let actionable_lines =
            snapshot.open_pull_requests
            |> list.filter(fn(pr) { pr.actionable })
            |> list.flat_map(fn(pr) {
              let comments =
                pr.review_comments
                |> list.map(fn(comment) {
                  "#" <> int.to_string(pr.number) <> ": " <> comment
                })
              let checks =
                pr.failing_checks
                |> list.map(fn(check) {
                  "#" <> int.to_string(pr.number) <> " check: " <> check
                })
              list.append(comments, checks)
            })

          case actionable_lines {
            [] -> "- Review-driven run, but no actionable comments or failing checks were captured."
            _ -> bullet_list(actionable_lines)
          }
        }
        _, _ -> "- No ingested review feedback for this update."
      }
    None -> "- No ingested review feedback for this update."
  }
}

fn render_stack_status(
  task: types.Task,
  repo_state_status: Option(RepoStateStatus),
) -> String {
  let lines = case task.superseded_pr_numbers {
    [] -> []
    pr_numbers -> ["Supersedes: " <> render_pr_numbers(pr_numbers)]
  }
  let lines = case repo_state_status {
    Some(status) ->
      list.append(lines, [
        "Repo-state drift: " <> status.drift,
        "Open PRs: " <> int.to_string(status.open_pr_count),
        "Actionable PRs: " <> int.to_string(status.actionable_pr_count),
      ])
    None -> lines
  }

  "## Stack / Replacement Status\n" <> bullet_list(lines)
}

fn planning_label(provenance: Option(types.PlanningProvenance)) -> String {
  case provenance {
    Some(value) -> types.planning_provenance_label(value)
    None -> "unknown"
  }
}

fn agent_summary(agent: types.ResolvedAgentConfig) -> String {
  let model_fragment = case agent.model {
    Some(model) -> " model=" <> model
    None -> ""
  }
  let reasoning_fragment = case agent.reasoning {
    Some(reasoning) -> " reasoning=" <> types.reasoning_to_string(reasoning)
    None -> ""
  }
  types.provider_to_string(agent.provider) <> model_fragment <> reasoning_fragment
}

fn bullet_list(items: List(String)) -> String {
  case items
    |> list.filter(fn(item) { string.trim(item) != "" })
  {
    [] -> "- None"
    filtered ->
      filtered
      |> list.map(fn(item) { "- " <> item })
      |> string.join(with: "\n")
  }
}

fn fallback_text(value: String) -> String {
  case string.trim(value) {
    "" -> "- None"
    trimmed -> trimmed
  }
}

fn render_pr_numbers(pr_numbers: List(Int)) -> String {
  case pr_numbers {
    [] -> "(none)"
    _ ->
      pr_numbers
      |> list.map(fn(number) { "#" <> int.to_string(number) })
      |> string.join(with: ", ")
  }
}

fn inline_list(items: List(String)) -> String {
  case items
    |> list.filter(fn(item) { string.trim(item) != "" })
  {
    [] -> "(none)"
    filtered -> string.join(filtered, with: ", ")
  }
}

fn list_difference(left: List(String), right: List(String)) -> List(String) {
  left
  |> list.filter(fn(item) { !list.contains(right, item) })
}

fn bool_label(value: Bool) -> String {
  case value {
    True -> "yes"
    False -> "no"
  }
}

fn fallback_scalar(value: String) -> String {
  case string.trim(value) {
    "" -> "(none)"
    trimmed -> trimmed
  }
}

fn render_optional(value: Option(String)) -> String {
  case value {
    Some(contents) -> string.trim(contents)
    None -> ""
  }
}
