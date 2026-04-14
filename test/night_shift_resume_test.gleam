import filepath
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
