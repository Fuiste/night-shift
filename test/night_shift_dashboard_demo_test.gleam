import filepath
import gleam/string
import night_shift/dashboard
import night_shift/demo
import night_shift/journal
import night_shift/shell
import night_shift/system
import night_shift/types
import night_shift_test_support as support
import simplifile

pub fn dashboard_start_session_tracks_completed_run_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-ui-integration-" <> unique,
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
  let assert Ok(session) =
    dashboard.start_start_session(repo_root, run.run_id, run, config)
  let final_payload = support.wait_for_run_payload(session.url, run.run_id, 40)

  system.set_env("PATH", old_path)
  support.restore_env("NIGHT_SHIFT_GH_BIN", old_gh_bin)
  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  system.set_env("XDG_STATE_HOME", old_state_home)

  assert string.contains(
    does: final_payload,
    contain: "\"status\":\"completed\"",
  )
  assert string.contains(does: final_payload, contain: "\"pr_number\":\"1\"")

  let _ = dashboard.stop_session(session)
  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn demo_run_succeeds_without_ui_test() {
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_repo_root = system.get_env("NIGHT_SHIFT_REPO_ROOT")
  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", support.local_demo_command())
  system.unset_env("NIGHT_SHIFT_REPO_ROOT")

  let first_result = demo.run(False)

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  support.restore_env("NIGHT_SHIFT_REPO_ROOT", old_repo_root)

  let _ = simplifile.delete(file_or_dir_at: demo.demo_root())

  let assert Ok(first_summary) = first_result

  assert string.contains(
    does: first_summary,
    contain: "Validated CLI flows: plan, start, status, report",
  )
  assert string.contains(
    does: first_summary,
    contain: "Proof file: "
      <> filepath.join(demo.demo_root(), "repo/IMPLEMENTED.md"),
  )
  assert string.contains(
    does: first_summary,
    contain: "Artifacts: " <> demo.demo_root(),
  )
}

pub fn demo_run_succeeds_with_ui_test() {
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_repo_root = system.get_env("NIGHT_SHIFT_REPO_ROOT")
  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", support.local_demo_command())
  system.unset_env("NIGHT_SHIFT_REPO_ROOT")

  let result = demo.run(True)

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  support.restore_env("NIGHT_SHIFT_REPO_ROOT", old_repo_root)

  let _ = simplifile.delete(file_or_dir_at: demo.demo_root())

  let assert Ok(summary) = result

  assert string.contains(
    does: summary,
    contain: "Validated UI flows: plan, dash, dashboard start, dashboard payload, status",
  )
  assert string.contains(does: summary, contain: "Dashboard: http://127.0.0.1:")
  assert string.contains(
    does: summary,
    contain: "Proof file: "
      <> filepath.join(demo.demo_root(), "repo/IMPLEMENTED.md"),
  )
}
