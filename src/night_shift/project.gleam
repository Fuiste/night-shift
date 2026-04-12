//// Canonical repo-local filesystem layout for Night Shift state.
import filepath
import simplifile

/// Return the root of the repo-local `.night-shift` directory.
pub fn home(repo_root: String) -> String {
  filepath.join(repo_root, ".night-shift")
}

/// Return the path to the repo-local Night Shift config file.
pub fn config_path(repo_root: String) -> String {
  filepath.join(home(repo_root), "config.toml")
}

/// Return the path to the worktree setup config file.
pub fn worktree_setup_path(repo_root: String) -> String {
  filepath.join(home(repo_root), "worktree-setup.toml")
}

/// Return the default execution brief path.
pub fn default_brief_path(repo_root: String) -> String {
  filepath.join(home(repo_root), "execution-brief.md")
}

/// Return the directory that stores persisted runs.
pub fn runs_root(repo_root: String) -> String {
  filepath.join(home(repo_root), "runs")
}

/// Return the directory that stores planning artifacts.
pub fn planning_root(repo_root: String) -> String {
  filepath.join(home(repo_root), "planning")
}

/// Return the path of the active-run lock file.
pub fn active_lock_path(repo_root: String) -> String {
  filepath.join(home(repo_root), "active.lock")
}

/// Return the repo-local gitignore path managed by Night Shift.
pub fn gitignore_path(repo_root: String) -> String {
  filepath.join(home(repo_root), ".gitignore")
}

/// Return the source repository's local exclude file path.
pub fn local_exclude_path(repo_root: String) -> String {
  filepath.join(repo_root, ".git/info/exclude")
}

/// Return the legacy one-file config path.
pub fn legacy_config_path(repo_root: String) -> String {
  filepath.join(repo_root, ".night-shift.toml")
}

/// Return `True` when repo-local Night Shift state already exists.
pub fn home_exists(repo_root: String) -> Bool {
  case simplifile.read_directory(at: home(repo_root)) {
    Ok(_) -> True
    Error(_) -> False
  }
}
