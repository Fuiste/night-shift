import gleam/option.{type Option}
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
    notes_source: types.NotesSource,
    warnings: List(String),
    next_action: String,
  )
}

pub type StatusResult {
  StatusResult(
    run: types.RunRecord,
    events: List(types.RunEvent),
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
  StartResult(run: types.RunRecord, warnings: List(String), next_action: String)
}

pub type ResumeResult {
  ResumeResult(
    run: types.RunRecord,
    warnings: List(String),
    next_action: String,
  )
}

pub type ReviewResult {
  ReviewResult(
    run: types.RunRecord,
    warnings: List(String),
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
