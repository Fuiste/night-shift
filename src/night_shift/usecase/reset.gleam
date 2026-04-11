import filepath
import gleam/list
import gleam/result
import night_shift/git
import night_shift/journal
import night_shift/project
import night_shift/system
import night_shift/types
import night_shift/usecase/result as workflow
import simplifile

pub fn execute(repo_root: String) -> workflow.ResetResult {
  let runs = journal.list_runs(repo_root) |> result.unwrap(or: [])
  let worktrees = collect_worktree_paths(runs, [])
  let reset_log =
    filepath.join(system.state_directory(), "night-shift/reset.log")
  let #(removed_worktrees, failed_worktrees) =
    remove_worktrees(repo_root, worktrees, reset_log, [], [])
  let prune_status = case git.prune_worktrees(repo_root, reset_log) {
    Ok(_) -> "Pruned git worktree metadata."
    Error(message) -> "Worktree prune warning: " <> message
  }
  let home_path = project.home(repo_root)
  let home_status = case simplifile.delete(file_or_dir_at: home_path) {
    Ok(_) -> "Removed state: " <> home_path
    Error(error) ->
      case project.home_exists(repo_root) {
        False -> "Removed state: (already absent) " <> home_path
        True ->
          "Unable to remove "
          <> home_path
          <> ": "
          <> simplifile.describe_error(error)
      }
  }

  workflow.ResetResult(
    repo_root: repo_root,
    removed_worktrees: removed_worktrees,
    failed_worktrees: failed_worktrees,
    prune_status: prune_status,
    home_status: home_status,
    next_action: "night-shift init",
  )
}

fn collect_worktree_paths(
  runs: List(types.RunRecord),
  acc: List(String),
) -> List(String) {
  case runs {
    [] -> acc
    [run, ..rest] -> {
      let next =
        run.tasks
        |> list.fold(acc, fn(paths, task) {
          case task.worktree_path, list.contains(paths, task.worktree_path) {
            "", _ -> paths
            _, True -> paths
            path, False -> [path, ..paths]
          }
        })
      collect_worktree_paths(rest, next)
    }
  }
}

fn remove_worktrees(
  repo_root: String,
  worktrees: List(String),
  log_path: String,
  removed: List(String),
  failed: List(String),
) -> #(List(String), List(String)) {
  case worktrees {
    [] -> #(list.reverse(removed), list.reverse(failed))
    [path, ..rest] ->
      case git.remove_worktree(repo_root, path, log_path) {
        Ok(_) ->
          remove_worktrees(repo_root, rest, log_path, [path, ..removed], failed)
        Error(message) ->
          remove_worktrees(repo_root, rest, log_path, removed, [
            path <> ": " <> message,
            ..failed
          ])
      }
  }
}
