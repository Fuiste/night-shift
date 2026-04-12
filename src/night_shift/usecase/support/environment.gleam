import gleam/option.{type Option, None, Some}
import gleam/result
import night_shift/project
import night_shift/worktree_setup

pub fn resolve_environment_name(
  repo_root: String,
  requested: Option(String),
) -> Result(String, String) {
  use maybe_config <- result.try(
    worktree_setup.load(project.worktree_setup_path(repo_root)),
  )
  use selected <- result.try(worktree_setup.choose_environment(
    maybe_config,
    requested,
  ))
  case selected {
    Some(environment) -> Ok(environment.name)
    None -> Ok("")
  }
}

pub fn ensure_saved_environment_is_valid(
  repo_root: String,
  environment_name: String,
) -> Result(Nil, String) {
  case environment_name {
    "" -> Ok(Nil)
    name ->
      resolve_environment_name(repo_root, Some(name))
      |> result.map(fn(_) { Nil })
  }
}
