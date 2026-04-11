import filepath
import gleam/list
import gleam/string
import night_shift/shell
import night_shift/system

pub fn repo_root(cwd: String) -> String {
  let log_path =
    filepath.join(system.state_directory(), "night-shift/git-root.log")
  let result = shell.run("git rev-parse --show-toplevel", cwd, log_path)
  case shell.succeeded(result) {
    True -> string.trim(result.output)
    False -> cwd
  }
}

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

pub fn has_changes(cwd: String, log_path: String) -> Bool {
  let result = shell.run("git status --short", cwd, log_path)
  shell.succeeded(result) && string.trim(result.output) != ""
}

pub fn changed_files(cwd: String, log_path: String) -> List(String) {
  let result = shell.run("git status --short", cwd, log_path)
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

pub fn head_commit(cwd: String, log_path: String) -> Result(String, String) {
  let result = shell.run("git rev-parse HEAD", cwd, log_path)
  case shell.succeeded(result) {
    True -> Ok(string.trim(result.output))
    False -> Error("Git command failed: " <> string.trim(result.output))
  }
}

pub fn commit_all(
  cwd: String,
  message: String,
  log_path: String,
) -> Result(Nil, String) {
  run_git("git add -A && git commit -m " <> shell.quote(message), cwd, log_path)
}

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
