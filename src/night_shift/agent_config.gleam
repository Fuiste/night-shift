import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import night_shift/types

pub fn resolve_plan_agent(
  config: types.Config,
  overrides: types.AgentOverrides,
) -> Result(types.ResolvedAgentConfig, String) {
  resolve_profile(
    config,
    fallback_phase_profile(config.planning_profile, config),
    overrides,
  )
}

pub fn resolve_start_agents(
  config: types.Config,
  overrides: types.AgentOverrides,
) -> Result(#(types.ResolvedAgentConfig, types.ResolvedAgentConfig), String) {
  use planning_agent <- result.try(resolve_profile(
    config,
    fallback_phase_profile(config.planning_profile, config),
    overrides,
  ))
  use execution_agent <- result.try(resolve_profile(
    config,
    fallback_phase_profile(config.execution_profile, config),
    overrides,
  ))
  Ok(#(planning_agent, execution_agent))
}

pub fn resolve_review_agent(
  config: types.Config,
  overrides: types.AgentOverrides,
) -> Result(types.ResolvedAgentConfig, String) {
  resolve_profile(
    config,
    fallback_phase_profile(config.review_profile, config),
    overrides,
  )
}

pub fn effective_phase_profile_name(
  phase_profile_name: String,
  config: types.Config,
) -> String {
  fallback_phase_profile(phase_profile_name, config)
}

pub fn summary(agent: types.ResolvedAgentConfig) -> String {
  let model = case agent.model {
    Some(model) -> model
    None -> "default"
  }
  let reasoning = case agent.reasoning {
    Some(level) -> types.reasoning_to_string(level)
    None -> "default"
  }

  agent.profile_name
  <> " (provider: "
  <> types.provider_to_string(agent.provider)
  <> ", model: "
  <> model
  <> ", reasoning: "
  <> reasoning
  <> ")"
}

fn resolve_profile(
  config: types.Config,
  phase_profile_name: String,
  overrides: types.AgentOverrides,
) -> Result(types.ResolvedAgentConfig, String) {
  let selected_profile_name = case overrides.profile {
    Some(profile_name) -> profile_name
    None -> phase_profile_name
  }

  use profile <- result.try(find_profile(config.profiles, selected_profile_name))
  let provider = case overrides.provider {
    Some(provider) -> provider
    None -> profile.provider
  }
  let provider_overrides = case overrides.provider {
    Some(override_provider) if override_provider != profile.provider -> []
    _ -> profile.provider_overrides
  }

  Ok(types.ResolvedAgentConfig(
    profile_name: selected_profile_name,
    provider: provider,
    model: choose_optional_string(overrides.model, profile.model),
    reasoning: choose_optional_reasoning(overrides.reasoning, profile.reasoning),
    provider_overrides: provider_overrides,
  ))
}

fn find_profile(
  profiles: List(types.AgentProfile),
  profile_name: String,
) -> Result(types.AgentProfile, String) {
  case list.find(profiles, fn(profile) { profile.name == profile_name }) {
    Ok(profile) -> Ok(profile)
    Error(Nil) -> Error("Unknown agent profile: " <> profile_name)
  }
}

fn choose_optional_string(
  candidate: Option(String),
  fallback: Option(String),
) -> Option(String) {
  case candidate {
    Some(value) -> Some(value)
    None -> fallback
  }
}

fn choose_optional_reasoning(
  candidate: Option(types.ReasoningLevel),
  fallback: Option(types.ReasoningLevel),
) -> Option(types.ReasoningLevel) {
  case candidate {
    Some(value) -> Some(value)
    None -> fallback
  }
}

fn fallback_phase_profile(
  phase_profile_name: String,
  config: types.Config,
) -> String {
  case phase_profile_name {
    "" -> config.default_profile
    profile_name -> profile_name
  }
}
