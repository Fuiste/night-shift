//// CLI parsing and operator-facing help text for Night Shift.
import gleam/option.{type Option, None, Some}
import gleam/result
import night_shift/types

/// Render the CLI usage text shown for `help` and parse failures.
pub fn usage() -> String {
  "Night Shift\n"
  <> "\n"
  <> "Commands:\n"
  <> "  --demo [--ui]\n"
  <> "  init [--profile <name>] [--provider <codex|cursor>] [--model <id>] [--reasoning <low|medium|high|xhigh>] [--yes] [--generate-setup]\n"
  <> "    Prompts interactively for provider, model, and initial worktree setup when those answers are not supplied.\n"
  <> "  reset [--yes] [--force]\n"
  <> "  plan --notes <file-or-inline-text> [--doc <path>] [--profile <name>] [--provider <codex|cursor>] [--model <id>] [--reasoning <low|medium|high|xhigh>]\n"
  <> "  start [--run <id>|latest] [--ui]\n"
  <> "  status [--run <id>|latest]\n"
  <> "  report [--run <id>|latest]\n"
  <> "  resolve [--run <id>|latest]\n"
  <> "  resume [--run <id>|latest] [--ui]\n"
  <> "  review [--profile <name>] [--provider <codex|cursor>] [--model <id>] [--reasoning <low|medium|high|xhigh>] [--environment <name>]\n"
}

/// Parse raw command-line arguments into a `Command`.
///
/// ## Examples
///
/// ```gleam
/// > parse(["start", "--run", "latest"])
/// Ok(types.Start(types.LatestRun, False))
/// ```
///
/// ```gleam
/// > parse(["plan"])
/// Error("The plan command requires --notes <file-or-inline-text>.")
/// ```
pub fn parse(args: List(String)) -> Result(types.Command, String) {
  case contains_demo_flag(args) {
    True -> parse_demo(args, False)
    False ->
      case args {
        [] -> Ok(types.Help)
        ["help", ..] -> Ok(types.Help)
        ["init", ..rest] -> parse_init(rest)
        ["reset", ..rest] -> parse_reset(rest)
        ["plan", ..rest] -> parse_plan(rest)
        ["start", ..rest] -> parse_start(rest)
        ["status", ..rest] -> parse_run_lookup(rest, types.Status)
        ["report", ..rest] -> parse_run_lookup(rest, types.Report)
        ["resolve", ..rest] -> parse_run_lookup(rest, types.Resolve)
        ["resume", ..rest] -> parse_resume(rest)
        ["review", ..rest] -> parse_review(rest)
        [command, ..] -> Error("Unknown command: " <> command)
      }
  }
}

fn contains_demo_flag(args: List(String)) -> Bool {
  case args {
    [] -> False
    ["--demo", ..] -> True
    [_, ..rest] -> contains_demo_flag(rest)
  }
}

fn parse_plan(args: List(String)) -> Result(types.Command, String) {
  parse_plan_flags(args, Error(Nil), None, types.empty_agent_overrides())
}

fn parse_plan_flags(
  args: List(String),
  notes_path: Result(String, Nil),
  doc_path: Option(String),
  agent_overrides: types.AgentOverrides,
) -> Result(types.Command, String) {
  case args {
    [] ->
      case notes_path {
        Ok(path) -> Ok(types.Plan(path, doc_path, agent_overrides))
        Error(Nil) ->
          Error("The plan command requires --notes <file-or-inline-text>.")
      }

    ["--notes", path, ..rest] ->
      parse_plan_flags(rest, Ok(path), doc_path, agent_overrides)

    ["--doc", path, ..rest] ->
      parse_plan_flags(rest, notes_path, Some(path), agent_overrides)

    ["--profile", profile_name, ..rest] ->
      parse_plan_flags(
        rest,
        notes_path,
        doc_path,
        types.AgentOverrides(..agent_overrides, profile: Some(profile_name)),
      )

    ["--provider", raw_provider, ..rest] -> {
      use provider <- result.try(types.provider_from_string(raw_provider))
      parse_plan_flags(
        rest,
        notes_path,
        doc_path,
        types.AgentOverrides(..agent_overrides, provider: Some(provider)),
      )
    }

    ["--model", model, ..rest] ->
      parse_plan_flags(
        rest,
        notes_path,
        doc_path,
        types.AgentOverrides(..agent_overrides, model: Some(model)),
      )

    ["--reasoning", raw_reasoning, ..rest] -> {
      use reasoning <- result.try(types.reasoning_from_string(raw_reasoning))
      parse_plan_flags(
        rest,
        notes_path,
        doc_path,
        types.AgentOverrides(..agent_overrides, reasoning: Some(reasoning)),
      )
    }

    [flag, ..] -> Error("Unsupported plan flag: " <> flag)
  }
}

fn parse_demo(
  args: List(String),
  ui_enabled: Bool,
) -> Result(types.Command, String) {
  case args {
    [] -> Ok(types.Demo(ui_enabled))
    ["--demo", ..rest] -> parse_demo(rest, ui_enabled)
    ["--ui", ..rest] -> parse_demo(rest, True)
    [_flag, ..] ->
      Error("--demo does not accept commands. Run `night-shift --demo [--ui]`.")
  }
}

fn parse_init(args: List(String)) -> Result(types.Command, String) {
  parse_init_flags(args, types.empty_agent_overrides(), False, False)
}

