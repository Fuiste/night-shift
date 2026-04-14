import gleam/list
import gleam/option.{None}
import night_shift/domain/task_graph
import night_shift/types

pub fn refresh_ready_states_promotes_completed_dependencies_test() {
  let tasks = [
    types.Task(
      id: "build",
      title: "Build",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      superseded_pr_numbers: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Completed,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      summary: "",
      runtime_context: None,
    ),
    types.Task(
      id: "verify",
      title: "Verify",
      description: "",
      dependencies: ["build"],
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
      runtime_context: None,
    ),
  ]

  let assert [_, verify] = task_graph.refresh_ready_states(tasks)
  assert verify.state == types.Ready
}

pub fn next_batch_respects_exclusive_tasks_test() {
  let tasks = [
    ready_task("exclusive", types.Exclusive),
    ready_task("parallel-a", types.Parallel),
    ready_task("parallel-b", types.Parallel),
  ]

  let batch = task_graph.next_batch(tasks, 3)

  assert list.length(batch) == 1
  let assert [task] = batch
  assert task.id == "exclusive"
}

pub fn merge_follow_up_tasks_avoids_duplicate_ids_test() {
  let existing = [ready_task("alpha", types.Serial)]
  let follow_ups = [
    types.FollowUpTask(
      id: "alpha",
      title: "Existing",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      superseded_pr_numbers: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
    ),
    types.FollowUpTask(
      id: "beta",
      title: "New",
      description: "",
      dependencies: ["alpha"],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      superseded_pr_numbers: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
    ),
  ]

  let merged = task_graph.merge_follow_up_tasks(existing, follow_ups)

  assert list.length(merged) == 2
  let assert Ok(beta) = merged |> list.find(fn(task) { task.id == "beta" })
  assert beta.state == types.Queued
}

pub fn task_base_ref_uses_dependency_branch_test() {
  let tasks = [
    types.Task(
      ..ready_task("alpha", types.Serial),
      branch_name: "night-shift/alpha",
    ),
    types.Task(..ready_task("beta", types.Serial), dependencies: ["alpha"]),
  ]
  let assert [_, beta] = tasks

  assert task_graph.task_base_ref(beta, tasks, "main") == "night-shift/alpha"
}

fn ready_task(id: String, mode: types.ExecutionMode) -> types.Task {
  types.Task(
    id: id,
    title: id,
    description: "",
    dependencies: [],
    acceptance: [],
    demo_plan: [],
    decision_requests: [],
    superseded_pr_numbers: [],
    kind: types.ImplementationTask,
    execution_mode: mode,
    state: types.Ready,
    worktree_path: "",
    branch_name: "",
    pr_number: "",
    summary: "",
    runtime_context: None,
  )
}
