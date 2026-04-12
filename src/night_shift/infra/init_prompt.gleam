import gleam/list
import gleam/option.{None, Some}
import gleam/result
import night_shift/infra/terminal_ui
import night_shift/provider_models
import night_shift/types

pub fn choose_setup_request(
  generate_setup: Bool,
  assume_yes: Bool,
  setup_exists: Bool,
) -> Result(Bool, String) {
  case setup_exists {
    True -> Ok(False)
    False ->
      case generate_setup, assume_yes {
        True, _ -> Ok(True)
        False, True -> Ok(False)
        False, False ->
          case terminal_ui.can_prompt_interactively() {
            True ->
              Ok(
                terminal_ui.select_from_labels(
                  "3. Should Night Shift draft an initial worktree setup using that provider?",
                  [
                    "Yes, draft worktree-setup.toml",
                    "No, create the blank template",
                  ],
                  0,
                )
                == 0,
              )
            False ->
              Error(
                "night-shift init needs either --generate-setup or --yes when not running in an interactive terminal.",
              )
          }
      }
  }
}

pub fn resolve_provider(
  config: types.Config,
  agent_overrides: types.AgentOverrides,
) -> Result(types.Provider, String) {
  case agent_overrides.provider {
    Some(provider_name) -> Ok(provider_name)
    None ->
      case terminal_ui.can_prompt_interactively() {
        True -> {
          let options = [
            "codex - OpenAI Codex CLI",
            "cursor - Cursor Agent",
          ]
          let default_index = default_provider_index(config)
          case
            terminal_ui.select_from_labels(
              "1. Which provider do you want to use?",
              options,
              default_index,
            )
          {
            1 -> Ok(types.Cursor)
            _ -> Ok(types.Codex)
          }
        }
        False ->
          Error(
            "night-shift init needs --provider <codex|cursor> when not running in an interactive terminal.",
          )
      }
  }
}

pub fn resolve_model(
  repo_root: String,
  config: types.Config,
  provider_name: types.Provider,
  agent_overrides: types.AgentOverrides,
) -> Result(String, String) {
  case agent_overrides.model {
    Some(model) -> Ok(model)
    None ->
      case terminal_ui.can_prompt_interactively() {
        True -> {
          use models <- result.try(provider_models.list_models(
            provider_name,
            repo_root,
          ))
          let labels = models |> list.map(fn(model) { model.label })
          let default_index =
            preferred_model_index(config, provider_name, models)
          let selected_index =
            terminal_ui.select_from_labels(
              "2. Which "
                <> types.provider_to_string(provider_name)
                <> " model should be your default?",
              labels,
              default_index,
            )
          use selected <- result.try(model_id_at(models, selected_index))
          Ok(selected)
        }
        False ->
          Error(
            "night-shift init needs --model <id> when not running in an interactive terminal.",
          )
      }
  }
}

fn default_provider_index(config: types.Config) -> Int {
  case default_profile(config) {
    Ok(profile) ->
      case profile.provider {
        types.Cursor -> 1
        _ -> 0
      }
    Error(_) -> 0
  }
}

fn preferred_model_index(
  config: types.Config,
  provider_name: types.Provider,
  models: List(provider_models.ProviderModel),
) -> Int {
  case default_profile(config) {
    Ok(profile) if profile.provider == provider_name ->
      case profile.model {
        Some(model_id) -> find_model_index(models, model_id, 0)
        None -> provider_models.default_index(models)
      }
    _ -> provider_models.default_index(models)
  }
}

fn default_profile(config: types.Config) -> Result(types.AgentProfile, Nil) {
  list.find(config.profiles, fn(profile) {
    profile.name == config.default_profile
  })
}

fn find_model_index(
  models: List(provider_models.ProviderModel),
  target: String,
  index: Int,
) -> Int {
  case models {
    [] -> 0
    [model, ..rest] ->
      case model.id == target {
        True -> index
        False -> find_model_index(rest, target, index + 1)
      }
  }
}

fn model_id_at(
  models: List(provider_models.ProviderModel),
  index: Int,
) -> Result(String, String) {
  case models, index {
    [model, ..], 0 -> Ok(model.id)
    [_, ..rest], _ -> model_id_at(rest, index - 1)
    [], _ -> Error("The selected model was out of range.")
  }
}
