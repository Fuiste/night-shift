import filepath
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import night_shift/agent_config
import night_shift/cli
import night_shift/config
import night_shift/dashboard
import night_shift/demo
import night_shift/journal
import night_shift/orchestrator
import night_shift/provider
import night_shift/project
import night_shift/shell
import night_shift/system
import night_shift/types
import night_shift/worktree_setup
import simplifile

pub fn main() -> Nil {
  let options = [
    Verbose,
    NoTty,
    Report(#(GleeunitProgress, [Colored(True)])),
    ScaleTimeouts(30),
  ]

  let result =
    find_test_files(matching: "**/*.{erl,gleam}", in: "test")
    |> list.map(gleam_to_erlang_module_name)
    |> list.map(dangerously_convert_string_to_atom(_, Utf8))
    |> run_eunit(options)

  let code = case result {
    Ok(_) -> 0
    Error(_) -> 1
  }
  halt(code)
}

type Atom

type Encoding {
  Utf8
}

type ReportModuleName {
  GleeunitProgress
}

type GleeunitProgressOption {
  Colored(Bool)
}

type EunitOption {
  Verbose
  NoTty
  Report(#(ReportModuleName, List(GleeunitProgressOption)))
  ScaleTimeouts(Int)
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "erlang", "binary_to_atom")
fn dangerously_convert_string_to_atom(value: String, encoding: Encoding) -> Atom

@external(erlang, "gleeunit_ffi", "find_files")
fn find_test_files(matching matching: String, in in: String) -> List(String)

@external(erlang, "gleeunit_ffi", "run_eunit")
fn run_eunit(modules: List(Atom), options: List(EunitOption)) -> Result(Nil, a)

fn gleam_to_erlang_module_name(path: String) -> String {
  case string.ends_with(path, ".gleam") {
    True ->
      path
      |> string.replace(".gleam", "")
      |> string.replace("/", "@")

    False ->
      path
      |> string.split("/")
      |> list.last
      |> result.unwrap(path)
      |> string.replace(".erl", "")
  }
}

pub fn parse_start_command_test() {
  let assert Ok(types.Start(types.RunId("run-123"), False)) =
    cli.parse(["start", "--run", "run-123"])
}

pub fn parse_init_command_test() {
  let assert Ok(types.Init(agent_overrides, True, True)) =
    cli.parse([
      "init",
      "--provider",
      "cursor",
      "--generate-setup",
      "--yes",
    ])

  assert agent_overrides.provider == Some(types.Cursor)
}

pub fn parse_reset_command_test() {
  let assert Ok(types.Reset(True, True)) =
    cli.parse(["reset", "--yes", "--force"])
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
  let assert Ok(types.Start(types.LatestRun, True)) =
    cli.parse(["start", "--ui"])
}

pub fn parse_start_command_without_brief_test() {
  let assert Ok(types.Start(types.LatestRun, False)) = cli.parse(["start"])
}

pub fn parse_plan_requires_notes_test() {
  let assert Error(message) = cli.parse(["plan"])
  assert message == "The plan command requires --notes <file-or-inline-text>."
}

pub fn parse_resolve_defaults_to_latest_test() {
  let assert Ok(types.Resolve(types.LatestRun)) = cli.parse(["resolve"])
}

pub fn parse_resume_command_with_ui_test() {
  let assert Ok(types.Resume(types.RunId("run-123"), True)) =
    cli.parse(["resume", "--run", "run-123", "--ui"])
}

pub fn parse_resume_rejects_environment_flag_test() {
  let assert Error(message) =
    cli.parse(["resume", "--environment", "dev"])
  assert message == "Unsupported flag: --environment"
}

pub fn parse_review_command_with_environment_test() {
  let assert Ok(types.Review(agent_overrides, Some("dev"))) =
    cli.parse(["review", "--environment", "dev"])
  assert agent_overrides == types.empty_agent_overrides()
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

pub fn parse_empty_worktree_setup_rejected_test() {
  let assert Error(message) = worktree_setup.parse("")
  assert string.contains(does: message, contain: "empty")
}

pub fn parse_multiline_worktree_command_lists_test() {
  let source =
    "version = 1\n"
    <> "default_environment = \"default\"\n\n"
    <> "[environments.default.env]\n"
    <> "HUSKY = \"0\"\n\n"
    <> "[environments.default.setup]\n"
    <> "default = [\n"
    <> "  \"pnpm install --frozen-lockfile\",\n"
    <> "]\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n\n"
    <> "[environments.default.maintenance]\n"
    <> "default = [\n"
    <> "  \"pnpm run lint\",\n"
    <> "  \"pnpm run test\",\n"
    <> "]\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n"

  let assert Ok(parsed) = worktree_setup.parse(source)
  let assert Ok(environment) = worktree_setup.find_environment(parsed, "default")

  assert environment.env_vars == [#("HUSKY", "0")]
  assert environment.setup.default == ["pnpm install --frozen-lockfile"]
  assert environment.maintenance.default
    == ["pnpm run lint", "pnpm run test"]
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

pub fn default_profile_is_phase_fallback_test() {
  let source =
    "default_profile = \"reviewer\"\n"
    <> "[profiles.reviewer]\n"
    <> "provider = \"cursor\"\n"

  let assert Ok(parsed) = config.parse(source)
  let assert Ok(planning_agent) =
    agent_config.resolve_plan_agent(parsed, types.empty_agent_overrides())
  let assert Ok(#(_planning_agent, execution_agent)) =
    agent_config.resolve_start_agents(parsed, types.empty_agent_overrides())
  let assert Ok(review_agent) =
    agent_config.resolve_review_agent(parsed, types.empty_agent_overrides())

  assert planning_agent.profile_name == "reviewer"
  assert planning_agent.provider == types.Cursor
  assert execution_agent.profile_name == "reviewer"
  assert review_agent.profile_name == "reviewer"
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

  let assert Ok(first_run) = start_run(repo_root, brief_a, types.Codex, 1)
  let assert Ok(_) = journal.mark_status(first_run, types.RunCompleted, "done")
  let assert Ok(second_run) = start_run(repo_root, brief_b, types.Cursor, 2)
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
    absolute_path(filepath.join(
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

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = write_fake_streaming_codex(fake_codex)
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

  let result =
    run_local_cli_command(
      ["plan", "--notes", notes_path, "--provider", "codex"],
      repo_root,
      filepath.join(base_dir, "plan.log"),
    )

  system.set_env("PATH", old_path)
  restore_env("XDG_STATE_HOME", old_state_home)
  restore_env("NIGHT_SHIFT_STREAM_UI", old_stream_ui)

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
    absolute_path(filepath.join(
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

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = write_fake_streaming_utf8_codex(fake_codex)
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

  let result =
    run_local_cli_command(
      ["plan", "--notes", notes_path, "--provider", "codex"],
      repo_root,
      filepath.join(base_dir, "plan.log"),
    )

  system.set_env("PATH", old_path)
  restore_env("XDG_STATE_HOME", old_state_home)
  restore_env("NIGHT_SHIFT_STREAM_UI", old_stream_ui)

  let assert Ok(output) = result
  assert string.contains(does: output, contain: "Planned run ")
  assert !string.contains(does: output, contain: "runtime error")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn plan_command_tty_streaming_restores_alt_screen_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-tui-stream-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let notes_path = filepath.join(base_dir, "notes.md")
  let fake_codex = filepath.join(bin_dir, "codex")
  let state_home = filepath.join(base_dir, "state")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = write_fake_streaming_codex(fake_codex)
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
    <> " NIGHT_SHIFT_REPO_ROOT="
    <> shell.quote(repo_root)
    <> " NIGHT_SHIFT_STREAM_UI=tui "
    <> local_demo_command()
    <> " plan --notes "
    <> shell.quote(notes_path)
    <> " --provider codex"
  let output =
    shell.run(
      script_capture_command(command),
      repo_root,
      filepath.join(base_dir, "tty-plan.log"),
    )

  let assert True = shell.succeeded(output)
  assert string.contains(does: output.output, contain: "\u{001b}[?1049h")
  assert string.contains(does: output.output, contain: "\u{001b}[?1049l")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn plan_document_handles_large_structured_json_line_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
  let assert Ok(_) = write_large_streaming_codex(fake_codex)
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
      types.NotesFile(notes_path),
      doc_path,
    )

  system.set_env("PATH", old_path)
  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(#(document, _artifact_path, _notes_source)) = result
  assert string.contains(does: document, contain: "# Night Shift Brief")
  assert string.contains(does: document, contain: "Large streaming payload")
  assert string.contains(does: document, contain: "AAAAAAAAAAAAAAAA")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
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
  let assert Ok(_) = initialize_project_home(repo_root)
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
    contain: "No open Night Shift run was found.",
  )
  assert string.contains(
    does: message,
    contain: "night-shift plan --notes",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn start_requires_init_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
    contain: "Night Shift is not initialized for this repository",
  )
  assert string.contains(does: message, contain: "night-shift init")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn init_writes_selected_provider_and_model_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
    run_local_cli_command(
      ["init", "--provider", "cursor", "--model", "composer-2-fast", "--yes"],
      repo_root,
      filepath.join(base_dir, "init.log"),
    )

  let assert Ok(message) = output
  let assert Ok(config_contents) = simplifile.read(project.config_path(repo_root))

  assert string.contains(does: message, contain: "Initialized")
  assert string.contains(does: config_contents, contain: "provider = \"cursor\"")
  assert string.contains(
    does: config_contents,
    contain: "model = \"composer-2-fast\"",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn init_requires_provider_outside_interactive_terminal_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
    run_local_cli_command(
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
    absolute_path(filepath.join(
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
    run_local_cli_command(
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

pub fn start_rejects_dirty_source_repo_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-start-dirty-source-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let state_home = filepath.join(base_dir, "state")
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = initialize_project_home(repo_root)
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
      agent_for(types.Codex),
      agent_for(types.Codex),
      "",
      1,
      None,
    )
  let assert Ok(_) =
    simplifile.write(
      "# Demo\nDirty\n",
      to: filepath.join(repo_root, "README.md"),
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
    contain: "Night Shift start requires a clean source repository",
  )
  assert string.contains(does: message, contain: repo_root)

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
  let default_doc = project.default_brief_path(repo_root)
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = initialize_project_home(repo_root)
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

  assert string.contains(does: first_output, contain: "Planned run ")
  assert string.contains(
    does: second_output,
    contain: "Planned run ",
  )
  assert string.contains(does: document, contain: "Alpha task")
  assert string.contains(does: document, contain: "Beta task")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn blocked_plan_status_and_report_show_decisions_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = write_resolve_loop_fake_provider(fake_provider)
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
    run_local_cli_command(
      ["plan", "--notes", notes_path],
      repo_root,
      filepath.join(base_dir, "plan.log"),
    )
  let status_result =
    run_local_cli_command(
      ["status"],
      repo_root,
      filepath.join(base_dir, "status.log"),
    )
  let assert Ok(#(run, _events)) = journal.load(repo_root, types.LatestRun)
  let assert Ok(report_contents) = simplifile.read(run.report_path)

  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(plan_output) = plan_result
  let assert Ok(status_output) = status_result

  assert string.contains(does: plan_output, contain: "Planned run ")
  assert string.contains(does: status_output, contain: "is blocked")
  assert string.contains(does: status_output, contain: "Blocked tasks: 1")
  assert string.contains(does: status_output, contain: "Outstanding decisions: 1")
  assert string.contains(
    does: status_output,
    contain: "Ready implementation tasks: 0",
  )
  assert string.contains(does: status_output, contain: "Next action: night-shift resolve")
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
    absolute_path(filepath.join(
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
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = write_resolve_loop_fake_provider(fake_provider)
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
    run_local_cli_command(
      ["plan", "--notes", notes_path],
      repo_root,
      filepath.join(base_dir, "plan.log"),
    )
  let resolve_result =
    run_local_cli_tty_command_with_input(
      ["resolve"],
      "\n\n",
      repo_root,
      filepath.join(base_dir, "resolve.log"),
    )
  let status_result =
    run_local_cli_command(
      ["status"],
      repo_root,
      filepath.join(base_dir, "status.log"),
    )
  let assert Ok(#(run, _events)) = journal.load(repo_root, types.LatestRun)
  let assert Ok(events_contents) = simplifile.read(run.events_path)

  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("XDG_STATE_HOME", old_state_home)

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
    absolute_path(filepath.join(
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
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = write_resolve_loop_fake_provider(fake_provider)
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
    run_local_cli_command(
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
    run_local_cli_tty_command_with_input(
      ["resolve"],
      "\n",
      repo_root,
      filepath.join(base_dir, "resolve.log"),
    )
  let assert Ok(#(updated_run, _events)) = journal.load(repo_root, types.LatestRun)

  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("XDG_STATE_HOME", old_state_home)

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
    absolute_path(filepath.join(
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
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = write_resolve_loop_fake_provider(fake_provider)
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
    run_local_cli_command(
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
    run_local_cli_command(
      ["status"],
      repo_root,
      filepath.join(base_dir, "status.log"),
    )
  let start_result =
    run_local_cli_command(
      ["start"],
      repo_root,
      filepath.join(base_dir, "start.log"),
    )
  let assert Ok(report_contents) =
    simplifile.read(filepath.join(stale_run.run_path, "report.md"))

  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(status_output) = status_result
  let assert Ok(start_output) = start_result

  assert string.contains(does: status_output, contain: "Blocked tasks: 1")
  assert string.contains(does: status_output, contain: "Outstanding decisions: 0")
  assert string.contains(does: status_output, contain: "Planning sync pending: yes")
  assert string.contains(does: status_output, contain: "Next action: night-shift resolve")
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
    contain: "- Manual-attention tasks: 0",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn start_dirty_night_shift_control_files_do_not_block_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = write_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  seed_git_repo(repo_root, base_dir)
  let assert Ok(_) =
    simplifile.write("Add a docs page.\n", to: notes_path)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("XDG_STATE_HOME", state_home)

  let _ =
    run_local_cli_command(
      ["plan", "--notes", notes_path],
      repo_root,
      filepath.join(base_dir, "plan.log"),
    )
  let assert Ok(_) = simplifile.write(
    worktree_setup.default_template(),
    to: project.worktree_setup_path(repo_root),
  )
  let start_result =
    run_local_cli_command(
      ["start"],
      repo_root,
      filepath.join(base_dir, "start.log"),
    )

  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("XDG_STATE_HOME", old_state_home)

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
    absolute_path(filepath.join(
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
  let assert Ok(_) = initialize_project_home(repo_root)
  seed_git_repo(repo_root, base_dir)
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
      agent_for(types.Codex),
      agent_for(types.Codex),
      "",
      1,
      None,
    )
  let run_with_worktree =
    types.RunRecord(
      ..run,
      tasks: [
        types.Task(
          id: "demo-task",
          title: "Demo task",
          description: "Demo",
          dependencies: [],
          acceptance: [],
          demo_plan: [],
          decision_requests: [],
          kind: types.ImplementationTask,
          execution_mode: types.Serial,
          state: types.Ready,
          worktree_path: worktree_path,
          branch_name: "night-shift/reset-demo",
          pr_number: "",
          summary: "",
        ),
      ],
    )
  let assert Ok(_) = journal.rewrite_run(run_with_worktree)

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", local_demo_command())
  system.set_env("XDG_STATE_HOME", state_home)

  let reset_result =
    run_local_cli_command(
      ["reset", "--yes"],
      repo_root,
      filepath.join(base_dir, "reset.log"),
    )

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(reset_output) = reset_result

  assert string.contains(does: reset_output, contain: "Night Shift reset complete")
  assert simplifile.read_directory(at: project.home(repo_root))
    |> result.is_error
  assert simplifile.read_directory(at: worktree_path)
    |> result.is_error

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
  let default_doc = project.default_brief_path(repo_root)
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = initialize_project_home(repo_root)
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
    provider.plan_document(
      agent_for(types.Codex),
      repo_root,
      types.NotesFile(notes_path),
      doc_path,
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
    absolute_path(filepath.join(
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
    provider.plan_document(
      agent_for(types.Codex),
      repo_root,
      types.NotesFile(notes_path),
      doc_path,
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
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-worktree-setup-empty-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let bin_dir = filepath.join(base_dir, "bin")
  let fake_codex = filepath.join(bin_dir, "codex")
  let output_path =
    filepath.join(repo_root, ".night-shift/worktree-setup.toml")
  let state_home = filepath.join(base_dir, "state")
  let old_path = system.get_env("PATH")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = write_empty_worktree_setup_codex(fake_codex)
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
      agent_for(types.Codex),
      repo_root,
      output_path,
    )

  system.set_env("PATH", old_path)
  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  system.set_env("XDG_STATE_HOME", old_state_home)

  let assert Error(message) = result
  assert string.contains(
    does: message,
    contain: "empty file",
  )

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
  let assert Ok(_) = write_fake_codex(fake_codex)
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
      agent_for(types.Codex),
      repo_root,
      types.NotesFile(notes_path),
      doc_path,
    )

  system.set_env("PATH", old_path)
  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(#(document, _artifact_path, _notes_source)) = result
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

  let assert Ok(run) = planned_run(repo_root, brief_path, types.Codex, 1)
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
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
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

pub fn orchestrator_start_delivers_provider_created_commit_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = write_committing_fake_provider(fake_provider)
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

  let assert Ok(run) = planned_run(repo_root, brief_path, types.Codex, 1)
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
      decision_requests: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Failed,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
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
    absolute_path(filepath.join(
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
  let assert Ok(_) = write_worktree_execution_codex(fake_codex)
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
    )
  let assert Ok(result) = provider.await_task(task_run)

  system.set_env("PATH", old_path)
  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)

  let assert Ok(contents) =
    simplifile.read(filepath.join(worktree_path, "EXECUTED.txt"))
  assert result.status == types.Completed
  assert string.contains(does: contents, contain: "executed in worktree")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn provider_await_task_recovers_trailing_junk_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
  let assert Ok(_) = simplifile.create_directory_all(filepath.join(run_path, "logs"))
  let assert Ok(_) = simplifile.create_directory_all(worktree_path)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = write_recoverable_execution_fake_provider(fake_provider)
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
    )
  let assert Ok(result) = provider.await_task(task_run)

  system.set_env("PATH", old_path)
  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)

  let assert Ok(raw_payload) =
    simplifile.read(filepath.join(
      run_path,
      "logs/demo-task.result.raw.jsonish",
    ))
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

pub fn orchestrator_start_blocks_manual_attention_before_bootstrap_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = write_manual_attention_fake_provider(fake_provider)
  let assert Ok(_) = write_test_worktree_setup(
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
  seed_git_repo(repo_root, base_dir)

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
    planned_run_in_environment(
      repo_root,
      brief_path,
      types.Codex,
      "default",
      1,
    )
  let assert Ok(blocked_run) = orchestrator.start(run, config)

  system.set_env("PATH", old_path)
  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("XDG_STATE_HOME", old_state_home)

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
      summary: "",
    ))
  let assert Ok(events) = simplifile.read(blocked_run.events_path)

  assert blocked_run.status == types.RunBlocked
  assert string.contains(
    does: blocked_task.summary,
    contain: "no worktree bootstrap or provider execution started",
  )
  assert string.contains(does: events, contain: "\"kind\":\"task_manual_attention\"")
  assert string.contains(does: events, contain: "\"kind\":\"task_started\"")
    == False
  assert simplifile.read(
    filepath.join(blocked_run.run_path, "logs/" <> blocked_task.id <> ".env.log"),
  )
    |> result.is_error

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_fails_environment_preflight_before_task_launch_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = write_fake_provider(fake_provider)
  let assert Ok(_) = write_test_worktree_setup(
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
  seed_git_repo(repo_root, base_dir)

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
    planned_run_in_environment(
      repo_root,
      brief_path,
      types.Codex,
      "default",
      1,
    )
  let assert Ok(failed_run) = orchestrator.start(run, config)

  system.set_env("PATH", old_path)
  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("XDG_STATE_HOME", old_state_home)

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
  assert string.contains(
    does: report_contents,
    contain: "## Failure",
  )
  assert string.contains(
    does: report_contents,
    contain: "environment bootstrap",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn environment_preflight_uses_explicit_bootstrap_requirements_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-preflight-generic-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let setup_path = project.worktree_setup_path(repo_root)
  let log_path = filepath.join(base_dir, "preflight.log")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = write_test_worktree_setup_with_preflight(
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
  assert string.contains(does: preflight_contents, contain: "[preflight] executable=sh")
  assert string.contains(does: preflight_contents, contain: "missing-tool") == False

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn environment_preflight_defaults_to_first_setup_executable_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
      system.state_directory(),
      "night-shift-preflight-default-" <> unique,
    ))
  let repo_root = filepath.join(base_dir, "repo")
  let setup_path = project.worktree_setup_path(repo_root)
  let log_path = filepath.join(base_dir, "preflight.log")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(repo_root)
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = write_test_worktree_setup(
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
  assert string.contains(does: preflight_contents, contain: "[preflight] executable=sh")
  assert string.contains(does: preflight_contents, contain: "missing-tool") == False

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_reports_setup_phase_failures_after_preflight_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = write_fake_provider(fake_provider)
  let assert Ok(_) = write_test_worktree_setup_with_preflight(
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
  seed_git_repo(repo_root, base_dir)

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
    planned_run_in_environment(
      repo_root,
      brief_path,
      types.Codex,
      "default",
      1,
    )
  let assert Ok(failed_run) = orchestrator.start(run, config)

  system.set_env("PATH", old_path)
  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(events) = simplifile.read(failed_run.events_path)
  let env_log =
    filepath.join(failed_run.run_path, "logs/demo-task.env.log")
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
      summary: "",
    ))

  assert failed_run.status == types.RunFailed
  assert string.contains(does: events, contain: "\"kind\":\"task_started\"")
  assert string.contains(does: events, contain: "\"kind\":\"task_failed\"")
  assert string.contains(
    does: env_contents,
    contain: "(exit 127)",
  )
  assert string.contains(
    does: env_contents,
    contain: "$ missing-tool install",
  )
  assert string.contains(
    does: failed_task.summary,
    contain: "Worktree setup phase failed while running `missing-tool install`",
  )

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_uses_setup_phase_for_new_worktrees_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_state_home = system.get_env("XDG_STATE_HOME")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ =
    simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = write_fake_provider(fake_provider)
  let assert Ok(_) = write_fake_gh(fake_gh)
  let assert Ok(_) = write_test_worktree_setup(
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
  seed_git_repo(repo_root, base_dir)
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

  let assert Ok(run) =
    planned_run_in_environment(
      repo_root,
      brief_path,
      types.Codex,
      "default",
      1,
    )
  let assert Ok(completed_run) = orchestrator.start(run, config)

  system.set_env("PATH", old_path)
  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("XDG_STATE_HOME", old_state_home)

  let assert Ok(env_log) =
    simplifile.read(
      filepath.join(completed_run.run_path, "logs/demo-task.env.log"),
    )

  assert completed_run.status == types.RunCompleted
  assert string.contains(does: env_log, contain: "phase=setup")
  assert string.contains(
    does: env_log,
    contain: "$ printf setup-phase >/dev/null",
  )
  assert string.contains(
    does: env_log,
    contain: "maintenance-phase",
  )
    == False

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_marks_decode_failures_failed_and_clears_lock_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = write_invalid_execution_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  seed_git_repo(repo_root, base_dir)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) = planned_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(active_run) = journal.activate_run(run)
  let assert Ok(failed_run) = orchestrator.start(active_run, config)

  system.set_env("PATH", old_path)
  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("XDG_STATE_HOME", old_state_home)

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
  assert string.contains(
    does: raw_payload,
    contain: "\"follow_up_tasks\":[}",
  )
  let assert Error(_) = simplifile.read(project.active_lock_path(repo_root))

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn orchestrator_start_continues_awaiting_batch_after_decode_failure_test() {
  let unique = system.unique_id()
  let base_dir =
    absolute_path(filepath.join(
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
  let assert Ok(_) = initialize_project_home(repo_root)
  let assert Ok(_) = write_batch_decode_fake_provider(fake_provider)
  let _ =
    shell.run(
      "chmod +x " <> shell.quote(fake_provider),
      base_dir,
      filepath.join(base_dir, "chmod.log"),
    )
  seed_git_repo(repo_root, base_dir)

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("XDG_STATE_HOME", state_home)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 2,
    )

  let assert Ok(run) = planned_run(repo_root, brief_path, types.Codex, 2)
  let assert Ok(active_run) = journal.activate_run(run)
  let assert Ok(failed_run) = orchestrator.start(active_run, config)

  system.set_env("PATH", old_path)
  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("XDG_STATE_HOME", old_state_home)

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

  let assert Ok(run) = planned_run(repo_root, brief_path, types.Codex, 1)
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
  let old_repo_root = system.get_env("NIGHT_SHIFT_REPO_ROOT")
  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", local_demo_command())
  system.unset_env("NIGHT_SHIFT_REPO_ROOT")

  let first_result = demo.run(False)

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  restore_env("NIGHT_SHIFT_REPO_ROOT", old_repo_root)

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
  assert string.contains(does: first_summary, contain: "Artifacts: " <> demo.demo_root())
}

pub fn demo_run_succeeds_with_ui_test() {
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_repo_root = system.get_env("NIGHT_SHIFT_REPO_ROOT")
  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", local_demo_command())
  system.unset_env("NIGHT_SHIFT_REPO_ROOT")

  let result = demo.run(True)

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  restore_env("NIGHT_SHIFT_REPO_ROOT", old_repo_root)

  let _ = simplifile.delete(file_or_dir_at: demo.demo_root())

  let assert Ok(summary) = result

  assert string.contains(
    does: summary,
    contain: "Validated UI flows: plan, start --ui, dashboard payload, status",
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

fn initialize_project_home(repo_root: String) -> Result(Nil, simplifile.FileError) {
  use _ <- result.try(simplifile.create_directory_all(project.home(repo_root)))
  use _ <- result.try(simplifile.write(
    config.render(types.default_config()),
    to: project.config_path(repo_root),
  ))
  simplifile.write(
    "*\n!config.toml\n!worktree-setup.toml\n!.gitignore\n",
    to: project.gitignore_path(repo_root),
  )
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

fn script_capture_command(command: String) -> String {
  case system.os_name() {
    "linux" -> "script -q -c " <> shell.quote(command) <> " /dev/null"
    _ -> "script -q /dev/null sh -lc " <> shell.quote(command)
  }
}

fn run_local_cli_command(
  args: List(String),
  cwd: String,
  log_path: String,
) -> Result(String, String) {
  let command = local_demo_command()
  let result =
    shell.run(
      "cd "
        <> shell.quote(cwd)
        <> " && "
        <> "NIGHT_SHIFT_REPO_ROOT="
        <> shell.quote(cwd)
        <> " "
        <> command
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

fn run_local_cli_tty_command_with_input(
  args: List(String),
  input: String,
  cwd: String,
  log_path: String,
) -> Result(String, String) {
  let command =
    "cd "
    <> shell.quote(cwd)
    <> " && "
    <> "NIGHT_SHIFT_REPO_ROOT="
    <> shell.quote(cwd)
    <> " "
    <> local_demo_command()
    <> " "
    <> {
      args
      |> list.map(shell.quote)
      |> string.join(with: " ")
    }
  let result =
    shell.run(
      "printf %s "
        <> shell.quote(input)
        <> " | "
        <> script_capture_command(command),
      cwd,
      log_path,
    )

  case shell.succeeded(result) {
    True -> Ok(result.output)
    False -> Error("TTY CLI command failed. See " <> log_path <> ".")
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
  start_run_in_environment(repo_root, brief_path, provider_name, "", max_workers)
}

fn planned_run(
  repo_root: String,
  brief_path: String,
  provider_name: types.Provider,
  max_workers: Int,
) -> Result(types.RunRecord, String) {
  planned_run_in_environment(
    repo_root,
    brief_path,
    provider_name,
    "",
    max_workers,
  )
}

fn start_run_in_environment(
  repo_root: String,
  brief_path: String,
  provider_name: types.Provider,
  environment_name: String,
  max_workers: Int,
) -> Result(types.RunRecord, String) {
  journal.start_run(
    repo_root,
    brief_path,
    agent_for(provider_name),
    agent_for(provider_name),
    environment_name,
    max_workers,
  )
}

fn planned_run_in_environment(
  repo_root: String,
  brief_path: String,
  provider_name: types.Provider,
  environment_name: String,
  max_workers: Int,
) -> Result(types.RunRecord, String) {
  use pending_run <- result.try(journal.create_pending_run(
    repo_root,
    brief_path,
    agent_for(provider_name),
    agent_for(provider_name),
    environment_name,
    max_workers,
    None,
  ))
  orchestrator.plan(pending_run)
}

fn seed_git_repo(repo_root: String, base_dir: String) -> Nil {
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
  Nil
}

fn write_test_worktree_setup(
  path: String,
  setup_commands: List(String),
  maintenance_commands: List(String),
) -> Result(Nil, simplifile.FileError) {
  write_test_worktree_setup_with_preflight(
    path,
    [],
    setup_commands,
    maintenance_commands,
  )
}

fn write_test_worktree_setup_with_preflight(
  path: String,
  preflight_commands: List(String),
  setup_commands: List(String),
  maintenance_commands: List(String),
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "version = 1\n"
      <> "default_environment = \"default\"\n\n"
      <> "[environments.default.env]\n\n"
      <> "[environments.default.preflight]\n"
      <> "default = "
      <> render_command_list(preflight_commands)
      <> "\n"
      <> "macos = []\n"
      <> "linux = []\n"
      <> "windows = []\n\n"
      <> "[environments.default.setup]\n"
      <> "default = "
      <> render_command_list(setup_commands)
      <> "\n"
      <> "macos = []\n"
      <> "linux = []\n"
      <> "windows = []\n\n"
      <> "[environments.default.maintenance]\n"
      <> "default = "
      <> render_command_list(maintenance_commands)
      <> "\n"
      <> "macos = []\n"
      <> "linux = []\n"
      <> "windows = []\n",
    to: path,
  )
}

fn render_command_list(commands: List(String)) -> String {
  case commands {
    [] -> "[]"
    _ ->
      "["
      <> string.join(
        list.map(commands, fn(command) { "\"" <> command <> "\"" }),
        with: ", ",
      )
      <> "]"
  }
}

fn write_fake_provider(path: String) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "PROMPT_FILE=$2\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Implement demo task\",\"description\":\"Create a file to prove execution\",\"dependencies\":[],\"acceptance\":[\"Create IMPLEMENTED.md\"],\"demo_plan\":[\"Show the new file\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
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

fn write_recoverable_execution_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Recoverable task\",\"description\":\"Recover a malformed payload.\",\"dependencies\":[],\"acceptance\":[\"Recover the execution payload.\"],\"demo_plan\":[\"Show the recovered result.\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Recovered demo task\",\"files_touched\":[],\"demo_evidence\":[\"Recovered from trailing junk\"],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[]}}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

fn write_invalid_execution_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Invalid result task\",\"description\":\"Return an invalid execution payload.\",\"dependencies\":[],\"acceptance\":[\"Night Shift reports a decode failure.\"],\"demo_plan\":[\"Inspect the task failure.\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Broken payload\",\"files_touched\":[],\"demo_evidence\":[],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

fn write_batch_decode_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "PROMPT_FILE=$2\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"bad-task\",\"title\":\"Bad task\",\"description\":\"Return malformed JSON.\",\"dependencies\":[],\"acceptance\":[\"Night Shift marks this failed.\"],\"demo_plan\":[\"Inspect bad-task.\"],\"execution_mode\":\"parallel\"},{\"id\":\"fail-task\",\"title\":\"Fail task\",\"description\":\"Return a valid failed result.\",\"dependencies\":[],\"acceptance\":[\"Night Shift marks this failed too.\"],\"demo_plan\":[\"Inspect fail-task.\"],\"execution_mode\":\"parallel\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif grep -q 'ID: bad-task' \"$PROMPT_FILE\"; then\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Bad task broke JSON\",\"files_touched\":[],\"demo_evidence\":[],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"failed\",\"summary\":\"Provider intentionally blocked the task.\",\"files_touched\":[],\"demo_evidence\":[],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

fn write_committing_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "PROMPT_FILE=$2\n"
      <> "WORKTREE=$3\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Implement demo task\",\"description\":\"Create a file to prove execution\",\"dependencies\":[],\"acceptance\":[\"Create IMPLEMENTED.md\"],\"demo_plan\":[\"Show the new file\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nPrepare the first work item for execution.\\n## Scope\\n- Alpha task\\n## Constraints\\n- Keep the brief cumulative.\\n## Deliverables\\n- Alpha implementation plan\\n## Acceptance Criteria\\n- Alpha task documented\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "  exit 0\n"
      <> "else\n"
      <> "  cd \"$WORKTREE\" || exit 1\n"
      <> "  echo 'completed by fake provider' > IMPLEMENTED.md\n"
      <> "  git add IMPLEMENTED.md && git commit -m 'feat: provider created commit' >/dev/null 2>&1 || exit 1\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Implemented demo task\",\"files_touched\":[\"IMPLEMENTED.md\"],\"demo_evidence\":[\"IMPLEMENTED.md created\"],\"pr\":{\"title\":\"[night-shift] Implement demo task\",\"summary\":\"Implemented the fake provider task.\",\"demo\":[\"IMPLEMENTED.md created\"],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

fn write_manual_attention_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"confirm-public-docs-structure\",\"title\":\"Confirm docs structure\",\"description\":\"Choose the canonical public docs structure before implementation continues.\",\"dependencies\":[],\"acceptance\":[\"A human confirms the docs structure.\"],\"demo_plan\":[\"Record the chosen structure in the brief.\"],\"task_kind\":\"manual_attention\",\"execution_mode\":\"exclusive\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nConfirm the docs structure.\\n## Scope\\n- Decide the public docs structure.\\n## Constraints\\n- Wait for a human decision before editing code.\\n## Deliverables\\n- A confirmed direction.\\n## Acceptance Criteria\\n- The docs structure is explicitly chosen.\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'manual-attention execution should not start\\n' >&2\n"
      <> "  exit 1\n"
      <> "fi\n",
    to: path,
  )
}

fn write_resolve_loop_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "PROMPT_FILE=$2\n"
      <> "if [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nAdd a first-pass docs wiki.\\n## Scope\\n- Add docs.\\n## Constraints\\n- Keep the work docs-only.\\n## Deliverables\\n- New docs pages\\n## Acceptance Criteria\\n- Docs exist\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  if grep -q 'readme-distribution:' \"$PROMPT_FILE\"; then\n"
      <> "    printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"create-wiki-index-page\",\"title\":\"Create wiki entry point page\",\"description\":\"Create the docs entry page after decisions are settled.\",\"dependencies\":[],\"acceptance\":[\"Create the wiki entry page.\"],\"demo_plan\":[\"Show the new page.\"],\"decision_requests\":[],\"task_kind\":\"implementation\",\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "    exit 0\n"
      <> "  fi\n"
      <> "  if grep -q 'wiki-location:' \"$PROMPT_FILE\"; then\n"
      <> "    printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"decide-docs-scope-and-links\",\"title\":\"Resolve wiki layout and reference decisions\",\"description\":\"Set repository documentation placement and README distribution before writing docs.\",\"dependencies\":[],\"acceptance\":[\"README and wiki scope are chosen.\"],\"demo_plan\":[\"Record the chosen README/wiki split.\"],\"decision_requests\":[{\"key\":\"readme-distribution\",\"question\":\"Which README sections should stay in README vs move or duplicate to the wiki first-pass?\",\"rationale\":\"Night Shift needs one documented content split before it can author the entry pages.\",\"options\":[{\"label\":\"keep-core\",\"description\":\"Keep README short, discovery-focused, and link into the wiki.\"},{\"label\":\"keep-full\",\"description\":\"Keep most reference material in README for now.\"}],\"recommended_option\":\"keep-core\",\"allow_freeform\":false}],\"task_kind\":\"manual_attention\",\"execution_mode\":\"exclusive\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "    exit 0\n"
      <> "  fi\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"decide-docs-scope-and-links\",\"title\":\"Resolve wiki layout and reference decisions\",\"description\":\"Set repository documentation placement before writing docs.\",\"dependencies\":[],\"acceptance\":[\"Primary docs root path is chosen.\"],\"demo_plan\":[\"Record the docs root path.\"],\"decision_requests\":[{\"key\":\"wiki-location\",\"question\":\"Where should the new markdown wiki live?\",\"rationale\":\"All internal links depend on the chosen docs root.\",\"options\":[],\"recommended_option\":\"docs/wiki\",\"allow_freeform\":false}],\"task_kind\":\"manual_attention\",\"execution_mode\":\"exclusive\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"noop\",\"files_touched\":[],\"demo_evidence\":[],\"pr\":{\"title\":\"noop\",\"summary\":\"noop\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n",
    to: path,
  )
}

fn write_empty_worktree_setup_codex(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" != \"exec\" ]; then\n"
      <> "  printf 'unexpected codex subcommand: %s\\n' \"$1\" >&2\n"
      <> "  exit 1\n"
      <> "fi\n"
      <> "printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n\\nNIGHT_SHIFT_RESULT_END\\n'\n",
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
      <> "    --skip-git-repo-check|--dangerously-bypass-approvals-and-sandbox|--json)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "    --color)\n"
      <> "      shift 2\n"
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

fn write_fake_streaming_codex(path: String) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" != \"exec\" ]; then\n"
      <> "  printf 'unexpected codex subcommand: %s\\n' \"$1\" >&2\n"
      <> "  exit 1\n"
      <> "fi\n"
      <> "shift\n"
      <> "while [ $# -gt 0 ]; do\n"
      <> "  case \"$1\" in\n"
      <> "    --skip-git-repo-check|--dangerously-bypass-approvals-and-sandbox|--json)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "    --color|--sandbox|-C)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -)\n"
      <> "      INPUT=$(cat)\n"
      <> "      if printf '%s' \"$INPUT\" | grep -q 'cumulative Night Shift brief'; then\n"
      <> "        printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"brief\"}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nPolish the harness streaming UI.\\n## Scope\\n- Replace raw line dumps with formatted stream output.\\n## Constraints\\n- Keep raw artifacts for debugging.\\n## Deliverables\\n- Improved stream presentation\\n## Acceptance Criteria\\n- Prompt is hidden in the live stream.\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "        exit 0\n"
      <> "      fi\n"
      <> "      if printf '%s' \"$INPUT\" | grep -q 'Break the supplied brief into a task DAG.'; then\n"
      <> "        printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"planner\"}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n{\\\"tasks\\\":[{\\\"id\\\":\\\"alpha\\\",\\\"title\\\":\\\"Alpha task\\\",\\\"description\\\":\\\"Create alpha proof\\\",\\\"dependencies\\\":[],\\\"acceptance\\\":[\\\"Create ALPHA.txt\\\"],\\\"demo_plan\\\":[\\\"Show ALPHA.txt\\\"],\\\"execution_mode\\\":\\\"parallel\\\"},{\\\"id\\\":\\\"beta\\\",\\\"title\\\":\\\"Beta task\\\",\\\"description\\\":\\\"Create beta proof\\\",\\\"dependencies\\\":[],\\\"acceptance\\\":[\\\"Create BETA.txt\\\"],\\\"demo_plan\\\":[\\\"Show BETA.txt\\\"],\\\"execution_mode\\\":\\\"parallel\\\"}]}\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "        exit 0\n"
      <> "      fi\n"
      <> "      if printf '%s' \"$INPUT\" | grep -q 'ID: alpha'; then\n"
      <> "        printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"alpha\"}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.started\",\"item\":{\"id\":\"item_1\",\"type\":\"command_execution\",\"command\":\"echo alpha > ALPHA.txt\",\"aggregated_output\":\"\",\"exit_code\":null,\"status\":\"in_progress\"}}'\n"
      <> "        sleep 0.1\n"
      <> "        printf 'alpha\\n' > ALPHA.txt\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_1\",\"type\":\"command_execution\",\"command\":\"echo alpha > ALPHA.txt\",\"aggregated_output\":\"alpha\\n\",\"exit_code\":0,\"status\":\"completed\"}}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_2\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n{\\\"status\\\":\\\"completed\\\",\\\"summary\\\":\\\"alpha ok\\\",\\\"files_touched\\\":[\\\"ALPHA.txt\\\"],\\\"demo_evidence\\\":[\\\"ALPHA.txt created\\\"],\\\"pr\\\":{\\\"title\\\":\\\"alpha\\\",\\\"summary\\\":\\\"alpha\\\",\\\"demo\\\":[\\\"ALPHA.txt created\\\"],\\\"risks\\\":[]},\\\"follow_up_tasks\\\":[]}\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "        exit 0\n"
      <> "      fi\n"
      <> "      if printf '%s' \"$INPUT\" | grep -q 'ID: beta'; then\n"
      <> "        printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"beta\"}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.started\",\"item\":{\"id\":\"item_1\",\"type\":\"command_execution\",\"command\":\"echo beta > BETA.txt\",\"aggregated_output\":\"\",\"exit_code\":null,\"status\":\"in_progress\"}}'\n"
      <> "        sleep 0.1\n"
      <> "        printf 'beta\\n' > BETA.txt\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_1\",\"type\":\"command_execution\",\"command\":\"echo beta > BETA.txt\",\"aggregated_output\":\"beta\\n\",\"exit_code\":0,\"status\":\"completed\"}}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_2\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n{\\\"status\\\":\\\"completed\\\",\\\"summary\\\":\\\"beta ok\\\",\\\"files_touched\\\":[\\\"BETA.txt\\\"],\\\"demo_evidence\\\":[\\\"BETA.txt created\\\"],\\\"pr\\\":{\\\"title\\\":\\\"beta\\\",\\\"summary\\\":\\\"beta\\\",\\\"demo\\\":[\\\"BETA.txt created\\\"],\\\"risks\\\":[]},\\\"follow_up_tasks\\\":[]}\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "        exit 0\n"
      <> "      fi\n"
      <> "      printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"fallback\"}'\n"
      <> "      printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n{\\\"status\\\":\\\"completed\\\",\\\"summary\\\":\\\"ok\\\",\\\"files_touched\\\":[],\\\"demo_evidence\\\":[],\\\"pr\\\":{\\\"title\\\":\\\"t\\\",\\\"summary\\\":\\\"s\\\",\\\"demo\\\":[],\\\"risks\\\":[]},\\\"follow_up_tasks\\\":[]}\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
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

fn write_fake_streaming_utf8_codex(path: String) -> Result(Nil, simplifile.FileError) {
  let long_output = repeat_text("a", 156) <> "\\u2014tail\\n"

  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" != \"exec\" ]; then\n"
      <> "  printf 'unexpected codex subcommand: %s\\n' \"$1\" >&2\n"
      <> "  exit 1\n"
      <> "fi\n"
      <> "shift\n"
      <> "while [ $# -gt 0 ]; do\n"
      <> "  case \"$1\" in\n"
      <> "    --skip-git-repo-check|--dangerously-bypass-approvals-and-sandbox|--json)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "    --color|--sandbox|-C|-m|-c)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -)\n"
      <> "      INPUT=$(cat)\n"
      <> "      if printf '%s' \"$INPUT\" | grep -q 'Break the supplied brief into a task DAG.'; then\n"
      <> "        printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"planner\"}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n{\\\"tasks\\\":[{\\\"id\\\":\\\"alpha\\\",\\\"title\\\":\\\"Alpha task\\\",\\\"description\\\":\\\"Create alpha proof\\\",\\\"dependencies\\\":[],\\\"acceptance\\\":[\\\"Create ALPHA.txt\\\"],\\\"demo_plan\\\":[\\\"Show ALPHA.txt\\\"],\\\"execution_mode\\\":\\\"serial\\\"}]}\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "        exit 0\n"
      <> "      else\n"
      <> "        printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"brief\"}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"Checking the docs surface before returning the brief.\"}}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_1\",\"type\":\"command_execution\",\"command\":\"sed -n '\\''320,420p'\\'' README.md\",\"aggregated_output\":\""
      <> long_output
      <> "\",\"exit_code\":0,\"status\":\"completed\"}}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_2\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nAdd the hello script.\\n## Scope\\n- Add a hello script.\\n## Constraints\\n- Keep scope tight.\\n## Deliverables\\n- hello script\\n## Acceptance Criteria\\n- script exists\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "        exit 0\n"
      <> "      fi\n"
      <> "      printf 'unexpected prompt\\n' >&2\n"
      <> "      exit 9\n"
      <> "      ;;\n"
      <> "    *)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "  esac\n"
      <> "done\n"
      <> "printf 'missing stdin prompt sentinel\\n' >&2\n"
      <> "exit 8\n",
    to: path,
  )
}

fn repeat_text(value: String, count: Int) -> String {
  case count <= 0 {
    True -> ""
    False -> value <> repeat_text(value, count - 1)
  }
}

fn write_worktree_execution_codex(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" != \"exec\" ]; then\n"
      <> "  printf 'unexpected codex subcommand: %s\\n' \"$1\" >&2\n"
      <> "  exit 1\n"
      <> "fi\n"
      <> "shift\n"
      <> "TARGET_DIR=''\n"
      <> "while [ $# -gt 0 ]; do\n"
      <> "  case \"$1\" in\n"
      <> "    --skip-git-repo-check|--dangerously-bypass-approvals-and-sandbox|--json)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "    --color|-m)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -c)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -C)\n"
      <> "      TARGET_DIR=$2\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -)\n"
      <> "      INPUT=$(cat)\n"
      <> "      cd /tmp || exit 1\n"
      <> "      if [ -n \"$TARGET_DIR\" ]; then\n"
      <> "        cd \"$TARGET_DIR\" || exit 1\n"
      <> "      fi\n"
      <> "      printf 'executed in worktree\\n' > EXECUTED.txt\n"
      <> "      printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"exec\"}'\n"
      <> "      printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n{\\\"status\\\":\\\"completed\\\",\\\"summary\\\":\\\"ok\\\",\\\"files_touched\\\":[\\\"EXECUTED.txt\\\"],\\\"demo_evidence\\\":[\\\"EXECUTED.txt created\\\"],\\\"pr\\\":{\\\"title\\\":\\\"t\\\",\\\"summary\\\":\\\"s\\\",\\\"demo\\\":[],\\\"risks\\\":[]},\\\"follow_up_tasks\\\":[]}\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "      exit 0\n"
      <> "      ;;\n"
      <> "    *)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "  esac\n"
      <> "done\n"
      <> "printf 'missing stdin prompt sentinel\\n' >&2\n"
      <> "exit 8\n",
    to: path,
  )
}

fn write_large_streaming_codex(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" != \"exec\" ]; then\n"
      <> "  printf 'unexpected codex subcommand: %s\\n' \"$1\" >&2\n"
      <> "  exit 1\n"
      <> "fi\n"
      <> "shift\n"
      <> "while [ $# -gt 0 ]; do\n"
      <> "  case \"$1\" in\n"
      <> "    --skip-git-repo-check|--dangerously-bypass-approvals-and-sandbox|--json)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "    --color|--sandbox|-C)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -)\n"
      <> "      python3 - <<'PY'\n"
      <> "import json, sys\n"
      <> "sys.stdin.read()\n"
      <> "large_block = 'A' * 17050\n"
      <> "brief = '# Night Shift Brief\\n## Objective\\nLarge streaming payload\\n## Scope\\n- ' + large_block + '\\n## Constraints\\n- Keep structured mode active.\\n## Deliverables\\n- Large line preserved\\n## Acceptance Criteria\\n- Full payload parsed\\n## Risks and Open Questions\\n- None.'\n"
      <> "print(json.dumps({\"type\": \"thread.started\", \"thread_id\": \"large\"}))\n"
      <> "print(json.dumps({\"type\": \"item.completed\", \"item\": {\"id\": \"item_0\", \"type\": \"agent_message\", \"text\": 'NIGHT_SHIFT_RESULT_START\\n' + brief + '\\nNIGHT_SHIFT_RESULT_END'}}))\n"
      <> "PY\n"
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
