import gleeunit
import filepath
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import night_shift/cli
import night_shift/config
import night_shift/dashboard
import night_shift/demo
import night_shift/harness
import night_shift/journal
import night_shift/orchestrator
import night_shift/shell
import night_shift/system
import night_shift/types
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_start_command_test() {
  let assert Ok(types.Start("brief.md", Ok(types.Cursor), Ok(2), False)) =
    cli.parse(["start", "--brief", "brief.md", "--harness", "cursor", "--max-workers", "2"])
}

pub fn parse_status_defaults_to_latest_test() {
  let assert Ok(types.Status(types.LatestRun)) = cli.parse(["status"])
}

pub fn parse_start_command_with_ui_test() {
  let assert Ok(types.Start("brief.md", Error(Nil), Error(Nil), True)) =
    cli.parse(["start", "--brief", "brief.md", "--ui"])
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
  let assert Ok(parsed) = config.parse("base_branch = \"develop\"\nmax_workers = 2")
  assert parsed.base_branch == "develop"
  assert parsed.max_workers == 2
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
  let base_dir = filepath.join(system.state_directory(), "night-shift-test-" <> unique)
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ = simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)

  let assert Ok(run) = journal.start_run(repo_root, brief_path, types.Codex, 2)
  let assert Ok(report_contents) = simplifile.read(run.report_path)
  let assert Ok(state_contents) = simplifile.read(run.state_path)

  assert string.contains(does: report_contents, contain: "Night Shift Report")
  assert string.contains(does: state_contents, contain: "\"run_id\"")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn latest_run_round_trip_test() {
  let unique = system.unique_id()
  let base_dir =
    filepath.join(system.state_directory(), "night-shift-test-round-trip-" <> unique)
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ = simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(run) = journal.start_run(repo_root, brief_path, types.Cursor, 1)
  let assert Ok(#(saved_run, _)) = journal.load(repo_root, types.LatestRun)

  assert saved_run.run_id == run.run_id
  assert saved_run.harness == types.Cursor
  assert result.is_ok(simplifile.delete(file_or_dir_at: base_dir))
}

pub fn list_runs_returns_newest_first_test() {
  let unique = system.unique_id()
  let base_dir = filepath.join(system.state_directory(), "night-shift-test-history-" <> unique)
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_a = filepath.join(base_dir, "brief-a.md")
  let brief_b = filepath.join(base_dir, "brief-b.md")

  let _ = simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief A", to: brief_a)
  let assert Ok(_) = simplifile.write("# Brief B", to: brief_b)

  let assert Ok(first_run) = journal.start_run(repo_root, brief_a, types.Codex, 1)
  let assert Ok(_) = journal.mark_status(first_run, types.RunCompleted, "done")
  let assert Ok(second_run) = journal.start_run(repo_root, brief_b, types.Cursor, 2)
  let assert Ok(runs) = journal.list_runs(repo_root)

  let assert [latest, previous, .._] = runs
  assert latest.run_id == second_run.run_id
  assert previous.run_id == first_run.run_id

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn dashboard_payloads_include_run_data_test() {
  let unique = system.unique_id()
  let base_dir = filepath.join(system.state_directory(), "night-shift-test-dashboard-" <> unique)
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ = simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(run) = journal.start_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(updated_run) =
    journal.append_event(
      run,
      types.RunEvent(kind: "task_progress", at: system.timestamp(), message: "Working", task_id: Some("demo-task")),
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
  let base_dir = filepath.join(system.state_directory(), "night-shift-test-dashboard-server-" <> unique)
  let repo_root = filepath.join(base_dir, "repo-" <> unique)
  let brief_path = filepath.join(base_dir, "brief.md")

  let _ = simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(run) = journal.start_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(session) = dashboard.start_view_session(repo_root, run.run_id)

  system.sleep(100)

  let assert Ok(index_html) = dashboard.http_get(session.url)
  let assert Ok(runs_payload) = dashboard.http_get(session.url <> "/api/runs")
  let assert Ok(run_payload) = dashboard.http_get(session.url <> "/api/runs/" <> run.run_id)

  assert string.contains(does: index_html, contain: "Night Shift Dashboard")
  assert string.contains(does: runs_payload, contain: run.run_id)
  assert string.contains(does: run_payload, contain: "\"run_id\":\"" <> run.run_id <> "\"")

  let _ = dashboard.stop_session(session)
  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn extract_json_payload_test() {
  let output =
    "noise\n"
    <> "NIGHT_SHIFT_RESULT_START\n"
    <> "{\"tasks\":[]}\n"
    <> "NIGHT_SHIFT_RESULT_END\n"

  let assert Ok(payload) = harness.extract_json_payload(output)
  assert payload == "{\"tasks\":[]}"
}

pub fn repo_state_path_is_stable_test() {
  let repo_root = "/tmp/night-shift-demo"
  assert journal.repo_state_path_for(repo_root) == journal.repo_state_path_for(repo_root)
}

pub fn orchestrator_start_runs_fake_harness_test() {
  let unique = system.unique_id()
  let base_dir = filepath.join(system.state_directory(), "night-shift-integration-" <> unique)
  let repo_root = filepath.join(base_dir, "repo")
  let remote_root = filepath.join(base_dir, "remote.git")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_harness = filepath.join(bin_dir, "fake-harness")
  let fake_gh = filepath.join(bin_dir, "gh")
  let old_path = system.get_env("PATH")
  let old_fake_harness = system.get_env("NIGHT_SHIFT_FAKE_HARNESS")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ = simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = write_fake_harness(fake_harness)
  let assert Ok(_) = write_fake_gh(fake_gh)
  let _ = shell.run("chmod +x " <> shell.quote(fake_harness) <> " " <> shell.quote(fake_gh), base_dir, filepath.join(base_dir, "chmod.log"))
  let _ = shell.run("git init --bare " <> shell.quote(remote_root), base_dir, filepath.join(base_dir, "remote.log"))
  let _ = shell.run("git init --initial-branch=main " <> shell.quote(repo_root), base_dir, filepath.join(base_dir, "repo-init.log"))
  let _ = shell.run("git config user.name 'Night Shift Test'", repo_root, filepath.join(base_dir, "git-user.log"))
  let _ = shell.run("git config user.email 'night-shift@example.com'", repo_root, filepath.join(base_dir, "git-email.log"))
  let assert Ok(_) = simplifile.write("# Demo\n", to: filepath.join(repo_root, "README.md"))
  let _ = shell.run("git add README.md && git commit -m 'chore: seed repo'", repo_root, filepath.join(base_dir, "seed.log"))
  let _ = shell.run("git remote add origin " <> shell.quote(remote_root), repo_root, filepath.join(base_dir, "remote-add.log"))
  let _ = shell.run("git push -u origin main", repo_root, filepath.join(base_dir, "push-main.log"))

  system.set_env("NIGHT_SHIFT_FAKE_HARNESS", fake_harness)
  system.set_env("PATH", bin_dir <> ":" <> old_path)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) = journal.start_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(completed_run) = orchestrator.start(run, config)

  system.set_env("PATH", old_path)
  system.set_env("NIGHT_SHIFT_FAKE_HARNESS", old_fake_harness)

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
  let base_dir = filepath.join(system.state_directory(), "night-shift-ui-integration-" <> unique)
  let repo_root = filepath.join(base_dir, "repo")
  let remote_root = filepath.join(base_dir, "remote.git")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_harness = filepath.join(bin_dir, "fake-harness")
  let fake_gh = filepath.join(bin_dir, "gh")
  let old_path = system.get_env("PATH")
  let old_fake_harness = system.get_env("NIGHT_SHIFT_FAKE_HARNESS")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ = simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) = simplifile.create_directory_all(bin_dir)
  let assert Ok(_) = simplifile.write("# Brief", to: brief_path)
  let assert Ok(_) = write_fake_harness(fake_harness)
  let assert Ok(_) = write_fake_gh(fake_gh)
  let _ = shell.run("chmod +x " <> shell.quote(fake_harness) <> " " <> shell.quote(fake_gh), base_dir, filepath.join(base_dir, "chmod.log"))
  let _ = shell.run("git init --bare " <> shell.quote(remote_root), base_dir, filepath.join(base_dir, "remote.log"))
  let _ = shell.run("git init --initial-branch=main " <> shell.quote(repo_root), base_dir, filepath.join(base_dir, "repo-init.log"))
  let _ = shell.run("git config user.name 'Night Shift Test'", repo_root, filepath.join(base_dir, "git-user.log"))
  let _ = shell.run("git config user.email 'night-shift@example.com'", repo_root, filepath.join(base_dir, "git-email.log"))
  let assert Ok(_) = simplifile.write("# Demo\n", to: filepath.join(repo_root, "README.md"))
  let _ = shell.run("git add README.md && git commit -m 'chore: seed repo'", repo_root, filepath.join(base_dir, "seed.log"))
  let _ = shell.run("git remote add origin " <> shell.quote(remote_root), repo_root, filepath.join(base_dir, "remote-add.log"))
  let _ = shell.run("git push -u origin main", repo_root, filepath.join(base_dir, "push-main.log"))

  system.set_env("NIGHT_SHIFT_FAKE_HARNESS", fake_harness)
  system.set_env("PATH", bin_dir <> ":" <> old_path)

  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  let assert Ok(run) = journal.start_run(repo_root, brief_path, types.Codex, 1)
  let assert Ok(session) = dashboard.start_start_session(repo_root, run.run_id, run, config)
  let final_payload = wait_for_run_payload(session.url, run.run_id, 20)

  system.set_env("PATH", old_path)
  system.set_env("NIGHT_SHIFT_FAKE_HARNESS", old_fake_harness)

  assert string.contains(does: final_payload, contain: "\"status\":\"completed\"")
  assert string.contains(does: final_payload, contain: "\"pr_number\":\"1\"")

  let _ = dashboard.stop_session(session)
  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn demo_run_succeeds_without_ui_test() {
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", local_demo_command())

  let result = demo.run(False)

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  let _ = simplifile.delete(file_or_dir_at: demo.demo_root())

  let assert Ok(Nil) = result
}

pub fn demo_run_succeeds_with_ui_test() {
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", local_demo_command())

  let result = demo.run(True)

  system.set_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  let _ = simplifile.delete(file_or_dir_at: demo.demo_root())

  let assert Ok(Nil) = result
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

fn write_fake_harness(path: String) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
    <> "MODE=$1\n"
    <> "PROMPT_FILE=$2\n"
    <> "if [ \"$MODE\" = \"plan\" ]; then\n"
    <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Implement demo task\",\"description\":\"Create a file to prove execution\",\"dependencies\":[],\"acceptance\":[\"Create IMPLEMENTED.md\"],\"demo_plan\":[\"Show the new file\"],\"parallel_safe\":false}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
    <> "else\n"
    <> "  echo 'completed by fake harness' > IMPLEMENTED.md\n"
    <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Implemented demo task\",\"files_touched\":[\"IMPLEMENTED.md\"],\"demo_evidence\":[\"IMPLEMENTED.md created\"],\"pr\":{\"title\":\"[night-shift] Implement demo task\",\"summary\":\"Implemented the fake harness task.\",\"demo\":[\"IMPLEMENTED.md created\"],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
    <> "fi\n",
    to: path,
  )
}

fn wait_for_run_payload(base_url: String, run_id: String, attempts: Int) -> String {
  let url = base_url <> "/api/runs/" <> run_id
  case attempts {
    value if value <= 0 ->
      dashboard.http_get(url)
      |> result.unwrap(or: "Unable to fetch dashboard payload.")
    _ ->
      case dashboard.http_get(url) {
        Ok(payload) ->
          case string.contains(does: payload, contain: "\"status\":\"completed\"") {
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
