//// Repo-local Night Shift config parsing and rendering.
////
//// The format is intentionally small and line-oriented so operators can edit
//// it by hand and Night Shift can round-trip it predictably.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/codec/shared
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

/// Load repo-local config from disk, falling back to defaults when the file
/// does not exist yet.
pub fn load(path: String) -> Result(types.Config, String) {
  case simplifile.read(path) {
    Ok(contents) -> parse(contents)
    Error(_) -> Ok(types.default_config())
  }
}

/// Render config to the repo-local file format.
pub fn render(config: types.Config) -> String {
  let root_lines = [
    "default_profile = " <> shared.render_string(config.default_profile),
    "planning_profile = " <> shared.render_string(config.planning_profile),
    "execution_profile = " <> shared.render_string(config.execution_profile),
    "",
    "base_branch = " <> shared.render_string(config.base_branch),
    "max_workers = " <> int.to_string(config.max_workers),
    "branch_prefix = " <> shared.render_string(config.branch_prefix),
    "pr_title_prefix = " <> shared.render_string(config.pr_title_prefix),
    "notifiers = "
      <> shared.render_string_list(
      config.notifiers |> list.map(types.notifier_to_string),
    ),
  ]

  let profile_lines =
    config.profiles
    |> list.map(render_profile)
    |> string.join(with: "\n\n")

  let verification_lines = case config.verification_commands {
    [] -> ""
    _ ->
      "\n\n[verification]\ncommands = "
      <> shared.render_string_list(config.verification_commands)
  }

  string.join(root_lines, with: "\n")
  <> "\n\n"
  <> profile_lines
  <> verification_lines
  <> "\n"
}

/// Parse repo-local config contents.
///
/// ## Examples
///
/// ```gleam
/// > parse("default_profile = \"default\"\nbase_branch = \"main\"\nmax_workers = 4\nbranch_prefix = \"night-shift\"\npr_title_prefix = \"[night-shift]\"\nnotifiers = [\"console\", \"report_file\"]\n")
/// Ok(types.default_config())
/// ```
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
    |> shared.strip_comments
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
        types.Config(..config, base_branch: shared.parse_string(raw_value)),
        state.section,
      ))

    RootSection, "default_profile" ->
      Ok(ParseState(
        types.Config(..config, default_profile: shared.parse_string(raw_value)),
        state.section,
      ))

    RootSection, "planning_profile" ->
      Ok(ParseState(
        types.Config(..config, planning_profile: shared.parse_string(raw_value)),
        state.section,
      ))

    RootSection, "execution_profile" ->
      Ok(ParseState(
        types.Config(
          ..config,
          execution_profile: shared.parse_string(raw_value),
        ),
        state.section,
      ))

    RootSection, "review_profile" ->
      Ok(ParseState(
        types.Config(..config, review_profile: shared.parse_string(raw_value)),
        state.section,
      ))

    RootSection, "max_workers" -> {
      use worker_count <- result.try(shared.parse_int(raw_value, "config"))
      Ok(ParseState(
        types.Config(..config, max_workers: worker_count),
        state.section,
      ))
    }

    RootSection, "branch_prefix" ->
      Ok(ParseState(
        types.Config(..config, branch_prefix: shared.parse_string(raw_value)),
        state.section,
      ))

    RootSection, "pr_title_prefix" ->
      Ok(ParseState(
        types.Config(..config, pr_title_prefix: shared.parse_string(raw_value)),
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
          verification_commands: shared.parse_string_list(raw_value),
        ),
        state.section,
      ))

    ProfileSection(profile_name), "provider" -> {
      use provider <- result.try(
        shared.parse_string(raw_value)
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
          types.AgentProfile(
            ..profile,
            model: shared.parse_optional_string(raw_value),
          )
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
              shared.parse_string(raw_value),
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
  |> shared.parse_string_list
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
  case shared.parse_string(raw_value) {
    "" -> Ok(None)
    value ->
      types.reasoning_from_string(value)
      |> result.map(fn(reasoning) { Some(reasoning) })
  }
}

fn render_profile(profile: types.AgentProfile) -> String {
  let base_lines = [
    "[profiles." <> profile.name <> "]",
    "provider = "
      <> shared.render_string(types.provider_to_string(profile.provider)),
  ]

  let model_lines = case profile.model {
    Some(model) -> ["model = " <> shared.render_string(model)]
    None -> []
  }

  let reasoning_lines = case profile.reasoning {
    Some(reasoning) -> [
      "reasoning = "
      <> shared.render_string(types.reasoning_to_string(reasoning)),
    ]
    None -> []
  }

  let override_lines = case profile.provider_overrides {
    [] -> []
    overrides ->
      list.append(
        ["", "[profiles." <> profile.name <> ".provider_overrides]"],
        overrides
          |> list.map(fn(override) {
            override.key <> " = " <> shared.render_string(override.value)
          }),
      )
  }

  string.join(
    list.flatten([base_lines, model_lines, reasoning_lines, override_lines]),
    with: "\n",
  )
}
