import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/types
import simplifile

pub const start_marker = "NIGHT_SHIFT_RESULT_START"

pub const end_marker = "NIGHT_SHIFT_RESULT_END"

@external(erlang, "night_shift_provider_support", "extract_balanced_json")
fn extract_balanced_json_raw(payload: String) -> String

pub type PayloadArtifacts {
  PayloadArtifacts(
    raw_payload_path: String,
    sanitized_payload_path: Option(String),
  )
}

pub type ExecutionPayloadTrust {
  ExactPayload
  SanitizedPayload
  RecoveredPayload
}

pub type DecodedExecutionPayload {
  DecodedExecutionPayload(
    execution_result: types.ExecutionResult,
    trust: ExecutionPayloadTrust,
    artifacts: PayloadArtifacts,
  )
}

pub type ExecutionDecodeError {
  PayloadExtractionFailure(message: String)
  JsonDecodeFailure(message: String, artifacts: PayloadArtifacts)
}

pub fn extract_payload(output: String) -> Result(String, String) {
  case extract_structured_output(output) {
    Ok(structured_output) -> extract_marker_payload(structured_output)
    Error(_) -> extract_marker_payload(output)
  }
}

pub fn extract_json_payload(output: String) -> Result(String, String) {
  extract_payload(output)
}

pub fn sanitize_json_payload(payload: String) -> Result(String, String) {
  case string.trim(extract_balanced_json_raw(payload)) {
    "" -> Error("Unable to recover a balanced JSON payload.")
    sanitized -> Ok(sanitized)
  }
}

pub fn decode_planned_tasks(output: String) -> Result(List(types.Task), String) {
  use payload <- result.try(extract_json_payload(output))
  json.parse(payload, planner_decoder())
  |> result.map_error(fn(_) { "Unable to decode planner output." })
}

pub fn decode_execution_result(
  output: String,
  log_path: String,
  failure_prefix: String,
) -> Result(types.ExecutionResult, String) {
  decode_execution_result_detailed(output, log_path, failure_prefix)
  |> result.map(fn(decoded) { decoded.execution_result })
  |> result.map_error(execution_decode_error_message)
}

pub fn decode_execution_result_detailed(
  output: String,
  log_path: String,
  failure_prefix: String,
) -> Result(DecodedExecutionPayload, ExecutionDecodeError) {
  use payload <- result.try(
    extract_payload(output)
    |> result.map_error(PayloadExtractionFailure),
  )
  let raw_payload_path = raw_payload_artifact_path(log_path)
  use _ <- result.try(
    write_file(raw_payload_path, payload)
    |> result.map_error(PayloadExtractionFailure),
  )

  case decode_execution_payload(payload) {
    Ok(#(decoded, trust, sanitized_payload)) -> {
      use _sanitized_payload_path <- result.try(persist_sanitized_payload(
        log_path,
        sanitized_payload,
      ))
      Ok(DecodedExecutionPayload(
        execution_result: decoded,
        trust: trust,
        artifacts: PayloadArtifacts(
          raw_payload_path: raw_payload_path,
          sanitized_payload_path: case sanitized_payload {
            Some(_) -> Some(sanitized_payload_artifact_path(log_path))
            None -> None
          },
        ),
      ))
    }
    Error(sanitized_payload) ->
      Error(JsonDecodeFailure(
        message: execution_decode_failure(
          failure_prefix,
          log_path,
          raw_payload_path,
          sanitized_payload,
          payload,
        ),
        artifacts: PayloadArtifacts(
          raw_payload_path: raw_payload_path,
          sanitized_payload_path: case sanitized_payload {
            Some(_) -> Some(sanitized_payload_artifact_path(log_path))
            None -> None
          },
        ),
      ))
  }
}

pub fn execution_decode_error_message(error: ExecutionDecodeError) -> String {
  case error {
    PayloadExtractionFailure(message) -> message
    JsonDecodeFailure(message, _) -> message
  }
}

fn extract_marker_payload(output: String) -> Result(String, String) {
  let sections =
    output
    |> string.split(start_marker)
    |> list.reverse

  use after_start <- result.try(case sections {
    [_] -> Error("Provider output did not contain the start marker.")
    [last_payload, ..] -> Ok(last_payload)
    [] -> Error("Provider output did not contain the start marker.")
  })

  use #(payload, _) <- result.try(
    string.split_once(after_start, end_marker)
    |> result.map_error(fn(_) {
      "Provider output did not contain the end marker."
    }),
  )

  Ok(string.trim(payload))
}

