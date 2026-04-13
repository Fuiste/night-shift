import gleam/int
import gleam/string
import night_shift/domain/repo_state
import night_shift/domain/review_lineage
import night_shift/types

pub fn derive_superseded_pr_numbers_maps_impacted_chain_to_replacement_chain_test() {
  let snapshot =
    repo_state.snapshot("2026-04-13T16:30:00Z", [
      pr_snapshot(11, "night-shift/root", "main", True, True),
      pr_snapshot(12, "night-shift/child", "night-shift/root", False, True),
      pr_snapshot(13, "night-shift/leaf", "night-shift/child", False, True),
    ])
  let tasks = [
    task("rewrite-root", []),
    task("update-nav", ["rewrite-root"]),
    task("refresh-links", ["update-nav"]),
  ]

  let assert Ok(derived_tasks) =
    review_lineage.derive_superseded_pr_numbers(snapshot, tasks)

  assert derived_tasks
    == [
      types.Task(..task("rewrite-root", []), superseded_pr_numbers: [11]),
      types.Task(..task("update-nav", ["rewrite-root"]), superseded_pr_numbers: [
        12,
      ]),
      types.Task(
        ..task("refresh-links", ["update-nav"]),
        superseded_pr_numbers: [13],
      ),
    ]
}

pub fn derive_superseded_pr_numbers_rejects_shape_mismatch_test() {
  let snapshot =
    repo_state.snapshot("2026-04-13T16:30:00Z", [
      pr_snapshot(11, "night-shift/root", "main", True, True),
      pr_snapshot(12, "night-shift/child", "night-shift/root", False, True),
      pr_snapshot(13, "night-shift/leaf", "night-shift/child", False, True),
    ])
  let tasks = [
    task("rewrite-root", []),
    task("update-nav", ["rewrite-root"]),
    task("refresh-links", ["rewrite-root"]),
  ]

  let assert Error(message) =
    review_lineage.derive_superseded_pr_numbers(snapshot, tasks)

  assert string.contains(does: message, contain: "impacted PR subtree shape")
}

fn pr_snapshot(
  number: Int,
  head_ref_name: String,
  base_ref_name: String,
  actionable: Bool,
  impacted: Bool,
) -> types.RepoPullRequestSnapshot {
  types.RepoPullRequestSnapshot(
    number: number,
    title: "PR " <> int.to_string(number),
    url: "https://example.com/pr/" <> int.to_string(number),
    head_ref_name: head_ref_name,
    base_ref_name: base_ref_name,
    review_decision: "",
    failing_checks: [],
    review_comments: [],
    actionable: actionable,
    impacted: impacted,
  )
}

fn task(id: String, dependencies: List(String)) -> types.Task {
  types.Task(
    id: id,
    title: id,
    description: "",
    dependencies: dependencies,
    acceptance: [],
    demo_plan: [],
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
}
