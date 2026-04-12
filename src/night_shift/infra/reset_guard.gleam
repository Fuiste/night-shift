import gleam/io
import gleam/string
import night_shift/journal
import night_shift/project
import night_shift/system

pub fn confirm(
  repo_root: String,
  assume_yes: Bool,
  can_prompt: Bool,
) -> Result(Nil, String) {
  case assume_yes {
    True -> Ok(Nil)
    False ->
      case can_prompt {
        False ->
          Error(
            "night-shift reset requires --yes when not running in an interactive terminal.",
          )
        True -> {
          io.println(
            "Reset Night Shift for "
            <> repo_root
            <> "? This removes "
            <> project.home(repo_root)
            <> " and all recorded Night Shift worktrees. Type `reset` to continue:",
          )
          case string.trim(system.read_line()) {
            "reset" -> Ok(Nil)
            _ -> Error("Night Shift reset aborted.")
          }
        }
      }
  }
}

pub fn ensure_safe(repo_root: String, force: Bool) -> Result(Nil, String) {
  case journal.active_run_id(repo_root) {
    Ok(run_id) ->
      case force {
        True -> Ok(Nil)
        False ->
          Error(
            "Night Shift run "
            <> run_id
            <> " is still active for this repository. Stop it first or rerun `night-shift reset --force`.",
          )
      }
    Error(_) -> Ok(Nil)
  }
}
