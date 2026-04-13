import filepath
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/result
import night_shift/git
import night_shift/journal
import night_shift/system
import night_shift/types
import simplifile

pub fn prune_superseded_successful_worktrees(
  run: types.RunRecord,
  superseded_pr_numbers: List(Int),
) -> Result(types.RunRecord, String) {
  case superseded_pr_numbers {
    [] -> Ok(run)
    _ ->
      case journal.list_runs(run.repo_root) {
        Ok(prior_runs) -> {
          let candidates =
            prior_runs
            |> list.filter(fn(candidate) {
              run_is_prune_candidate(run, candidate, superseded_pr_numbers)
            })
          use #(pruned_run, pruned_any) <- result.try(prune_candidate_runs(
            run,
            candidates,
          ))
          case pruned_any {
            True ->
              finalize_worktree_prune_metadata(
                pruned_run,
                filepath.join(pruned_run.run_path, "logs/worktree-prune.log"),
              )
            False -> Ok(pruned_run)
          }
        }
        Error(message) ->
          append_worktree_prune_warning(
            run,
            "Night Shift completed review supersession cleanup, but could not inspect prior runs for safe worktree pruning: "
              <> message,
          )
      }
  }
}

fn run_is_prune_candidate(
  current_run: types.RunRecord,
  candidate: types.RunRecord,
  superseded_pr_numbers: List(Int),
) -> Bool {
  candidate.run_id != current_run.run_id
  && candidate.status == types.RunCompleted
  && run_pr_numbers_fully_superseded(candidate, superseded_pr_numbers)
}

fn run_pr_numbers_fully_superseded(
  run: types.RunRecord,
  superseded_pr_numbers: List(Int),
) -> Bool {
  let candidate_pr_numbers =
    run.tasks
    |> list.filter_map(fn(task) {
      case task.state == types.Completed && task.worktree_path != "" {
        True ->
          case parse_pr_number(task.pr_number) {
            Ok(pr_number) -> Ok(pr_number)
            Error(_) -> Error(Nil)
          }
        False -> Error(Nil)
      }
    })

  case candidate_pr_numbers {
    [] -> False
    _ ->
      list.all(candidate_pr_numbers, fn(pr_number) {
        list.contains(superseded_pr_numbers, pr_number)
      })
  }
}

fn prune_candidate_runs(
  run: types.RunRecord,
  candidates: List(types.RunRecord),
) -> Result(#(types.RunRecord, Bool), String) {
  case candidates {
    [] -> Ok(#(run, False))
    [candidate, ..rest] -> {
      use #(updated_run, candidate_pruned) <- result.try(prune_run_worktrees(
        run,
        candidate,
      ))
      use #(final_run, rest_pruned) <- result.try(prune_candidate_runs(
        updated_run,
        rest,
      ))
      Ok(#(final_run, candidate_pruned || rest_pruned))
    }
  }
}

fn prune_run_worktrees(
  run: types.RunRecord,
  candidate: types.RunRecord,
) -> Result(#(types.RunRecord, Bool), String) {
  prune_run_worktrees_loop(run, candidate, candidate.tasks, False)
}

fn prune_run_worktrees_loop(
  run: types.RunRecord,
  candidate: types.RunRecord,
  tasks: List(types.Task),
  pruned_any: Bool,
) -> Result(#(types.RunRecord, Bool), String) {
  case tasks {
    [] -> Ok(#(run, pruned_any))
    [task, ..rest] -> {
      use #(updated_run, task_pruned) <- result.try(prune_worktree_if_safe(
        run,
        candidate,
        task,
      ))
      prune_run_worktrees_loop(
        updated_run,
        candidate,
        rest,
        pruned_any || task_pruned,
      )
    }
  }
}

fn prune_worktree_if_safe(
  run: types.RunRecord,
  candidate: types.RunRecord,
  task: types.Task,
) -> Result(#(types.RunRecord, Bool), String) {
  case task.worktree_path {
    "" -> Ok(#(run, False))
    worktree_path -> {
      let log_path =
        filepath.join(
          run.run_path,
          "logs/worktree-prune-" <> candidate.run_id <> "-" <> task.id <> ".log",
        )
      case simplifile.read_directory(at: worktree_path) {
        Error(_) ->
          append_worktree_prune_warning(
            run,
            "Night Shift skipped pruning superseded worktree for run "
              <> candidate.run_id
              <> " task "
              <> task.id
              <> " because the path no longer exists: "
              <> worktree_path,
          )
          |> result.map(fn(updated_run) { #(updated_run, False) })
        Ok(_) ->
          case git.has_changes(worktree_path, log_path) {
            True ->
              append_worktree_prune_warning(
                run,
                "Night Shift retained superseded worktree for run "
                  <> candidate.run_id
                  <> " task "
                  <> task.id
                  <> " because it still has local changes: "
                  <> worktree_path,
              )
              |> result.map(fn(updated_run) { #(updated_run, False) })
            False ->
              case git.remove_worktree(run.repo_root, worktree_path, log_path) {
                Ok(_) ->
                  journal.append_event(
                    run,
                    types.RunEvent(
                      kind: "worktree_pruned",
                      at: system.timestamp(),
                      message: "Pruned clean superseded worktree for run "
                        <> candidate.run_id
                        <> " task "
                        <> task.id
                        <> " at "
                        <> worktree_path
                        <> ".",
                      task_id: None,
                    ),
                  )
                  |> result.map(fn(updated_run) { #(updated_run, True) })
                Error(message) ->
                  append_worktree_prune_warning(
                    run,
                    "Night Shift could not prune superseded worktree for run "
                      <> candidate.run_id
                      <> " task "
                      <> task.id
                      <> ": "
                      <> message,
                  )
                  |> result.map(fn(updated_run) { #(updated_run, False) })
              }
          }
      }
    }
  }
}

fn finalize_worktree_prune_metadata(
  run: types.RunRecord,
  log_path: String,
) -> Result(types.RunRecord, String) {
  case git.prune_worktrees(run.repo_root, log_path) {
    Ok(_) -> Ok(run)
    Error(message) ->
      append_worktree_prune_warning(
        run,
        "Night Shift pruned clean superseded worktrees, but `git worktree prune` reported a warning: "
          <> message,
      )
  }
}

fn append_worktree_prune_warning(
  run: types.RunRecord,
  message: String,
) -> Result(types.RunRecord, String) {
  journal.append_event(
    run,
    types.RunEvent(
      kind: "worktree_prune_warning",
      at: system.timestamp(),
      message: message,
      task_id: None,
    ),
  )
}

fn parse_pr_number(pr_number: String) -> Result(Int, Nil) {
  int.parse(pr_number)
}
