import filepath
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import night_shift/cli
import night_shift/config
import night_shift/dashboard
import night_shift/demo
import night_shift/journal
import night_shift/orchestrator
import night_shift/provider
import night_shift/shell
import night_shift/system
import night_shift/types
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_start_command_test() {
  let assert Ok(types.Start(Some("brief.md"), agent_overrides, Ok(2), False)) =
    cli.parse([
      "start",
      "--brief",
      "brief.md",
      "--provider",
      "cursor",
      "--max-workers",
      "2",
    ])

  assert agent_overrides.provider == Some(types.Cursor)
}

pub fn parse_plan_command_test() {
  let assert Ok(types.Plan("notes.md", None, agent_overrides)) =
    cli.parse(["plan", "--notes", "notes.md"])
  assert agent_overrides == types.empty_agent_overrides()
}

pub fn parse_plan_command_with_doc_and_provider_test() {
  let assert Ok(types.Plan("notes.md", Some("custom.md"), agent_overrides)) =
    cli.parse([
      "plan",
      "--notes",
      "notes.md",
      "--doc",
      "custom.md",
      "--provider",
      "cursor",
    ])

  assert agent_overrides.provider == Some(types.Cursor)
}

pub fn parse_status_defaults_to_latest_test() {
  let assert Ok(types.Status(types.LatestRun)) = cli.parse(["status"])
}

pub fn parse_start_command_with_ui_test() {
  let assert Ok(types.Start(Some("brief.md"), agent_overrides, Error(Nil), True)) =
    cli.parse(["start", "--brief", "brief.md", "--ui"])
  assert agent_overrides == types.empty_agent_overrides()
}

pub fn parse_start_command_without_brief_test() {
  let assert Ok(types.Start(None, agent_overrides, Error(Nil), False)) =
    cli.parse(["start"])
  assert agent_overrides == types.empty_agent_overrides()
}

pub fn parse_plan_requires_notes_test() {
  let assert Error(message) = cli.parse(["plan"])
  assert message == "The plan command requires --notes <path>."
}

pub fn parse_resume_command_with_ui_test() {
  let assert Ok(types.Resume(types.RunId("run-123"), True)) =
    cli.parse(["resume", "--run", "run-123", "--ui"])
}

pub fn parse_demo_command_test() {
  let assert Ok(types.Demo(False)) = cli.parse(["--demo"])
}

pub fn parse_demo_command_with_ui_test() {
  let assert Ok(types.Demo(True)) = cli.parse(["--demo", "--ui"])
}

pub fn parse_default_config_values_test() {
  let assert Ok(parsed) =
    config.parse("base_branch = \"develop\"\nmax_workers = 2")
  assert parsed.base_branch == "develop"
  assert parsed.max_workers == 2
  assert parsed.default_profile == "default"
}

pub fn parse_profile_config_test() {
  let source =
    "default_profile = \"default\"\n"
    <> "planning_profile = \"planner\"\n"
    <> "[profiles.planner]\n"
    <> "provider = \"codex\"\n"
    <> "model = \"gpt-5.4-mini\"\n"
    <> "reasoning = \"medium\"\n"
    <> "[profiles.planner.provider_overrides]\n"
    <> "mode = \"plan\"\n"

  let assert Ok(parsed) = config.parse(source)
  let assert [default_profile, planner, ..] = parsed.profiles

  assert parsed.planning_profile == "planner"
  assert default_profile.name == "default"
  assert planner.name == "planner"
  assert planner.provider == types.Codex
  assert planner.model == Some("gpt-5.4-mini")
  assert planner.reasoning == Some(types.Medium)
  assert planner.provider_overrides
    == [types.ProviderOverride(key: "mode", value: "plan")]
}

pub fn parse_notifiers_and_verification_commands_test() {
  let source =
    "notifiers = [\"console\", \"report_file\"]\n"
    <> "[verification]\n"
    <> "commands = [\"gleam test\", \"npm test\"]\n"

  let assert Ok(parsed) = config.parse(source)

  assert parsed.notifiers == [types.ConsoleNotifier, types.ReportFileNotifier]
  assert parsed.verification_commands == ["gleam test", "npm test"]
}

