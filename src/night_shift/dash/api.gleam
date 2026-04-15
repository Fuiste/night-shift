import filepath
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import night_shift/agent_config
import night_shift/config
import night_shift/dash/projection
import night_shift/dash/session
import night_shift/journal
import night_shift/project
import night_shift/provider_models
import night_shift/system
import night_shift/types
import night_shift/usecase/init as init_usecase
import night_shift/usecase/plan as plan_usecase
import night_shift/usecase/resolve as resolve_usecase
import night_shift/usecase/resume as resume_usecase
import night_shift/usecase/start as start_usecase
import simplifile

pub fn workspace_json(
  repo_root: String,
  requested_run_id: Option(String),
) -> Result(String, String) {
  let #(resolved_config, initialized) = load_repo_config(repo_root)
  projection.workspace_json(
    repo_root,
    requested_run_id,
    resolved_config,
    initialized,
    session.command_state(repo_root),
  )
}

pub fn init_models_json(
  repo_root: String,
  provider_name: String,
) -> Result(String, String) {
  use provider <- result.try(types.provider_from_string(provider_name))
  use models <- result.try(provider_models.list_models(provider, repo_root))
  Ok(
    json.object([
      #("provider", json.string(provider_name)),
      #(
        "models",
        json.array(models, fn(model) {
          json.object([
            #("id", json.string(model.id)),
            #("label", json.string(model.label)),
            #("is_default", json.bool(model.is_default)),
          ])
        }),
      ),
      #("default_index", json.int(provider_models.default_index(models))),
    ])
    |> json.to_string,
  )
}

pub fn init_action(repo_root: String, body: String) -> Result(String, String) {
  use request <- result.try(decode_body(body, init_request_decoder()))
  let #(base_config, _) = load_repo_config(repo_root)
  let overrides =
    types.AgentOverrides(
      profile: request.profile,
      provider: Some(request.provider),
      model: Some(request.model),
      reasoning: request.reasoning,
    )

  use result_view <- result.try(
    init_usecase.execute(
      repo_root,
      base_config,
      overrides,
      request.generate_setup,
      True,
      fn(_, _) { Ok(request.provider) },
      fn(_, _, _, _) { Ok(request.model) },
      fn(_, _, _) { Ok(request.generate_setup) },
    ),
  )

  Ok(command_response_json(
    "Initialization complete. " <> result_view.next_action,
    result_view.next_action,
    None,
  ))
}

pub fn plan_action(
  repo_root: String,
  body: String,
  from_reviews: Bool,
) -> Result(String, String) {
  let resolved_config = require_initialized_config(repo_root)
  use config_value <- result.try(resolved_config)
  use request <- result.try(decode_body(body, plan_request_decoder()))
  let overrides = request.overrides
  use planning_agent <- result.try(agent_config.resolve_plan_agent(
    config_value,
    overrides,
  ))
  use view <- result.try(plan_usecase.execute(
    repo_root,
    request.notes,
    from_reviews,
    request.doc_path,
    planning_agent,
    config_value,
  ))
  Ok(command_response_json(
    "Planning complete.",
    view.next_action,
    Some(view.run.run_id),
  ))
}

pub fn start_command(
  repo_root: String,
  run_id: String,
) -> Result(String, String) {
  use config_value <- result.try(require_initialized_config(repo_root))
  use view <- result.try(start_usecase.execute(
    repo_root,
    types.RunId(run_id),
    config_value,
  ))
  Ok(command_response_json(
    "Start finished.",
    view.next_action,
    Some(view.run.run_id),
  ))
}

pub fn resume_command(
  repo_root: String,
  run_id: String,
) -> Result(String, String) {
  use config_value <- result.try(require_initialized_config(repo_root))
  use view <- result.try(resume_usecase.execute(
    repo_root,
    types.RunId(run_id),
    config_value,
  ))
  Ok(command_response_json(
    "Resume finished.",
    view.next_action,
    Some(view.run.run_id),
  ))
}