fn extract_structured_output(output: String) -> Result(String, String) {
  let messages =
    output
    |> string.split("\n")
    |> list.filter_map(fn(line) {
      case string.trim(line) {
        "" -> Error(Nil)
        trimmed ->
          case json.parse(trimmed, structured_output_decoder()) {
            Ok(text) -> Ok(text)
            Error(_) -> Error(Nil)
          }
      }
    })

  case messages {
    [] -> Error("Harness output did not contain a structured assistant result.")
    _ -> Ok(string.join(messages, with: "\n"))
  }
}

fn execution_decode_failure(
  prefix: String,
  log_path: String,
  raw_payload_path: String,
  sanitized_payload: Option(String),
  original_payload: String,
) -> String {
  prefix
  <> " Night Shift captured the provider result, but it was not a valid execution JSON object.\n"
  <> "Task log: "
  <> log_path
  <> "\n"
  <> "Raw payload: "
  <> raw_payload_path
  <> case sanitized_payload {
    Some(_) ->
      "\nSanitized payload: " <> sanitized_payload_artifact_path(log_path)
    None -> ""
  }
  <> case sanitized_payload {
    Some(sanitized) ->
      case sanitized == string.trim(original_payload) {
        True -> ""
        False ->
          "\nNight Shift recovered a candidate JSON object, but decoding still failed."
      }
    None -> ""
  }
}