pub fn start_run_creates_report_and_state_test() {
  let unique = system.unique_id()
  let base_dir =
    filepath.join(system.state_directory(), "night-shift-test-" <> unique)
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)

  let assert Ok(run) = start_run(repo_root, brief_path, types.Codex, 2)
  let assert Ok(report_contents) = simplifile.read(run.report_path)
  let assert Ok(state_contents) = simplifile.read(run.state_path)

  assert string.contains(does: report_contents, contain: "Night Shift Report")
  assert string.contains(does: state_contents, contain: "\"run_id\"")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn latest_run_round_trip_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-test-round-trip-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(run) = start_run(repo_root, brief_path, types.Cursor, 1)
  let assert Ok(#(saved_run, _)) = journal.load(repo_root, types.LatestRun)

  assert saved_run.run_id == run.run_id
  assert saved_run.execution_agent.provider == types.Cursor
  assert result.is_ok(simplifile.delete(file_or_dir_at: base_dir))
}

pub fn list_runs_returns_newest_first_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-test-history-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_a = filepath.join(base_dir, "brief-a.md")
  let brief_b = filepath.join(base_dir, "brief-b.md")

  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief A", to: brief_a)
  let assert Ok(_) = simplifile.write("# Brief B", to: brief_b)

  let assert Ok(first_run) =
    start_run(repo_root, brief_a, types.Codex, 1)
  let assert Ok(_) = journal.mark_status(first_run, types.RunCompleted, "done")
  let assert Ok(second_run) =
    start_run(repo_root, brief_b, types.Cursor, 2)
  let assert Ok(runs) = journal.list_runs(repo_root)

  let assert [latest, previous, ..] = runs
  assert latest.run_id == second_run.run_id
  assert previous.run_id == first_run.run_id

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn dashboard_payloads_include_run_data_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-test-dashboard-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(run) = start_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(updated_run) =
    journal.append_event(
      run,
      types.RunEvent(
        kind: "task_progress",
        at: system.timestamp(),
        message: "Working",
        task_id: Some("demo-task"),
      ),
    )

  let assert Ok(runs_payload) = dashboard.runs_json(repo_root)
  let assert Ok(run_payload) = dashboard.run_json(repo_root, updated_run.run_id)

  assert string.contains(does: runs_payload, contain: updated_run.run_id)
  assert string.contains(does: run_payload, contain: "\"events\"")
  assert string.contains(does: run_payload, contain: "\"report\"")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn dashboard_server_serves_run_data_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-test-dashboard-server-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(run) = start_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(session) = dashboard.start_view_session(repo_root, run.run_id)

  system.sleep(100)

  let assert Ok(index_html) = dashboard.http_get(session.url)
  let assert Ok(runs_payload) = dashboard.http_get(session.url <> "/api/runs")
  let assert Ok(run_payload) =
    dashboard.http_get(session.url <> "/api/runs/" <> run.run_id)

  assert string.contains(does: index_html, contain: "Night Shift Dashboard")
  assert string.contains(does: runs_payload, contain: run.run_id)
  assert string.contains(
    does: run_payload,
    contain: "\"run_id\":\"" <> run.run_id <> "\"",
  )

  let _ = dashboard.stop_session(session)
  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn extract_json_payload_test() {
  let output =
    "noise\n"
    <> "NIGHT_SHIFT_RESULT_START\n"
    <> "{\"tasks\":[]}\n"
    <> "NIGHT_SHIFT_RESULT_END\n"

  let assert Ok(payload) = provider.extract_json_payload(output)
  assert payload == "{\"tasks\":[]}"
}

