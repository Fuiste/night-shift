//// Thin compatibility shim over the dedicated Dash application layer.

import gleam/json
import gleam/option.{None}
import gleam/result
import night_shift/config
import night_shift/dash/api
import night_shift/dash/assets
import night_shift/dash/projection
import night_shift/dash/session
import night_shift/project
import night_shift/types
import night_shift/usecase/resume as resume_usecase
import night_shift/usecase/start as start_usecase
import simplifile

@external(erlang, "night_shift_dashboard_server", "http_get")
pub fn http_get(url: String) -> Result(String, String)

@external(erlang, "night_shift_dashboard_server", "http_post")
pub fn http_post(url: String, body: String) -> Result(String, String)

pub fn start_view_session(
  repo_root: String,
  initial_run_id: String,
) -> Result(session.Session, String) {
  session_open(repo_root, initial_run_id)
}

pub fn start_start_session(
  repo_root: String,
  initial_run_id: String,
  _run: types.RunRecord,
  config: types.Config,
) -> Result(session.Session, String) {
  use opened <- result.try(session_open(repo_root, initial_run_id))
  use _ <- result.try(start_usecase.execute(
    repo_root,
    types.RunId(initial_run_id),
    config,
  ))
  Ok(opened)
}

pub fn start_resume_session(
  repo_root: String,
  initial_run_id: String,
  _run: types.RunRecord,
  config: types.Config,
) -> Result(session.Session, String) {
  use opened <- result.try(session_open(repo_root, initial_run_id))
  use _ <- result.try(resume_usecase.execute(
    repo_root,
    types.RunId(initial_run_id),
    config,
  ))
  Ok(opened)
}

pub fn stop_session(opened: session.Session) -> Nil {
  session.stop_session(opened)
}

pub fn runs_json(repo_root: String) -> Result(String, String) {
  use workspace <- result.try(api.workspace_json(repo_root, None))
  Ok(workspace)
}

pub fn run_json(repo_root: String, run_id: String) -> Result(String, String) {
  let #(config, initialized) = load_repo_config(repo_root)
  let command_state = session.command_state(repo_root)
  use run_payload <- result.try(projection.load_run_projection(
    repo_root,
    run_id,
    config,
  ))
  Ok(
    json.object([
      #("initialized", json.bool(initialized)),
      #(
        "command_state",
        json.nullable(from: command_state, of: command_state_json),
      ),
      #("run", json.nullable(from: run_payload, of: identity_json)),
    ])
    |> json.to_string,
  )
}

pub fn apply_recovery_action(
  repo_root: String,
  run_id: String,
  action_name: String,
) -> Result(String, String) {
  api.recovery_action(repo_root, run_id, action_name, "{}")
}

pub fn index_html(initial_run_id: String) -> Result(String, String) {
  assets.app_shell(initial_run_id)
}

fn session_open(
  repo_root: String,
  initial_run_id: String,
) -> Result(session.Session, String) {
  use _ <- result.try(assets.ensure_assets_ready())
  session.open(repo_root, initial_run_id)
}

fn load_repo_config(repo_root: String) -> #(types.Config, Bool) {
  let config_path = project.config_path(repo_root)
  case simplifile.read(config_path) {
    Ok(contents) ->
      case config.parse(contents) {
        Ok(parsed) -> #(parsed, True)
        Error(_) -> #(types.default_config(), False)
      }
    Error(_) -> #(types.default_config(), False)
  }
}

fn command_state_json(state: session.CommandState) -> json.Json {
  json.object([
    #("name", json.string(state.name)),
    #("run_id", json.nullable(from: state.run_id, of: json.string)),
    #("started_at", json.string(state.started_at)),
    #("summary", json.string(state.summary)),
  ])
}

fn identity_json(value: json.Json) -> json.Json {
  value
}
