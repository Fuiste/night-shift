import gleam/option.{None, Some}
import gleam/string
import night_shift/report
import night_shift/repo_state_runtime
import night_shift/types

pub fn render_live_review_report_includes_repo_state_and_supersession_test() {
  let rendered =
    report.render_live(
      review_run(),
      [
        types.RunEvent(
          kind: "pr_superseded",
          at: "2026-04-13T18:00:00Z",
          message: "Closed superseded PR #12 after opening replacement PRs #15.",
          task_id: None,
        ),
        types.RunEvent(
          kind: "worktree_pruned",
          at: "2026-04-13T18:01:00Z",
          message: "Pruned clean superseded worktree for run prior-run task rewrite-root at /tmp/prior-root.",
          task_id: None,
        ),
        types.RunEvent(
          kind: "execution_payload_warning",
          at: "2026-04-13T18:02:00Z",
          message: "Accepted a recovered execution payload for task rewrite-root.\nRaw payload: /tmp/raw.jsonish\nSanitized payload: /tmp/recovered.json",
          task_id: Some("rewrite-root"),
        ),
      ],
      Some(repo_state_runtime.RepoStateView(
        snapshot_captured_at: "2026-04-13T17:30:00Z",
        open_pr_count: 3,
        actionable_pr_count: 1,
        drift: repo_state_runtime.RepoStateDrifted,
      )),
    )

  assert string.contains(does: rendered, contain: "Captured open PRs: 2")
  assert string.contains(does: rendered, contain: "Current open PRs: 3")
  assert string.contains(does: rendered, contain: "Drift: yes")
  assert string.contains(does: rendered, contain: "### Actionable PRs")
  assert string.contains(does: rendered, contain: "#12 Root rewrite")
  assert string.contains(does: rendered, contain: "### Impacted PRs")
  assert string.contains(
    does: rendered,
    contain: "rewrite-root -> supersedes #12 (replacement PR #15)",
  )
  assert string.contains(does: rendered, contain: "## Worktree Hygiene")
  assert string.contains(does: rendered, contain: "Pruned superseded worktrees: 1")
  assert string.contains(does: rendered, contain: "## Execution Recovery")
}

pub fn render_persisted_review_report_uses_snapshot_without_live_repo_state_test() {
  let rendered = report.render_persisted(review_run(), [])

  assert string.contains(does: rendered, contain: "Captured open PRs: 2")
  assert string.contains(does: rendered, contain: "Captured actionable PRs: 1")
  assert !string.contains(does: rendered, contain: "Current open PRs:")
  assert !string.contains(does: rendered, contain: "Drift: yes")
}

fn review_run() -> types.RunRecord {
  types.RunRecord(
    run_id: "review-run",
    repo_root: "/tmp/repo",
    run_path: "/tmp/repo/.night-shift/runs/review-run",
    brief_path: "/tmp/repo/.night-shift/runs/review-run/brief.md",
    state_path: "/tmp/repo/.night-shift/runs/review-run/state.json",
    events_path: "/tmp/repo/.night-shift/runs/review-run/events.jsonl",
    report_path: "/tmp/repo/.night-shift/runs/review-run/report.md",
    lock_path: "/tmp/repo/.night-shift/active.lock",
    planning_agent: types.resolved_agent_from_provider(types.Codex),
    execution_agent: types.resolved_agent_from_provider(types.Codex),
    environment_name: "default",
    max_workers: 1,
    notes_source: None,
    planning_provenance: Some(types.ReviewsOnly),
    repo_state_snapshot: Some(repo_state_snapshot()),
    decisions: [],
    planning_dirty: False,
    status: types.RunCompleted,
    created_at: "2026-04-13T17:30:00Z",
    updated_at: "2026-04-13T18:02:00Z",
    tasks: [
      replacement_task(
        "rewrite-root",
        [12],
        "15",
        "/tmp/repo/.night-shift/runs/review-run/worktrees/rewrite-root",
      ),
      replacement_task(
        "refresh-links",
        [13],
        "16",
        "/tmp/repo/.night-shift/runs/review-run/worktrees/refresh-links",
      ),
    ],
  )
}

fn replacement_task(
  id: String,
  superseded_pr_numbers: List(Int),
  pr_number: String,
  worktree_path: String,
) -> types.Task {
  types.Task(
    id: id,
    title: id,
    description: "",
    dependencies: [],
    acceptance: [],
    demo_plan: [],
    decision_requests: [],
    superseded_pr_numbers: superseded_pr_numbers,
    kind: types.ImplementationTask,
    execution_mode: types.Serial,
    state: types.Completed,
    worktree_path: worktree_path,
    branch_name: "night-shift/" <> id,
    pr_number: pr_number,
    summary: "Updated " <> id,
  )
}

fn repo_state_snapshot() -> types.RepoStateSnapshot {
  types.RepoStateSnapshot(
    captured_at: "2026-04-13T17:30:00Z",
    digest: "digest",
    open_pull_requests: [
      types.RepoPullRequestSnapshot(
        number: 12,
        title: "Root rewrite",
        url: "https://example.test/pr/12",
        head_ref_name: "night-shift/root",
        base_ref_name: "main",
        review_decision: "REVIEW_REQUIRED",
        failing_checks: [],
        review_comments: ["Please rewrite the root document."],
        actionable: True,
        impacted: True,
      ),
      types.RepoPullRequestSnapshot(
        number: 13,
        title: "Descendant links",
        url: "https://example.test/pr/13",
        head_ref_name: "night-shift/child",
        base_ref_name: "night-shift/root",
        review_decision: "",
        failing_checks: [],
        review_comments: [],
        actionable: False,
        impacted: True,
      ),
    ],
  )
}
