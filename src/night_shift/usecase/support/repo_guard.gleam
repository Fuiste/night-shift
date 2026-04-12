import filepath
import gleam/list
import gleam/string
import night_shift/git
import night_shift/system

pub fn ensure_clean_repo_for_start(
  repo_root: String,
) -> Result(List(String), String) {
  let log_path =
    filepath.join(system.state_directory(), "night-shift/start-clean.log")
  let changed_files = git.changed_files(repo_root, log_path)
  let source_changes =
    changed_files
    |> list.filter(fn(path) { !is_control_plane_path(path) })
  let control_changes =
    changed_files
    |> list.filter(is_control_plane_path)

  case source_changes, control_changes {
    [], [] -> Ok([])
    [], _ ->
      Ok([
        "Night Shift noticed repo-local control-plane changes under `.night-shift/` and will continue.\nChanged control files:\n"
        <> render_changed_paths(control_changes)
        <> "\nThese files stay in the source checkout and are not part of execution worktrees or delivery PRs.",
      ])
    _, _ ->
      Error(
        "Night Shift start requires a clean source repository so execution worktrees and delivery stay aligned.\nChanged files:\n"
        <> render_changed_paths(source_changes)
        <> start_clean_repo_suggestion(source_changes, repo_root),
      )
  }
}

fn render_changed_paths(paths: List(String)) -> String {
  paths
  |> list.map(fn(path) { "- " <> path })
  |> string.join(with: "\n")
}

fn is_control_plane_path(path: String) -> Bool {
  path == ".night-shift" || string.starts_with(path, ".night-shift/")
}

fn start_clean_repo_suggestion(paths: List(String), repo_root: String) -> String {
  let only_night_shift =
    list.all(paths, fn(path) {
      path == ".night-shift" || string.starts_with(path, ".night-shift/")
    })
  case only_night_shift {
    True ->
      "\nCommit or discard those .night-shift changes before rerunning `night-shift start`, or run `night-shift reset` from "
      <> repo_root
      <> " to eject and reinitialize Night Shift."
    False ->
      "\nCommit, stash, or move those changes out of "
      <> repo_root
      <> " and rerun `night-shift start`."
  }
}
