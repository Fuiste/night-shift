import gleam/list
import gleam/result
import gleam/string
import night_shift/types

pub type ReconciliationWarning {
  ReconciliationWarning(
    task_id: String,
    previous_key: String,
    new_key: String,
    question: String,
  )
}

pub fn reconcile_decision_requests(
  decisions: List(types.RecordedDecision),
  tasks: List(types.Task),
) -> Result(#(List(types.Task), List(ReconciliationWarning)), String) {
  reconcile_tasks(decisions, tasks, [], [])
}

fn reconcile_tasks(
  decisions: List(types.RecordedDecision),
  tasks: List(types.Task),
  rewritten_tasks: List(types.Task),
  warnings: List(ReconciliationWarning),
) -> Result(#(List(types.Task), List(ReconciliationWarning)), String) {
  case tasks {
    [] -> Ok(#(list.reverse(rewritten_tasks), list.reverse(warnings)))
    [task, ..rest] -> {
      use #(updated_task, new_warnings) <- result.try(reconcile_task(
        decisions,
        task,
      ))
      reconcile_tasks(
        decisions,
        rest,
        [updated_task, ..rewritten_tasks],
        list.append(list.reverse(new_warnings), warnings),
      )
    }
  }
}

fn reconcile_task(
  decisions: List(types.RecordedDecision),
  task: types.Task,
) -> Result(#(types.Task, List(ReconciliationWarning)), String) {
  use #(requests, warnings) <- result.try(
    reconcile_requests(decisions, task.id, task.decision_requests, [], []),
  )
  Ok(#(types.Task(..task, decision_requests: requests), warnings))
}

fn reconcile_requests(
  decisions: List(types.RecordedDecision),
  task_id: String,
  requests: List(types.DecisionRequest),
  rewritten: List(types.DecisionRequest),
  warnings: List(ReconciliationWarning),
) -> Result(#(List(types.DecisionRequest), List(ReconciliationWarning)), String) {
  case requests {
    [] -> Ok(#(list.reverse(rewritten), list.reverse(warnings)))
    [request, ..rest] -> {
      case types.decision_recorded(decisions, request.key) {
        True ->
          reconcile_requests(
            decisions,
            task_id,
            rest,
            [request, ..rewritten],
            warnings,
          )
        False ->
          case compatible_decisions(decisions, request) {
            [] ->
              reconcile_requests(
                decisions,
                task_id,
                rest,
                [request, ..rewritten],
                warnings,
              )
            [decision] -> {
              let updated_request =
                types.DecisionRequest(..request, key: decision.key)
              let warning =
                ReconciliationWarning(
                  task_id: task_id,
                  previous_key: request.key,
                  new_key: decision.key,
                  question: request.question,
                )
              reconcile_requests(
                decisions,
                task_id,
                rest,
                [updated_request, ..rewritten],
                [warning, ..warnings],
              )
            }
            _ ->
              Error(
                "Planner re-asked a previously answered decision ambiguously: "
                <> request.question
                <> ". Reuse the recorded decision key instead of inventing a new question.",
              )
          }
      }
    }
  }
}

fn compatible_decisions(
  decisions: List(types.RecordedDecision),
  request: types.DecisionRequest,
) -> List(types.RecordedDecision) {
  decisions
  |> list.filter(fn(decision) {
    compatible_question_pair(request.question, decision.question)
  })
}

fn compatible_question_pair(
  request_question: String,
  recorded_question: String,
) -> Bool {
  let normalized_request = normalized_question(request_question)
  let normalized_recorded = normalized_question(recorded_question)
  let request_tokens = normalized_tokens(request_question)
  let recorded_tokens = normalized_tokens(recorded_question)
  let shared_tokens = shared_token_count(request_tokens, recorded_tokens)

  case normalized_request == normalized_recorded && normalized_request != "" {
    True -> True
    False ->
      case
        is_file_location_question(request_question)
        && is_file_location_question(recorded_question)
      {
        True -> True
        False ->
          shared_tokens >= 2
          && shared_tokens * 2
          >= smallest_token_length(request_tokens, recorded_tokens)
      }
  }
}

fn smallest_token_length(left: List(String), right: List(String)) -> Int {
  let left_length = list.length(left)
  let right_length = list.length(right)
  case left_length <= right_length {
    True -> left_length
    False -> right_length
  }
}

fn shared_token_count(left: List(String), right: List(String)) -> Int {
  left
  |> list.filter(fn(token) { list.contains(right, token) })
  |> list.length
}

fn is_file_location_question(question: String) -> Bool {
  let lowered = string.lowercase(question)
  list.any(
    [
      "file",
      "doc",
      "documentation",
      "location",
      "target",
      "host",
      "where",
      "place",
      "receive",
      "added",
    ],
    fn(token) { string.contains(does: lowered, contain: token) },
  )
}

fn normalized_question(question: String) -> String {
  normalized_tokens(question)
  |> string.join(with: " ")
}

fn normalized_tokens(question: String) -> List(String) {
  question
  |> string.lowercase
  |> strip_punctuation
  |> string.split(" ")
  |> list.filter(fn(token) {
    let trimmed = string.trim(token)
    trimmed != "" && !list.contains(filler_tokens(), trimmed)
  })
}

fn strip_punctuation(value: String) -> String {
  list.fold(
    [
      "?",
      ".",
      ",",
      ":",
      ";",
      "!",
      "(",
      ")",
      "[",
      "]",
      "{",
      "}",
      "'",
      "\"",
      "-",
      "_",
      "/",
    ],
    value,
    fn(text, punctuation) {
      string.replace(in: text, each: punctuation, with: " ")
    },
  )
}

fn filler_tokens() -> List(String) {
  [
    "which",
    "where",
    "should",
    "the",
    "a",
    "one",
    "tiny",
    "next",
    "day",
    "nextday",
    "follow",
    "up",
    "followup",
    "file",
  ]
}
