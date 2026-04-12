import night_shift/domain/task_validation
import night_shift/types

pub fn validate_planned_tasks_rejects_file_path_dependencies_test() {
  let tasks = [
    task("create-index", ["docs/wiki/index.md"]),
  ]

  let assert Error(issues) = task_validation.validate_planned_tasks([], tasks)

  assert task_validation.render_issues(issues)
    == "task `create-index` depends on unknown task id `docs/wiki/index.md`"
}

pub fn validate_planned_tasks_accepts_completed_dependency_ids_test() {
  let completed = [types.Task(..task("seed-docs", []), state: types.Completed)]
  let planned = [task("create-index", ["seed-docs"])]

  let assert Ok(Nil) =
    task_validation.validate_planned_tasks(completed, planned)
}

pub fn validate_follow_up_tasks_accepts_existing_and_same_batch_ids_test() {
  let existing = [task("seed-docs", [])]
  let follow_ups = [
    follow_up("smoke", ["seed-docs"]),
    follow_up("publish", ["smoke"]),
  ]

  let assert Ok(Nil) =
    task_validation.validate_follow_up_tasks(existing, "seed-docs", follow_ups)
}

pub fn validate_follow_up_tasks_rejects_file_path_dependencies_test() {
  let follow_ups = [follow_up("smoke", ["docs/wiki/combinators.md"])]

  let assert Error(issues) =
    task_validation.validate_follow_up_tasks([], "seed-docs", follow_ups)

  assert task_validation.render_issues(issues)
    == "task `smoke` depends on unknown task id `docs/wiki/combinators.md`"
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
    kind: types.ImplementationTask,
    execution_mode: types.Serial,
    state: types.Queued,
    worktree_path: "",
    branch_name: "",
    pr_number: "",
    summary: "",
  )
}

fn follow_up(id: String, dependencies: List(String)) -> types.FollowUpTask {
  types.FollowUpTask(
    id: id,
    title: id,
    description: "",
    dependencies: dependencies,
    acceptance: [],
    demo_plan: [],
    decision_requests: [],
    kind: types.ImplementationTask,
    execution_mode: types.Serial,
  )
}
