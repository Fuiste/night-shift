//// Thin git command wrappers used by Night Shift orchestration.

import filepath
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/shell
import night_shift/system

/// Resolve the repository root for the given working directory.
pub fn repo_root(cwd: String) -> String {
  let log_path =
    filepath.join(system.state_directory(), "night-shift/git-root.log")
  let result = shell.run("git rev-parse --show-toplevel", cwd, log_path)
  case shell.succeeded(result) {
    True -> string.trim(result.output)
    False -> cwd
  }
}

/// Create a new worktree and branch for a task.
pub fn create_worktree(
  repo_root: String,
  worktree_path: String,
  branch_name: String,
  base_ref: String,
  log_path: String,
) -> Result(Nil, String) {
  run_git(
    "git worktree add -b "
      <> shell.quote(branch_name)
      <> " "
      <> shell.quote(worktree_path)
      <> " "
      <> shell.quote(base_ref),
    repo_root,
    log_path,
  )
}

/// Attach an existing branch to a worktree path, fetching it first if needed.
pub fn attach_worktree(
  repo_root: String,
  worktree_path: String,
  branch_name: String,
  log_path: String,
) -> Result(Nil, String) {
  run_git(
    "git show-ref --verify --quiet refs/heads/"
      <> shell.quote(branch_name)
      <> " || git fetch origin "
      <> shell.quote(branch_name)
      <> ":"
      <> shell.quote(branch_name)
      <> " && git worktree add "
      <> shell.quote(worktree_path)
      <> " "
      <> shell.quote(branch_name),
    repo_root,
    log_path,
  )
}

/// Return the mounted worktree path for a branch when one already exists.
pub fn mounted_worktree_path(
  repo_root: String,
  branch_name: String,
  log_path: String,
) -> Result(Option(String), String) {
  let command =
    "git worktree list --porcelain | awk -v target="
    <> shell.quote("refs/heads/" <> branch_name)
    <> " 'BEGIN { path = \"\" } $1 == \"worktree\" { path = substr($0, 10) } $1 == \"branch\" && $2 == target { print path; exit }'"
  let result = shell.run(command, repo_root, log_path)
  case shell.succeeded(result) {
    True ->
      case string.trim(result.output) {
        "" -> Ok(None)
        path -> Ok(Some(path))
      }
    False -> Error("Git command failed: " <> string.trim(result.output))
  }
}

/// Return `True` when the working tree has tracked or untracked changes.
pub fn has_changes(cwd: String, log_path: String) -> Bool {
  let result =
    shell.run("git status --short --untracked-files=all", cwd, log_path)
  shell.succeeded(result) && string.trim(result.output) != ""
}

/// List changed file paths from `git status --short`.
pub fn changed_files(cwd: String, log_path: String) -> List(String) {
  let result =
    shell.run("git status --short --untracked-files=all", cwd, log_path)
  case shell.succeeded(result) {
    True ->
      result.output
      |> string.trim
      |> string.split("\n")
      |> list.filter_map(fn(line) {
        let trimmed = string.trim(line)
        case trimmed {
          "" -> Error(Nil)
          _ -> {
            let file = case string.length(trimmed) > 3 {
              True -> string.drop_start(trimmed, 3)
              False -> trimmed
            }
            Ok(file)
          }
        }
      })
    False -> []
  }
}

/// Remove a worktree path forcefully.
pub fn remove_worktree(
  repo_root: String,
  worktree_path: String,
  log_path: String,
) -> Result(Nil, String) {
  run_git(
    "git worktree remove --force " <> shell.quote(worktree_path),
    repo_root,
    log_path,
  )
}

/// Prune stale git worktree metadata.
pub fn prune_worktrees(
  repo_root: String,
  log_path: String,
) -> Result(Nil, String) {
  run_git("git worktree prune", repo_root, log_path)
}

/// List file paths changed between two refs.
pub fn changed_files_between(
  cwd: String,
  from_ref: String,
  to_ref: String,
  log_path: String,
) -> List(String) {
  let result =
    shell.run(
      "git diff --name-only "
        <> shell.quote(from_ref)
        <> " "
        <> shell.quote(to_ref),
      cwd,
      log_path,
    )

  case shell.succeeded(result) {
    True ->
      result.output
      |> string.trim
      |> string.split("\n")
      |> list.filter_map(fn(line) {
        case string.trim(line) {
          "" -> Error(Nil)
          file -> Ok(file)
        }
      })
    False -> []
  }
}

/// Resolve `HEAD` to a commit id.
pub fn head_commit(cwd: String, log_path: String) -> Result(String, String) {
  let result = shell.run("git rev-parse HEAD", cwd, log_path)
  case shell.succeeded(result) {
    True -> Ok(string.trim(result.output))
    False -> Error("Git command failed: " <> string.trim(result.output))
  }
}

/// Stage all changes and create one commit.
pub fn commit_all(
  cwd: String,
  message: String,
  log_path: String,
) -> Result(Nil, String) {
  run_git("git add -A && git commit -m " <> shell.quote(message), cwd, log_path)
}

/// Push a branch and set its upstream.
pub fn push_branch(
  cwd: String,
  branch_name: String,
  log_path: String,
) -> Result(Nil, String) {
  run_git(
    "git push --set-upstream origin " <> shell.quote(branch_name),
    cwd,
    log_path,
  )
}

fn run_git(
  command: String,
  cwd: String,
  log_path: String,
) -> Result(Nil, String) {
  let result = shell.run(command, cwd, log_path)
  case shell.succeeded(result) {
    True -> Ok(Nil)
    False -> Error("Git command failed: " <> string.trim(result.output))
  }
}
