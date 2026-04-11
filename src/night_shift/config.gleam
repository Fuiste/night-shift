import gleam/int
import gleam/list
import gleam/result
import gleam/string
import night_shift/types
import simplifile

type Section {
  RootSection
  VerificationSection
  DiscordSection
}

type ParseState {
  ParseState(config: types.Config, section: Section)
}

pub fn load(path: String) -> Result(types.Config, String) {
  case simplifile.read(path) {
    Ok(contents) -> parse(contents)
    Error(_) -> Ok(types.default_config())
  }
}

pub fn parse(contents: String) -> Result(types.Config, String) {
  let initial = ParseState(types.default_config(), RootSection)

  contents
  |> string.split("\n")
  |> parse_lines(initial)
  |> result.map(fn(state) { state.config })
}

fn parse_lines(
  lines: List(String),
  state: ParseState,
) -> Result(ParseState, String) {
  case lines {
    [] -> Ok(state)
    [line, ..rest] -> {
      use next_state <- result.try(parse_line(line, state))
      parse_lines(rest, next_state)
    }
  }
}

fn parse_line(line: String, state: ParseState) -> Result(ParseState, String) {
  let cleaned =
    line
    |> strip_comments
    |> string.trim

  case cleaned {
    "" -> Ok(state)
    "[verification]" -> Ok(ParseState(state.config, VerificationSection))
    "[discord]" -> Ok(ParseState(state.config, DiscordSection))
    _ -> parse_assignment(cleaned, state)
  }
}

fn strip_comments(line: String) -> String {
  case string.split(line, "#") {
    [first, .._] -> first
    [] -> line
  }
}

fn parse_assignment(
  assignment: String,
  state: ParseState,
) -> Result(ParseState, String) {
  case string.split_once(assignment, "=") {
    Ok(#(key, value)) -> apply_value(
      string.trim(key),
      string.trim(value),
      state,
    )
    Error(Nil) -> Error("Invalid config line: " <> assignment)
  }
}

fn apply_value(
  key: String,
  raw_value: String,
  state: ParseState,
) -> Result(ParseState, String) {
  let config = state.config

  case state.section, key {
    RootSection, "base_branch" ->
      Ok(ParseState(
        types.Config(..config, base_branch: parse_string(raw_value)),
        state.section,
      ))

    RootSection, "default_harness" -> {
      use harness <- result.try(
        parse_string(raw_value)
        |> types.harness_from_string
      )

      Ok(ParseState(
        types.Config(..config, default_harness: harness),
        state.section,
      ))
    }

    RootSection, "max_workers" -> {
      use worker_count <- result.try(parse_int(raw_value))
      Ok(ParseState(
        types.Config(..config, max_workers: worker_count),
        state.section,
      ))
    }

    RootSection, "branch_prefix" ->
      Ok(ParseState(
        types.Config(..config, branch_prefix: parse_string(raw_value)),
        state.section,
      ))

    RootSection, "pr_title_prefix" ->
      Ok(ParseState(
        types.Config(..config, pr_title_prefix: parse_string(raw_value)),
        state.section,
      ))

    RootSection, "notifiers" -> {
      use notifiers <- result.try(parse_notifiers(raw_value))
      Ok(ParseState(
        types.Config(..config, notifiers: notifiers),
        state.section,
      ))
    }

    DiscordSection, "webhook_url_env" ->
      Ok(ParseState(
        types.Config(
          ..config,
          discord: types.DiscordConfig(webhook_url_env: parse_string(raw_value)),
        ),
        state.section,
      ))

    VerificationSection, "commands" ->
      Ok(ParseState(
        types.Config(..config, verification_commands: parse_string_list(raw_value)),
        state.section,
      ))

    _, _ -> Error("Unsupported config key: " <> key)
  }
}

fn parse_notifiers(raw_value: String) -> Result(List(types.NotifierName), String) {
  raw_value
  |> parse_string_list
  |> parse_notifier_values([])
}

fn parse_notifier_values(
  values: List(String),
  acc: List(types.NotifierName),
) -> Result(List(types.NotifierName), String) {
  case values {
    [] -> Ok(list.reverse(acc))
    [value, ..rest] -> {
      use notifier <- result.try(types.notifier_from_string(value))
      parse_notifier_values(rest, [notifier, ..acc])
    }
  }
}

fn parse_int(raw_value: String) -> Result(Int, String) {
  case int.parse(raw_value) {
    Ok(value) -> Ok(value)
    Error(Nil) -> Error("Expected integer but received: " <> raw_value)
  }
}

fn parse_string(raw_value: String) -> String {
  let trimmed = raw_value |> string.trim
  let without_prefix =
    case string.starts_with(trimmed, "\"") {
      True -> string.drop_start(trimmed, 1)
      False -> trimmed
    }

  case string.ends_with(without_prefix, "\"") {
    True -> string.drop_end(without_prefix, 1)
    False -> without_prefix
  }
}

fn parse_string_list(raw_value: String) -> List(String) {
  let trimmed = raw_value |> string.trim
  let without_prefix =
    case string.starts_with(trimmed, "[") {
      True -> string.drop_start(trimmed, 1)
      False -> trimmed
    }

  let inner =
    case string.ends_with(without_prefix, "]") {
      True -> string.drop_end(without_prefix, 1)
      False -> without_prefix
    }
    |> string.trim

  case inner {
    "" -> []
    _ ->
      inner
      |> string.split(",")
      |> list.map(fn(item) { parse_string(item) })
  }
}
