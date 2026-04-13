import gleam/list
import gleam/string
import gleeunit/should
import night_shift/domain/plan_hygiene
import night_shift/types

pub fn normalize_planned_tasks_merges_single_validation_tail_test() {
  let parent =
    types.Task(
      id: "update-qa-notes",
      title: "Update QA notes",
      description: "Add the requested note to QA_NOTES.md.",
      dependencies: [],
      acceptance: ["Add the requested note."],
      demo_plan: ["Inspect QA_NOTES.md."],
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
  let validation =
    types.Task(
      id: "validate-qa-notes",
      title: "Validate minimality and safety",
      description: "Confirm the docs-only change stays minimal.",
      dependencies: ["update-qa-notes"],
      acceptance: ["Validate the tiny docs-only change."],
      demo_plan: ["Confirm the diff stays tiny."],
      decision_requests: [],
      superseded_pr_numbers: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Queued,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      summary: "",
    )

  let assert Ok([merged]) =
    plan_hygiene.normalize_planned_tasks([parent, validation])

  assert string.contains(does: merged.description, contain: "Validation note:")
  should.equal(2, list.length(merged.acceptance))
  should.equal(2, list.length(merged.demo_plan))
}

pub fn normalize_planned_tasks_rejects_fragmented_tiny_plan_test() {
  let context =
    types.Task(
      id: "collect-context",
      title: "Collect brief and repo context",
      description: "Inspect the brief and repo context before editing QA_NOTES.",
      dependencies: [],
      acceptance: ["Understand the tiny docs-only task."],
      demo_plan: ["Summarize the repo context."],
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
  let implementation =
    types.Task(
      id: "update-qa-notes",
      title: "Update QA notes",
      description: "Add the requested note to QA_NOTES.md.",
      dependencies: ["collect-context"],
      acceptance: ["Add the requested note."],
      demo_plan: ["Inspect QA_NOTES.md."],
      decision_requests: [],
      superseded_pr_numbers: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Queued,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      summary: "",
    )
  let validation =
    types.Task(
      id: "validate-qa-notes",
      title: "Validate minimality and safety",
      description: "Confirm the docs-only change stays minimal.",
      dependencies: ["update-qa-notes"],
      acceptance: ["Validate the tiny docs-only change."],
      demo_plan: ["Confirm the diff stays tiny."],
      decision_requests: [],
      superseded_pr_numbers: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Queued,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      summary: "",
    )

  let assert Error(message) =
    plan_hygiene.normalize_planned_tasks([context, implementation, validation])

  assert string.contains(does: message, contain: "fragmented tiny plan")
}
