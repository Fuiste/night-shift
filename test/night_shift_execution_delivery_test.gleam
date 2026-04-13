import filepath
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import night_shift/github
import night_shift/journal
import night_shift/orchestrator
import night_shift/project
import night_shift/provider
import night_shift/shell
import night_shift/system
import night_shift/types
import night_shift/worktree_setup
import night_shift_test_support as support
import simplifile

pub fn repo_state_path_is_stable_test() {
  let repo_root = "/tmp/night-shift-demo"
  assert journal.repo_state_path_for(repo_root)
    == journal.repo_state_path_for(repo_root)
}

pub fn github_open_or_update_pr_uses_create_output_when_listing_lags_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-gh-create-output-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let run_path = filepath.join(base_dir, "run")
  let bin_dir = filepath.join(base_dir, "bin")
  let fake_gh = filepath.join(bin_dir, "gh")
  let old_path = system.get_env("PATH")
  let old_gh_bin = system.get_env("NIGHT_SHIFT_GH_BIN")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) =
    simplifile.create_directory_all(filepath.join(run_path, "logs"))
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_delayed_listing_fake_gh(fake_gh)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_gh),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )

  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("NIGHT_SHIFT_GH_BIN", fake_gh)

  let result =
    github.open_or_update_pr(
      repo_root,
      "night-shift/demo-branch",
      "main",
      "Demo PR",
      "Body",
      run_path,
      filepath.join(run_path, "logs/gh.log"),
    )

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_GH_BIN", old_gh_bin)

  let assert Ok(pr) = result
  assert pr.number == 42
  assert pr.url == "https://example.test/pr/42"
  assert pr.head_ref_name == "night-shift/demo-branch"
  assert pr.title == "Demo PR"

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_runs_fake_provider_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-integration-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let remote_root = filepath.join(base_dir, "remote.git")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let fake_gh = filepath.join(bin_dir, "gh")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_gh_bin = system.get_env("NIGHT_SHIFT_GH_BIN")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = support.write_fake_provider(fake_provider)
  let assert Ok(_) = support.write_fake_gh(fake_gh)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider) <> " " <> shell.quote(fake_gh),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let _ =
    shell.run(
      "git init --bare " <> shell.quote(remote_root),
      base_dir,
      filepath.join(base_dir, "remote.log"),
    )
  let _ =
    shell.run(
      "git init --initial-branch=main " <> shell.quote(repo_root),
      base_dir,
      filepath.join(base_dir, "repo-init.log"),
    )
  let _ =
    shell.run(
      "git config user.name 'Night Shift Test'",
      repo_root,
      filepath.join(base_dir, "git-user.log"),
    )
  let _ =
    shell.run(
      "git config user.email 'night-shift@example.com'",
      repo_root,
      filepath.join(base_dir, "git-email.log"),
    )
  let assert Ok(_) =
    simplifile.write("# Demo\n", to: filepath.join(repo_root, "README.md"))
  let _ =
    shell.run(
      "git add README.md && git commit -m 'chore: seed repo'",
      repo_root,
      filepath.join(base_dir, "seed.log"),
    )
  let _ =
    shell.run(
      "git remote add origin " <> shell.quote(remote_root),
      repo_root,
      filepath.join(base_dir, "remote-add.log"),
    )
  let _ =
    shell.run(
      "git push -u origin main",
      repo_root,
      filepath.join(base_dir, "push-main.log"),
    )

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("NIGHT_SHIFT_GH_BIN", fake_gh)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) =
    support.planned_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(completed_run) = orchestrator.start(run, config)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_GH_BIN", old_gh_bin)
  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let completed_task =
    completed_run.tasks
    |> list.find(fn(task) { task.state == types.Completed })
    |> result.unwrap(or: types.Task(
      id: "missing",
      title: "missing",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Failed,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    ))

  assert completed_run.status == types.RunCompleted
  assert completed_task.pr_number == "1"
  assert string.contains(does: completed_task.summary, contain: "Implemented")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_preserves_partial_success_after_delivery_failure_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-partial-delivery-failure-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let remote_root = filepath.join(base_dir, "remote.git")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let fake_gh = filepath.join(bin_dir, "gh")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_gh_bin = system.get_env("NIGHT_SHIFT_GH_BIN")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = support.write_partial_delivery_fake_provider(fake_provider)
  let assert Ok(_) = support.write_branch_sensitive_fake_gh(fake_gh)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider) <> " " <> shell.quote(fake_gh),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let _ =
    shell.run(
      "git init --bare " <> shell.quote(remote_root),
      base_dir,
      filepath.join(base_dir, "remote.log"),
    )
  support.seed_git_repo(repo_root, base_dir)
  let _ =
    shell.run(
      "git remote add origin " <> shell.quote(remote_root),
      repo_root,
      filepath.join(base_dir, "remote-add.log"),
    )
  let _ =
    shell.run(
      "git push -u origin main",
      repo_root,
      filepath.join(base_dir, "push-main.log"),
    )

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("NIGHT_SHIFT_GH_BIN", fake_gh)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 2,
    )

  let assert Ok(run) =
    support.planned_run(repo_root, brief_path, types.Codex, 2)
  let assert Ok(failed_run) = orchestrator.start(run, config)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_GH_BIN", old_gh_bin)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let alpha_task =
    failed_run.tasks
    |> list.find(fn(task) { task.id == "alpha-task" })
    |> result.unwrap(or: types.Task(
      id: "",
      title: "",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Queued,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    ))
  let beta_task =
    failed_run.tasks
    |> list.find(fn(task) { task.id == "beta-task" })
    |> result.unwrap(or: types.Task(
      id: "",
      title: "",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Queued,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    ))
  let assert Ok(report_contents) = simplifile.read(failed_run.report_path)
  let assert Ok(events) = simplifile.read(failed_run.events_path)

  assert failed_run.status == types.RunFailed
  assert alpha_task.state == types.Completed
  assert alpha_task.pr_number == "1"
  assert beta_task.state == types.Failed
  assert string.contains(
    does: beta_task.summary,
    contain: "Primary blocker: GitHub PR delivery failed.",
  )
  assert string.contains(does: report_contents, contain: "- Completed tasks: 1")
  assert string.contains(does: report_contents, contain: "- Opened PRs: 1")
  assert string.contains(does: report_contents, contain: "- Failed tasks: 1")
  assert string.contains(
    does: report_contents,
    contain: "- Type: partial success",
  )
  assert string.contains(does: events, contain: "\"kind\":\"pr_opened\"")
  let assert Error(_) = simplifile.read(project.active_lock_path(repo_root))

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_delivers_provider_created_commit_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-provider-commit-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let remote_root = filepath.join(base_dir, "remote.git")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let fake_gh = filepath.join(bin_dir, "gh")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_gh_bin = system.get_env("NIGHT_SHIFT_GH_BIN")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = support.write_committing_fake_provider(fake_provider)
  let assert Ok(_) = support.write_fake_gh(fake_gh)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider) <> " " <> shell.quote(fake_gh),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let _ =
    shell.run(
      "git init --bare " <> shell.quote(remote_root),
      base_dir,
      filepath.join(base_dir, "remote.log"),
    )
  let _ =
    shell.run(
      "git init --initial-branch=main " <> shell.quote(repo_root),
      base_dir,
      filepath.join(base_dir, "repo-init.log"),
    )
  let _ =
    shell.run(
      "git config user.name 'Night Shift Test'",
      repo_root,
      filepath.join(base_dir, "git-user.log"),
    )
  let _ =
    shell.run(
      "git config user.email 'night-shift@example.com'",
      repo_root,
      filepath.join(base_dir, "git-email.log"),
    )
  let assert Ok(_) =
    simplifile.write("# Demo\n", to: filepath.join(repo_root, "README.md"))
  let _ =
    shell.run(
      "git add README.md && git commit -m 'chore: seed repo'",
      repo_root,
      filepath.join(base_dir, "seed.log"),
    )
  let _ =
    shell.run(
      "git remote add origin " <> shell.quote(remote_root),
      repo_root,
      filepath.join(base_dir, "remote-add.log"),
    )
  let _ =
    shell.run(
      "git push -u origin main",
      repo_root,
      filepath.join(base_dir, "push-main.log"),
    )

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("NIGHT_SHIFT_GH_BIN", fake_gh)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) =
    support.planned_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(completed_run) = orchestrator.start(run, config)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_GH_BIN", old_gh_bin)
  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let completed_task =
    completed_run.tasks
    |> list.find(fn(task) { task.state == types.Completed })
    |> result.unwrap(or: types.Task(
      id: "missing",
      title: "missing",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Failed,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    ))

  assert completed_run.status == types.RunCompleted
  assert completed_task.pr_number == "1"
  assert string.contains(
    does: completed_task.summary,
    contain: "IMPLEMENTED.md",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn start_task_runs_codex_execution_in_worktree_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-codex-worktree-" <> unique,
    ))
  let bin_dir = filepath.join(base_dir, "bin")
  let fake_codex = filepath.join(bin_dir, "codex")
  let run_path = filepath.join(base_dir, "run")
  let worktree_path = filepath.join(base_dir, "worktree")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) =
    simplifile.create_directory_all(filepath.join(run_path, "logs"))
  let assert Ok(_) = simplifile.create_directory_all(worktree_path)
  let assert Ok(_) = support.write_worktree_execution_codex(fake_codex)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_codex),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )

  system.unset_env("NIGHT_SHIFT_FAKE_PROVIDER")
  system.set_env("PATH", bin_dir <> ":" <> old_path)

  let task =
    types.Task(
      id: "demo-task",
      title: "Demo task",
      description: "Create a proof file in the task worktree.",
      dependencies: [],
      acceptance: ["Create EXECUTED.txt in the task worktree."],
      demo_plan: ["Show EXECUTED.txt."],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Ready,
      worktree_path: worktree_path,
      branch_name: "night-shift/demo",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    )

  let assert Ok(task_run) =
    provider.start_task(
      types.resolved_agent_from_provider(types.Codex),
      base_dir,
      run_path,
      task,
      worktree_path,
      [],
      "seed-head",
      "night-shift/demo",
      "main",
      provider.CreatedWorktree,
    )
  let assert Ok(result) = provider.await_task(task_run)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)

  let assert Ok(contents) =
    simplifile.read(filepath.join(worktree_path, "EXECUTED.txt"))
  assert result.status == types.Completed
  assert string.contains(does: contents, contain: "executed in worktree")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn provider_await_task_recovers_trailing_junk_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-provider-recover-" <> unique,
    ))
  let run_path = filepath.join(base_dir, "run")
  let worktree_path = filepath.join(base_dir, "worktree")
  let bin_dir = filepath.join(base_dir, "bin")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) =
    simplifile.create_directory_all(filepath.join(run_path, "logs"))
  let assert Ok(_) = simplifile.create_directory_all(worktree_path)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) =
    support.write_recoverable_execution_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)

  let task =
    types.Task(
      id: "demo-task",
      title: "Recoverable provider output",
      description: "Return a result with trailing junk that Night Shift should sanitize.",
      dependencies: [],
      acceptance: ["Return a completed execution result."],
      demo_plan: ["Recover the sanitized payload."],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Ready,
      worktree_path: worktree_path,
      branch_name: "night-shift/demo",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    )

  let assert Ok(task_run) =
    provider.start_task(
      types.resolved_agent_from_provider(types.Codex),
      base_dir,
      run_path,
      task,
      worktree_path,
      [],
      "seed-head",
      "night-shift/demo",
      "main",
      provider.CreatedWorktree,
    )
  let assert Ok(result) = provider.await_task(task_run)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)

  let assert Ok(raw_payload) =
    simplifile.read(filepath.join(run_path, "logs/demo-task.result.raw.jsonish"))
  let assert Ok(sanitized_payload) =
    simplifile.read(filepath.join(
      run_path,
      "logs/demo-task.result.sanitized.json",
    ))

  assert result.status == types.Completed
  assert string.contains(does: raw_payload, contain: "\"follow_up_tasks\":[]}}")
  assert string.contains(
    does: sanitized_payload,
    contain: "\"follow_up_tasks\":[]}",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn provider_await_task_normalizes_absolute_files_touched_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-provider-absolute-paths-" <> unique,
    ))
  let run_path = filepath.join(base_dir, "run")
  let worktree_path = filepath.join(base_dir, "worktree")
  let bin_dir = filepath.join(base_dir, "bin")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) =
    simplifile.create_directory_all(filepath.join(run_path, "logs"))
  let assert Ok(_) = simplifile.create_directory_all(worktree_path)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) =
    support.write_absolute_files_touched_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)

  let task =
    types.Task(
      id: "demo-task",
      title: "Absolute path payload",
      description: "Return absolute files_touched entries inside the task worktree.",
      dependencies: [],
      acceptance: ["Normalize files_touched back to repo-relative paths."],
      demo_plan: ["Return EXECUTED.txt as a touched file."],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Ready,
      worktree_path: worktree_path,
      branch_name: "night-shift/demo",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    )

  let assert Ok(task_run) =
    provider.start_task(
      types.resolved_agent_from_provider(types.Codex),
      base_dir,
      run_path,
      task,
      worktree_path,
      [],
      "seed-head",
      "night-shift/demo",
      "main",
      provider.CreatedWorktree,
    )
  let assert Ok(awaited) = provider.await_task_detailed(task_run)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)

  assert awaited.execution_result.status == types.Completed
  assert awaited.execution_result.files_touched == ["EXECUTED.txt"]

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn provider_await_task_rejects_absolute_paths_outside_worktree_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-provider-outside-paths-" <> unique,
    ))
  let run_path = filepath.join(base_dir, "run")
  let worktree_path = filepath.join(base_dir, "worktree")
  let bin_dir = filepath.join(base_dir, "bin")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) =
    simplifile.create_directory_all(filepath.join(run_path, "logs"))
  let assert Ok(_) = simplifile.create_directory_all(worktree_path)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) =
    support.write_outside_files_touched_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)

  let task =
    types.Task(
      id: "demo-task",
      title: "Outside path payload",
      description: "Return absolute files_touched entries outside the task worktree.",
      dependencies: [],
      acceptance: ["Reject unsafe files_touched entries."],
      demo_plan: ["Reject /tmp/outside.txt."],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Ready,
      worktree_path: worktree_path,
      branch_name: "night-shift/demo",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    )

  let assert Ok(task_run) =
    provider.start_task(
      types.resolved_agent_from_provider(types.Codex),
      base_dir,
      run_path,
      task,
      worktree_path,
      [],
      "seed-head",
      "night-shift/demo",
      "main",
      provider.CreatedWorktree,
    )
  let assert Error(provider.PayloadDecodeFailed(message, _)) =
    provider.await_task_detailed(task_run)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)

  assert string.contains(does: message, contain: "outside the task worktree")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn provider_payload_repair_accepts_valid_repair_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-provider-payload-repair-" <> unique,
    ))
  let run_path = filepath.join(base_dir, "run")
  let worktree_path = filepath.join(base_dir, "worktree")
  let bin_dir = filepath.join(base_dir, "bin")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) =
    simplifile.create_directory_all(filepath.join(run_path, "logs"))
  let assert Ok(_) = simplifile.create_directory_all(worktree_path)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) =
    support.write_payload_repair_success_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)

  let task =
    types.Task(
      id: "demo-task",
      title: "Payload repair payload",
      description: "Return malformed JSON, then repair it without changing files again.",
      dependencies: [],
      acceptance: ["Create REPAIRED.md."],
      demo_plan: ["Show REPAIRED.md."],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Ready,
      worktree_path: worktree_path,
      branch_name: "night-shift/demo",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    )

  let assert Ok(task_run) =
    provider.start_task(
      types.resolved_agent_from_provider(types.Codex),
      base_dir,
      run_path,
      task,
      worktree_path,
      [],
      "seed-head",
      "night-shift/demo",
      "main",
      provider.CreatedWorktree,
    )
  let assert Error(provider.PayloadDecodeFailed(message, _)) =
    provider.await_task_detailed(task_run)
  let assert Ok(repaired) =
    provider.repair_execution_payload(
      types.resolved_agent_from_provider(types.Codex),
      base_dir,
      worktree_path,
      [],
      run_path,
      task,
      message,
    )

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)

  let assert Ok(raw_payload) =
    simplifile.read(filepath.join(
      run_path,
      "logs/demo-task.payload-repair.result.raw.jsonish",
    ))

  assert repaired.execution_result.status == types.Completed
  assert repaired.execution_result.files_touched == ["REPAIRED.md"]
  assert provider.execution_trust_warning(repaired, task.id) == None
  assert string.contains(
    does: raw_payload,
    contain: "\"summary\":\"Payload repaired successfully\"",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn provider_payload_repair_accepts_recoverable_repair_with_warning_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-provider-payload-repair-warning-" <> unique,
    ))
  let run_path = filepath.join(base_dir, "run")
  let worktree_path = filepath.join(base_dir, "worktree")
  let bin_dir = filepath.join(base_dir, "bin")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) =
    simplifile.create_directory_all(filepath.join(run_path, "logs"))
  let assert Ok(_) = simplifile.create_directory_all(worktree_path)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) =
    support.write_payload_repair_warning_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)

  let task =
    types.Task(
      id: "demo-task",
      title: "Payload repair warning payload",
      description: "Return trailing junk during payload repair.",
      dependencies: [],
      acceptance: ["Create REPAIRED.md."],
      demo_plan: ["Show REPAIRED.md."],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Ready,
      worktree_path: worktree_path,
      branch_name: "night-shift/demo",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    )

  let assert Ok(task_run) =
    provider.start_task(
      types.resolved_agent_from_provider(types.Codex),
      base_dir,
      run_path,
      task,
      worktree_path,
      [],
      "seed-head",
      "night-shift/demo",
      "main",
      provider.CreatedWorktree,
    )
  let assert Error(provider.PayloadDecodeFailed(message, _)) =
    provider.await_task_detailed(task_run)
  let assert Ok(repaired) =
    provider.repair_execution_payload(
      types.resolved_agent_from_provider(types.Codex),
      base_dir,
      worktree_path,
      [],
      run_path,
      task,
      message,
    )

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)

  let assert Some(warning) = provider.execution_trust_warning(repaired, task.id)
  let assert Ok(sanitized_payload) =
    simplifile.read(filepath.join(
      run_path,
      "logs/demo-task.payload-repair.result.sanitized.json",
    ))

  assert repaired.execution_result.status == types.Completed
  assert string.contains(does: warning, contain: "recovered")
  assert string.contains(
    does: sanitized_payload,
    contain: "\"summary\":\"Payload repaired with trailing junk\"",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn provider_payload_repair_rejects_unsafe_paths_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-provider-payload-repair-unsafe-" <> unique,
    ))
  let run_path = filepath.join(base_dir, "run")
  let worktree_path = filepath.join(base_dir, "worktree")
  let bin_dir = filepath.join(base_dir, "bin")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) =
    simplifile.create_directory_all(filepath.join(run_path, "logs"))
  let assert Ok(_) = simplifile.create_directory_all(worktree_path)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) =
    support.write_payload_repair_unsafe_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)

  let task =
    types.Task(
      id: "demo-task",
      title: "Unsafe payload repair payload",
      description: "Return an unsafe files_touched entry during payload repair.",
      dependencies: [],
      acceptance: ["Reject unsafe repaired paths."],
      demo_plan: ["Reject /tmp/outside.txt."],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Ready,
      worktree_path: worktree_path,
      branch_name: "night-shift/demo",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    )

  let assert Ok(task_run) =
    provider.start_task(
      types.resolved_agent_from_provider(types.Codex),
      base_dir,
      run_path,
      task,
      worktree_path,
      [],
      "seed-head",
      "night-shift/demo",
      "main",
      provider.CreatedWorktree,
    )
  let assert Error(provider.PayloadDecodeFailed(message, _)) =
    provider.await_task_detailed(task_run)
  let assert Error(provider.PayloadRepairFailure(failure, artifacts)) =
    provider.repair_execution_payload(
      types.resolved_agent_from_provider(types.Codex),
      base_dir,
      worktree_path,
      [],
      run_path,
      task,
      message,
    )

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)

  assert string.contains(does: failure, contain: "outside the task worktree")
  assert artifacts.raw_payload_path
    == Some(filepath.join(
      run_path,
      "logs/demo-task.payload-repair.result.raw.jsonish",
    ))

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_accepts_recovered_execution_payload_with_warning_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-recovered-execution-warning-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let remote_root = filepath.join(base_dir, "remote.git")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let fake_gh = filepath.join(bin_dir, "gh")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_gh_bin = system.get_env("NIGHT_SHIFT_GH_BIN")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) =
    support.write_recoverable_delivery_fake_provider(fake_provider)
  let assert Ok(_) = support.write_fake_gh(fake_gh)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider) <> " " <> shell.quote(fake_gh),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let _ =
    shell.run(
      "git init --bare " <> shell.quote(remote_root),
      base_dir,
      filepath.join(base_dir, "remote.log"),
    )
  support.seed_git_repo(repo_root, base_dir)
  let _ =
    shell.run(
      "git remote add origin " <> shell.quote(remote_root),
      repo_root,
      filepath.join(base_dir, "remote-add.log"),
    )
  let _ =
    shell.run(
      "git push -u origin main",
      repo_root,
      filepath.join(base_dir, "push-main.log"),
    )

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("NIGHT_SHIFT_GH_BIN", fake_gh)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) =
    support.planned_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(completed_run) = orchestrator.start(run, config)
  let assert Ok(report_contents) = simplifile.read(completed_run.report_path)
  let assert Ok(events_contents) = simplifile.read(completed_run.events_path)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_GH_BIN", old_gh_bin)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  assert completed_run.status == types.RunCompleted
  assert string.contains(
    does: events_contents,
    contain: "\"kind\":\"execution_payload_warning\"",
  )
  assert string.contains(
    does: report_contents,
    contain: "## Execution Recovery",
  )
  assert string.contains(
    does: report_contents,
    contain: "Accepted recovered execution payloads: 1",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_prunes_clean_superseded_worktrees_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-superseded-prune-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let fake_gh = filepath.join(bin_dir, "gh")
  let prior_brief_path = filepath.join(base_dir, "prior-brief.md")
  let current_brief_path = filepath.join(base_dir, "current-brief.md")
  let prior_worktree = filepath.join(base_dir, "prior-worktree")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_gh_bin = system.get_env("NIGHT_SHIFT_GH_BIN")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Prior brief", to: prior_brief_path)
  let assert Ok(_) = simplifile.write("# Current brief", to: current_brief_path)
  let assert Ok(_) = support.write_supersession_fake_gh(fake_gh)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_gh),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  support.seed_git_repo(repo_root, base_dir)
  let _ =
    shell.run(
      "git worktree add -b night-shift/prior "
        <> shell.quote(prior_worktree)
        <> " main",
      repo_root,
      filepath.join(base_dir, "worktree.log"),
    )

  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("NIGHT_SHIFT_GH_BIN", fake_gh)
  system.set_env("XDG_STATE_HOME", state_home)

  let assert Ok(prior_run) =
    journal.create_pending_run(
      repo_root,
      prior_brief_path,
      support.agent_for(types.Codex),
      support.agent_for(types.Codex),
      "",
      1,
      None,
    )
  let prior_completed_task =
    types.Task(
      id: "rewrite-root",
      title: "Rewrite root",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      superseded_pr_numbers: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Completed,
      worktree_path: prior_worktree,
      branch_name: "night-shift/prior",
      pr_number: "12",
      summary: "Prior completed task",
    )
  let assert Ok(_) =
    journal.rewrite_run(
      types.RunRecord(..prior_run, status: types.RunCompleted, tasks: [
        prior_completed_task,
      ]),
    )

  let assert Ok(current_run) =
    journal.create_pending_run_with_context(
      repo_root,
      current_brief_path,
      support.agent_for(types.Codex),
      support.agent_for(types.Codex),
      "",
      1,
      None,
      Some(types.ReviewsOnly),
      None,
    )
  let replacement_task =
    types.Task(
      id: "rewrite-root-v2",
      title: "Rewrite root v2",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      superseded_pr_numbers: [12],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Completed,
      worktree_path: "",
      branch_name: "night-shift/rewrite-root-v2",
      pr_number: "15",
      summary: "Replacement completed task",
    )
  let replacement_run =
    types.RunRecord(..current_run, status: types.RunActive, tasks: [
      replacement_task,
    ])

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(final_run) = orchestrator.start(replacement_run, config)
  let assert Ok(events_contents) = simplifile.read(final_run.events_path)
  let assert Ok(report_contents) = simplifile.read(final_run.report_path)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_GH_BIN", old_gh_bin)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  assert final_run.status == types.RunCompleted
  let assert Error(_) = simplifile.read_directory(at: prior_worktree)
  assert string.contains(
    does: events_contents,
    contain: "\"kind\":\"pr_superseded\"",
  )
  assert string.contains(
    does: events_contents,
    contain: "\"kind\":\"worktree_pruned\"",
  )
  assert string.contains(does: report_contents, contain: "## Worktree Hygiene")
  assert string.contains(
    does: report_contents,
    contain: "Pruned superseded worktrees: 1",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_blocks_manual_attention_before_bootstrap_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-manual-attention-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = support.write_manual_attention_fake_provider(fake_provider)
  let assert Ok(_) =
    support.write_test_worktree_setup(
      project.worktree_setup_path(repo_root),
      ["missing-tool setup"],
      ["missing-tool maintenance"],
    )
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  support.seed_git_repo(repo_root, base_dir)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) =
    support.planned_run_in_environment(
      repo_root,
      brief_path,
      types.Codex,
      "default",
      1,
    )
  let assert Ok(blocked_run) = orchestrator.start(run, config)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let blocked_task =
    blocked_run.tasks
    |> list.find(fn(task) { task.state == types.ManualAttention })
    |> result.unwrap(or: types.Task(
      id: "missing",
      title: "missing",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      kind: types.ManualAttentionTask,
      execution_mode: types.Exclusive,
      state: types.Failed,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    ))
  let assert Ok(events) = simplifile.read(blocked_run.events_path)

  assert blocked_run.status == types.RunBlocked
  assert string.contains(
    does: blocked_task.summary,
    contain: "no worktree bootstrap or provider execution started",
  )
  assert string.contains(
    does: events,
    contain: "\"kind\":\"task_manual_attention\"",
  )
  assert string.contains(does: events, contain: "\"kind\":\"task_started\"")
    == False
  assert simplifile.read(filepath.join(
      blocked_run.run_path,
      "logs/" <> blocked_task.id <> ".env.log",
    ))
    |> result.is_error

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_fails_environment_preflight_before_task_launch_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-preflight-failure-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = support.write_fake_provider(fake_provider)
  let assert Ok(_) =
    support.write_test_worktree_setup(
      project.worktree_setup_path(repo_root),
      ["missing-tool setup"],
      ["missing-tool maintenance"],
    )
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  support.seed_git_repo(repo_root, base_dir)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) =
    support.planned_run_in_environment(
      repo_root,
      brief_path,
      types.Codex,
      "default",
      1,
    )
  let assert Ok(failed_run) = orchestrator.start(run, config)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(events) = simplifile.read(failed_run.events_path)
  let preflight_log =
    filepath.join(failed_run.run_path, "logs/environment-preflight.log")
  let assert Ok(preflight_contents) = simplifile.read(preflight_log)
  let assert Ok(report_contents) = simplifile.read(failed_run.report_path)

  assert failed_run.status == types.RunFailed
  assert string.contains(
    does: events,
    contain: "\"kind\":\"environment_preflight_failed\"",
  )
  assert string.contains(does: events, contain: "\"kind\":\"task_started\"")
    == False
  assert string.contains(does: preflight_contents, contain: "missing-tool")
  assert string.contains(
    does: report_contents,
    contain: "- Run-level failures: 1",
  )
  assert string.contains(does: report_contents, contain: "## Failure")
  assert string.contains(
    does: report_contents,
    contain: "environment bootstrap",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn environment_preflight_uses_explicit_bootstrap_requirements_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-preflight-generic-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let setup_path = project.worktree_setup_path(repo_root)
  let log_path = filepath.join(base_dir, "preflight.log")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) =
    support.write_test_worktree_setup_with_preflight(
      setup_path,
      ["sh"],
      ["sh -c 'echo bootstrap >/dev/null'", "missing-tool install"],
      ["missing-tool verify"],
    )

  let result =
    worktree_setup.preflight_environment(
      repo_root,
      "default",
      setup_path,
      log_path,
    )
  let assert Ok(preflight_contents) = simplifile.read(log_path)

  let assert Ok(_) = result
  assert string.contains(
    does: preflight_contents,
    contain: "[preflight] executable=sh",
  )
  assert string.contains(does: preflight_contents, contain: "missing-tool")
    == False

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn environment_preflight_defaults_to_first_setup_executable_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-preflight-default-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let setup_path = project.worktree_setup_path(repo_root)
  let log_path = filepath.join(base_dir, "preflight.log")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) =
    support.write_test_worktree_setup(
      setup_path,
      ["sh -c 'echo bootstrap >/dev/null'", "missing-tool install"],
      ["missing-tool verify"],
    )

  let result =
    worktree_setup.preflight_environment(
      repo_root,
      "default",
      setup_path,
      log_path,
    )
  let assert Ok(preflight_contents) = simplifile.read(log_path)

  let assert Ok(_) = result
  assert string.contains(
    does: preflight_contents,
    contain: "[preflight] executable=sh",
  )
  assert string.contains(does: preflight_contents, contain: "missing-tool")
    == False

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_reports_setup_phase_failures_after_preflight_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-setup-runtime-failure-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = support.write_fake_provider(fake_provider)
  let assert Ok(_) =
    support.write_test_worktree_setup_with_preflight(
      project.worktree_setup_path(repo_root),
      ["sh"],
      ["sh -c 'echo bootstrap >/dev/null'", "missing-tool install"],
      [],
    )
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  support.seed_git_repo(repo_root, base_dir)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) =
    support.planned_run_in_environment(
      repo_root,
      brief_path,
      types.Codex,
      "default",
      1,
    )
  let assert Ok(failed_run) = orchestrator.start(run, config)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(events) = simplifile.read(failed_run.events_path)
  let env_log = filepath.join(failed_run.run_path, "logs/demo-task.env.log")
  let assert Ok(env_contents) = simplifile.read(env_log)
  let failed_task =
    failed_run.tasks
    |> list.find(fn(task) { task.id == "demo-task" })
    |> result.unwrap(or: types.Task(
      id: "",
      title: "",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Queued,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    ))

  assert failed_run.status == types.RunFailed
  assert string.contains(does: events, contain: "\"kind\":\"task_started\"")
  assert string.contains(does: events, contain: "\"kind\":\"task_failed\"")
  assert string.contains(does: env_contents, contain: "(exit 127)")
  assert string.contains(does: env_contents, contain: "$ missing-tool install")
  assert string.contains(
    does: failed_task.summary,
    contain: "Worktree setup phase failed while running `missing-tool install`",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_uses_setup_phase_for_new_worktrees_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-setup-phase-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let remote_root = filepath.join(base_dir, "remote.git")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let fake_gh = filepath.join(bin_dir, "gh")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_gh_bin = system.get_env("NIGHT_SHIFT_GH_BIN")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = support.write_fake_provider(fake_provider)
  let assert Ok(_) = support.write_fake_gh(fake_gh)
  let assert Ok(_) =
    support.write_test_worktree_setup(
      project.worktree_setup_path(repo_root),
      ["printf setup-phase >/dev/null"],
      ["printf maintenance-phase >/dev/null"],
    )
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider) <> " " <> shell.quote(fake_gh),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let _ =
    shell.run(
      "git init --bare " <> shell.quote(remote_root),
      base_dir,
      filepath.join(base_dir, "remote.log"),
    )
  support.seed_git_repo(repo_root, base_dir)
  let _ =
    shell.run(
      "git remote add origin " <> shell.quote(remote_root),
      repo_root,
      filepath.join(base_dir, "remote-add.log"),
    )
  let _ =
    shell.run(
      "git push -u origin main",
      repo_root,
      filepath.join(base_dir, "push-main.log"),
    )

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("NIGHT_SHIFT_GH_BIN", fake_gh)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) =
    support.planned_run_in_environment(
      repo_root,
      brief_path,
      types.Codex,
      "default",
      1,
    )
  let assert Ok(completed_run) = orchestrator.start(run, config)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_GH_BIN", old_gh_bin)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(env_log) =
    simplifile.read(filepath.join(
      completed_run.run_path,
      "logs/demo-task.env.log",
    ))

  assert completed_run.status == types.RunCompleted
  assert string.contains(does: env_log, contain: "phase=setup")
  assert string.contains(
    does: env_log,
    contain: "$ printf setup-phase >/dev/null",
  )
  assert string.contains(does: env_log, contain: "maintenance-phase") == False

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_marks_decode_failures_failed_and_clears_lock_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-decode-failure-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) =
    support.write_invalid_execution_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  support.seed_git_repo(repo_root, base_dir)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) =
    support.planned_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(active_run) = journal.activate_run(run)
  let assert Ok(failed_run) = orchestrator.start(active_run, config)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let failed_task =
    failed_run.tasks
    |> list.find(fn(task) { task.id == "demo-task" })
    |> result.unwrap(or: types.Task(
      id: "",
      title: "",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Queued,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    ))
  let assert Ok(events) = simplifile.read(failed_run.events_path)
  let assert Ok(raw_payload) =
    simplifile.read(filepath.join(
      failed_run.run_path,
      "logs/demo-task.result.raw.jsonish",
    ))

  assert failed_run.status == types.RunFailed
  assert failed_task.state == types.Failed
  assert string.contains(
    does: failed_task.summary,
    contain: "Unable to decode execution output for task demo-task.",
  )
  assert string.contains(does: events, contain: "\"kind\":\"task_failed\"")
  assert string.contains(does: events, contain: "\"kind\":\"run_failed\"")
  assert string.contains(does: raw_payload, contain: "\"follow_up_tasks\":[}")
  let assert Error(_) = simplifile.read(project.active_lock_path(repo_root))

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_plan_rejects_invalid_dependency_graph_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-invalid-plan-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) =
    support.write_invalid_plan_dependency_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  support.seed_git_repo(repo_root, base_dir)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)

  let assert Ok(pending_run) =
    journal.create_pending_run(
      repo_root,
      brief_path,
      support.agent_for(types.Codex),
      support.agent_for(types.Codex),
      "",
      1,
      None,
    )
  let assert Ok(dirty_pending_run) =
    journal.rewrite_run(types.RunRecord(..pending_run, planning_dirty: True))
  let assert Error(message) = orchestrator.plan(dirty_pending_run)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)

  let assert Ok(#(persisted_run, events)) =
    journal.load(repo_root, types.RunId(dirty_pending_run.run_id))
  let assert Ok(report) = simplifile.read(persisted_run.report_path)

  assert persisted_run.planning_dirty == True
  assert persisted_run.tasks == []
  assert string.contains(does: message, contain: "docs/wiki/index.md")
  assert string.contains(does: report, contain: "planning_validation_failed")
  assert list.any(events, fn(event) {
    event.kind == "planning_validation_failed"
  })

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_routes_dirty_decode_failures_to_manual_attention_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-dirty-decode-failure-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) =
    support.write_dirty_invalid_execution_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  support.seed_git_repo(repo_root, base_dir)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) =
    support.planned_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(active_run) = journal.activate_run(run)
  let assert Ok(blocked_run) = orchestrator.start(active_run, config)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let blocked_task =
    blocked_run.tasks
    |> list.find(fn(task) { task.id == "demo-task" })
    |> result.unwrap(or: types.Task(
      id: "",
      title: "",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Queued,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    ))
  let assert Ok(report) = simplifile.read(blocked_run.report_path)
  let assert Ok(events) = simplifile.read(blocked_run.events_path)
  let assert Ok(raw_payload) =
    simplifile.read(filepath.join(
      blocked_run.run_path,
      "logs/demo-task.result.raw.jsonish",
    ))
  let assert Ok(created_file) =
    simplifile.read(filepath.join(blocked_task.worktree_path, "BROKEN.md"))

  assert blocked_run.status == types.RunBlocked
  assert blocked_task.state == types.ManualAttention
  assert string.contains(
    does: blocked_task.summary,
    contain: "candidate worktree changes",
  )
  assert string.contains(does: blocked_task.summary, contain: "Raw payload:")
  assert string.contains(
    does: blocked_task.summary,
    contain: "Payload repair prompt:",
  )
  assert string.contains(does: report, contain: "Raw payload:")
  assert string.contains(does: report, contain: "Payload repair failures: 1")
  assert string.contains(
    does: events,
    contain: "\"kind\":\"execution_payload_repair_started\"",
  )
  assert string.contains(
    does: events,
    contain: "\"kind\":\"execution_payload_repair_failed\"",
  )
  assert string.contains(does: raw_payload, contain: "\"follow_up_tasks\":[}")
  assert string.contains(does: created_file, contain: "decode fallback")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_recovers_dirty_decode_failures_with_payload_repair_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-payload-repair-success-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let remote_root = filepath.join(base_dir, "remote.git")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let fake_gh = filepath.join(bin_dir, "gh")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_gh_bin = system.get_env("NIGHT_SHIFT_GH_BIN")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) =
    support.write_payload_repair_success_fake_provider(fake_provider)
  let assert Ok(_) = support.write_fake_gh(fake_gh)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider) <> " " <> shell.quote(fake_gh),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let _ =
    shell.run(
      "git init --bare " <> shell.quote(remote_root),
      base_dir,
      filepath.join(base_dir, "remote.log"),
    )
  support.seed_git_repo(repo_root, base_dir)
  let _ =
    shell.run(
      "git remote add origin " <> shell.quote(remote_root),
      repo_root,
      filepath.join(base_dir, "remote-add.log"),
    )
  let _ =
    shell.run(
      "git push -u origin main",
      repo_root,
      filepath.join(base_dir, "push-main.log"),
    )

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("NIGHT_SHIFT_GH_BIN", fake_gh)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) =
    support.planned_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(completed_run) = orchestrator.start(run, config)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_GH_BIN", old_gh_bin)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let completed_task =
    completed_run.tasks
    |> list.find(fn(task) { task.id == "demo-task" })
    |> result.unwrap(or: types.Task(
      id: "",
      title: "",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Queued,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    ))
  let assert Ok(events) = simplifile.read(completed_run.events_path)
  let assert Ok(report) = simplifile.read(completed_run.report_path)
  let assert Ok(created_file) =
    simplifile.read(filepath.join(completed_task.worktree_path, "REPAIRED.md"))

  assert completed_run.status == types.RunCompleted
  assert completed_task.state == types.Completed
  assert completed_task.pr_number == "1"
  assert string.contains(does: completed_task.summary, contain: "REPAIRED.md")
  assert string.contains(
    does: events,
    contain: "\"kind\":\"execution_payload_repair_started\"",
  )
  assert string.contains(
    does: events,
    contain: "\"kind\":\"execution_payload_repair_succeeded\"",
  )
  assert !string.contains(
    does: events,
    contain: "\"kind\":\"task_manual_attention\"",
  )
  assert string.contains(does: report, contain: "Payload repair attempts: 1")
  assert string.contains(does: report, contain: "Payload repair successes: 1")
  assert string.contains(does: created_file, contain: "payload repair success")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_blocks_invalid_follow_up_tasks_before_delivery_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-invalid-follow-up-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) =
    support.write_invalid_follow_up_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  support.seed_git_repo(repo_root, base_dir)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) =
    support.planned_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(active_run) = journal.activate_run(run)
  let assert Ok(blocked_run) = orchestrator.start(active_run, config)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let blocked_task =
    blocked_run.tasks
    |> list.find(fn(task) { task.id == "demo-task" })
    |> result.unwrap(or: types.Task(
      id: "",
      title: "",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Queued,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    ))
  let assert Ok(events_text) = simplifile.read(blocked_run.events_path)
  let assert Ok(created_file) =
    simplifile.read(filepath.join(
      blocked_task.worktree_path,
      "docs/wiki/combinators.md",
    ))

  assert blocked_run.status == types.RunBlocked
  assert blocked_task.state == types.ManualAttention
  assert blocked_task.pr_number == ""
  assert string.contains(
    does: blocked_task.summary,
    contain: "follow-up task graph was invalid",
  )
  assert string.contains(
    does: blocked_task.summary,
    contain: "docs/wiki/combinators.md",
  )
  assert string.contains(does: events_text, contain: "\"kind\":\"pr_opened\"")
    == False
  assert string.contains(
    does: events_text,
    contain: "\"kind\":\"task_manual_attention\"",
  )
  assert string.contains(does: created_file, contain: "guard")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_continues_awaiting_batch_after_decode_failure_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-batch-decode-failure-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = support.write_batch_decode_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  support.seed_git_repo(repo_root, base_dir)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 2,
    )

  let assert Ok(run) =
    support.planned_run(repo_root, brief_path, types.Codex, 2)
  let assert Ok(active_run) = journal.activate_run(run)
  let assert Ok(failed_run) = orchestrator.start(active_run, config)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(events) = simplifile.read(failed_run.events_path)
  let bad_task =
    failed_run.tasks
    |> list.find(fn(task) { task.id == "bad-task" })
    |> result.unwrap(or: types.Task(
      id: "",
      title: "",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Queued,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    ))
  let fail_task =
    failed_run.tasks
    |> list.find(fn(task) { task.id == "fail-task" })
    |> result.unwrap(or: types.Task(
      id: "",
      title: "",
      description: "",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Queued,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      superseded_pr_numbers: [],
      summary: "",
    ))

  assert failed_run.status == types.RunFailed
  assert bad_task.state == types.Failed
  assert fail_task.state == types.Failed
  assert string.contains(
    does: fail_task.summary,
    contain: "Provider intentionally blocked the task.",
  )
  assert string.contains(does: events, contain: "\"task_id\":\"bad-task\"")
  assert string.contains(does: events, contain: "\"task_id\":\"fail-task\"")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}
