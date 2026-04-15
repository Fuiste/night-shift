import filepath
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import night_shift/dashboard
import night_shift/domain/confidence
import night_shift/domain/provenance as provenance_domain
import night_shift/domain/repo_state
import night_shift/git
import night_shift/journal
import night_shift/repo_state_runtime
import night_shift/report
import night_shift/shell
import night_shift/system
import night_shift/types
import night_shift/usecase/doctor
import night_shift/usecase/status as status_usecase
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
  assert string.contains(
    does: rendered,
    contain: "Provenance: /tmp/repo/.night-shift/runs/review-run/provenance.json",
  )
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

pub fn status_summary_calls_out_setup_recovery_and_replacements_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-status-setup-recovery-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  support.seed_git_repo(repo_root, base_dir)
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 1)
  let blocked_run =
    types.RunRecord(
      ..run,
      status: types.RunBlocked,
      planning_provenance: Some(types.ReviewsOnly),
      recovery_blocker: Some(types.RecoveryBlocker(
        kind: types.EnvironmentPreflightBlocker,
        phase: types.PreflightPhase,
        task_id: None,
        message: "missing-tool setup",
        log_path: filepath.join(run.run_path, "logs/environment-preflight.log"),
        no_changes_produced: True,
        disposition: types.RecoveryBlocking,
      )),
      tasks: [
        types.Task(
          ..list.first(run.tasks)
          |> result.unwrap(or: types.Task(
            id: "review-fix",
            title: "Review fix",
            description: "",
            dependencies: [],
            acceptance: [],
            demo_plan: [],
            decision_requests: [],
            superseded_pr_numbers: [36, 37],
            kind: types.ImplementationTask,
            execution_mode: types.Serial,
            state: types.Queued,
            worktree_path: "",
            branch_name: "",
            pr_number: "",
            summary: "",
            runtime_context: None,
          )),
          superseded_pr_numbers: [36, 37],
        ),
      ],
    )
  let assert Ok(_) = journal.rewrite_run(blocked_run)
  let assert Ok(status_result) =
    status_usecase.execute(repo_root, types.LatestRun, types.default_config())

  assert status_result.confidence.posture == types.ConfidenceLow
  assert string.contains(
    does: status_result.summary,
    contain: "Blocked before implementation: yes",
  )
  assert string.contains(
    does: status_result.summary,
    contain: "Existing reviewed PRs remain unchanged until replacement delivery succeeds.",
  )
  assert string.contains(
    does: status_result.summary,
    contain: "Next action: night-shift resolve",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn confidence_is_low_for_interrupted_implementation_manual_attention_test() {
  let missing_worktree =
    filepath.join(review_run().repo_root, "missing-blocked-impl")
  let blocked_run =
    types.RunRecord(..review_run(), status: types.RunBlocked, tasks: [
      types.Task(
        id: "blocked-impl",
        title: "Blocked implementation task",
        description: "Needs manual recovery after an interrupted run.",
        dependencies: [],
        acceptance: [],
        demo_plan: [],
        decision_requests: [],
        superseded_pr_numbers: [],
        kind: types.ImplementationTask,
        execution_mode: types.Serial,
        state: types.ManualAttention,
        worktree_path: missing_worktree,
        branch_name: "",
        pr_number: "",
        summary: "Interrupted run left changes in the worktree.",
        runtime_context: None,
      ),
    ])
  let assessment = confidence.assess(blocked_run, [], None)

  assert assessment.posture == types.ConfidenceLow
  assert string.contains(
    does: confidence.reasons_summary(assessment),
    contain: "manual recovery",
  )
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
    types.RunRecord(..run, tasks: [
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
        runtime_context: None,
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
        runtime_context: None,
      ),
    ])
  let assert Ok(_) = journal.rewrite_run(updated_run)
  let assert Ok(rendered) =
    doctor.execute(repo_root, types.LatestRun, types.default_config())

  assert string.contains(
    does: rendered,
    contain: "[manual_attention] Dirty task",
  )
  assert string.contains(
    does: rendered,
    contain: "[irrecoverable] Missing task",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn doctor_recommends_inspection_for_interrupted_implementation_manual_attention_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-doctor-interrupted-impl-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  support.seed_git_repo(repo_root, base_dir)
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 1)
  let blocked_run =
    types.RunRecord(..run, status: types.RunBlocked, tasks: [
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
        state: types.ManualAttention,
        worktree_path: repo_root,
        branch_name: "night-shift/dirty-task",
        pr_number: "",
        summary: "Interrupted run left changes in the worktree.",
        runtime_context: None,
      ),
    ])
  let assert Ok(_) = journal.rewrite_run(blocked_run)
  let assert Ok(rendered) =
    doctor.execute(repo_root, types.LatestRun, types.default_config())

  assert string.contains(
    does: rendered,
    contain: "Inspect the report and retained worktree for the interrupted implementation task",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn doctor_recommends_resolve_for_blocked_before_implementation_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-doctor-setup-recovery-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  support.seed_git_repo(repo_root, base_dir)
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 1)
  let blocked_run =
    types.RunRecord(
      ..run,
      status: types.RunBlocked,
      recovery_blocker: Some(types.RecoveryBlocker(
        kind: types.TaskSetupBlocker,
        phase: types.SetupPhase,
        task_id: Some("demo-task"),
        message: "Worktree setup phase failed while running `missing-tool install`.",
        log_path: filepath.join(run.run_path, "logs/demo-task.env.log"),
        no_changes_produced: True,
        disposition: types.RecoveryBlocking,
      )),
    )
  let assert Ok(_) = journal.rewrite_run(blocked_run)
  let assert Ok(rendered) =
    doctor.execute(repo_root, types.LatestRun, types.default_config())

  assert string.contains(
    does: rendered,
    contain: "Inspect the blocked-before-implementation setup gate first:",
  )
  assert string.contains(
    does: rendered,
    contain: "use `night-shift resolve` to inspect, continue, or abandon the run.",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn doctor_does_not_write_probe_log_into_worktree_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-doctor-clean-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let brief_path = filepath.join(base_dir, "brief.md")
  let worktree_path = filepath.join(base_dir, "clean-worktree")
  let probe_path = filepath.join(worktree_path, ".night-shift-doctor.log")
  let git_log = filepath.join(base_dir, "worktree-add.log")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  support.seed_git_repo(repo_root, base_dir)
  let assert Ok(_) =
    git.create_worktree(
      repo_root,
      worktree_path,
      "night-shift/clean-task",
      "main",
      git_log,
    )
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 1)
  let updated_run =
    types.RunRecord(..run, tasks: [
      types.Task(
        id: "clean-task",
        title: "Clean task",
        description: "",
        dependencies: [],
        acceptance: [],
        demo_plan: [],
        decision_requests: [],
        superseded_pr_numbers: [],
        kind: types.ImplementationTask,
        execution_mode: types.Serial,
        state: types.Running,
        worktree_path: worktree_path,
        branch_name: "night-shift/clean-task",
        pr_number: "",
        summary: "",
        runtime_context: None,
      ),
    ])
  let assert Ok(_) = journal.rewrite_run(updated_run)
  let assert Ok(rendered) =
    doctor.execute(repo_root, types.LatestRun, types.default_config())

  assert string.contains(
    does: rendered,
    contain: "[resume_with_warning] Clean task",
  )
  let assert Error(_) = simplifile.read(probe_path)

  let _ =
    shell.run(
      "git worktree remove --force " <> shell.quote(worktree_path),
      repo_root,
      filepath.join(base_dir, "worktree-remove.log"),
    )
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
    recovery_blocker: None,
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
        runtime_context: None,
      ),
    ],
    handoff_states: [],
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
