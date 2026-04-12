import gleam/list
import gleam/string
import night_shift/types

pub type ValidationIssue {
  DuplicateTaskId(task_id: String)
  UnknownDependency(task_id: String, dependency: String)
}

pub fn validate_planned_tasks(
  completed_tasks: List(types.Task),
  planned_tasks: List(types.Task),
) -> Result(Nil, List(ValidationIssue)) {
  let allowed_dependency_ids =
    list.append(
      completed_tasks |> list.map(fn(task) { task.id }),
      planned_tasks |> list.map(fn(task) { task.id }),
    )

  planned_tasks
  |> validate_unique_ids([])
  |> append_issues(validate_dependencies_for_tasks(
    planned_tasks,
    allowed_dependency_ids,
  ))
  |> finish_validation
}

pub fn validate_follow_up_tasks(
  existing_tasks: List(types.Task),
  _source_task_id: String,
  follow_up_tasks: List(types.FollowUpTask),
) -> Result(Nil, List(ValidationIssue)) {
  let allowed_dependency_ids =
    list.append(
      existing_tasks |> list.map(fn(task) { task.id }),
      follow_up_tasks |> list.map(fn(task) { task.id }),
    )

  follow_up_tasks
  |> validate_unique_follow_up_ids([])
  |> append_issues(validate_dependencies_for_follow_ups(
    follow_up_tasks,
    allowed_dependency_ids,
  ))
  |> finish_validation
}

pub fn render_issues(issues: List(ValidationIssue)) -> String {
  issues
  |> list.map(render_issue)
  |> string.join(with: "; ")
}

fn append_issues(
  left: List(ValidationIssue),
  right: List(ValidationIssue),
) -> List(ValidationIssue) {
  list.append(left, right)
}

fn finish_validation(
  issues: List(ValidationIssue),
) -> Result(Nil, List(ValidationIssue)) {
  case issues {
    [] -> Ok(Nil)
    _ -> Error(issues)
  }
}

fn validate_unique_ids(
  tasks: List(types.Task),
  seen: List(String),
) -> List(ValidationIssue) {
  case tasks {
    [] -> []
    [task, ..rest] ->
      case list.contains(seen, task.id) {
        True -> [DuplicateTaskId(task.id), ..validate_unique_ids(rest, seen)]
        False -> validate_unique_ids(rest, [task.id, ..seen])
      }
  }
}

fn validate_unique_follow_up_ids(
  tasks: List(types.FollowUpTask),
  seen: List(String),
) -> List(ValidationIssue) {
  case tasks {
    [] -> []
    [task, ..rest] ->
      case list.contains(seen, task.id) {
        True -> [
          DuplicateTaskId(task.id),
          ..validate_unique_follow_up_ids(rest, seen)
        ]
        False -> validate_unique_follow_up_ids(rest, [task.id, ..seen])
      }
  }
}

fn validate_dependencies_for_tasks(
  tasks: List(types.Task),
  allowed_dependency_ids: List(String),
) -> List(ValidationIssue) {
  case tasks {
    [] -> []
    [task, ..rest] ->
      list.append(
        validate_dependencies(
          task.id,
          task.dependencies,
          allowed_dependency_ids,
        ),
        validate_dependencies_for_tasks(rest, allowed_dependency_ids),
      )
  }
}

fn validate_dependencies_for_follow_ups(
  tasks: List(types.FollowUpTask),
  allowed_dependency_ids: List(String),
) -> List(ValidationIssue) {
  case tasks {
    [] -> []
    [task, ..rest] ->
      list.append(
        validate_dependencies(
          task.id,
          task.dependencies,
          allowed_dependency_ids,
        ),
        validate_dependencies_for_follow_ups(rest, allowed_dependency_ids),
      )
  }
}

fn validate_dependencies(
  task_id: String,
  dependencies: List(String),
  allowed_dependency_ids: List(String),
) -> List(ValidationIssue) {
  case dependencies {
    [] -> []
    [dependency, ..rest] ->
      case list.contains(allowed_dependency_ids, dependency) {
        True -> validate_dependencies(task_id, rest, allowed_dependency_ids)
        False -> [
          UnknownDependency(task_id: task_id, dependency: dependency),
          ..validate_dependencies(task_id, rest, allowed_dependency_ids)
        ]
      }
  }
}

fn render_issue(issue: ValidationIssue) -> String {
  case issue {
    DuplicateTaskId(task_id) -> "duplicate task id `" <> task_id <> "`"
    UnknownDependency(task_id, dependency) ->
      "task `"
      <> task_id
      <> "` depends on unknown task id `"
      <> dependency
      <> "`"
  }
}
