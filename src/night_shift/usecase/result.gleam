import gleam/option.{type Option}
import night_shift/repo_state_runtime
import night_shift/types

pub type InitResult {
  InitResult(
    repo_root: String,
    config_status: String,
    setup_status: String,
    next_action: String,
  )
}

pub type PlanResult {
  PlanResult(
    run: types.RunRecord,
    brief_path: String,
    artifact_path: String,
    planning_provenance: types.PlanningProvenance,
    warnings: List(String),
    next_action: String,
  )
}

pub type StatusResult {
  StatusResult(
    run: types.RunRecord,
    events: List(types.RunEvent),
    repo_state_view: Option(repo_state_runtime.RepoStateView),
    confidence: types.ConfidenceAssessment,
    provenance_path: String,
    summary: String,
    next_action: String,
  )
}

pub type ResolveResult {
  ResolveResult(
    run: types.RunRecord,
    warnings: List(String),
    next_action: String,
    summary: Option(String),
  )
}

pub type StartResult {
  StartResult(
    run: types.RunRecord,
    warnings: List(String),
    repo_state_view: Option(repo_state_runtime.RepoStateView),
    next_action: String,
  )
}

pub type ResumeResult {
  ResumeResult(
    run: types.RunRecord,
    warnings: List(String),
    repo_state_view: Option(repo_state_runtime.RepoStateView),
    next_action: String,
  )
}

pub type ResetResult {
  ResetResult(
    repo_root: String,
    removed_worktrees: List(String),
    failed_worktrees: List(String),
    prune_status: String,
    home_status: String,
    next_action: String,
  )
}
