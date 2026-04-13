import gleam/option.{None}
import night_shift/domain/run_state
import night_shift/types

pub fn final_status_prefers_failed_over_blocked_test() {
  let tasks = [
    task_with_state("failed", types.Failed),
    task_with_state("blocked", types.ManualAttention),
  ]

  assert run_state.final_status(tasks) == types.RunFailed
}

pub fn recover_task_marks_dirty_running_worktrees_manual_attention_test() {
  let recovered =
    run_state.recover_task(task_with_state("running", types.Running), True)

  assert recovered.state == types.ManualAttention
}

pub fn recover_in_flight_task_marks_clean_running_worktrees_failed_test() {
  let recovered =
    run_state.recover_in_flight_task(
      task_with_state("running", types.Running),
      False,
    )

  assert recovered.state == types.Failed
}

pub fn event_kind_for_state_maps_blocked_variants_test() {
  assert run_state.event_kind_for_state(types.ManualAttention)
    == "task_manual_attention"
  assert run_state.event_kind_for_state(types.Blocked) == "task_blocked"
  assert run_state.event_kind_for_state(types.Failed) == "task_failed"
}

fn task_with_state(id: String, state: types.TaskState) -> types.Task {
  types.Task(
    id: id,
    title: id,
    description: "Demo",
    dependencies: [],
    acceptance: [],
    demo_plan: [],
    decision_requests: [],
    superseded_pr_numbers: [],
    kind: types.ImplementationTask,
    execution_mode: types.Serial,
    state: state,
    worktree_path: "/tmp/demo",
    branch_name: "",
    pr_number: "",
    summary: "",
    runtime_context: None,
  )
}