fn decode_execution_payload(
  payload: String,
) -> Result(
  #(types.ExecutionResult, ExecutionPayloadTrust, Option(String)),
  Option(String),
) {
  let trimmed_payload = string.trim(payload)

  case json.parse(trimmed_payload, execution_decoder()) {
    Ok(decoded) -> Ok(#(decoded, ExactPayload, None))
    Error(_) -> {
      let balanced_candidate = case sanitize_json_payload(trimmed_payload) {
        Ok(sanitized) -> sanitized
        Error(_) -> trimmed_payload
      }
      case
        decode_execution_candidate(
          balanced_candidate,
          trimmed_payload,
          SanitizedPayload,
        )
      {
        Ok(decoded) -> Ok(decoded)
        Error(last_candidate) -> {
          let recovered_candidate = recover_json_prefix(trimmed_payload)
          case
            decode_execution_candidate(
              recovered_candidate,
              trimmed_payload,
              RecoveredPayload,
            )
          {
            Ok(decoded) -> Ok(decoded)
            Error(_) -> Error(last_candidate)
          }
        }
      }
    }
  }
}

fn decode_execution_candidate(
  candidate: String,
  original_payload: String,
  trust: ExecutionPayloadTrust,
) -> Result(
  #(types.ExecutionResult, ExecutionPayloadTrust, Option(String)),
  Option(String),
) {
  let trimmed_candidate = string.trim(candidate)
  case
    trimmed_candidate == ""
    || trimmed_candidate == string.trim(original_payload)
  {
    True -> Error(None)
    False ->
      case json.parse(trimmed_candidate, execution_decoder()) {
        Ok(decoded) -> Ok(#(decoded, trust, Some(trimmed_candidate)))
        Error(_) -> Error(Some(trimmed_candidate))
      }
  }
}

fn persist_sanitized_payload(
  log_path: String,
  sanitized_payload: Option(String),
) -> Result(Option(String), ExecutionDecodeError) {
  case sanitized_payload {
    Some(sanitized) -> {
      let path = sanitized_payload_artifact_path(log_path)
      use _ <- result.try(
        write_file(path, sanitized)
        |> result.map_error(PayloadExtractionFailure),
      )
      Ok(Some(path))
    }
    None -> Ok(None)
  }
}

fn recover_json_prefix(payload: String) -> String {
  recover_json_prefix_loop(payload, string.length(payload))
}

fn recover_json_prefix_loop(payload: String, width: Int) -> String {
  case width <= 0 {
    True -> payload
    False -> {
      let candidate =
        string.drop_end(payload, string.length(payload) - width)
        |> string.trim
      case candidate {
        "" -> recover_json_prefix_loop(payload, width - 1)
        _ ->
          case json.parse(candidate, execution_decoder()) {
            Ok(_) -> candidate
            Error(_) -> recover_json_prefix_loop(payload, width - 1)
          }
      }
    }
  }
}

pub fn payload_trust_label(trust: ExecutionPayloadTrust) -> String {
  case trust {
    ExactPayload -> "exact"
    SanitizedPayload -> "sanitized"
    RecoveredPayload -> "recovered"
  }
}

fn raw_payload_artifact_path(log_path: String) -> String {
  string.replace(in: log_path, each: ".log", with: ".result.raw.jsonish")
}

fn sanitized_payload_artifact_path(log_path: String) -> String {
  string.replace(in: log_path, each: ".log", with: ".result.sanitized.json")
}

fn write_file(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.write(contents, to: path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to write " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}

fn structured_output_decoder() -> decode.Decoder(String) {
  decode.one_of(cursor_result_decoder(), or: [codex_agent_message_decoder()])
}

fn codex_agent_message_decoder() -> decode.Decoder(String) {
  use event_type <- decode.field("type", decode.string)
  case event_type {
    "item.completed" -> {
      use item <- decode.field("item", {
        use item_type <- decode.field("type", decode.string)
        use text <- decode.field("text", decode.string)
        case item_type {
          "agent_message" -> decode.success(text)
          _ -> decode.failure("", "CodexAgentMessage")
        }
      })
      decode.success(item)
    }
    _ -> decode.failure("", "CodexAgentMessage")
  }
}

fn cursor_result_decoder() -> decode.Decoder(String) {
  use event_type <- decode.field("type", decode.string)
  case event_type {
    "result" -> {
      use result <- decode.field("result", decode.string)
      decode.success(result)
    }
    _ -> decode.failure("", "CursorResult")
  }
}

fn planner_decoder() -> decode.Decoder(List(types.Task)) {
  use tasks <- decode.field("tasks", decode.list(planned_task_decoder()))
  decode.success(tasks)
}

fn planned_task_decoder() -> decode.Decoder(types.Task) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use description <- decode.field("description", decode.string)
  use dependencies <- decode.field("dependencies", decode.list(decode.string))
  use acceptance <- decode.field("acceptance", decode.list(decode.string))
  use demo_plan <- decode.field("demo_plan", decode.list(decode.string))
  use decision_requests <- decode.then(optional_decision_requests_decoder())
  use superseded_pr_numbers <- decode.then(
    optional_superseded_pr_numbers_decoder(),
  )
  use kind <- decode.then(task_kind_decoder())
  use execution_mode <- decode.then(execution_mode_decoder())
  decode.success(types.Task(
    id: id,
    title: title,
    description: description,
    dependencies: dependencies,
    acceptance: acceptance,
    demo_plan: demo_plan,
    decision_requests: decision_requests,
    superseded_pr_numbers: superseded_pr_numbers,
    kind: kind,
    execution_mode: execution_mode,
    state: types.Queued,
    worktree_path: "",
    branch_name: "",
    pr_number: "",
    summary: "",
  ))
}

fn execution_decoder() -> decode.Decoder(types.ExecutionResult) {
  use status <- decode.field("status", execution_status_decoder())
  use summary <- decode.field("summary", decode.string)
  use files_touched <- decode.field("files_touched", decode.list(decode.string))
  use demo_evidence <- decode.field("demo_evidence", decode.list(decode.string))
  use pr <- decode.field("pr", pr_decoder())
  use follow_up_tasks <- decode.field(
    "follow_up_tasks",
    decode.list(follow_up_task_decoder()),
  )
  decode.success(types.ExecutionResult(
    status: status,
    summary: summary,
    files_touched: files_touched,
    demo_evidence: demo_evidence,
    pr: pr,
    follow_up_tasks: follow_up_tasks,
  ))
}

fn pr_decoder() -> decode.Decoder(types.PrPlan) {
  use title <- decode.field("title", decode.string)
  use summary <- decode.field("summary", decode.string)
  use demo <- decode.field("demo", decode.list(decode.string))
  use risks <- decode.field("risks", decode.list(decode.string))
  decode.success(types.PrPlan(
    title: title,
    summary: summary,
    demo: demo,
    risks: risks,
  ))
}

fn follow_up_task_decoder() -> decode.Decoder(types.FollowUpTask) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use description <- decode.field("description", decode.string)
  use dependencies <- decode.field("dependencies", decode.list(decode.string))
  use acceptance <- decode.field("acceptance", decode.list(decode.string))
  use demo_plan <- decode.field("demo_plan", decode.list(decode.string))
  use decision_requests <- decode.then(optional_decision_requests_decoder())
  use superseded_pr_numbers <- decode.then(
    optional_superseded_pr_numbers_decoder(),
  )
  use kind <- decode.then(task_kind_decoder())
  use execution_mode <- decode.then(execution_mode_decoder())
  decode.success(types.FollowUpTask(
    id: id,
    title: title,
    description: description,
    dependencies: dependencies,
    acceptance: acceptance,
    demo_plan: demo_plan,
    decision_requests: decision_requests,
    superseded_pr_numbers: superseded_pr_numbers,
    kind: kind,
    execution_mode: execution_mode,
  ))
}

fn execution_status_decoder() -> decode.Decoder(types.TaskState) {
  use status <- decode.then(decode.string)
  case status {
    "completed" -> decode.success(types.Completed)
    "blocked" -> decode.success(types.Blocked)
    "failed" -> decode.success(types.Failed)
    "manual_attention" -> decode.success(types.ManualAttention)
    _ -> decode.failure(types.Failed, "ExecutionStatus")
  }
}

fn execution_mode_decoder() -> decode.Decoder(types.ExecutionMode) {
  decode.one_of(field_execution_mode_decoder(), or: [
    legacy_parallel_safe_decoder(),
  ])
}

fn task_kind_decoder() -> decode.Decoder(types.TaskKind) {
  decode.one_of(field_task_kind_decoder(), or: [legacy_task_kind_decoder()])
}

fn field_task_kind_decoder() -> decode.Decoder(types.TaskKind) {
  use raw <- decode.field("task_kind", decode.string)
  case types.task_kind_from_string(raw) {
    Ok(kind) -> decode.success(kind)
    Error(_) -> decode.failure(types.ImplementationTask, "TaskKind")
  }
}

fn legacy_task_kind_decoder() -> decode.Decoder(types.TaskKind) {
  decode.success(types.ImplementationTask)
}

fn decision_request_decoder() -> decode.Decoder(types.DecisionRequest) {
  use key <- decode.field("key", decode.string)
  use question <- decode.field("question", decode.string)
  use rationale <- decode.field("rationale", decode.string)
  use options <- decode.then(optional_decision_options_decoder())
  use recommended_option <- decode.then(optional_recommended_option_decoder())
  use allow_freeform <- decode.then(optional_allow_freeform_decoder())
  decode.success(types.DecisionRequest(
    key: key,
    question: question,
    rationale: rationale,
    options: options,
    recommended_option: recommended_option,
    allow_freeform: allow_freeform,
  ))
}

fn decision_option_decoder() -> decode.Decoder(types.DecisionOption) {
  use label <- decode.field("label", decode.string)
  use description <- decode.field("description", decode.string)
  decode.success(types.DecisionOption(label: label, description: description))
}

fn field_execution_mode_decoder() -> decode.Decoder(types.ExecutionMode) {
  use raw <- decode.field("execution_mode", decode.string)
  case types.execution_mode_from_string(raw) {
    Ok(mode) -> decode.success(mode)
    Error(_) -> decode.failure(types.Serial, "ExecutionMode")
  }
}

fn legacy_parallel_safe_decoder() -> decode.Decoder(types.ExecutionMode) {
  use parallel_safe <- decode.field("parallel_safe", decode.bool)
  case parallel_safe {
    True -> decode.success(types.Parallel)
    False -> decode.success(types.Exclusive)
  }
}

fn optional_decision_requests_decoder() -> decode.Decoder(
  List(types.DecisionRequest),
) {
  decode.one_of(
    {
      use requests <- decode.field(
        "decision_requests",
        decode.list(decision_request_decoder()),
      )
      decode.success(requests)
    },
    or: [decode.success([])],
  )
}

fn optional_superseded_pr_numbers_decoder() -> decode.Decoder(List(Int)) {
  decode.one_of(
    {
      use values <- decode.field(
        "superseded_pr_numbers",
        decode.list(decode.int),
      )
      decode.success(values)
    },
    or: [decode.success([])],
  )
}

fn optional_decision_options_decoder() -> decode.Decoder(
  List(types.DecisionOption),
) {
  decode.one_of(
    {
      use options <- decode.field(
        "options",
        decode.list(decision_option_decoder()),
      )
      decode.success(options)
    },
    or: [decode.success([])],
  )
}

fn optional_recommended_option_decoder() -> decode.Decoder(Option(String)) {
  decode.one_of(
    {
      use option <- decode.field(
        "recommended_option",
        decode.optional(decode.string),
      )
      decode.success(option)
    },
    or: [decode.success(None)],
  )
}

fn optional_allow_freeform_decoder() -> decode.Decoder(Bool) {
  decode.one_of(
    {
      use allow_freeform <- decode.field("allow_freeform", decode.bool)
      decode.success(allow_freeform)
    },
    or: [decode.success(True)],
  )
}
