import filepath
import gleam/option.{None, Some}
import gleam/string
import night_shift/dashboard
import night_shift/domain/provenance as provenance_domain
import night_shift/domain/repo_state
import night_shift/journal
import night_shift/report
import night_shift/repo_state_runtime
import night_shift/system
import night_shift/types
import night_shift/usecase/doctor
import night_shift_test_support as support
import simplifile

pub fn persisted_run_writes_provenance_artifact_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-provenance-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(provenance_contents) =
    simplifile.read(filepath.join(run.run_path, "provenance.json"))

  assert string.contains(does: provenance_contents, contain: "\"run_id\"")
  assert string.contains(
    does: provenance_contents,
    contain: "\"provenance_path\":\""
      <> filepath.join(run.run_path, "provenance.json")
      <> "\"",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn report_includes_confidence_and_provenance_test() {
  let rendered = report.render_live(review_run(), [], Some(review_state_view()))

  assert string.contains(does: rendered, contain: "Confidence posture:")
  assert string.contains(does: rendered, contain: "Confidence reasons:")
  assert string.contains(does: rendered, contain: "Provenance: /tmp/repo/.night-shift/runs/review-run/provenance.json")
}

pub fn provenance_render_includes_review_drift_test() {
  let assert Ok(rendered) =
    provenance_domain.render(
      review_run(),
      [],
      Some(review_state_view()),
      None,
      types.ProvenanceJson,
      [],
    )

  assert string.contains(does: rendered, contain: "\"review_state\"")
  assert string.contains(does: rendered, contain: "\"drift\":\"yes\"")
  assert string.contains(
    does: rendered,
    contain: "\"superseded_pr_numbers\":[12]",
  )
}

pub fn dashboard_payload_includes_confidence_and_provenance_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-dashboard-trust-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(updated_run) =
    journal.append_event(
      run,
      types.RunEvent(
        kind: "execution_payload_warning",
        at: system.timestamp(),
        message: "Accepted a recovered execution payload.",
        task_id: Some("demo-task"),
      ),
    )
  let assert Ok(run_payload) = dashboard.run_json(repo_root, updated_run.run_id)

  assert string.contains(does: run_payload, contain: "\"confidence_posture\"")
  assert string.contains(does: run_payload, contain: "\"provenance_path\"")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn doctor_flags_dirty_and_missing_worktrees_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-doctor-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let brief_path = filepath.join(base_dir, "brief.md")
  let missing_worktree = filepath.join(base_dir, "missing-worktree")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  support.seed_git_repo(repo_root, base_dir)
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(_) =
    simplifile.write("dirty\n", to: filepath.join(repo_root, "DIRTY.md"))
  let updated_run =
    types.RunRecord(
      ..run,
      tasks: [
        types.Task(
          id: "dirty-task",
          title: "Dirty task",
          description: "",
          dependencies: [],
          acceptance: [],
          demo_plan: [],
          decision_requests: [],
          superseded_pr_numbers: [],
          kind: types.ImplementationTask,
          execution_mode: types.Serial,
          state: types.Running,
          worktree_path: repo_root,
          branch_name: "night-shift/dirty-task",
          pr_number: "",
          summary: "",
        ),
        types.Task(
          id: "missing-task",
          title: "Missing task",
          description: "",
          dependencies: [],
          acceptance: [],
          demo_plan: [],
          decision_requests: [],
          superseded_pr_numbers: [],
          kind: types.ImplementationTask,
          execution_mode: types.Serial,
          state: types.Running,
          worktree_path: missing_worktree,
          branch_name: "night-shift/missing-task",
          pr_number: "",
          summary: "",
        ),
      ],
    )
  let assert Ok(_) = journal.rewrite_run(updated_run)
  let assert Ok(rendered) =
    doctor.execute(repo_root, types.LatestRun, types.default_config())

  assert string.contains(does: rendered, contain: "[manual_attention] Dirty task")
  assert string.contains(does: rendered, contain: "[irrecoverable] Missing task")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
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
      types.Task(
        id: "rewrite-root",
        title: "rewrite-root",
        description: "",
        dependencies: [],
        acceptance: [],
        demo_plan: [],
        decision_requests: [],
        superseded_pr_numbers: [12],
        kind: types.ImplementationTask,
        execution_mode: types.Serial,
        state: types.Completed,
        worktree_path: "/tmp/repo/.night-shift/runs/review-run/worktrees/rewrite-root",
        branch_name: "night-shift/rewrite-root",
        pr_number: "15",
        summary: "Updated rewrite-root",
      ),
    ],
  )
}

fn repo_state_snapshot() -> repo_state.RepoStateSnapshot {
  repo_state.RepoStateSnapshot(
    captured_at: "2026-04-13T17:30:00Z",
    digest: "digest",
    open_pull_requests: [
      repo_state.RepoPullRequestSnapshot(
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
    ],
  )
}

fn review_state_view() -> repo_state_runtime.RepoStateView {
  repo_state_runtime.RepoStateView(
    snapshot_captured_at: "2026-04-13T17:30:00Z",
    open_pr_count: 2,
    actionable_pr_count: 1,
    drift: repo_state_runtime.RepoStateDrifted,
  )
}