pub fn extract_payload_markdown_test() {
  let output =
    "planning-doc\n"
    <> "NIGHT_SHIFT_RESULT_START\n"
    <> "# Night Shift Brief\n"
    <> "## Objective\n"
    <> "Capture the work.\n"
    <> "NIGHT_SHIFT_RESULT_END\n"

  let assert Ok(payload) = provider.extract_payload(output)
  assert string.contains(does: payload, contain: "# Night Shift Brief")
}

pub fn extract_payload_uses_last_result_block_test() {
  let output =
    "user\n"
    <> "NIGHT_SHIFT_RESULT_START\n"
    <> "# Night Shift Brief\n"
    <> "## Objective\n"
    <> "...\n"
    <> "NIGHT_SHIFT_RESULT_END\n"
    <> "codex\n"
    <> "NIGHT_SHIFT_RESULT_START\n"
    <> "# Night Shift Brief\n"
    <> "## Objective\n"
    <> "Real brief.\n"
    <> "NIGHT_SHIFT_RESULT_END\n"

  let assert Ok(payload) = provider.extract_payload(output)
  assert string.contains(does: payload, contain: "Real brief.")
  assert !string.contains(does: payload, contain: "...\n")
}

pub fn extract_json_payload_uses_last_result_block_test() {
  let output =
    "user\n"
    <> "NIGHT_SHIFT_RESULT_START\n"
    <> "{\"tasks\":[]}\n"
    <> "NIGHT_SHIFT_RESULT_END\n"
    <> "codex\n"
    <> "NIGHT_SHIFT_RESULT_START\n"
    <> "{\"tasks\":[{\"id\":\"real-task\"}]}\n"
    <> "NIGHT_SHIFT_RESULT_END\n"

  let assert Ok(payload) = provider.extract_json_payload(output)
  assert payload == "{\"tasks\":[{\"id\":\"real-task\"}]}"
}

