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
  <> "  plan --from-reviews [--notes <file-or-inline-text>] [--doc <path>] [--profile <name>] [--provider <codex|cursor>] [--model <id>] [--reasoning <low|medium|high|xhigh>]\n"
  <> "  start [--run <id>|latest] [--ui]\n"
  <> "  status [--run <id>|latest]\n"
  <> "  report [--run <id>|latest]\n"
  <> "  provenance [--run <id>|latest] [--task <task-id>] [--format <json|md>]\n"
  <> "  doctor [--run <id>|latest]\n"
  <> "  resolve [--run <id>|latest]\n"
  <> "  resume [--run <id>|latest] [--ui|--explain]\n"
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
        ["provenance", ..rest] -> parse_provenance(rest)
        ["doctor", ..rest] -> parse_run_lookup(rest, types.Doctor)
        ["resolve", ..rest] -> parse_run_lookup(rest, types.Resolve)
        ["resume", ..rest] -> parse_resume(rest)
        ["review", ..] ->
          Error(
            "`night-shift review` was replaced by `night-shift plan --from-reviews`.",
          )
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
  parse_plan_flags(args, None, None, False, types.empty_agent_overrides())
}

fn parse_plan_flags(
  args: List(String),
  notes_path: Option(String),
  doc_path: Option(String),
  from_reviews: Bool,
  agent_overrides: types.AgentOverrides,
) -> Result(types.Command, String) {
  case args {
    [] ->
      case from_reviews, notes_path {
        True, _ -> Ok(types.Plan(notes_path, doc_path, True, agent_overrides))
        False, Some(path) ->
          Ok(types.Plan(Some(path), doc_path, False, agent_overrides))
        False, None ->
          Error("The plan command requires --notes <file-or-inline-text>.")
      }

    ["--notes", path, ..rest] ->
      parse_plan_flags(
        rest,
        Some(path),
        doc_path,
        from_reviews,
        agent_overrides,
      )

    ["--from-reviews", ..rest] ->
      parse_plan_flags(rest, notes_path, doc_path, True, agent_overrides)

    ["--doc", path, ..rest] ->
      parse_plan_flags(
        rest,
        notes_path,
        Some(path),
        from_reviews,
        agent_overrides,
      )

    ["--profile", profile_name, ..rest] ->
      parse_plan_flags(
        rest,
        notes_path,
        doc_path,
        from_reviews,
        types.AgentOverrides(..agent_overrides, profile: Some(profile_name)),
      )

    ["--provider", raw_provider, ..rest] -> {
      use provider <- result.try(types.provider_from_string(raw_provider))
      parse_plan_flags(
        rest,
        notes_path,
        doc_path,
        from_reviews,
        types.AgentOverrides(..agent_overrides, provider: Some(provider)),
      )
    }

    ["--model", model, ..rest] ->
      parse_plan_flags(
        rest,
        notes_path,
        doc_path,
        from_reviews,
        types.AgentOverrides(..agent_overrides, model: Some(model)),
      )

    ["--reasoning", raw_reasoning, ..rest] -> {
      use reasoning <- result.try(types.reasoning_from_string(raw_reasoning))
      parse_plan_flags(
        rest,
        notes_path,
        doc_path,
        from_reviews,
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
  parse_resume_flags(args, types.LatestRun, False, False)
}

fn parse_resume_flags(
  args: List(String),
  run: types.RunSelector,
  ui_enabled: Bool,
  explain_only: Bool,
) -> Result(types.Command, String) {
  case args {
    [] ->
      case ui_enabled && explain_only {
        True -> Error("`resume --explain` cannot be combined with `--ui`.")
        False -> Ok(types.Resume(run, ui_enabled, explain_only))
      }
    ["--run", "latest", ..rest] ->
      parse_resume_flags(rest, types.LatestRun, ui_enabled, explain_only)
    ["--run", run_id, ..rest] ->
      parse_resume_flags(rest, types.RunId(run_id), ui_enabled, explain_only)
    ["--ui", ..rest] -> parse_resume_flags(rest, run, True, explain_only)
    ["--explain", ..rest] ->
      parse_resume_flags(rest, run, ui_enabled, True)
    [flag, ..] -> Error("Unsupported flag: " <> flag)
  }
}

fn parse_provenance(args: List(String)) -> Result(types.Command, String) {
  parse_provenance_flags(args, types.LatestRun, None, types.ProvenanceMarkdown)
}

fn parse_provenance_flags(
  args: List(String),
  run: types.RunSelector,
  task_id: Option(String),
  format: types.ProvenanceFormat,
) -> Result(types.Command, String) {
  case args {
    [] -> Ok(types.Provenance(run, task_id, format))
    ["--run", "latest", ..rest] ->
      parse_provenance_flags(rest, types.LatestRun, task_id, format)
    ["--run", run_id, ..rest] ->
      parse_provenance_flags(rest, types.RunId(run_id), task_id, format)
    ["--task", next_task_id, ..rest] ->
      parse_provenance_flags(rest, run, Some(next_task_id), format)
    ["--format", "json", ..rest] ->
      parse_provenance_flags(rest, run, task_id, types.ProvenanceJson)
    ["--format", "md", ..rest] ->
      parse_provenance_flags(rest, run, task_id, types.ProvenanceMarkdown)
    ["--format", raw_format, ..] ->
      Error("Unsupported provenance format: " <> raw_format)
    [flag, ..] -> Error("Unsupported flag: " <> flag)
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
