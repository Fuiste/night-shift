import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/repo_state_runtime
import night_shift/types
import simplifile

pub fn assess(
  run: types.RunRecord,
  events: List(types.RunEvent),
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> types.ConfidenceAssessment {
  let severe = severe_reasons(run, events)
  let moderate = moderate_reasons(events, repo_state_view)
  let positive = positive_reasons(run, events)

  case severe {
    [_, ..] ->
      types.ConfidenceAssessment(
        posture: types.ConfidenceLow,
        reasons: take_first(list.append(severe, moderate), 4),
      )
    [] ->
      case moderate {
        [_, ..] ->
          types.ConfidenceAssessment(
            posture: types.ConfidenceGuarded,
            reasons: take_first(list.append(moderate, positive), 4),
          )
        [] ->
          types.ConfidenceAssessment(
            posture: types.ConfidenceHigh,
            reasons: case positive {
              [] -> ["No elevated-risk signals are recorded for this run."]
              _ -> take_first(positive, 4)
            },
          )
      }
  }
}

pub fn reasons_summary(assessment: types.ConfidenceAssessment) -> String {
  case assessment.reasons {
    [] -> "none"
    reasons -> string.join(reasons, with: " | ")
  }
}

fn severe_reasons(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> List(String) {
  let manual_attention_count =
    run.tasks
    |> list.filter(fn(task) {
      types.task_requires_manual_attention(run.decisions, task)
    })
    |> list.length
  let failed_count =
    run.tasks
    |> list.filter(fn(task) { task.state == types.Failed })
    |> list.length
  let missing_worktrees =
    run.tasks
    |> list.filter(fn(task) { task.worktree_path != "" })
    |> list.filter(fn(task) { !directory_exists(task.worktree_path) })
    |> list.length
  let payload_repair_failures =
    event_count(events, "execution_payload_repair_failed")
  let run_failed = event_count(events, "run_failed")

  [
    latest_environment_preflight_failure(events)
      |> option_reason("Environment bootstrap failed."),
    count_reason(
      manual_attention_count,
      "manual-attention task is still unresolved.",
      "manual-attention tasks are still unresolved.",
    ),
    count_reason(
      unresolved_decision_requests_count(run),
      "operator decision is still unresolved.",
      "operator decisions are still unresolved.",
    ),
    count_reason(failed_count, "task failed.", "tasks failed."),
    count_reason(
      payload_repair_failures,
      "payload repair failed.",
      "payload repairs failed.",
    ),
    count_reason(
      missing_worktrees,
      "retained worktree is missing from disk.",
      "retained worktrees are missing from disk.",
    ),
    count_reason(
      run_failed,
      "run failure was recorded.",
      "run failures were recorded.",
    ),
  ]
  |> list.filter_map(identity_reason)
}

fn moderate_reasons(
  events: List(types.RunEvent),
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> List(String) {
  let payload_warnings = event_count(events, "execution_payload_warning")
  let payload_repairs =
    event_count(events, "execution_payload_repair_succeeded")
  let prune_warnings = event_count(events, "worktree_prune_warning")
  let supersession_warnings = event_count(events, "review_supersession_warning")
  let repo_state_reason = case repo_state_view {
    Some(view) ->
      case view.drift {
        repo_state_runtime.RepoStateDrifted ->
          Some("Review snapshot drifted since planning.")
        repo_state_runtime.RepoStateDriftUnknown(_) ->
          Some("Live review snapshot refresh is unavailable.")
        _ -> None
      }
    None -> None
  }

  [
    count_reason(
      payload_warnings,
      "recovered execution payload was accepted.",
      "recovered execution payloads were accepted.",
    ),
    count_reason(
      payload_repairs,
      "JSON-only payload repair succeeded.",
      "JSON-only payload repairs succeeded.",
    ),
    count_reason(
      prune_warnings,
      "worktree prune warning was recorded.",
      "worktree prune warnings were recorded.",
    ),
    count_reason(
      supersession_warnings,
      "review supersession warning was recorded.",
      "review supersession warnings were recorded.",
    ),
    repo_state_reason,
  ]
  |> list.filter_map(identity_reason)
}

fn positive_reasons(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> List(String) {
  let pr_opened = event_count(events, "pr_opened")
  let verified = event_count(events, "task_verified")
  let retained_worktrees =
    run.tasks
    |> list.filter(fn(task) { task.worktree_path != "" })
    |> list.length
  let retained_and_present =
    retained_worktrees > 0
    && list.all(
      run.tasks
        |> list.filter(fn(task) { task.worktree_path != "" }),
      fn(task) { directory_exists(task.worktree_path) },
    )

  [
    case verified > 0 {
      True -> Some("Verification passed for delivered task work.")
      False -> None
    },
    case pr_opened > 0 {
      True -> Some("Delivered pull requests are recorded in the journal.")
      False -> None
    },
    case unresolved_decision_requests_count(run) == 0 {
      True -> Some("No outstanding operator decisions remain.")
      False -> None
    },
    case retained_and_present {
      True ->
        Some("Retained worktrees remain mounted for inspection and recovery.")
      False -> None
    },
  ]
  |> list.filter_map(identity_reason)
}

fn unresolved_decision_requests_count(run: types.RunRecord) -> Int {
  run.tasks
  |> list.filter(fn(task) {
    types.task_requires_manual_attention(run.decisions, task)
  })
  |> list.map(fn(task) {
    list.length(types.unresolved_decision_requests(run.decisions, task))
  })
  |> list.fold(0, fn(total, count) { total + count })
}

fn event_count(events: List(types.RunEvent), kind: String) -> Int {
  events
  |> list.filter(fn(event) { event.kind == kind })
  |> list.length
}

fn latest_environment_preflight_failure(
  events: List(types.RunEvent),
) -> Option(String) {
  latest_environment_preflight_failure_loop(list.reverse(events))
}

fn latest_environment_preflight_failure_loop(
  events: List(types.RunEvent),
) -> Option(String) {
  case events {
    [] -> None
    [event, ..rest] ->
      case event.kind == "environment_preflight_failed" {
        True -> Some(event.message)
        False -> latest_environment_preflight_failure_loop(rest)
      }
  }
}

fn directory_exists(path: String) -> Bool {
  case simplifile.read_directory(at: path) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn option_reason(value: Option(a), message: String) -> Option(String) {
  case value {
    Some(_) -> Some(message)
    None -> None
  }
}

fn count_reason(count: Int, singular: String, plural: String) -> Option(String) {
  case count {
    0 -> None
    1 -> Some("1 " <> singular)
    _ -> Some(int.to_string(count) <> " " <> plural)
  }
}

fn identity_reason(value: Option(String)) -> Result(String, Nil) {
  case value {
    Some(reason) -> Ok(reason)
    None -> Error(Nil)
  }
}

fn take_first(values: List(String), limit: Int) -> List(String) {
  take_first_loop(values, limit, [])
}

fn take_first_loop(
  values: List(String),
  remaining: Int,
  acc: List(String),
) -> List(String) {
  case values, remaining <= 0 {
    _, True -> list.reverse(acc)
    [], False -> list.reverse(acc)
    [value, ..rest], False ->
      take_first_loop(rest, remaining - 1, [value, ..acc])
  }
}
