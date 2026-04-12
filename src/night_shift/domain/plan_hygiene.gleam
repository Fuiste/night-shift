import gleam/list
import gleam/string
import night_shift/types

pub fn normalize_planned_tasks(
  tasks: List(types.Task),
) -> Result(List(types.Task), String) {
  case mergeable_validation_tail(tasks) {
    Ok(merged) -> Ok(merged)
    Error(_) ->
      case fragmented_tiny_plan(tasks) {
        True -> Error(fragmented_plan_message(tasks))
        False -> Ok(tasks)
      }
  }
}

fn mergeable_validation_tail(
  tasks: List(types.Task),
) -> Result(List(types.Task), Nil) {
  let validation_tasks = list.filter(tasks, is_validation_only_task)
  let context_tasks = list.filter(tasks, is_context_only_task)
  let concrete_tasks = list.filter(tasks, is_concrete_implementation_task)
  let manual_attention_tasks =
    list.filter(tasks, fn(task) { task.kind == types.ManualAttentionTask })

  case validation_tasks, context_tasks, concrete_tasks, manual_attention_tasks {
    [validation_task], [], [parent], [] -> {
      case validation_task.dependencies == [parent.id] {
        True -> Ok(merge_validation_task(tasks, parent, validation_task))
        False -> Error(Nil)
      }
    }
    _, _, _, _ -> Error(Nil)
  }
}

fn merge_validation_task(
  tasks: List(types.Task),
  parent: types.Task,
  validation_task: types.Task,
) -> List(types.Task) {
  tasks
  |> list.filter(fn(task) { task.id != validation_task.id })
  |> list.map(fn(task) {
    case task.id == parent.id {
      True ->
        types.Task(
          ..task,
          description: task.description
            <> "\n\nValidation note: "
            <> validation_task.description,
          acceptance: list.append(task.acceptance, validation_task.acceptance),
          demo_plan: list.append(task.demo_plan, validation_task.demo_plan),
        )
      False -> task
    }
  })
}

fn fragmented_tiny_plan(tasks: List(types.Task)) -> Bool {
  let validation_tasks = list.filter(tasks, is_validation_only_task)
  let context_tasks = list.filter(tasks, is_context_only_task)
  let concrete_tasks = list.filter(tasks, is_concrete_implementation_task)
  let manual_attention_tasks =
    list.filter(tasks, fn(task) { task.kind == types.ManualAttentionTask })

  list.length(concrete_tasks) == 1
  && manual_attention_tasks == []
  && {
    context_tasks != []
    || list.length(validation_tasks) > 1
    || { validation_tasks != [] && context_tasks != [] }
  }
}

fn fragmented_plan_message(tasks: List(types.Task)) -> String {
  let flagged_titles =
    tasks
    |> list.filter(fn(task) {
      is_validation_only_task(task) || is_context_only_task(task)
    })
    |> list.map(fn(task) { task.title })
    |> string.join(with: ", ")

  "Planner produced a fragmented tiny plan with wrapper tasks: "
  <> flagged_titles
  <> ". Return one meaningful implementation task unless a real dependency boundary requires otherwise."
}

fn is_concrete_implementation_task(task: types.Task) -> Bool {
  task.kind == types.ImplementationTask
  && !is_validation_only_task(task)
  && !is_context_only_task(task)
}

fn is_validation_only_task(task: types.Task) -> Bool {
  task.kind == types.ImplementationTask
  && list.length(task.dependencies) == 1
  && is_serial_or_exclusive(task.execution_mode)
  && contains_keyword(task.title <> " " <> task.description, [
    "validate",
    "verify",
    "confirm",
    "check",
    "minimality",
    "safety",
  ])
}

fn is_context_only_task(task: types.Task) -> Bool {
  task.kind == types.ImplementationTask
  && is_serial_or_exclusive(task.execution_mode)
  && contains_keyword(task.title <> " " <> task.description, [
    "collect",
    "inspect",
    "review",
    "repo context",
    "brief context",
  ])
}

fn contains_keyword(text: String, keywords: List(String)) -> Bool {
  let lowered = string.lowercase(text)
  list.any(keywords, fn(keyword) {
    string.contains(does: lowered, contain: keyword)
  })
}

fn is_serial_or_exclusive(mode: types.ExecutionMode) -> Bool {
  case mode {
    types.Serial -> True
    types.Exclusive -> True
    _ -> False
  }
}
