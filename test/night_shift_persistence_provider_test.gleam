import filepath
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import night_shift/dashboard
import night_shift/journal
import night_shift/project
import night_shift/provider
import night_shift/shell
import night_shift/system
import night_shift/types
import night_shift_test_support as support
import simplifile

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

  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 2)
  let assert Ok(report_contents) = simplifile.read(run.report_path)
  let assert Ok(state_contents) = simplifile.read(run.state_path)

  assert string.contains(does: report_contents, contain: "Night Shift Report")
  assert string.contains(does: state_contents, contain: "\"run_id\"")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn latest_run_round_trip_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-test-round-trip-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Cursor, 1)
  let assert Ok(#(saved_run, _)) = journal.load(repo_root, types.LatestRun)

  assert saved_run.run_id == run.run_id
  assert saved_run.execution_agent.provider == types.Cursor
  assert result.is_ok(simplifile.delete(file_or_dir_at: base_dir))
}

pub fn review_driven_run_round_trip_with_repo_state_snapshot_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-test-review-state-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")
  let notes_source = types.InlineNotes(filepath.join(base_dir, "notes.md"))
  let planning_provenance = types.ReviewsAndNotes(notes_source)
  let repo_state_snapshot = support.sample_repo_state_snapshot()

  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)

  let assert Ok(run) =
    journal.create_pending_run_with_context(
      repo_root,
      brief_path,
      support.agent_for(types.Codex),
      support.agent_for(types.Codex),
      "",
      1,
      Some(notes_source),
      Some(planning_provenance),
      Some(repo_state_snapshot),
    )
  let assert Ok(#(saved_run, _events)) =
    journal.load(repo_root, types.LatestRun)

  assert saved_run.run_id == run.run_id
  assert saved_run.planning_provenance == Some(planning_provenance)
  assert saved_run.repo_state_snapshot == Some(repo_state_snapshot)

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn reviews_only_run_round_trip_with_null_notes_source_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-test-reviews-only-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")
  let repo_state_snapshot = support.sample_repo_state_snapshot()

  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)

  let assert Ok(run) =
    journal.create_pending_run_with_context(
      repo_root,
      brief_path,
      support.agent_for(types.Codex),
      support.agent_for(types.Codex),
      "",
      1,
      None,
      Some(types.ReviewsOnly),
      Some(repo_state_snapshot),
    )
  let assert Ok(#(saved_run, _events)) =
    journal.load(repo_root, types.LatestRun)

  assert saved_run.run_id == run.run_id
  assert saved_run.notes_source == None
  assert saved_run.planning_provenance == Some(types.ReviewsOnly)
  assert saved_run.repo_state_snapshot == Some(repo_state_snapshot)

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn latest_run_ignores_incomplete_newer_directory_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-test-ignore-incomplete-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")
  let incomplete_run_path = filepath.join(project.runs_root(repo_root), "zzzz")

  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(_) =
    simplifile.create_directory_all(filepath.join(incomplete_run_path, "logs"))
  let assert Ok(_) =
    simplifile.write(
      "# Partial brief",
      to: filepath.join(incomplete_run_path, "brief.md"),
    )

  let assert Ok(#(saved_run, _events)) =
    journal.load(repo_root, types.LatestRun)
  let assert Ok(runs) = journal.list_runs(repo_root)

  assert saved_run.run_id == run.run_id
  assert list.length(runs) == 1

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn list_runs_returns_newest_first_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
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
    support.start_run(repo_root, brief_a, types.Codex, 1)
  let assert Ok(_) = journal.mark_status(first_run, types.RunCompleted, "done")
  let assert Ok(second_run) =
    support.start_run(repo_root, brief_b, types.Cursor, 2)
  let assert Ok(runs) = journal.list_runs(repo_root)

  let assert [latest, previous, ..] = runs
  assert latest.run_id == second_run.run_id
  assert previous.run_id == first_run.run_id

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn dashboard_payloads_include_run_data_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-test-dashboard-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 1)
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

pub fn dashboard_payloads_include_setup_recovery_context_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-dashboard-recovery-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
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
            id: "demo-task",
            title: "Demo task",
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
  let assert Ok(run_payload) = dashboard.run_json(repo_root, run.run_id)

  assert string.contains(does: run_payload, contain: "\"recovery_blocker\"")
  assert string.contains(
    does: run_payload,
    contain: "\"kind\":\"environment_preflight\"",
  )
  assert string.contains(
    does: run_payload,
    contain: "\"replacement_pr_numbers\":[36,37]",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn dashboard_recovery_action_continue_updates_run_state_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-dashboard-recovery-action-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  support.seed_git_repo(repo_root, base_dir)
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 1)
  let blocked_run =
    types.RunRecord(
      ..run,
      status: types.RunBlocked,
      recovery_blocker: Some(types.RecoveryBlocker(
        kind: types.EnvironmentPreflightBlocker,
        phase: types.PreflightPhase,
        task_id: None,
        message: "missing-tool setup",
        log_path: filepath.join(run.run_path, "logs/environment-preflight.log"),
        no_changes_produced: True,
        disposition: types.RecoveryBlocking,
      )),
    )
  let assert Ok(_) = journal.rewrite_run(blocked_run)
  let assert Ok(summary) =
    dashboard.apply_recovery_action(repo_root, run.run_id, "continue")
  let assert Ok(#(updated_run, events)) =
    journal.load(repo_root, types.RunId(run.run_id))

  assert string.contains(
    does: summary,
    contain: "Next action: night-shift start",
  )
  assert updated_run.status == types.RunPending
  assert updated_run.recovery_blocker
    == Some(types.RecoveryBlocker(
      kind: types.EnvironmentPreflightBlocker,
      phase: types.PreflightPhase,
      task_id: None,
      message: "missing-tool setup",
      log_path: filepath.join(run.run_path, "logs/environment-preflight.log"),
      no_changes_produced: True,
      disposition: types.RecoveryWaivedOnce,
    ))
  assert list.any(events, fn(event) { event.kind == "setup_recovery_approved" })

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn dashboard_server_serves_run_data_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-test-dashboard-server-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(run) = support.start_run(repo_root, brief_path, types.Codex, 1)
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

pub fn sanitize_json_payload_recovers_trailing_junk_test() {
  let payload =
    "{\"status\":\"completed\",\"summary\":\"ok\",\"files_touched\":[],\"demo_evidence\":[],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[]}}\n"

  let assert Ok(sanitized) = provider.sanitize_json_payload(payload)
  assert string.trim(sanitized)
    == "{\"status\":\"completed\",\"summary\":\"ok\",\"files_touched\":[],\"demo_evidence\":[],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[]}"
}

pub fn extract_payload_from_codex_json_stream_test() {
  let output =
    "{\"type\":\"thread.started\",\"thread_id\":\"demo\"}\n"
    <> "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"Running a quick check before returning the result.\"}}\n"
    <> "{\"type\":\"item.started\",\"item\":{\"id\":\"item_1\",\"type\":\"command_execution\",\"command\":\"/bin/zsh -lc pwd\",\"aggregated_output\":\"\",\"exit_code\":null,\"status\":\"in_progress\"}}\n"
    <> "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_1\",\"type\":\"command_execution\",\"command\":\"/bin/zsh -lc pwd\",\"aggregated_output\":\"/tmp/demo\\n\",\"exit_code\":0,\"status\":\"completed\"}}\n"
    <> "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_2\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n{\\\"status\\\":\\\"completed\\\",\\\"summary\\\":\\\"ok\\\",\\\"files_touched\\\":[],\\\"demo_evidence\\\":[],\\\"pr\\\":{\\\"title\\\":\\\"t\\\",\\\"summary\\\":\\\"s\\\",\\\"demo\\\":[],\\\"risks\\\":[]},\\\"follow_up_tasks\\\":[]}\\nNIGHT_SHIFT_RESULT_END\"}}\n"

  let assert Ok(payload) = provider.extract_payload(output)
  assert string.contains(does: payload, contain: "\"status\":\"completed\"")
  assert string.contains(does: payload, contain: "\"summary\":\"ok\"")
}

pub fn extract_payload_from_cursor_stream_json_test() {
  let output =
    "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"demo\"}\n"
    <> "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Working...\"}]},\"session_id\":\"demo\",\"timestamp_ms\":1}\n"
    <> "{\"type\":\"tool_call\",\"subtype\":\"started\",\"call_id\":\"tool_1\",\"tool_call\":{\"shellToolCall\":{\"args\":{\"command\":\"pwd\"},\"description\":\"Print current working directory\"}},\"session_id\":\"demo\"}\n"
    <> "{\"type\":\"tool_call\",\"subtype\":\"completed\",\"call_id\":\"tool_1\",\"tool_call\":{\"shellToolCall\":{\"args\":{\"command\":\"pwd\"},\"result\":{\"success\":{\"exitCode\":0,\"interleavedOutput\":\"/tmp/demo\\n\"}},\"description\":\"Print current working directory\"}},\"session_id\":\"demo\"}\n"
    <> "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"`pwd` returned `/tmp/demo`.\\n\\nNIGHT_SHIFT_RESULT_START {\\\"status\\\":\\\"completed\\\",\\\"summary\\\":\\\"ok\\\",\\\"files_touched\\\":[],\\\"demo_evidence\\\":[],\\\"pr\\\":{\\\"title\\\":\\\"t\\\",\\\"summary\\\":\\\"s\\\",\\\"demo\\\":[],\\\"risks\\\":[]},\\\"follow_up_tasks\\\":[]} NIGHT_SHIFT_RESULT_END\",\"session_id\":\"demo\"}\n"

  let assert Ok(payload) = provider.extract_payload(output)
  assert string.contains(does: payload, contain: "\"status\":\"completed\"")
  assert string.contains(does: payload, contain: "\"summary\":\"ok\"")
}

pub fn plan_command_non_tty_streaming_stays_plain_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-plain-stream-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let fake_codex = filepath.join(bin_dir, "codex")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_state_home = system.get_env("XDG_STATE_HOME")
  let old_stream_ui = system.get_env("NIGHT_SHIFT_STREAM_UI")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_fake_streaming_codex(fake_codex)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_codex),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let assert Ok(_) =
    simplifile.write("# Notes\n- polish the stream UI\n", to: notes_path)

  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)
  system.set_env("NIGHT_SHIFT_STREAM_UI", "auto")
  system.unset_env("NIGHT_SHIFT_FAKE_PROVIDER")

  let result =
    support.run_local_cli_command(
      ["plan", "--notes", notes_path, "--provider", "codex"],
      repo_root,
      filepath.join(base_dir, "plan.log"),
    )

  system.set_env("PATH", old_path)
  support.restore_env("XDG_STATE_HOME", old_state_home)
  support.restore_env("NIGHT_SHIFT_STREAM_UI", old_stream_ui)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)

  let assert Ok(output) = result
  assert !string.contains(does: output, contain: "\u{001b}")
  assert string.contains(does: output, contain: "[brief] prompt hidden; see ")
  assert string.contains(does: output, contain: "Planned run ")
  assert !string.contains(
    does: output,
    contain: "You are Night Shift's planning provider.",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn plan_command_streaming_handles_utf8_tool_output_truncation_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-utf8-stream-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let fake_codex = filepath.join(bin_dir, "codex")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_state_home = system.get_env("XDG_STATE_HOME")
  let old_stream_ui = system.get_env("NIGHT_SHIFT_STREAM_UI")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_fake_streaming_utf8_codex(fake_codex)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_codex),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let assert Ok(_) =
    simplifile.write("# Notes\n- add a hello script\n", to: notes_path)

  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)
  system.set_env("NIGHT_SHIFT_STREAM_UI", "auto")
  system.unset_env("NIGHT_SHIFT_FAKE_PROVIDER")

  let result =
    support.run_local_cli_command(
      ["plan", "--notes", notes_path, "--provider", "codex"],
      repo_root,
      filepath.join(base_dir, "plan.log"),
    )

  system.set_env("PATH", old_path)
  support.restore_env("XDG_STATE_HOME", old_state_home)
  support.restore_env("NIGHT_SHIFT_STREAM_UI", old_stream_ui)
  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)

  let assert Ok(output) = result
  assert string.contains(does: output, contain: "Planned run ")
  assert !string.contains(does: output, contain: "runtime error")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn plan_command_tty_streaming_restores_alt_screen_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-tui-stream-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let fake_codex = filepath.join(bin_dir, "codex")
  let state_home = filepath.join(base_dir, "state")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = support.initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = support.write_fake_streaming_codex(fake_codex)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_codex),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let assert Ok(_) =
    simplifile.write("# Notes\n- polish the stream UI\n", to: notes_path)

  let command =
    "cd "
    <> shell.quote(repo_root)
    <> " && "
    <> "PATH="
    <> shell.quote(bin_dir <> ":" <> system.get_env("PATH"))
    <> " XDG_STATE_HOME="
    <> shell.quote(state_home)
    <> " NIGHT_SHIFT_FAKE_PROVIDER="
    <> shell.quote("")
    <> " NIGHT_SHIFT_REPO_ROOT="
    <> shell.quote(repo_root)
    <> " NIGHT_SHIFT_STREAM_UI=tui "
    <> support.local_demo_command()
    <> " plan --notes "
    <> shell.quote(notes_path)
    <> " --provider codex"
  let output =
    shell.run(
      support.script_capture_command(command),
      repo_root,
      filepath.join(base_dir, "tty-plan.log"),
    )

  let assert True = shell.succeeded(output)
  assert string.contains(does: output.output, contain: "\u{001b}[?1049h")
  assert string.contains(does: output.output, contain: "\u{001b}[?1049l")

  support.restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn plan_document_handles_large_structured_json_line_test() {
  let unique = system.unique_id()
  let base_dir =
    support.absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-large-stream-" <> unique,
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
  let assert Ok(_) = support.write_large_streaming_codex(fake_codex)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_codex),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  let assert Ok(_) =
    simplifile.write(
      "# Notes\n- capture a very large brief section\n",
      to: notes_path,
    )

  system.unset_env("NIGHT_SHIFT_FAKE_PROVIDER")
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)

  let result =
    provider.plan_document(
      types.resolved_agent_from_provider(types.Codex),
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
  assert string.contains(does: document, contain: "Large streaming payload")
  assert string.contains(does: document, contain: "AAAAAAAAAAAAAAAA")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}
