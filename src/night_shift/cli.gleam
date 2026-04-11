import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import night_shift/types

pub fn usage() -> String {
  "Night Shift\n"
  <> "\n"
  <> "Commands:\n"
  <> "  --demo [--ui]\n"
  <> "  plan --notes <path> [--doc <path>] [--profile <name>] [--provider <codex|cursor>] [--model <id>] [--reasoning <low|medium|high|xhigh>]\n"
  <> "  start [--brief <path>] [--profile <name>] [--provider <codex|cursor>] [--model <id>] [--reasoning <low|medium|high|xhigh>] [--max-workers <n>] [--ui]\n"
  <> "  status [--run <id>|latest]\n"
  <> "  report [--run <id>|latest]\n"
  <> "  resume [--run <id>|latest] [--ui]\n"
  <> "  review [--profile <name>] [--provider <codex|cursor>] [--model <id>] [--reasoning <low|medium|high|xhigh>]\n"
}

pub fn parse(args: List(String)) -> Result(types.Command, String) {
  case contains_demo_flag(args) {
    True -> parse_demo(args, False)
    False ->
      case args {
        [] -> Ok(types.Help)
        ["help", ..] -> Ok(types.Help)
        ["plan", ..rest] -> parse_plan(rest)
        ["start", ..rest] -> parse_start(rest)
        ["status", ..rest] -> parse_run_lookup(rest, types.Status)
        ["report", ..rest] -> parse_run_lookup(rest, types.Report)
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
        Error(Nil) -> Error("The plan command requires --notes <path>.")
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

fn parse_start(args: List(String)) -> Result(types.Command, String) {
  parse_start_flags(args, None, types.empty_agent_overrides(), Error(Nil), False)
}

fn parse_start_flags(
  args: List(String),
  brief_path: Option(String),
  agent_overrides: types.AgentOverrides,
  max_workers: Result(Int, Nil),
  ui_enabled: Bool,
) -> Result(types.Command, String) {
  case args {
    [] -> Ok(types.Start(brief_path, agent_overrides, max_workers, ui_enabled))

    ["--brief", path, ..rest] ->
      parse_start_flags(rest, Some(path), agent_overrides, max_workers, ui_enabled)

    ["--profile", profile_name, ..rest] ->
      parse_start_flags(
        rest,
        brief_path,
        types.AgentOverrides(..agent_overrides, profile: Some(profile_name)),
        max_workers,
        ui_enabled,
      )

    ["--provider", raw_provider, ..rest] -> {
      use provider <- result.try(types.provider_from_string(raw_provider))
      parse_start_flags(
        rest,
        brief_path,
        types.AgentOverrides(..agent_overrides, provider: Some(provider)),
        max_workers,
        ui_enabled,
      )
    }

    ["--model", model, ..rest] ->
      parse_start_flags(
        rest,
        brief_path,
        types.AgentOverrides(..agent_overrides, model: Some(model)),
        max_workers,
        ui_enabled,
      )

    ["--reasoning", raw_reasoning, ..rest] -> {
      use reasoning <- result.try(types.reasoning_from_string(raw_reasoning))
      parse_start_flags(
        rest,
        brief_path,
        types.AgentOverrides(..agent_overrides, reasoning: Some(reasoning)),
        max_workers,
        ui_enabled,
      )
    }

    ["--max-workers", raw_count, ..rest] -> {
      use parsed_count <- result.try(parse_positive_int(raw_count))
      parse_start_flags(
        rest,
        brief_path,
        agent_overrides,
        Ok(parsed_count),
        ui_enabled,
      )
    }

    ["--ui", ..rest] ->
      parse_start_flags(rest, brief_path, agent_overrides, max_workers, True)

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
  parse_review_flags(args, types.empty_agent_overrides())
}

fn parse_review_flags(
  args: List(String),
  agent_overrides: types.AgentOverrides,
) -> Result(types.Command, String) {
  case args {
    [] -> Ok(types.Review(agent_overrides))
    ["--profile", profile_name, ..rest] ->
      parse_review_flags(
        rest,
        types.AgentOverrides(..agent_overrides, profile: Some(profile_name)),
      )
    ["--provider", raw_provider, ..rest] -> {
      use provider <- result.try(types.provider_from_string(raw_provider))
      parse_review_flags(
        rest,
        types.AgentOverrides(..agent_overrides, provider: Some(provider)),
      )
    }
    ["--model", model, ..rest] ->
      parse_review_flags(
        rest,
        types.AgentOverrides(..agent_overrides, model: Some(model)),
      )
    ["--reasoning", raw_reasoning, ..rest] -> {
      use reasoning <- result.try(types.reasoning_from_string(raw_reasoning))
      parse_review_flags(
        rest,
        types.AgentOverrides(..agent_overrides, reasoning: Some(reasoning)),
      )
    }
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

fn parse_positive_int(raw_value: String) -> Result(Int, String) {
  case int.parse(raw_value) {
    Ok(value) if value > 0 -> Ok(value)
    Ok(_) -> Error("--max-workers must be a positive integer.")
    Error(Nil) -> Error("Expected integer but received: " <> raw_value)
  }
}
