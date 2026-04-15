import gleam/option.{None, Some}
import gleam/string
import night_shift/agent_config
import night_shift/cli
import night_shift/config
import night_shift/types
import night_shift/worktree_setup

pub fn parse_start_command_test() {
  let assert Ok(types.Start(types.RunId("run-123"))) =
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
  let assert Ok(types.Plan(Some("notes.md"), None, False, agent_overrides)) =
    cli.parse(["plan", "--notes", "notes.md"])
  assert agent_overrides == types.empty_agent_overrides()
}

pub fn parse_plan_command_with_doc_and_provider_test() {
  let assert Ok(types.Plan(
    Some("notes.md"),
    Some("custom.md"),
    False,
    agent_overrides,
  )) =
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

pub fn parse_plan_from_reviews_without_notes_test() {
  let assert Ok(types.Plan(None, None, True, agent_overrides)) =
    cli.parse(["plan", "--from-reviews"])

  assert agent_overrides == types.empty_agent_overrides()
}

pub fn parse_status_defaults_to_latest_test() {
  let assert Ok(types.Status(types.LatestRun)) = cli.parse(["status"])
}

pub fn parse_start_command_rejects_ui_flag_test() {
  let assert Error(message) = cli.parse(["start", "--ui"])
  assert message
    == "`start --ui` was replaced by `night-shift dash`, which now owns the browser flow."
}

pub fn parse_dash_command_defaults_to_latest_test() {
  let assert Ok(types.Dash(types.LatestRun)) = cli.parse(["dash"])
}

pub fn parse_dash_command_with_run_selector_test() {
  let assert Ok(types.Dash(types.RunId("run-123"))) =
    cli.parse(["dash", "--run", "run-123"])
}

pub fn parse_dash_command_rejects_transitional_start_flag_test() {
  let assert Error(message) = cli.parse(["dash", "--start"])
  assert message
    == "`night-shift dash --start` was removed; open Dash and use the Start button in the browser."
}

pub fn parse_start_command_without_brief_test() {
  let assert Ok(types.Start(types.LatestRun)) = cli.parse(["start"])
}

pub fn parse_plan_requires_notes_test() {
  let assert Error(message) = cli.parse(["plan"])
  assert message == "The plan command requires --notes <file-or-inline-text>."
}

pub fn parse_resolve_defaults_to_latest_test() {
  let assert Ok(types.Resolve(types.LatestRun, None, None)) =
    cli.parse(["resolve"])
}

pub fn parse_resolve_task_continue_command_test() {
  let assert Ok(types.Resolve(
    types.RunId("run-123"),
    Some("task-1"),
    Some(types.ResolveContinue),
  )) =
    cli.parse([
      "resolve",
      "--run",
      "run-123",
      "--task",
      "task-1",
      "--continue",
    ])
}

pub fn parse_resolve_rejects_missing_action_for_task_test() {
  let assert Error(message) = cli.parse(["resolve", "--task", "task-1"])
  assert message
    == "`night-shift resolve --task <task-id>` requires exactly one of `--inspect`, `--continue`, `--complete`, or `--abandon`."
}

pub fn parse_resolve_rejects_action_without_task_test() {
  let assert Error(message) = cli.parse(["resolve", "--inspect"])
  assert message
    == "`night-shift resolve` action flags require `--task <task-id>`."
}

pub fn parse_resolve_rejects_multiple_actions_test() {
  let assert Error(message) =
    cli.parse([
      "resolve",
      "--task",
      "task-1",
      "--inspect",
      "--continue",
    ])
  assert message
    == "`night-shift resolve --task <task-id>` accepts exactly one of `--inspect`, `--continue`, `--complete`, or `--abandon`."
}

pub fn parse_resume_command_rejects_ui_flag_test() {
  let assert Error(message) = cli.parse(["resume", "--run", "run-123", "--ui"])
  assert message
    == "`resume --ui` was replaced by `night-shift dash`, which now owns the browser flow."
}

pub fn parse_resume_explain_command_test() {
  let assert Ok(types.Resume(types.LatestRun, True)) =
    cli.parse(["resume", "--explain"])
}

pub fn parse_doctor_command_test() {
  let assert Ok(types.Doctor(types.RunId("run-123"))) =
    cli.parse(["doctor", "--run", "run-123"])
}

pub fn parse_provenance_command_test() {
  let assert Ok(types.Provenance(
    types.LatestRun,
    Some("task-1"),
    types.ProvenanceJson,
  )) = cli.parse(["provenance", "--task", "task-1", "--format", "json"])
}

pub fn parse_resume_rejects_environment_flag_test() {
  let assert Error(message) = cli.parse(["resume", "--environment", "dev"])
  assert message == "Unsupported flag: --environment"
}

pub fn parse_review_command_guides_to_plan_from_reviews_test() {
  let assert Error(message) = cli.parse(["review", "--environment", "dev"])
  assert message
    == "`night-shift review` was replaced by `night-shift plan --from-reviews`."
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
  let assert Ok(environment) =
    worktree_setup.find_environment(parsed, "default")

  assert environment.env_vars == [#("HUSKY", "0")]
  assert environment.setup.default == ["pnpm install --frozen-lockfile"]
  assert environment.maintenance.default == ["pnpm run lint", "pnpm run test"]
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

pub fn parse_handoff_config_test() {
  let source =
    "[handoff]\n"
    <> "enabled = false\n"
    <> "pr_body_mode = \"prepend\"\n"
    <> "managed_comment = true\n"
    <> "provenance = \"light\"\n"
    <> "include_files_touched = false\n"
    <> "include_acceptance = true\n"
    <> "include_stack_context = false\n"
    <> "include_verification_summary = false\n"
    <> "pr_body_prefix_path = \".night-shift/pr-prefix.md\"\n"
    <> "comment_suffix_path = \".night-shift/comment-suffix.md\"\n"

  let assert Ok(parsed) = config.parse(source)

  assert parsed.handoff.enabled == False
  assert parsed.handoff.pr_body_mode == types.HandoffBodyPrepend
  assert parsed.handoff.managed_comment == True
  assert parsed.handoff.provenance == types.HandoffProvenanceLight
  assert parsed.handoff.include_files_touched == False
  assert parsed.handoff.include_acceptance == True
  assert parsed.handoff.include_stack_context == False
  assert parsed.handoff.include_verification_summary == False
  assert parsed.handoff.pr_body_prefix_path == Some(".night-shift/pr-prefix.md")
  assert parsed.handoff.comment_suffix_path
    == Some(".night-shift/comment-suffix.md")
}

pub fn render_handoff_config_round_trip_test() {
  let configured =
    types.Config(
      ..types.default_config(),
      handoff: types.HandoffConfig(
        enabled: True,
        pr_body_mode: types.HandoffBodyPrepend,
        managed_comment: True,
        provenance: types.HandoffProvenanceMinimal,
        include_files_touched: False,
        include_acceptance: True,
        include_stack_context: False,
        include_verification_summary: False,
        pr_body_prefix_path: Some(".night-shift/pr-prefix.md"),
        pr_body_suffix_path: None,
        comment_prefix_path: Some(".night-shift/comment-prefix.md"),
        comment_suffix_path: None,
      ),
    )

  let rendered = config.render(configured)
  let assert Ok(parsed) = config.parse(rendered)

  assert parsed.handoff == configured.handoff
}
