import gleam/option.{None}
import gleam/string
import night_shift/domain/pull_request
import night_shift/types

pub fn render_body_includes_metadata_and_sections_test() {
  let run = sample_run()
  let task = sample_task()
  let execution_result =
    types.ExecutionResult(
      status: types.Completed,
      summary: "Implemented the docs flow.",
      files_touched: [],
      demo_evidence: [],
      pr: types.PrPlan(
        title: "[night-shift] Docs flow",
        summary: "Adds the docs flow implementation.",
        demo: ["Open the docs page", "Verify the new CTA"],
        risks: ["Search indexing still needs follow-up"],
      ),
      follow_up_tasks: [],
    )

  let body =
    pull_request.render_body(run, task, execution_result, "$ gleam test")

  assert string.contains(body, "## Summary\nAdds the docs flow implementation.")
  assert string.contains(
    body,
    "## Demo\n- Open the docs page\n- Verify the new CTA",
  )
  assert string.contains(body, "## Verification\n```\n$ gleam test\n```")
  assert string.contains(
    body,
    "## Known Risks\n- Search indexing still needs follow-up",
  )
  assert string.contains(
    body,
    "<!-- night-shift:run=run-123;task=docs-flow;brief=/tmp/brief.md -->",
  )
}

pub fn review_task_defaults_empty_lists_to_none_test() {
  let task =
    pull_request.review_task(
      42,
      "https://example.com/pr/42",
      "Tighten the onboarding flow.",
      "codex/review-42",
      [],
      [],
    )

  assert task.id == "review-pr-42"
  assert task.branch_name == "codex/review-42"
  assert task.execution_mode == types.Exclusive
  assert task.state == types.Ready
  assert task.pr_number == "42"
  assert string.contains(task.description, "Review notes:\n- None")
  assert string.contains(task.description, "Failing checks:\n- None")
}

pub fn review_task_keeps_requested_feedback_in_description_test() {
  let task =
    pull_request.review_task(
      18,
      "https://example.com/pr/18",
      "Refactor the architecture.",
      "codex/architecture-reset",
      ["Please add coverage for review mode."],
      ["CI / test"],
    )

  assert string.contains(
    task.description,
    "- Please add coverage for review mode.",
  )
  assert string.contains(task.description, "- CI / test")
}

pub fn render_body_includes_superseded_section_when_present_test() {
  let run = sample_run()
  let task = types.Task(..sample_task(), superseded_pr_numbers: [11, 12])
  let execution_result =
    types.ExecutionResult(
      status: types.Completed,
      summary: "Implemented the replacement stack.",
      files_touched: [],
      demo_evidence: [],
      pr: types.PrPlan(
        title: "[night-shift] Replace docs stack",
        summary: "Replaces the old docs stack.",
        demo: [],
        risks: [],
      ),
      follow_up_tasks: [],
    )

  let body =
    pull_request.render_body(run, task, execution_result, "$ gleam test")

  assert string.contains(body, "## Supersedes\n- #11\n- #12")
}

fn sample_run() -> types.RunRecord {
  types.RunRecord(
    run_id: "run-123",
    repo_root: "/repo",
    run_path: "/repo/.night-shift/runs/run-123",
    brief_path: "/tmp/brief.md",
    state_path: "",
    events_path: "",
    report_path: "",
    lock_path: "",
    planning_agent: types.resolved_agent_from_provider(types.Codex),
    execution_agent: types.resolved_agent_from_provider(types.Codex),
    environment_name: "",
    max_workers: 1,
    notes_source: None,
    planning_provenance: None,
    repo_state_snapshot: None,
    decisions: [],
    planning_dirty: False,
    status: types.RunPending,
    created_at: "",
    updated_at: "",
    tasks: [],
    handoff_states: [],
  )
}

fn sample_task() -> types.Task {
  types.Task(
    id: "docs-flow",
    title: "Docs flow",
    description: "",
    dependencies: [],
    acceptance: [],
    demo_plan: [],
    decision_requests: [],
    superseded_pr_numbers: [],
    kind: types.ImplementationTask,
    execution_mode: types.Serial,
    state: types.Ready,
    worktree_path: "",
    branch_name: "",
    pr_number: "",
    summary: "",
  )
}
