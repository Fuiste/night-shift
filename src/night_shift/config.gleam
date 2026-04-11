import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/types
import simplifile

type Section {
  RootSection
  VerificationSection
  ProfileSection(name: String)
  ProfileOverridesSection(name: String)
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
    _ ->
      case string.starts_with(cleaned, "["), string.ends_with(cleaned, "]") {
        True, True ->
          parse_section(cleaned)
          |> result.map(fn(section) { ParseState(state.config, section) })
        _, _ -> parse_assignment(cleaned, state)
      }
  }
}

fn parse_section(section: String) -> Result(Section, String) {
  let inner =
    section
    |> string.drop_start(1)
    |> string.drop_end(1)

  case inner {
    "verification" -> Ok(VerificationSection)
    _ ->
      case string.split(inner, ".") {
        ["profiles", name] -> Ok(ProfileSection(name))
        ["profiles", name, "provider_overrides"] ->
          Ok(ProfileOverridesSection(name))
        _ -> Error("Unsupported config section: " <> section)
      }
  }
}

fn strip_comments(line: String) -> String {
  case string.split(line, "#") {
    [first, ..] -> first
    [] -> line
  }
}

fn parse_assignment(
  assignment: String,
  state: ParseState,
) -> Result(ParseState, String) {
  case string.split_once(assignment, "=") {
    Ok(#(key, value)) ->
      apply_value(string.trim(key), string.trim(value), state)
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

    RootSection, "default_profile" ->
      Ok(ParseState(
        types.Config(..config, default_profile: parse_string(raw_value)),
        state.section,
      ))

    RootSection, "planning_profile" ->
      Ok(ParseState(
        types.Config(..config, planning_profile: parse_string(raw_value)),
        state.section,
      ))

    RootSection, "execution_profile" ->
      Ok(ParseState(
        types.Config(..config, execution_profile: parse_string(raw_value)),
        state.section,
      ))

    RootSection, "review_profile" ->
      Ok(ParseState(
        types.Config(..config, review_profile: parse_string(raw_value)),
        state.section,
      ))

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
      Ok(ParseState(types.Config(..config, notifiers: notifiers), state.section))
    }

    VerificationSection, "commands" ->
      Ok(ParseState(
        types.Config(
          ..config,
          verification_commands: parse_string_list(raw_value),
        ),
        state.section,
      ))

    ProfileSection(profile_name), "provider" -> {
      use provider <- result.try(
        parse_string(raw_value)
        |> types.provider_from_string,
      )
      Ok(ParseState(
        upsert_profile(state.config, profile_name, fn(profile) {
          types.AgentProfile(..profile, provider: provider)
        }),
        state.section,
      ))
    }

    ProfileSection(profile_name), "model" ->
      Ok(ParseState(
        upsert_profile(state.config, profile_name, fn(profile) {
          types.AgentProfile(..profile, model: parse_optional_string(raw_value))
        }),
        state.section,
      ))

    ProfileSection(profile_name), "reasoning" -> {
      use reasoning <- result.try(parse_optional_reasoning(raw_value))
      Ok(ParseState(
        upsert_profile(state.config, profile_name, fn(profile) {
          types.AgentProfile(..profile, reasoning: reasoning)
        }),
        state.section,
      ))
    }

    ProfileOverridesSection(profile_name), override_key ->
      Ok(ParseState(
        upsert_profile(state.config, profile_name, fn(profile) {
          types.AgentProfile(
            ..profile,
            provider_overrides: upsert_provider_override(
              profile.provider_overrides,
              override_key,
              parse_string(raw_value),
            ),
          )
        }),
        state.section,
      ))

    _, _ -> Error("Unsupported config key: " <> key)
  }
}

fn upsert_profile(
  config: types.Config,
  profile_name: String,
  update: fn(types.AgentProfile) -> types.AgentProfile,
) -> types.Config {
  let updated_profiles =
    upsert_profile_in_list(config.profiles, profile_name, update)
  types.Config(..config, profiles: updated_profiles)
}

fn upsert_profile_in_list(
  profiles: List(types.AgentProfile),
  profile_name: String,
  update: fn(types.AgentProfile) -> types.AgentProfile,
) -> List(types.AgentProfile) {
  case profiles {
    [] -> [update(blank_profile(profile_name))]
    [profile, ..rest] if profile.name == profile_name -> [
      update(profile),
      ..rest
    ]
    [profile, ..rest] -> [
      profile,
      ..upsert_profile_in_list(rest, profile_name, update)
    ]
  }
}

fn blank_profile(name: String) -> types.AgentProfile {
  types.AgentProfile(..types.default_agent_profile(), name: name)
}

fn upsert_provider_override(
  overrides: List(types.ProviderOverride),
  key: String,
  value: String,
) -> List(types.ProviderOverride) {
  case overrides {
    [] -> [types.ProviderOverride(key: key, value: value)]
    [override, ..rest] if override.key == key -> [
      types.ProviderOverride(key: key, value: value),
      ..rest
    ]
    [override, ..rest] -> [
      override,
      ..upsert_provider_override(rest, key, value)
    ]
  }
}

fn parse_notifiers(
  raw_value: String,
) -> Result(List(types.NotifierName), String) {
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

fn parse_optional_reasoning(
  raw_value: String,
) -> Result(Option(types.ReasoningLevel), String) {
  case parse_string(raw_value) {
    "" -> Ok(None)
    value ->
      types.reasoning_from_string(value)
      |> result.map(fn(reasoning) { Some(reasoning) })
  }
}

fn parse_int(raw_value: String) -> Result(Int, String) {
  case int.parse(raw_value) {
    Ok(value) -> Ok(value)
    Error(Nil) -> Error("Expected integer but received: " <> raw_value)
  }
}

fn parse_optional_string(raw_value: String) -> Option(String) {
  case parse_string(raw_value) {
    "" -> None
    value -> Some(value)
  }
}

fn parse_string(raw_value: String) -> String {
  let trimmed = raw_value |> string.trim
  let without_prefix = case string.starts_with(trimmed, "\"") {
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
  let without_prefix = case string.starts_with(trimmed, "[") {
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
