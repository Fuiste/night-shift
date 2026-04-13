import gleam/list
import gleam/result
import gleam/string
import night_shift/types

pub fn normalize_tasks(tasks: List(types.Task)) -> List(types.Task) {
  tasks
  |> list.map(fn(task) {
    case task.dependencies {
      [] -> types.Task(..task, state: initial_task_state(task))
      _ -> types.Task(..task, state: types.Queued)
    }
  })
}

pub fn refresh_ready_states(tasks: List(types.Task)) -> List(types.Task) {
  let completed_ids =
    tasks
    |> list.filter(fn(task) { task.state == types.Completed })
    |> list.map(fn(task) { task.id })

  tasks
  |> list.map(fn(task) {
    case task.state {
      types.Queued ->
        case types.is_task_ready(task, completed_ids) {
          True -> types.Task(..task, state: types.Ready)
          False -> task
        }
      _ -> task
    }
  })
}

pub fn next_batch(tasks: List(types.Task), max_workers: Int) -> List(types.Task) {
  let ready_tasks = list.filter(tasks, fn(task) { task.state == types.Ready })

  case
    list.find(ready_tasks, fn(task) { task.kind == types.ManualAttentionTask })
  {
    Ok(task) -> [task]
    Error(_) ->
      ready_tasks
      |> build_batch(max_workers, [], False)
      |> list.reverse
  }
}

pub fn replace_task(
  tasks: List(types.Task),
  updated: types.Task,
) -> List(types.Task) {
  tasks
  |> list.map(fn(task) {
    case task.id == updated.id {
      True -> updated
      False -> task
    }
  })
}

pub fn merge_follow_up_tasks(
  tasks: List(types.Task),
  follow_up_tasks: List(types.FollowUpTask),
) -> List(types.Task) {
  follow_up_tasks
  |> list.fold(tasks, fn(acc, follow_up) {
    case list.any(acc, fn(task) { task.id == follow_up.id }) {
      True -> acc
      False -> [
        types.Task(
          id: follow_up.id,
          title: follow_up.title,
          description: follow_up.description,
          dependencies: follow_up.dependencies,
          acceptance: follow_up.acceptance,
          demo_plan: follow_up.demo_plan,
          decision_requests: follow_up.decision_requests,
          superseded_pr_numbers: follow_up.superseded_pr_numbers,
          kind: follow_up.kind,
          execution_mode: follow_up.execution_mode,
          state: types.Queued,
          worktree_path: "",
          branch_name: "",
          pr_number: "",
          summary: "",
        ),
        ..acc
      ]
    }
  })
  |> list.reverse
  |> refresh_ready_states
}

pub fn merge_planned_tasks(
  existing_tasks: List(types.Task),
  planned_tasks: List(types.Task),
) -> List(types.Task) {
  let preserved_completed = completed_tasks(existing_tasks)
  let completed_ids = preserved_completed |> list.map(fn(task) { task.id })
  let remaining_planned =
    planned_tasks
    |> list.filter(fn(task) { !list.contains(completed_ids, task.id) })

  list.append(preserved_completed, remaining_planned)
  |> refresh_ready_states
}

pub fn completed_tasks(tasks: List(types.Task)) -> List(types.Task) {
  tasks
  |> list.filter(fn(task) { task.state == types.Completed })
}

pub fn task_base_ref(
  task: types.Task,
  tasks: List(types.Task),
  default_base: String,
) -> String {
  case task.dependencies {
    [] -> default_base
    [dependency, ..] ->
      tasks
      |> list.find(fn(candidate) { candidate.id == dependency })
      |> result.map(fn(found) {
        case found.branch_name {
          "" -> default_base
          branch_name -> branch_name
        }
      })
      |> result.unwrap(or: default_base)
  }
}

pub fn build_branch_name(
  prefix: String,
  run_id: String,
  task_id: String,
) -> String {
  prefix <> "/" <> sanitize_segment(run_id) <> "-" <> sanitize_segment(task_id)
}

fn initial_task_state(task: types.Task) -> types.TaskState {
  case task.kind {
    types.ManualAttentionTask -> types.Ready
    types.ImplementationTask -> types.Ready
  }
}

fn build_batch(
  ready_tasks: List(types.Task),
  max_workers: Int,
  acc: List(types.Task),
  has_serial: Bool,
) -> List(types.Task) {
  case ready_tasks, list.length(acc) >= max_workers {
    _, True -> acc
    [], False -> acc
    [task, ..rest], False ->
      case task.execution_mode, acc {
        types.Exclusive, [] -> [task]
        types.Exclusive, _ -> acc
        types.Parallel, _ ->
          build_batch(rest, max_workers, [task, ..acc], has_serial)
        types.Serial, _ ->
          case has_serial {
            True -> acc
            False -> build_batch(rest, max_workers, [task, ..acc], True)
          }
      }
  }
}

fn sanitize_segment(value: String) -> String {
  value
  |> string.replace(each: "/", with: "-")
  |> string.replace(each: " ", with: "-")
  |> string.replace(each: ":", with: "-")
}