pub fn resolve_decisions_action(
  repo_root: String,
  run_id: String,
  body: String,
) -> Result(String, String) {
  use config_value <- result.try(require_initialized_config(repo_root))
  use request <- result.try(decode_body(body, decision_resolution_decoder()))
  let answers =
    request.answers
    |> list.map(fn(answer) {
      types.RecordedDecision(
        key: answer.key,
        question: answer.question,
        answer: answer.answer,
        answered_at: system.timestamp(),
      )
    })
  use view <- result.try(
    resolve_usecase.execute(
      repo_root,
      types.RunId(run_id),
      None,
      None,
      config_value,
      fn(_, _) { Ok(#(answers, [])) },
    ),
  )
  Ok(command_response_json(
    resolve_summary(view.summary, "Decision resolution complete."),
    view.next_action,
    Some(view.run.run_id),
  ))
}

pub fn recovery_action(
  repo_root: String,
  run_id: String,
  action_name: String,
  body: String,
) -> Result(String, String) {
  use config_value <- result.try(require_initialized_config(repo_root))
  use action <- result.try(parse_recovery_action(action_name))
  let task_id =
    decode_body(body, recovery_request_decoder())
    |> result.unwrap(or: RecoveryRequest(task_id: None))
    |> fn(request) { request.task_id }
  use view <- result.try(
    resolve_usecase.execute(
      repo_root,
      types.RunId(run_id),
      task_id,
      Some(action),
      config_value,
      fn(_, _) {
        Error("Dashboard recovery actions do not collect planning decisions.")
      },
    ),
  )
  Ok(command_response_json(
    resolve_summary(view.summary, "Recovery updated.")
      <> "\nNext action: "
      <> view.next_action,
    view.next_action,
    Some(view.run.run_id),
  ))
}

pub fn artifact_contents(
  repo_root: String,
  run_id: String,
  path_segments: List(String),
) -> Result(#(String, String), String) {
  use _ <- result.try(validate_artifact_segments(path_segments))
  use #(run, _) <- result.try(journal.load(repo_root, types.RunId(run_id)))
  let absolute_path = filepath.join(run.run_path, join_segments(path_segments))
  use contents <- result.try(case simplifile.read(absolute_path) {
    Ok(value) -> Ok(value)
    Error(error) ->
      Error(
        "Unable to read artifact "
        <> absolute_path
        <> ": "
        <> simplifile.describe_error(error),
      )
  })
  Ok(#(artifact_content_type(path_segments), contents))
}

type InitRequest {
  InitRequest(
    provider: types.Provider,
    model: String,
    reasoning: Option(types.ReasoningLevel),
    profile: Option(String),
    generate_setup: Bool,
  )
}

type PlanRequest {
  PlanRequest(
    notes: Option(String),
    doc_path: Option(String),
    overrides: types.AgentOverrides,
  )
}

type DecisionAnswer {
  DecisionAnswer(key: String, question: String, answer: String)
}

type DecisionResolutionRequest {
  DecisionResolutionRequest(answers: List(DecisionAnswer))
}

type RecoveryRequest {
  RecoveryRequest(task_id: Option(String))
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

fn require_initialized_config(repo_root: String) -> Result(types.Config, String) {
  let #(loaded_config, initialized) = load_repo_config(repo_root)
  case initialized {
    True -> Ok(loaded_config)
    False ->
      Error(
        "Night Shift is not initialized for this repository. Open `night-shift dash` and use the init flow first.",
      )
  }
}

fn command_response_json(
  summary: String,
  next_action: String,
  run_id: Option(String),
) -> String {
  json.object([
    #("ok", json.bool(True)),
    #("summary", json.string(summary)),
    #("next_action", json.string(next_action)),
    #("run_id", json.nullable(from: run_id, of: json.string)),
  ])
  |> json.to_string
}

fn parse_recovery_action(
  action_name: String,
) -> Result(types.ResolveAction, String) {
  case action_name {
    "inspect" -> Ok(types.ResolveInspect)
    "continue" -> Ok(types.ResolveContinue)
    "complete" -> Ok(types.ResolveComplete)
    "abandon" -> Ok(types.ResolveAbandon)
    _ -> Error("Unsupported dashboard recovery action: " <> action_name)
  }
}

fn validate_artifact_segments(
  path_segments: List(String),
) -> Result(Nil, String) {
  case
    list.any(path_segments, fn(segment) {
      segment == "" || segment == "." || segment == ".."
    })
  {
    True -> Error("Invalid artifact path.")
    False -> Ok(Nil)
  }
}

fn join_segments(segments: List(String)) -> String {
  case segments {
    [] -> ""
    [segment] -> segment
    [segment, ..rest] -> filepath.join(segment, join_segments(rest))
  }
}

fn artifact_content_type(path_segments: List(String)) -> String {
  case reverse(path_segments, []) {
    ["json", ..] -> "application/json; charset=utf-8"
    ["md", ..] -> "text/markdown; charset=utf-8"
    ["log", ..] -> "text/plain; charset=utf-8"
    _ -> "text/plain; charset=utf-8"
  }
}

fn reverse(items: List(String), acc: List(String)) -> List(String) {
  case items {
    [] -> acc
    [item, ..rest] -> reverse(rest, [item, ..acc])
  }
}

fn resolve_summary(summary: Option(String), fallback: String) -> String {
  case summary {
    Some(value) -> value
    None -> fallback
  }
}

fn decode_body(body: String, decoder: decode.Decoder(a)) -> Result(a, String) {
  json.parse(body, decoder)
  |> result.map_error(fn(_) { "Invalid dashboard request body." })
}

fn init_request_decoder() -> decode.Decoder(InitRequest) {
  use raw_provider <- decode.field("provider", decode.string)
  use model <- decode.field("model", decode.string)
  use maybe_reasoning <- decode.optional_field(
    "reasoning",
    None,
    decode.optional(decode.string),
  )
  use profile <- decode.optional_field(
    "profile",
    None,
    decode.optional(decode.string),
  )
  use generate_setup <- decode.optional_field(
    "generate_setup",
    False,
    decode.bool,
  )
  case types.provider_from_string(raw_provider) {
    Ok(provider) ->
      decode.success(InitRequest(
        provider: provider,
        model: model,
        reasoning: parse_reasoning(maybe_reasoning),
        profile: profile,
        generate_setup: generate_setup,
      ))
    Error(_) ->
      decode.failure(
        InitRequest(
          provider: types.Codex,
          model: "",
          reasoning: None,
          profile: None,
          generate_setup: False,
        ),
        "InitRequest",
      )
  }
}

fn plan_request_decoder() -> decode.Decoder(PlanRequest) {
  use notes <- decode.optional_field(
    "notes",
    None,
    decode.optional(decode.string),
  )
  use doc_path <- decode.optional_field(
    "doc_path",
    None,
    decode.optional(decode.string),
  )
  use profile <- decode.optional_field(
    "profile",
    None,
    decode.optional(decode.string),
  )
  use raw_provider <- decode.optional_field(
    "provider",
    None,
    decode.optional(decode.string),
  )
  use model <- decode.optional_field(
    "model",
    None,
    decode.optional(decode.string),
  )
  use maybe_reasoning <- decode.optional_field(
    "reasoning",
    None,
    decode.optional(decode.string),
  )
  decode.success(PlanRequest(
    notes: notes,
    doc_path: doc_path,
    overrides: types.AgentOverrides(
      profile: profile,
      provider: parse_provider(raw_provider),
      model: model,
      reasoning: parse_reasoning(maybe_reasoning),
    ),
  ))
}

fn decision_resolution_decoder() -> decode.Decoder(DecisionResolutionRequest) {
  use answers <- decode.field("answers", decode.list(decision_answer_decoder()))
  decode.success(DecisionResolutionRequest(answers: answers))
}

fn decision_answer_decoder() -> decode.Decoder(DecisionAnswer) {
  use key <- decode.field("key", decode.string)
  use question <- decode.field("question", decode.string)
  use answer <- decode.field("answer", decode.string)
  decode.success(DecisionAnswer(key: key, question: question, answer: answer))
}

fn recovery_request_decoder() -> decode.Decoder(RecoveryRequest) {
  use task_id <- decode.optional_field(
    "task_id",
    None,
    decode.optional(decode.string),
  )
  decode.success(RecoveryRequest(task_id: task_id))
}

fn parse_reasoning(
  maybe_reasoning: Option(String),
) -> Option(types.ReasoningLevel) {
  case maybe_reasoning {
    Some(raw_reasoning) ->
      case types.reasoning_from_string(raw_reasoning) {
        Ok(level) -> Some(level)
        Error(_) -> None
      }
    None -> None
  }
}

fn parse_provider(maybe_provider: Option(String)) -> Option(types.Provider) {
  case maybe_provider {
    Some(raw_provider) ->
      case types.provider_from_string(raw_provider) {
        Ok(provider) -> Some(provider)
        Error(_) -> None
      }
    None -> None
  }
}
