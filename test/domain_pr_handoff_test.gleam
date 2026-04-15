import gleam/option.{None, Some}
import gleam/string
import night_shift/domain/pr_handoff
import night_shift/types
import night_shift_test_support

pub fn render_body_region_includes_sections_and_snippets_test() {
  let handoff =
    types.HandoffConfig(
      ..types.default_handoff_config(),
      include_acceptance: True,
    )
  let body =
    pr_handoff.render_body_region(
      handoff,
      sample_run(),
      sample_task(),
      sample_execution_result(),
      "$ gleam test",
      pr_handoff.Snippets(
        body_prefix: Some("Team prefix"),
        body_suffix: Some("Team suffix"),
        comment_prefix: None,
        comment_suffix: None,
      ),
    )

  assert string.contains(body, pr_handoff.body_start_marker)
  assert string.contains(body, "Team prefix")
  assert string.contains(body, "## Context")
  assert string.contains(body, "## Scope")
  assert string.contains(
    body,
    "Files touched: src/app.gleam, test/app_test.gleam",
  )
  assert string.contains(
    body,
    "Acceptance: Add the app entrypoint, Cover the happy path",
  )
  assert string.contains(body, "## Evidence")
  assert string.contains(body, "Verification digest:")
  assert string.contains(body, "## Provenance")
  assert string.contains(body, "Team suffix")
  assert string.contains(body, pr_handoff.body_end_marker)
}

pub fn render_managed_comment_reports_delta_and_review_context_test() {
  let comment =
    pr_handoff.render_managed_comment(
      sample_review_run(),
      sample_task(),
      sample_execution_result(),
      "$ gleam test",
      Some(types.TaskHandoffState(
        task_id: "task-1",
        delivered_pr_number: "15",
        last_delivered_commit_sha: "abc123",
        last_handoff_files: ["src/old.gleam"],
        last_verification_digest: "old-digest",
        last_risks: ["Old risk"],
        last_handoff_updated_at: "2026-04-13T17:00:00Z",
        body_region_present: True,
        managed_comment_present: True,
      )),
      Some(pr_handoff.RepoStateStatus(
        drift: "yes",
        open_pr_count: 3,
        actionable_pr_count: 1,
      )),
      pr_handoff.empty_snippets(),
    )

  assert string.contains(comment, "## Since Last Review")
  assert string.contains(
    comment,
    "Added files: src/app.gleam, test/app_test.gleam",
  )
  assert string.contains(comment, "Removed files: src/old.gleam")
  assert string.contains(comment, "Verification changed: yes")
  assert string.contains(comment, "## Review Feedback Status")
  assert string.contains(
    comment,
    "#11: Review COMMENTED: Please make QA_NOTES.md the canonical doc.",
  )
  assert string.contains(comment, "## Stack / Replacement Status")
  assert string.contains(comment, "Repo-state drift: yes")
  assert string.contains(comment, pr_handoff.comment_marker("task-1"))
}

pub fn render_body_region_omits_unknown_pr_number_from_scope_test() {
  let body =
    pr_handoff.render_body_region(
      types.default_handoff_config(),
      sample_run(),
      types.Task(..sample_task(), pr_number: ""),
      sample_execution_result(),
      "$ gleam test",
      pr_handoff.empty_snippets(),
    )

  assert !string.contains(does: body, contain: "PR: (none)")
  assert !string.contains(does: body, contain: "\n- PR:")
}

fn sample_run() -> types.RunRecord {
  types.RunRecord(
    run_id: "run-123",
    repo_root: "/repo",
    run_path: "/repo/.night-shift/runs/run-123",
    brief_path: "/repo/.night-shift/execution-brief.md",
    state_path: "",
    events_path: "",
    report_path: "",
    lock_path: "",
    planning_agent: types.resolved_agent_from_provider(types.Codex),
    execution_agent: types.resolved_agent_from_provider(types.Codex),
    environment_name: "",
    max_workers: 1,
    notes_source: None,
    planning_provenance: Some(types.NotesOnly(types.NotesFile("notes.md"))),
    repo_state_snapshot: None,
    decisions: [],
    planning_dirty: False,
    status: types.RunPending,
    created_at: "",
    updated_at: "",
    recovery_blocker: None,
    tasks: [],
    handoff_states: [],
  )
}

fn sample_review_run() -> types.RunRecord {
  types.RunRecord(
    ..sample_run(),
    planning_provenance: Some(types.ReviewsOnly),
    repo_state_snapshot: Some(
      night_shift_test_support.sample_repo_state_snapshot(),
    ),
  )
}

fn sample_task() -> types.Task {
  types.Task(
    id: "task-1",
    title: "Task 1",
    description: "Add the new app entrypoint.",
    dependencies: [],
    acceptance: ["Add the app entrypoint", "Cover the happy path"],
    demo_plan: [],
    decision_requests: [],
    superseded_pr_numbers: [11, 12],
    kind: types.ImplementationTask,
    execution_mode: types.Serial,
    state: types.Ready,
    worktree_path: "",
    branch_name: "night-shift/task-1",
    pr_number: "15",
    summary: "",
    runtime_context: None,
  )
}

fn sample_execution_result() -> types.ExecutionResult {
  types.ExecutionResult(
    status: types.Completed,
    summary: "Completed the app task.",
    files_touched: ["src/app.gleam", "test/app_test.gleam"],
    demo_evidence: ["Ran the app entrypoint"],
    pr: types.PrPlan(
      title: "Task 1",
      summary: "Adds the app entrypoint.",
      demo: ["Ran the app entrypoint"],
      risks: ["Docs follow-up remains."],
    ),
    follow_up_tasks: [],
  )
}
