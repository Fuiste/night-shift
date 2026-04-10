import gleeunit
import night_shift/cli
import night_shift/config
import night_shift/types

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
