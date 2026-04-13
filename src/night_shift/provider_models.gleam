//// Provider model discovery for interactive setup flows.

import filepath
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import night_shift/codec/artifact_path
import night_shift/journal
import night_shift/shell
import night_shift/types
import simplifile

/// A provider model that can be presented to the operator.
pub type ProviderModel {
  ProviderModel(id: String, label: String, is_default: Bool)
}

/// Ask a provider CLI for the models it can currently run.
pub fn list_models(
  provider_name: types.Provider,
  repo_root: String,
) -> Result(List(ProviderModel), String) {
  let artifact_path = model_artifact_path(repo_root)
  let provider_id = types.provider_to_string(provider_name)
  let log_path = filepath.join(artifact_path, provider_id <> "-models.log")
  use _ <- result.try(create_directory(artifact_path))
  let command = command_for(provider_name)
  let command_result = shell.run(command, repo_root, log_path)

  case shell.succeeded(command_result) {
    True ->
      parse_models(provider_name, command_result.output)
      |> result.map_error(fn(message) { message <> " See " <> log_path })
    False ->
      Error(
        "Unable to list models for provider "
        <> provider_id
        <> ". See "
        <> log_path,
      )
  }
}

/// Return the index of the default model, or `0` when none is marked.
pub fn default_index(models: List(ProviderModel)) -> Int {
  find_default_index(models, 0)
}

fn find_default_index(models: List(ProviderModel), index: Int) -> Int {
  case models {
    [] -> 0
    [model, ..rest] ->
      case model.is_default {
        True -> index
        False -> find_default_index(rest, index + 1)
      }
  }
}

fn parse_models(
  provider_name: types.Provider,
  output: String,
) -> Result(List(ProviderModel), String) {
  case provider_name {
    types.Codex -> parse_codex_models(output)
    types.Cursor -> parse_cursor_models(output)
  }
}

fn parse_cursor_models(output: String) -> Result(List(ProviderModel), String) {
  let models =
    output
    |> string.split("\n")
    |> list.filter_map(fn(line) {
      let trimmed = string.trim(line)
      case trimmed {
        "" -> Error(Nil)
        _ ->
          case string.split_once(trimmed, " - ") {
            Ok(#(id, description)) ->
              Ok(ProviderModel(
                id: string.trim(id),
                label: trimmed,
                is_default: is_cursor_default(description),
              ))
            Error(_) -> Error(Nil)
          }
      }
    })

  case models {
    [] -> Error("Cursor did not return any selectable models.")
    _ -> Ok(models)
  }
}

fn is_cursor_default(description: String) -> Bool {
  string.contains(does: description, contain: "(current, default)")
  || string.contains(does: description, contain: "(default)")
}

fn parse_codex_models(output: String) -> Result(List(ProviderModel), String) {
  let decoded =
    output
    |> string.split("\n")
    |> list.filter_map(fn(line) {
      let trimmed = string.trim(line)
      case trimmed {
        "" -> Error(Nil)
        _ ->
          case json.parse(trimmed, codex_model_list_decoder()) {
            Ok(models) -> Ok(models)
            Error(_) -> Error(Nil)
          }
      }
    })

  case decoded {
    [models, ..] -> Ok(models)
    [] -> Error("Codex did not return any selectable models.")
  }
}

fn codex_model_list_decoder() -> decode.Decoder(List(ProviderModel)) {
  use id <- decode.field("id", decode.int)
  case id {
    2 -> {
      use result <- decode.field("result", {
        use data <- decode.field("data", decode.list(codex_model_decoder()))
        decode.success(data)
      })
      decode.success(result)
    }
    _ -> decode.failure([], "CodexModelListResponse")
  }
}

fn codex_model_decoder() -> decode.Decoder(ProviderModel) {
  use id <- decode.field("id", decode.string)
  use display_name <- decode.field("displayName", decode.string)
  use description <- decode.field("description", decode.string)
  use is_default <- decode.field("isDefault", decode.bool)
  decode.success(ProviderModel(
    id: id,
    label: display_name <> " - " <> description,
    is_default: is_default,
  ))
}

fn command_for(provider_name: types.Provider) -> String {
  case provider_name {
    types.Codex -> codex_model_command()
    types.Cursor -> "cursor-agent --list-models"
  }
}

fn codex_model_command() -> String {
  let initialize =
    "{\"jsonrpc\":\"2.0\",\"method\":\"initialize\",\"id\":1,\"params\":{\"clientInfo\":{\"name\":\"night-shift\",\"title\":\"Night Shift\",\"version\":\"0.0.0\"},\"capabilities\":{\"experimentalApi\":false}}}"
  let list_request =
    "{\"jsonrpc\":\"2.0\",\"method\":\"model/list\",\"id\":2,\"params\":{\"limit\":100}}"

  "("
  <> "printf '%s\\n' "
  <> shell.quote(initialize)
  <> "; sleep 1; "
  <> "printf '%s\\n' "
  <> shell.quote(list_request)
  <> "; sleep 1"
  <> ") | codex app-server --listen stdio://"
}

fn model_artifact_path(repo_root: String) -> String {
  artifact_path.timestamped_directory(journal.planning_root_for(repo_root))
}

fn create_directory(path: String) -> Result(Nil, String) {
  case simplifile.create_directory_all(path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to create directory "
        <> path
        <> ": "
        <> simplifile.describe_error(error),
      )
  }
}
