import gleam/list
import gleam/string
import night_shift/types

pub fn final_status(tasks: List(types.Task)) -> types.RunStatus {
  case list.any(tasks, fn(task) { task.state == types.Failed }) {
    True -> types.RunFailed
    False ->
      case
        list.any(tasks, fn(task) {
          task.state == types.Blocked || task.state == types.ManualAttention
        })
      {
        True -> types.RunBlocked
        False -> types.RunCompleted
      }
  }
}

pub fn has_blocking_attention(tasks: List(types.Task)) -> Bool {
  list.any(tasks, fn(task) {
    task.state == types.ManualAttention || task.state == types.Blocked
  })
}

pub fn recover_task(task: types.Task, has_worktree_changes: Bool) -> types.Task {
  case task.state {
    types.Running ->
      case task.worktree_path {
        "" -> types.Task(..task, state: types.Queued)
        _ ->
          case has_worktree_changes {
            True ->
              types.Task(
                ..task,
                state: types.ManualAttention,
                summary: "Interrupted run left changes in the worktree.",
              )
            False -> types.Task(..task, state: types.Queued)
          }
      }
    _ -> task
  }
}

pub fn recover_in_flight_task(
  task: types.Task,
  has_worktree_changes: Bool,
) -> types.Task {
  case task.state {
    types.Running -> {
      let recovered_state = case has_worktree_changes {
        True -> types.ManualAttention
        False -> types.Failed
      }
      let recovered_summary = case string.trim(task.summary) {
        "" ->
          "Primary blocker: Night Shift stopped before this started task could be finalized.\n\nEnvironment notes: inspect the task log and worktree before retrying."
        existing ->
          existing
          <> "\n\nRecovery notes: Night Shift stopped before this started task could be finalized."
      }
      types.Task(..task, state: recovered_state, summary: recovered_summary)
    }
    _ -> task
  }
}

pub fn event_kind_for_state(state: types.TaskState) -> String {
  case state {
    types.ManualAttention -> "task_manual_attention"
    types.Failed -> "task_failed"
    types.Blocked -> "task_blocked"
    _ -> "task_failed"
  }
}