fn parse_init_flags(
  args: List(String),
  agent_overrides: types.AgentOverrides,
  generate_setup: Bool,
  assume_yes: Bool,
) -> Result(types.Command, String) {
  case args {
    [] -> Ok(types.Init(agent_overrides, generate_setup, assume_yes))
    ["--profile", profile_name, ..rest] ->
      parse_init_flags(
        rest,
        types.AgentOverrides(..agent_overrides, profile: Some(profile_name)),
        generate_setup,
        assume_yes,
      )
    ["--provider", raw_provider, ..rest] -> {
      use provider <- result.try(types.provider_from_string(raw_provider))
      parse_init_flags(
        rest,
        types.AgentOverrides(..agent_overrides, provider: Some(provider)),
        generate_setup,
        assume_yes,
      )
    }
    ["--model", model, ..rest] ->
      parse_init_flags(
        rest,
        types.AgentOverrides(..agent_overrides, model: Some(model)),
        generate_setup,
        assume_yes,
      )
    ["--reasoning", raw_reasoning, ..rest] -> {
      use reasoning <- result.try(types.reasoning_from_string(raw_reasoning))
      parse_init_flags(
        rest,
        types.AgentOverrides(..agent_overrides, reasoning: Some(reasoning)),
        generate_setup,
        assume_yes,
      )
    }
    ["--generate-setup", ..rest] ->
      parse_init_flags(rest, agent_overrides, True, assume_yes)
    ["--yes", ..rest] ->
      parse_init_flags(rest, agent_overrides, generate_setup, True)
    [flag, ..] -> Error("Unsupported init flag: " <> flag)
  }
}

fn parse_start(args: List(String)) -> Result(types.Command, String) {
  parse_start_flags(args, types.LatestRun, False)
}

fn parse_reset(args: List(String)) -> Result(types.Command, String) {
  parse_reset_flags(args, False, False)
}

fn parse_reset_flags(
  args: List(String),
  assume_yes: Bool,
  force: Bool,
) -> Result(types.Command, String) {
  case args {
    [] -> Ok(types.Reset(assume_yes, force))
    ["--yes", ..rest] -> parse_reset_flags(rest, True, force)
    ["--force", ..rest] -> parse_reset_flags(rest, assume_yes, True)
    [flag, ..] -> Error("Unsupported reset flag: " <> flag)
  }
}

fn parse_start_flags(
  args: List(String),
  run: types.RunSelector,
  ui_enabled: Bool,
) -> Result(types.Command, String) {
  case args {
    [] -> Ok(types.Start(run, ui_enabled))
    ["--run", "latest", ..rest] ->
      parse_start_flags(rest, types.LatestRun, ui_enabled)
    ["--run", run_id, ..rest] ->
      parse_start_flags(rest, types.RunId(run_id), ui_enabled)
    ["--ui", ..rest] -> parse_start_flags(rest, run, True)
    [flag, ..] -> Error("Unsupported start flag: " <> flag)
  }
}

fn parse_resume(args: List(String)) -> Result(types.Command, String) {
  parse_resume_flags(args, types.LatestRun, False)
}

fn parse_resume_flags(
  args: List(String),
  run: types.RunSelector,
  ui_enabled: Bool,
) -> Result(types.Command, String) {
  case args {
    [] -> Ok(types.Resume(run, ui_enabled))
    ["--run", "latest", ..rest] ->
      parse_resume_flags(rest, types.LatestRun, ui_enabled)
    ["--run", run_id, ..rest] ->
      parse_resume_flags(rest, types.RunId(run_id), ui_enabled)
    ["--ui", ..rest] -> parse_resume_flags(rest, run, True)
    [flag, ..] -> Error("Unsupported flag: " <> flag)
  }
}

fn parse_review(args: List(String)) -> Result(types.Command, String) {
  parse_review_flags(args, types.empty_agent_overrides(), None)
}

fn parse_review_flags(
  args: List(String),
  agent_overrides: types.AgentOverrides,
  environment_name: Option(String),
) -> Result(types.Command, String) {
  case args {
    [] -> Ok(types.Review(agent_overrides, environment_name))
    ["--profile", profile_name, ..rest] ->
      parse_review_flags(
        rest,
        types.AgentOverrides(..agent_overrides, profile: Some(profile_name)),
        environment_name,
      )
    ["--provider", raw_provider, ..rest] -> {
      use provider <- result.try(types.provider_from_string(raw_provider))
      parse_review_flags(
        rest,
        types.AgentOverrides(..agent_overrides, provider: Some(provider)),
        environment_name,
      )
    }
    ["--model", model, ..rest] ->
      parse_review_flags(
        rest,
        types.AgentOverrides(..agent_overrides, model: Some(model)),
        environment_name,
      )
    ["--reasoning", raw_reasoning, ..rest] -> {
      use reasoning <- result.try(types.reasoning_from_string(raw_reasoning))
      parse_review_flags(
        rest,
        types.AgentOverrides(..agent_overrides, reasoning: Some(reasoning)),
        environment_name,
      )
    }
    ["--environment", name, ..rest] ->
      parse_review_flags(rest, agent_overrides, Some(name))
    [flag, ..] -> Error("Unsupported review flag: " <> flag)
  }
}

fn parse_run_lookup(
  args: List(String),
  constructor: fn(types.RunSelector) -> types.Command,
) -> Result(types.Command, String) {
  case args {
    [] -> Ok(constructor(types.LatestRun))
    ["--run", "latest"] -> Ok(constructor(types.LatestRun))
    ["--run", run_id] -> Ok(constructor(types.RunId(run_id)))
    [flag, ..] -> Error("Unsupported flag: " <> flag)
  }
}
