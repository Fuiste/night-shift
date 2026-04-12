import filepath
import simplifile

pub fn home(repo_root: String) -> String {
  filepath.join(repo_root, ".night-shift")
}

pub fn config_path(repo_root: String) -> String {
  filepath.join(home(repo_root), "config.toml")
}

pub fn worktree_setup_path(repo_root: String) -> String {
  filepath.join(home(repo_root), "worktree-setup.toml")
}

pub fn default_brief_path(repo_root: String) -> String {
  filepath.join(home(repo_root), "execution-brief.md")
}

pub fn runs_root(repo_root: String) -> String {
  filepath.join(home(repo_root), "runs")
}

pub fn planning_root(repo_root: String) -> String {
  filepath.join(home(repo_root), "planning")
}

pub fn active_lock_path(repo_root: String) -> String {
  filepath.join(home(repo_root), "active.lock")
}

pub fn gitignore_path(repo_root: String) -> String {
  filepath.join(home(repo_root), ".gitignore")
}

pub fn local_exclude_path(repo_root: String) -> String {
  filepath.join(repo_root, ".git/info/exclude")
}

pub fn legacy_config_path(repo_root: String) -> String {
  filepath.join(repo_root, ".night-shift.toml")
}

pub fn home_exists(repo_root: String) -> Bool {
  case simplifile.read_directory(at: home(repo_root)) {
    Ok(_) -> True
    Error(_) -> False
  }
}
