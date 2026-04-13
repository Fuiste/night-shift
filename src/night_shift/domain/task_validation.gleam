import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/types

pub type ValidationIssue {
  DuplicateTaskId(task_id: String)
  UnknownDependency(task_id: String, dependency: String)
  UnreadablePlanningBrief(path: String, reason: String)
  ExpectedImplementationTaskCount(expected: Int, actual: Int)
  ExpectedStrictSerialImplementationChain
  ReviewSupersessionMappingMismatch(message: String)
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

pub fn validate_explicit_serial_requirements(
  brief_contents: String,
  planned_tasks: List(types.Task),
) -> Result(Nil, List(ValidationIssue)) {
  case strict_serial_requirement(brief_contents) {
    None -> Ok(Nil)
    Some(expected_count) -> {
      let implementation_tasks =
        planned_tasks
        |> list.filter(fn(task) { task.kind == types.ImplementationTask })
      let implementation_task_count = list.length(implementation_tasks)

      let count_issues = case expected_count {
        Some(expected) ->
          case implementation_task_count == expected {
            True -> []
            False -> [
              ExpectedImplementationTaskCount(
                expected: expected,
                actual: implementation_task_count,
              ),
            ]
          }
        _ -> []
      }

      count_issues
      |> append_issues(validate_strict_serial_chain(implementation_tasks))
      |> finish_validation
    }
  }
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
    UnreadablePlanningBrief(path, reason) ->
      "unable to read planning brief `"
      <> path
      <> "`: "
      <> reason
    ExpectedImplementationTaskCount(expected, actual) ->
      "planner must return exactly "
      <> int_to_string(expected)
      <> " implementation tasks, but returned "
      <> int_to_string(actual)
    ExpectedStrictSerialImplementationChain ->
      "planner must return implementation tasks as one strict serial dependency chain"
    ReviewSupersessionMappingMismatch(message) ->
      "superseded pull request lineage mismatch: " <> message
  }
}

fn validate_strict_serial_chain(tasks: List(types.Task)) -> List(ValidationIssue) {
  case tasks {
    [] -> [ExpectedStrictSerialImplementationChain]
    [_] -> []
    _ -> {
      let task_ids = tasks |> list.map(fn(task) { task.id })
      let roots = tasks |> list.filter(fn(task) {
        implementation_parent_count(task, task_ids) == 0
      })
      let leaves = tasks |> list.filter(fn(task) {
        implementation_child_count(task, tasks) == 0
      })
      let every_task_has_chain_degree =
        list.all(tasks, fn(task) {
          implementation_parent_count(task, task_ids) <= 1
          && implementation_child_count(task, tasks) <= 1
        })
      let edge_count =
        tasks
        |> list.map(fn(task) { implementation_parent_count(task, task_ids) })
        |> list.fold(0, int_add)

      case
        list.length(roots) == 1
        && list.length(leaves) == 1
        && every_task_has_chain_degree
        && edge_count == list.length(tasks) - 1
      {
        True -> []
        False -> [ExpectedStrictSerialImplementationChain]
      }
    }
  }
}

fn implementation_parent_count(task: types.Task, task_ids: List(String)) -> Int {
  task.dependencies
  |> list.filter(fn(dependency) { list.contains(task_ids, dependency) })
  |> list.length
}

fn implementation_child_count(task: types.Task, tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(candidate) { list.contains(candidate.dependencies, task.id) })
  |> list.length
}

fn strict_serial_requirement(brief_contents: String) -> Option(Option(Int)) {
  let normalized = normalize_requirement_text(brief_contents)
  case explicitly_requires_strict_serial_chain(normalized) {
    True -> Some(requested_implementation_task_count(normalized))
    False -> None
  }
}

fn explicitly_requires_strict_serial_chain(brief_contents: String) -> Bool {
  let markers = [
    "strict serial",
    "serial dependency chain",
    "single chain",
    "exact serial stack",
  ]

  list.any(markers, fn(marker) {
    string.contains(does: brief_contents, contain: marker)
  })
}

fn requested_implementation_task_count(brief_contents: String) -> Option(Int) {
  brief_contents
  |> string.split(" ")
  |> count_from_tokens
}

fn count_from_tokens(tokens: List(String)) -> Option(Int) {
  case tokens {
    [exactly, count, implementation, ..rest] ->
      case exactly == "exactly" && implementation == "implementation" {
        True ->
          case int.parse(count) {
            Ok(parsed) -> Some(parsed)
            Error(_) -> None
          }
        False -> count_from_tokens([count, implementation, ..rest])
      }
    [_token, ..rest] -> count_from_tokens(rest)
    [] -> None
  }
}

fn normalize_requirement_text(contents: String) -> String {
  contents
  |> string.lowercase
  |> string.replace("\n", " ")
  |> string.replace("\r", " ")
  |> string.replace(",", " ")
  |> string.replace(".", " ")
  |> string.replace(":", " ")
  |> string.replace(";", " ")
  |> string.replace("(", " ")
  |> string.replace(")", " ")
}

fn int_to_string(value: Int) -> String {
  value
  |> int.to_string
}

fn int_add(acc: Int, value: Int) -> Int {
  acc + value
}
