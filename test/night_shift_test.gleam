import gleeunit
import filepath
import gleam/result
import gleam/string
import night_shift/cli
import night_shift/config
import night_shift/harness
import night_shift/journal
import night_shift/system
import night_shift/types
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_start_command_test() {
  let assert Ok(types.Start("brief.md", Ok(types.Cursor), Ok(2))) =
    cli.parse(["start", "--brief", "brief.md", "--harness", "cursor", "--max-workers", "2"])
}

pub fn parse_status_defaults_to_latest_test() {
  let assert Ok(types.Status(types.LatestRun)) = cli.parse(["status"])
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

pub fn extract_json_payload_test() {
  let output =
    "noise\n"
    <> "NIGHT_SHIFT_RESULT_START\n"
    <> "{\"tasks\":[]}\n"
    <> "NIGHT_SHIFT_RESULT_END\n"

  let assert Ok(payload) = harness.extract_json_payload(output)
  assert payload == "{\"tasks\":[]}"
}