pub fn start_without_brief_requires_default_doc_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-start-default-missing-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let state_home = filepath.join(base_dir, "state")
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) =
    simplifile.write("", to: filepath.join(repo_root, ".night-shift.toml"))
  let _ =
    shell.run(
      "git init --initial-branch=main " <> shell.quote(repo_root),
      base_dir,
      filepath.join(base_dir, "repo-init.log"),
    )

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", local_demo_command())
  system.set_env("XDG_STATE_HOME", state_home)

  let output =
    run_local_cli_command(
      ["start"],
      repo_root,
      filepath.join(base_dir, "start.log"),
    )

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(message) = output
  assert string.contains(
    does: message,
    contain: "No default brief was found at",
  )
  assert string.contains(
    does: message,
    contain: filepath.join(repo_root, types.default_brief_filename),
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn plan_command_creates_and_updates_default_brief_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-plan-cli-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_a = filepath.join(base_dir, "notes-a.md")
  let notes_b = filepath.join(base_dir, "notes-b.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let default_doc = filepath.join(repo_root, types.default_brief_filename)
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = write_fake_provider(fake_provider)
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
  let assert Ok(_) =
    simplifile.write("", to: filepath.join(repo_root, ".night-shift.toml"))
  let assert Ok(_) = simplifile.write("Alpha task\n", to: notes_a)
  let assert Ok(_) = simplifile.write("Beta task\n", to: notes_b)

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", local_demo_command())
  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("XDG_STATE_HOME", state_home)

  let first_result =
    run_local_cli_command(
      ["plan", "--notes", notes_a],
      repo_root,
      filepath.join(base_dir, "plan-a.log"),
    )
  let second_result =
    run_local_cli_command(
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

  assert string.contains(does: first_output, contain: "Updated planning brief:")
  assert string.contains(
    does: second_output,
    contain: "Updated planning brief:",
  )
  assert string.contains(does: document, contain: "Alpha task")
  assert string.contains(does: document, contain: "Beta task")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn plan_command_leaves_existing_doc_on_failed_provider_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-plan-cli-failure-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let default_doc = filepath.join(repo_root, types.default_brief_filename)
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = write_fake_provider(fake_provider)
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
  let assert Ok(_) =
    simplifile.write("", to: filepath.join(repo_root, ".night-shift.toml"))
  let assert Ok(_) = simplifile.write("Keep this brief.\n", to: default_doc)
  let assert Ok(_) = simplifile.write("fail-plan-doc-exit\n", to: notes_path)

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", local_demo_command())
  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("XDG_STATE_HOME", state_home)

  let result =
    run_local_cli_command(
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
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-plan-markers-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let doc_path = filepath.join(repo_root, types.default_brief_filename)
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = write_fake_provider(fake_provider)
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
    provider.plan_document(agent_for(types.Codex), repo_root, notes_path, doc_path)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let assert Error(message) = result
  assert string.contains(does: message, contain: "start marker")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn plan_document_reports_empty_payload_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-plan-empty-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let doc_path = filepath.join(repo_root, types.default_brief_filename)
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let state_home = filepath.join(base_dir, "state")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = write_fake_provider(fake_provider)
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
    provider.plan_document(agent_for(types.Codex), repo_root, notes_path, doc_path)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let assert Error(message) = result
  assert string.contains(does: message, contain: "empty brief")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn codex_plan_document_reads_prompt_from_stdin_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-codex-plan-stdin-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let doc_path = filepath.join(repo_root, types.default_brief_filename)
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
  let assert Ok(_) = write_fake_codex(fake_codex)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_codex),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let assert Ok(_) = simplifile.write("# Notes\n- add a hello script\n", to: notes_path)

  system.unset_env("NIGHT_SHIFT_FAKE_PROVIDER")
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)

  let result =
    provider.plan_document(agent_for(types.Codex), repo_root, notes_path, doc_path)

  system.set_env("PATH", old_path)
  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(#(document, _artifact_path)) = result
  assert string.contains(does: document, contain: "# Night Shift Brief")
  assert string.contains(does: document, contain: "Add the hello script.")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn repo_state_path_is_stable_test() {
  let repo_root = "/tmp/night-shift-demo"
  assert journal.repo_state_path_for(repo_root)
    == journal.repo_state_path_for(repo_root)
}

pub fn orchestrator_start_runs_fake_provider_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = write_fake_provider(fake_provider)
  let assert Ok(_) = write_fake_gh(fake_gh)
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
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) = start_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(completed_run) = orchestrator.start(run, config)

  system.set_env("PATH", old_path)
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
      parallel_safe: False,
      state: types.Failed,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      summary: "",
    ))

  assert completed_run.status == types.RunCompleted
  assert completed_task.pr_number == "1"
  assert string.contains(does: completed_task.summary, contain: "Implemented")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn dashboard_start_session_tracks_completed_run_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = write_fake_provider(fake_provider)
  let assert Ok(_) = write_fake_gh(fake_gh)
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
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) = start_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(session) =
    dashboard.start_start_session(repo_root, run.run_id, run, config)
  let final_payload = wait_for_run_payload(session.url, run.run_id, 20)

  system.set_env("PATH", old_path)
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
  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", local_demo_command())

  let first_result = demo.run(False)
  let second_result = demo.run(False)

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  let _ = simplifile.delete(file_or_dir_at: demo.demo_root())

  let assert Ok(first_summary) = first_result
  let assert Ok(second_summary) = second_result

  assert string.contains(
    does: first_summary,
    contain: "Validated CLI flows: start, status, report",
  )
  assert string.contains(
    does: first_summary,
    contain: "Proof file: "
      <> filepath.join(demo.demo_root(), "repo/IMPLEMENTED.md"),
  )
  assert string.contains(
    does: second_summary,
    contain: "Artifacts: " <> demo.demo_root(),
  )
}

pub fn demo_run_succeeds_with_ui_test() {
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", local_demo_command())

  let result = demo.run(True)

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  let _ = simplifile.delete(file_or_dir_at: demo.demo_root())

  let assert Ok(summary) = result

  assert string.contains(
    does: summary,
    contain: "Validated UI flows: start --ui, dashboard payload, status",
  )
  assert string.contains(does: summary, contain: "Dashboard: http://127.0.0.1:")
  assert string.contains(
    does: summary,
    contain: "Proof file: "
      <> filepath.join(demo.demo_root(), "repo/IMPLEMENTED.md"),
  )
}

