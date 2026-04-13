import filepath
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import night_shift/journal
import night_shift/project
import night_shift/provider
import night_shift/shell
import night_shift/system
import night_shift/types
import night_shift/worktree_setup
import night_shift_test_support as support
import simplifile

pub fn start_without_brief_requires_default_doc_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-start-default-missing-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let state_home = filepath.join(base_dir, "state")
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let _ =
    shell.run(
      "git init --initial-branch=main " <> shell.quote(repo_root),
      base_dir,
      filepath.join(base_dir, "repo-init.log"),
    )

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", support.local_demo_command())
  system.set_env("XDG_STATE_HOME", state_home)

  let output =
    support.run_local_cli_command(
      ["start"],
      repo_root,
      filepath.join(base_dir, "start.log"),
    )

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(message) = output
  assert string.contains(
    does: message,
    contain: "No open Night Shift run was found.",
  )
  assert string.contains(does: message, contain: "night-shift plan --notes")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn start_requires_init_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-start-requires-init-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let state_home = filepath.join(base_dir, "state")
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let _ =
    shell.run(
      "git init --initial-branch=main " <> shell.quote(repo_root),
      base_dir,
      filepath.join(base_dir, "repo-init.log"),
    )

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", support.local_demo_command())
  system.set_env("XDG_STATE_HOME", state_home)

  let output =
    support.run_local_cli_command(
      ["start"],
      repo_root,
      filepath.join(base_dir, "start.log"),
    )

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(message) = output
  assert string.contains(
    does: message,
    contain: "Night Shift is not initialized for this repository",
  )
  assert string.contains(does: message, contain: "night-shift init")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn init_writes_selected_provider_and_model_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-init-config-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let _ =
    shell.run(
      "git init --initial-branch=main " <> shell.quote(repo_root),
      base_dir,
      filepath.join(base_dir, "repo-init.log"),
    )

  let output =
    support.run_local_cli_command(
      ["init", "--provider", "cursor", "--model", "composer-2-fast", "--yes"],
      repo_root,
      filepath.join(base_dir, "init.log"),
    )

  let assert Ok(message) = output
  let assert Ok(config_contents) =
    simplifile.read(project.config_path(repo_root))

  assert string.contains(does: message, contain: "Initialized")
  assert string.contains(
    does: config_contents,
    contain: "provider = \"cursor\"",
  )
  assert string.contains(
    does: config_contents,
    contain: "model = \"composer-2-fast\"",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn init_adds_local_exclude_entry_and_keeps_repo_clean_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-init-exclude-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let _ =
    shell.run(
      "git init --initial-branch=main " <> shell.quote(repo_root),
      base_dir,
      filepath.join(base_dir, "repo-init.log"),
    )

  let assert Ok(_) =
    support.run_local_cli_command(
      ["init", "--provider", "codex", "--model", "gpt-5.4-mini", "--yes"],
      repo_root,
      filepath.join(base_dir, "init-first.log"),
    )
  let assert Ok(_) =
    support.run_local_cli_command(
      ["init", "--provider", "codex", "--model", "gpt-5.4-mini", "--yes"],
      repo_root,
      filepath.join(base_dir, "init-second.log"),
    )
  let assert Ok(exclude_contents) =
    simplifile.read(project.local_exclude_path(repo_root))
  let status =
    shell.run(
      "git status --short",
      repo_root,
      filepath.join(base_dir, "status.log"),
    )

  assert string.contains(does: exclude_contents, contain: "/.night-shift/")
  assert list.length(
      string.split(exclude_contents, "\n")
      |> list.filter(fn(line) { string.trim(line) == "/.night-shift/" }),
    )
    == 1
  assert shell.succeeded(status)
  assert string.trim(status.output) == ""

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn init_requires_provider_outside_interactive_terminal_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-init-requires-provider-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let _ =
    shell.run(
      "git init --initial-branch=main " <> shell.quote(repo_root),
      base_dir,
      filepath.join(base_dir, "repo-init.log"),
    )

  let output =
    support.run_local_cli_command(
      ["init"],
      repo_root,
      filepath.join(base_dir, "init.log"),
    )

  let assert Ok(message) = output

  assert string.contains(
    does: message,
    contain: "night-shift init needs --provider <codex|cursor>",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn init_rejects_cursor_reasoning_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-init-cursor-reasoning-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let _ =
    shell.run(
      "git init --initial-branch=main " <> shell.quote(repo_root),
      base_dir,
      filepath.join(base_dir, "repo-init.log"),
    )

  let output =
    support.run_local_cli_command(
      [
        "init",
        "--provider",
        "cursor",
        "--reasoning",
        "medium",
        "--model",
        "composer-2-fast",
        "--yes",
      ],
      repo_root,
      filepath.join(base_dir, "init.log"),
    )

  let assert Ok(message) = output

  assert string.contains(
    does: message,
    contain: "Cursor does not support Night Shift's normalized reasoning control.",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn review_command_guides_to_plan_from_reviews_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-review-reuse-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let remote_root = filepath.join(base_dir, "remote.git")
  let bin_dir = filepath.join(base_dir, "bin")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let fake_gh = filepath.join(bin_dir, "gh")
  let existing_worktree = filepath.join(base_dir, "existing-review-worktree")
  let old_path = system.get_env("PATH")
  let old_gh_bin = system.get_env("NIGHT_SHIFT_GH_BIN")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let _ =
    shell.run(
      "git init --initial-branch=main " <> shell.quote(repo_root),
      base_dir,
      filepath.join(base_dir, "repo-init.log"),
    )
  let _ =
    shell.run(
      "git init --bare " <> shell.quote(remote_root),
      base_dir,
      filepath.join(base_dir, "remote-init.log"),
    )
  let _ =
    shell.run(
      "git -C "
        <> shell.quote(repo_root)
        <> " config user.email 'night-shift@example.test' && git -C "
        <> shell.quote(repo_root)
        <> " config user.name 'Night Shift Test' && git -C "
        <> shell.quote(repo_root)
        <> " remote add origin "
        <> shell.quote(remote_root)
        <> " && printf '# scratch\\n' > "
        <> shell.quote(filepath.join(repo_root, "README.md"))
        <> " && git -C "
        <> shell.quote(repo_root)
        <> " add README.md && git -C "
        <> shell.quote(repo_root)
        <> " commit -m 'init' >/dev/null && git -C "
        <> shell.quote(repo_root)
        <> " push -u origin main >/dev/null",
      base_dir,
      filepath.join(base_dir, "seed.log"),
    )
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = support.write_fake_provider(fake_provider)
  let assert Ok(_) = support.write_review_fake_gh(fake_gh)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider) <> " " <> shell.quote(fake_gh),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let _ =
    shell.run(
      "git -C "
        <> shell.quote(repo_root)
        <> " worktree add -b night-shift/demo "
        <> shell.quote(existing_worktree)
        <> " main",
      base_dir,
      filepath.join(base_dir, "worktree.log"),
    )

  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("NIGHT_SHIFT_GH_BIN", fake_gh)
  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)

  let result =
    support.run_local_cli_command(
      ["review", "--provider", "codex"],
      repo_root,
      filepath.join(base_dir, "review.log"),
    )

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_GH_BIN", old_gh_bin)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)

  let assert Ok(output) = result
  let assert Error(report_error) =
    journal.read_report(repo_root, types.LatestRun)

  assert string.contains(
    does: output,
    contain: "`night-shift review` was replaced by `night-shift plan --from-reviews`.",
  )
  assert string.contains(does: report_error, contain: "No Night Shift runs")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn start_rejects_dirty_source_repo_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-start-dirty-source-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let state_home = filepath.join(base_dir, "state")
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) =
    simplifile.write("# Brief\n", to: project.default_brief_path(repo_root))
  let assert Ok(_) =
    simplifile.write("# Demo\n", to: filepath.join(repo_root, "README.md"))
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
  let _ =
    shell.run(
      "git add .night-shift README.md && git commit -m 'chore: seed repo'",
      repo_root,
      filepath.join(base_dir, "seed.log"),
    )
  let assert Ok(_pending_run) =
    journal.create_pending_run(
      repo_root,
      project.default_brief_path(repo_root),
      support.agent_for(types.Codex),
      support.agent_for(types.Codex),
      "",
      1,
      None,
    )
  let assert Ok(_) =
    simplifile.write(
      "# Demo\nDirty\n",
      to: filepath.join(repo_root, "README.md"),
    )

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", support.local_demo_command())
  system.set_env("XDG_STATE_HOME", state_home)

  let output =
    support.run_local_cli_command(
      ["start"],
      repo_root,
      filepath.join(base_dir, "start.log"),
    )

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(message) = output
  assert string.contains(
    does: message,
    contain: "Night Shift start requires a clean source repository",
  )
  assert string.contains(does: message, contain: repo_root)

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn plan_command_creates_and_updates_default_brief_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-plan-cli-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_a = filepath.join(base_dir, "notes-a.md")
  let notes_b = filepath.join(base_dir, "notes-b.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let default_doc = project.default_brief_path(repo_root)
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let _ =
    shell.run(
      "git init --initial-branch=main " <> shell.quote(repo_root),
      base_dir,
      filepath.join(base_dir, "repo-init.log"),
    )
  let assert Ok(_) = simplifile.write("Alpha task\n", to: notes_a)
  let assert Ok(_) = simplifile.write("Beta task\n", to: notes_b)

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", support.local_demo_command())
  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("XDG_STATE_HOME", state_home)

  let first_result =
    support.run_local_cli_command(
      ["plan", "--notes", notes_a],
      repo_root,
      filepath.join(base_dir, "plan-a.log"),
    )
  let second_result =
    support.run_local_cli_command(
      ["plan", "--notes", notes_b],
      repo_root,
      filepath.join(base_dir, "plan-b.log"),
    )

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(first_output) = first_result
  let assert Ok(second_output) = second_result
  let assert Ok(document) = simplifile.read(default_doc)

  assert string.contains(does: first_output, contain: "Planned run ")
  assert string.contains(does: second_output, contain: "Planned run ")
  assert string.contains(does: document, contain: "Alpha task")
  assert string.contains(does: document, contain: "Beta task")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn blocked_plan_status_and_report_show_decisions_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-blocked-status-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_resolve_loop_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let assert Ok(_) =
    simplifile.write("Add a first-pass docs wiki.\n", to: notes_path)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("XDG_STATE_HOME", state_home)

  let plan_result =
    support.run_local_cli_command(
      ["plan", "--notes", notes_path],
      repo_root,
      filepath.join(base_dir, "plan.log"),
    )
  let status_result =
    support.run_local_cli_command(
      ["status"],
      repo_root,
      filepath.join(base_dir, "status.log"),
    )
  let assert Ok(#(run, _events)) = journal.load(repo_root, types.LatestRun)
  let assert Ok(report_contents) = simplifile.read(run.report_path)

  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(plan_output) = plan_result
  let assert Ok(status_output) = status_result

  assert string.contains(does: plan_output, contain: "Planned run ")
  assert string.contains(does: status_output, contain: "is blocked")
  assert string.contains(does: status_output, contain: "Blocked tasks: 1")
  assert string.contains(
    does: status_output,
    contain: "Outstanding decisions: 1",
  )
  assert string.contains(
    does: status_output,
    contain: "Ready implementation tasks: 0",
  )
  assert string.contains(
    does: status_output,
    contain: "Next action: night-shift resolve",
  )
  assert string.contains(
    does: report_contents,
    contain: "- Manual-attention tasks: 1",
  )
  assert string.contains(
    does: report_contents,
    contain: "- Outstanding decisions: 1",
  )
  assert string.contains(
    does: report_contents,
    contain: "Where should the new markdown wiki live?",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn resolve_command_recovers_and_loops_until_pending_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-resolve-loop-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_resolve_loop_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let assert Ok(_) =
    simplifile.write("Add a first-pass docs wiki.\n", to: notes_path)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("XDG_STATE_HOME", state_home)

  let _ =
    support.run_local_cli_command(
      ["plan", "--notes", notes_path],
      repo_root,
      filepath.join(base_dir, "plan.log"),
    )
  let resolve_result =
    support.run_local_cli_tty_command_with_input(
      ["resolve"],
      "\n\n",
      repo_root,
      filepath.join(base_dir, "resolve.log"),
    )
  let status_result =
    support.run_local_cli_command(
      ["status"],
      repo_root,
      filepath.join(base_dir, "status.log"),
    )
  let assert Ok(#(run, _events)) = journal.load(repo_root, types.LatestRun)
  let assert Ok(events_contents) = simplifile.read(run.events_path)

  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(resolve_output) = resolve_result
  let assert Ok(status_output) = status_result

  assert run.status == types.RunPending
  assert string.contains(
    does: resolve_output,
    contain: "finished with status pending",
  )
  assert string.contains(does: resolve_output, contain: "Question 1/1")
  assert string.contains(
    does: status_output,
    contain: "Outstanding decisions: 0",
  )
  assert string.contains(does: status_output, contain: "Ready tasks: 1")
  assert string.contains(
    does: events_contents,
    contain: "\"kind\":\"decision_contract_warning\"",
  )
  assert string.contains(
    does: events_contents,
    contain: "Where should the new markdown wiki live? -> docs/wiki",
  )
  assert string.contains(
    does: events_contents,
    contain: "Which README sections should stay in README vs move or duplicate to the wiki first-pass? -> keep-core",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn resolve_command_recovers_from_planning_sync_pending_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-resolve-recovery-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_resolve_loop_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let assert Ok(_) =
    simplifile.write("Add a first-pass docs wiki.\n", to: notes_path)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("XDG_STATE_HOME", state_home)

  let _ =
    support.run_local_cli_command(
      ["plan", "--notes", notes_path],
      repo_root,
      filepath.join(base_dir, "plan.log"),
    )
  let assert Ok(#(run, _)) = journal.load(repo_root, types.LatestRun)
  let stale_run =
    types.RunRecord(
      ..run,
      decisions: [
        types.RecordedDecision(
          key: "wiki-location",
          question: "Where should the new markdown wiki live?",
          answer: "docs/wiki",
          answered_at: system.timestamp(),
        ),
      ],
      planning_dirty: True,
      status: types.RunBlocked,
    )
  let assert Ok(_) = journal.rewrite_run(stale_run)

  let resolve_result =
    support.run_local_cli_tty_command_with_input(
      ["resolve"],
      "\n",
      repo_root,
      filepath.join(base_dir, "resolve.log"),
    )
  let assert Ok(#(updated_run, _events)) =
    journal.load(repo_root, types.LatestRun)

  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(resolve_output) = resolve_result

  assert updated_run.status == types.RunPending
  assert updated_run.planning_dirty == False
  assert string.contains(
    does: resolve_output,
    contain: "Planning sync pending: no",
  )
  assert string.contains(does: resolve_output, contain: "Question 1/1")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn stale_blocked_run_status_and_start_guidance_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-stale-blocked-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_resolve_loop_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let assert Ok(_) =
    simplifile.write("Add a first-pass docs wiki.\n", to: notes_path)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("XDG_STATE_HOME", state_home)

  let _ =
    support.run_local_cli_command(
      ["plan", "--notes", notes_path],
      repo_root,
      filepath.join(base_dir, "plan.log"),
    )
  let assert Ok(#(run, _)) = journal.load(repo_root, types.LatestRun)
  let stale_run =
    types.RunRecord(
      ..run,
      decisions: [
        types.RecordedDecision(
          key: "wiki-location",
          question: "Where should the new markdown wiki live?",
          answer: "docs/wiki",
          answered_at: system.timestamp(),
        ),
      ],
      planning_dirty: True,
      status: types.RunBlocked,
    )
  let assert Ok(_) = journal.rewrite_run(stale_run)

  let status_result =
    support.run_local_cli_command(
      ["status"],
      repo_root,
      filepath.join(base_dir, "status.log"),
    )
  let start_result =
    support.run_local_cli_command(
      ["start"],
      repo_root,
      filepath.join(base_dir, "start.log"),
    )
  let assert Ok(report_contents) =
    simplifile.read(filepath.join(stale_run.run_path, "report.md"))

  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(status_output) = status_result
  let assert Ok(start_output) = start_result

  assert string.contains(does: status_output, contain: "Blocked tasks: 1")
  assert string.contains(
    does: status_output,
    contain: "Outstanding decisions: 0",
  )
  assert string.contains(
    does: status_output,
    contain: "Planning sync pending: yes",
  )
  assert string.contains(
    does: status_output,
    contain: "Next action: night-shift resolve",
  )
  assert string.contains(
    does: start_output,
    contain: "recorded new planning answers or notes but has not been replanned yet",
  )
  assert string.contains(
    does: report_contents,
    contain: "Decision recorded; Night Shift still needs to replan this run.",
  )
  assert string.contains(does: report_contents, contain: "- Blocked tasks: 1")
  assert string.contains(
    does: report_contents,
    contain: "- Manual-attention tasks: 1",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn start_dirty_night_shift_control_files_do_not_block_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-dirty-config-start-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  support.seed_git_repo(repo_root, base_dir)
  let assert Ok(_) = simplifile.write("Add a docs page.\n", to: notes_path)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("XDG_STATE_HOME", state_home)

  let _ =
    support.run_local_cli_command(
      ["plan", "--notes", notes_path],
      repo_root,
      filepath.join(base_dir, "plan.log"),
    )
  let assert Ok(_) =
    simplifile.write(
      worktree_setup.default_template(),
      to: project.worktree_setup_path(repo_root),
    )
  let start_result =
    support.run_local_cli_command(
      ["start"],
      repo_root,
      filepath.join(base_dir, "start.log"),
    )

  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(start_output) = start_result

  assert string.contains(
    does: start_output,
    contain: ".night-shift/worktree-setup.toml",
  )
  assert string.contains(
    does: start_output,
    contain: "repo-local control-plane changes under `.night-shift/`",
  )
  assert string.contains(
    does: start_output,
    contain: "are not part of execution worktrees or delivery PRs",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn reset_command_removes_project_home_and_worktrees_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-reset-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let worktree_path = filepath.join(base_dir, "task-worktree")
  let state_home = filepath.join(base_dir, "state")
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  support.seed_git_repo(repo_root, base_dir)
  let _ =
    shell.run(
      "git worktree add -b night-shift/reset-demo "
        <> shell.quote(worktree_path)
        <> " main",
      repo_root,
      filepath.join(base_dir, "worktree.log"),
    )

  let brief_path = project.default_brief_path(repo_root)
  let assert Ok(_) = simplifile.write("# Brief\n", to: brief_path)
  let assert Ok(run) =
    journal.create_pending_run(
      repo_root,
      brief_path,
      support.agent_for(types.Codex),
      support.agent_for(types.Codex),
      "",
      1,
      None,
    )
  let run_with_worktree =
    types.RunRecord(..run, tasks: [
      types.Task(
        id: "demo-task",
        title: "Demo task",
        description: "Demo",
        dependencies: [],
        acceptance: [],
        demo_plan: [],
        decision_requests: [],
        superseded_pr_numbers: [],
        kind: types.ImplementationTask,
        execution_mode: types.Serial,
        state: types.Ready,
        worktree_path: worktree_path,
        branch_name: "night-shift/reset-demo",
        pr_number: "",
        summary: "",
        runtime_context: None,
      ),
    ])
  let assert Ok(_) = journal.rewrite_run(run_with_worktree)

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", support.local_demo_command())
  system.set_env("XDG_STATE_HOME", state_home)

  let reset_result =
    support.run_local_cli_command(
      ["reset", "--yes"],
      repo_root,
      filepath.join(base_dir, "reset.log"),
    )

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(reset_output) = reset_result

  assert string.contains(
    does: reset_output,
    contain: "Night Shift reset complete",
  )
  assert string.contains(
    does: reset_output,
    contain: "Local Night Shift branches and remote PRs were not modified.",
  )
  assert simplifile.read_directory(at: project.home(repo_root))
    |> result.is_error
  assert simplifile.read_directory(at: worktree_path)
    |> result.is_error

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn plan_command_leaves_existing_doc_on_failed_provider_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-plan-cli-failure-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let default_doc = project.default_brief_path(repo_root)
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let _ =
    shell.run(
      "git init --initial-branch=main " <> shell.quote(repo_root),
      base_dir,
      filepath.join(base_dir, "repo-init.log"),
    )
  let assert Ok(_) = simplifile.write("Keep this brief.\n", to: default_doc)
  let assert Ok(_) = simplifile.write("fail-plan-doc-exit\n", to: notes_path)

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", support.local_demo_command())
  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("XDG_STATE_HOME", state_home)

  let result =
    support.run_local_cli_command(
      ["plan", "--notes", notes_path],
      repo_root,
      filepath.join(base_dir, "plan-fail.log"),
    )

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(output) = result
  let assert Ok(document) = simplifile.read(default_doc)

  assert string.contains(does: output, contain: "Planning provider failed.")
  assert document == "Keep this brief.\n"

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn plan_document_reports_missing_markers_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-plan-markers-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let doc_path = project.default_brief_path(repo_root)
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let assert Ok(_) =
    simplifile.write("fail-plan-doc-no-marker\n", to: notes_path)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("XDG_STATE_HOME", state_home)

  let result =
    provider.plan_document(
      support.agent_for(types.Codex),
      repo_root,
      Some(types.NotesFile(notes_path)),
      doc_path,
      None,
    )

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let assert Error(message) = result
  assert string.contains(does: message, contain: "start marker")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn plan_document_reports_empty_payload_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-plan-empty-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let doc_path = project.default_brief_path(repo_root)
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let assert Ok(_) = simplifile.write("fail-plan-doc-empty\n", to: notes_path)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("XDG_STATE_HOME", state_home)

  let result =
    provider.plan_document(
      support.agent_for(types.Codex),
      repo_root,
      Some(types.NotesFile(notes_path)),
      doc_path,
      None,
    )

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let assert Error(message) = result
  assert string.contains(does: message, contain: "empty brief")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn generate_worktree_setup_reports_empty_payload_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-worktree-setup-empty-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let fake_codex = filepath.join(bin_dir, "codex")
  let output_path = filepath.join(repo_root, ".night-shift/worktree-setup.toml")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_empty_worktree_setup_codex(fake_codex)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_codex),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )

  system.unset_env("NIGHT_SHIFT_FAKE_PROVIDER")
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)

  let result =
    provider.generate_worktree_setup(
      support.agent_for(types.Codex),
      repo_root,
      output_path,
    )

  system.set_env("PATH", old_path)
  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let assert Error(message) = result
  assert string.contains(does: message, contain: "empty file")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn codex_plan_document_reads_prompt_from_stdin_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-codex-plan-stdin-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let doc_path = project.default_brief_path(repo_root)
  let fake_codex = filepath.join(bin_dir, "codex")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_fake_codex(fake_codex)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_codex),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let assert Ok(_) =
    simplifile.write("# Notes\n- add a hello script\n", to: notes_path)

  system.unset_env("NIGHT_SHIFT_FAKE_PROVIDER")
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)

  let result =
    provider.plan_document(
      support.agent_for(types.Codex),
      repo_root,
      Some(types.NotesFile(notes_path)),
      doc_path,
      None,
    )

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  support.restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(#(document, _artifact_path)) = result
  assert string.contains(does: document, contain: "# Night Shift Brief")
  assert string.contains(does: document, contain: "Add the hello script.")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}
