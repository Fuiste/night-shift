import filepath
import gleam/list
import gleam/option.{None}
import night_shift/git
import night_shift/journal
import night_shift/system
import night_shift/types
import night_shift/usecase/resume
import night_shift_test_support as support
import simplifile

pub fn resume_keeps_clean_interrupted_worktree_requeueable_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "resume-clean-worktree-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let brief_path = filepath.join(base_dir, "brief.md")
  let worktree_path = filepath.join(base_dir, "task-worktree")
  let git_log = filepath.join(base_dir, "worktree-add.log")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  support.seed_git_repo(repo_root, base_dir)
  let assert Ok(_) = simplifile.write("# Brief\n", to: brief_path)
  let assert Ok(_) =
    git.create_worktree(
      repo_root,
      worktree_path,
      "night-shift/resume-clean-task",
      "main",
      git_log,
    )
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 1)
  let running_task =
    types.Task(
      id: "resume-clean-task",
      title: "Resume clean task",
      description: "Verify resume leaves a clean worktree resumable.",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      superseded_pr_numbers: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Running,
      worktree_path: worktree_path,
      branch_name: "night-shift/resume-clean-task",
      pr_number: "",
      summary: "",
      runtime_context: None,
    )
  let interrupted_run = types.RunRecord(..run, tasks: [running_task])
  let assert Ok(_) = journal.rewrite_run(interrupted_run)

  let assert Ok(resumed) = resume.prepare_resumed_run(interrupted_run)
  let assert [task] = resumed.tasks

  assert task.state == types.Ready
  assert task.summary == ""
  assert git.changed_files(worktree_path, filepath.join(base_dir, "status.log"))
    == []
  let assert Error(_) =
    simplifile.read(filepath.join(worktree_path, ".night-shift-recover.log"))

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn resume_marks_dirty_interrupted_worktree_manual_attention_with_truthful_event_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "resume-dirty-worktree-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  support.seed_git_repo(repo_root, base_dir)
  let assert Ok(_) = simplifile.write("# Brief\n", to: brief_path)
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(_) =
    simplifile.write("dirty\n", to: filepath.join(repo_root, "DIRTY.md"))
  let running_task =
    types.Task(
      id: "resume-dirty-task",
      title: "Resume dirty task",
      description: "Verify resume reports manual attention honestly.",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      superseded_pr_numbers: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Running,
      worktree_path: repo_root,
      branch_name: "night-shift/resume-dirty-task",
      pr_number: "",
      summary: "",
      runtime_context: None,
    )
  let interrupted_run = types.RunRecord(..run, tasks: [running_task])
  let assert Ok(_) = journal.rewrite_run(interrupted_run)

  let assert Ok(resumed) = resume.prepare_resumed_run(interrupted_run)
  let assert [task] = resumed.tasks
  let assert Ok(#(_loaded_run, events)) =
    journal.load(repo_root, types.RunId(run.run_id))
  let assert [latest_event, ..] = list.reverse(events)

  assert task.state == types.ManualAttention
  assert task.summary == "Interrupted run left changes in the worktree."
  assert latest_event.kind == "task_progress"
  assert latest_event.message
    == "Recovery marked 1 interrupted task for manual attention; no tasks were requeued."

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn resume_does_not_append_recovery_event_without_running_tasks_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "resume-no-running-tasks-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  support.seed_git_repo(repo_root, base_dir)
  let assert Ok(_) = simplifile.write("# Brief\n", to: brief_path)
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 1)
  let manual_attention_task =
    types.Task(
      id: "resume-manual-attention-task",
      title: "Resume manual attention task",
      description: "Verify repeated resume does not fake new recovery work.",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      superseded_pr_numbers: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.ManualAttention,
      worktree_path: repo_root,
      branch_name: "night-shift/resume-manual-attention-task",
      pr_number: "",
      summary: "Interrupted run left changes in the worktree.",
      runtime_context: None,
    )
  let blocked_run =
    types.RunRecord(..run, status: types.RunBlocked, tasks: [
      manual_attention_task,
    ])
  let assert Ok(_) = journal.rewrite_run(blocked_run)
  let assert Ok(#(_before_run, before_events)) =
    journal.load(repo_root, types.RunId(run.run_id))

  let assert Ok(resumed) = resume.prepare_resumed_run(blocked_run)
  let assert Ok(#(_after_run, after_events)) =
    journal.load(repo_root, types.RunId(run.run_id))

  assert resumed.tasks == blocked_run.tasks
  assert list.length(after_events) == list.length(before_events)

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}