fn absolute_path(path: String) -> String {
  case string.starts_with(path, "/") {
    True -> path
    False -> filepath.join(system.cwd(), path)
  }
}

fn local_demo_command() -> String {
  let cwd = system.cwd()
  let erlang_root = filepath.join(cwd, "build/dev/erlang")
  let ebin_paths = [
    filepath.join(erlang_root, "night_shift/ebin"),
    filepath.join(erlang_root, "gleam_stdlib/ebin"),
    filepath.join(erlang_root, "gleam_json/ebin"),
    filepath.join(erlang_root, "filepath/ebin"),
    filepath.join(erlang_root, "simplifile/ebin"),
    filepath.join(erlang_root, "gleeunit/ebin"),
  ]

  "erl"
  <> {
    ebin_paths
    |> list.map(fn(path) { " -pa " <> shell.quote(path) })
    |> string.join(with: "")
  }
  <> " -noshell -eval "
  <> shell.quote("'night_shift@@main':run(night_shift).")
  <> " -extra"
}

fn run_local_cli_command(
  args: List(String),
  cwd: String,
  log_path: String,
) -> Result(String, String) {
  let command = local_demo_command()
  let result =
    shell.run(
      command
        <> " "
        <> {
        args
        |> list.map(shell.quote)
        |> string.join(with: " ")
      },
      cwd,
      log_path,
    )

  case shell.succeeded(result) {
    True -> Ok(result.output)
    False -> Error("CLI command failed. See " <> log_path <> ".")
  }
}

fn agent_for(provider_name: types.Provider) -> types.ResolvedAgentConfig {
  types.resolved_agent_from_provider(provider_name)
}

fn start_run(
  repo_root: String,
  brief_path: String,
  provider_name: types.Provider,
  max_workers: Int,
) -> Result(types.RunRecord, String) {
  journal.start_run(
    repo_root,
    brief_path,
    agent_for(provider_name),
    agent_for(provider_name),
    max_workers,
  )
}

fn write_fake_provider(path: String) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "PROMPT_FILE=$2\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Implement demo task\",\"description\":\"Create a file to prove execution\",\"dependencies\":[],\"acceptance\":[\"Create IMPLEMENTED.md\"],\"demo_plan\":[\"Show the new file\"],\"parallel_safe\":false}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  if grep -q 'fail-plan-doc-exit' \"$PROMPT_FILE\"; then\n"
      <> "    printf 'forced failure\\n' >&2\n"
      <> "    exit 1\n"
      <> "  fi\n"
      <> "  if grep -q 'fail-plan-doc-no-marker' \"$PROMPT_FILE\"; then\n"
      <> "    printf 'planning-doc without markers\\n'\n"
      <> "    exit 0\n"
      <> "  fi\n"
      <> "  if grep -q 'fail-plan-doc-empty' \"$PROMPT_FILE\"; then\n"
      <> "    printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "    exit 0\n"
      <> "  fi\n"
      <> "  if grep -q 'Beta task' \"$PROMPT_FILE\"; then\n"
      <> "    grep -q 'Alpha task' \"$PROMPT_FILE\" || exit 1\n"
      <> "    printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nPrepare the combined work for execution.\\n## Scope\\n- Alpha task\\n- Beta task\\n## Constraints\\n- Keep the brief cumulative.\\n## Deliverables\\n- Alpha implementation plan\\n- Beta implementation plan\\n## Acceptance Criteria\\n- Alpha task documented\\n- Beta task documented\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "    exit 0\n"
      <> "  fi\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nPrepare the first work item for execution.\\n## Scope\\n- Alpha task\\n## Constraints\\n- Keep the brief cumulative.\\n## Deliverables\\n- Alpha implementation plan\\n## Acceptance Criteria\\n- Alpha task documented\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "  exit 0\n"
      <> "else\n"
      <> "  echo 'completed by fake provider' > IMPLEMENTED.md\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Implemented demo task\",\"files_touched\":[\"IMPLEMENTED.md\"],\"demo_evidence\":[\"IMPLEMENTED.md created\"],\"pr\":{\"title\":\"[night-shift] Implement demo task\",\"summary\":\"Implemented the fake provider task.\",\"demo\":[\"IMPLEMENTED.md created\"],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

