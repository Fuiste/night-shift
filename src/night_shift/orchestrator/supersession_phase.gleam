import filepath
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import night_shift/github
import night_shift/journal
import night_shift/orchestrator/worktree_hygiene
import night_shift/system
import night_shift/types

pub type SupersededReplacement {
  SupersededReplacement(
    superseded_pr_number: Int,
    replacement_pr_numbers: List(Int),
  )
}

pub fn finalize_completed_run(
  run: types.RunRecord,
) -> Result(types.RunRecord, String) {
  case run.planning_provenance {
    Some(provenance) ->
      case types.planning_provenance_uses_reviews(provenance) {
        True -> {
          let mappings = collect_superseded_replacements(run.tasks)
          use superseded_run <- result.try(close_superseded_pull_requests(
            run,
            mappings,
          ))
          worktree_hygiene.prune_superseded_successful_worktrees(
            superseded_run,
            collect_superseded_pr_numbers(mappings),
          )
        }
        False -> Ok(run)
      }
    None -> Ok(run)
  }
}

fn collect_superseded_replacements(
  tasks: List(types.Task),
) -> List(SupersededReplacement) {
  tasks
  |> list.fold([], fn(acc, task) {
    case task.state == types.Completed, parse_pr_number(task.pr_number) {
      True, Ok(replacement_pr_number) ->
        task.superseded_pr_numbers
        |> list.fold(acc, fn(acc, superseded_pr_number) {
          record_superseded_replacement(
            acc,
            superseded_pr_number,
            replacement_pr_number,
          )
        })
      _, _ -> acc
    }
  })
}

fn record_superseded_replacement(
  mappings: List(SupersededReplacement),
  superseded_pr_number: Int,
  replacement_pr_number: Int,
) -> List(SupersededReplacement) {
  case mappings {
    [] -> [
      SupersededReplacement(
        superseded_pr_number: superseded_pr_number,
        replacement_pr_numbers: [replacement_pr_number],
      ),
    ]
    [SupersededReplacement(existing_pr_number, replacements), ..rest] ->
      case existing_pr_number == superseded_pr_number {
        True -> [
          SupersededReplacement(
            superseded_pr_number: existing_pr_number,
            replacement_pr_numbers: append_unique_int(
              replacements,
              replacement_pr_number,
            ),
          ),
          ..rest
        ]
        False -> [
          SupersededReplacement(
            superseded_pr_number: existing_pr_number,
            replacement_pr_numbers: replacements,
          ),
          ..record_superseded_replacement(
            rest,
            superseded_pr_number,
            replacement_pr_number,
          )
        ]
      }
  }
}

fn close_superseded_pull_requests(
  run: types.RunRecord,
  mappings: List(SupersededReplacement),
) -> Result(types.RunRecord, String) {
  case mappings {
    [] -> Ok(run)
    [
      SupersededReplacement(superseded_pr_number, replacement_pr_numbers),
      ..rest
    ] -> {
      let log_path =
        filepath.join(
          run.run_path,
          "logs/review-supersession-"
            <> int.to_string(superseded_pr_number)
            <> ".log",
        )
      let replacement_summary = render_pr_numbers(replacement_pr_numbers)
      let event = case
        github.mark_pull_request_superseded(
          run.repo_root,
          superseded_pr_number,
          replacement_pr_numbers,
          log_path,
        )
      {
        Ok(_) ->
          types.RunEvent(
            kind: "pr_superseded",
            at: system.timestamp(),
            message: "Closed superseded PR #"
              <> int.to_string(superseded_pr_number)
              <> " after opening replacement PRs "
              <> replacement_summary
              <> ".",
            task_id: None,
          )
        Error(message) ->
          types.RunEvent(
            kind: "review_supersession_warning",
            at: system.timestamp(),
            message: "Replacement PRs "
              <> replacement_summary
              <> " were created, but Night Shift could not close superseded PR #"
              <> int.to_string(superseded_pr_number)
              <> ": "
              <> message,
            task_id: None,
          )
      }
      use updated_run <- result.try(journal.append_event(run, event))
      close_superseded_pull_requests(updated_run, rest)
    }
  }
}

pub fn render_pr_numbers(pr_numbers: List(Int)) -> String {
  pr_numbers
  |> list.map(fn(pr_number) { "#" <> int.to_string(pr_number) })
  |> string.join(with: ", ")
}

fn collect_superseded_pr_numbers(
  mappings: List(SupersededReplacement),
) -> List(Int) {
  mappings
  |> list.map(fn(mapping) { mapping.superseded_pr_number })
}

fn append_unique_int(values: List(Int), candidate: Int) -> List(Int) {
  case list.contains(values, candidate) {
    True -> values
    False -> list.append(values, [candidate])
  }
}

fn parse_pr_number(pr_number: String) -> Result(Int, Nil) {
  int.parse(pr_number)
}