fn write_fake_codex(path: String) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" != \"exec\" ]; then\n"
      <> "  printf 'unexpected codex subcommand: %s\\n' \"$1\" >&2\n"
      <> "  exit 1\n"
      <> "fi\n"
      <> "shift\n"
      <> "while [ $# -gt 0 ]; do\n"
      <> "  case \"$1\" in\n"
      <> "    --skip-git-repo-check|--dangerously-bypass-approvals-and-sandbox)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "    --sandbox)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -C)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -m)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -c)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -)\n"
      <> "      INPUT=$(cat)\n"
      <> "      printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\n'\n"
      <> "      if printf '%s' \"$INPUT\" | grep -q 'add a hello script'; then\n"
      <> "        printf 'Add the hello script.\\n'\n"
      <> "      else\n"
      <> "        printf 'Missing notes.\\n'\n"
      <> "      fi\n"
      <> "      printf '## Scope\\n- Add a hello script.\\n## Constraints\\n- Keep scope tight.\\n## Deliverables\\n- hello script\\n## Acceptance Criteria\\n- script exists\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "      exit 0\n"
      <> "      ;;\n"
      <> "    *)\n"
      <> "      printf 'expected prompt on stdin, got positional argument: %s\\n' \"$1\" >&2\n"
      <> "      exit 7\n"
      <> "      ;;\n"
      <> "  esac\n"
      <> "done\n"
      <> "printf 'missing stdin prompt sentinel\\n' >&2\n"
      <> "exit 8\n",
    to: path,
  )
}

fn restore_env(name: String, value: String) -> Nil {
  case value {
    "" -> system.unset_env(name)
    _ -> system.set_env(name, value)
  }
}

fn wait_for_run_payload(
  base_url: String,
  run_id: String,
  attempts: Int,
) -> String {
  let url = base_url <> "/api/runs/" <> run_id
  case attempts {
    value if value <= 0 ->
      dashboard.http_get(url)
      |> result.unwrap(or: "Unable to fetch dashboard payload.")
    _ ->
      case dashboard.http_get(url) {
        Ok(payload) ->
          case
            string.contains(does: payload, contain: "\"status\":\"completed\"")
          {
            True -> payload
            False -> {
              system.sleep(150)
              wait_for_run_payload(base_url, run_id, attempts - 1)
            }
          }
        Error(_) -> {
          system.sleep(150)
          wait_for_run_payload(base_url, run_id, attempts - 1)
        }
      }
  }
}

fn write_fake_gh(path: String) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"list\" ]; then\n"
      <> "  BRANCH=$(git rev-parse --abbrev-ref HEAD)\n"
      <> "  printf '[{\"number\":1,\"url\":\"https://example.test/pr/1\",\"headRefName\":\"%s\",\"title\":\"Night Shift PR\"}]\\n' \"$BRANCH\"\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"edit\" ]; then\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"create\" ]; then\n"
      <> "  printf 'https://example.test/pr/1\\n'\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"view\" ]; then\n"
      <> "  printf '{\"number\":1,\"title\":\"Night Shift PR\",\"body\":\"Review body\",\"headRefName\":\"night-shift/demo\",\"baseRefName\":\"main\",\"url\":\"https://example.test/pr/1\",\"reviewDecision\":\"REVIEW_REQUIRED\",\"statusCheckRollup\":[],\"reviews\":[],\"comments\":[]}'\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "printf 'unsupported gh invocation: %s %s\\n' \"$1\" \"$2\" >&2\n"
      <> "exit 1\n",
    to: path,
  )
}
