import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/types

pub fn encode_run(run: types.RunRecord) -> String {
  json.object([
    #("run_id", json.string(run.run_id)),
    #("repo_root", json.string(run.repo_root)),
    #("run_path", json.string(run.run_path)),
    #("brief_path", json.string(run.brief_path)),
    #("state_path", json.string(run.state_path)),
    #("events_path", json.string(run.events_path)),
    #("report_path", json.string(run.report_path)),
    #("lock_path", json.string(run.lock_path)),
    #("planning_agent", encode_resolved_agent(run.planning_agent)),
    #("execution_agent", encode_resolved_agent(run.execution_agent)),
    #("environment_name", json.string(run.environment_name)),
    #("max_workers", json.int(run.max_workers)),
    #(
      "notes_source",
      json.nullable(from: run.notes_source, of: encode_notes_source),
    ),
    #(
      "planning_provenance",
      json.nullable(
        from: run.planning_provenance,
        of: encode_planning_provenance,
      ),
    ),
    #(
      "repo_state_snapshot",
      json.nullable(
        from: run.repo_state_snapshot,
        of: encode_repo_state_snapshot,
      ),
    ),
    #("decisions", json.array(run.decisions, encode_recorded_decision)),
    #("planning_dirty", json.bool(run.planning_dirty)),
    #("status", json.string(types.run_status_to_string(run.status))),
    #("created_at", json.string(run.created_at)),
    #("updated_at", json.string(run.updated_at)),
    #("tasks", json.array(run.tasks, encode_task)),
  ])
  |> json.to_string
}

pub fn encode_event(event: types.RunEvent) -> String {
  json.object([
    #("kind", json.string(event.kind)),
    #("at", json.string(event.at)),
    #("message", json.string(event.message)),
    #("task_id", json.nullable(from: event.task_id, of: json.string)),
  ])
  |> json.to_string
}

pub fn decode_run(contents: String) -> Result(types.RunRecord, String) {
  let decoder = case
    string.contains(does: contents, contain: "\"planning_agent\"")
  {
    True -> run_decoder()
    False -> legacy_run_decoder()
  }

  json.parse(contents, decoder)
  |> result.map_error(fn(_) { "Unable to decode stored run state." })
}

pub fn decode_event(line: String) -> Result(types.RunEvent, String) {
  json.parse(line, event_decoder())
  |> result.map_error(fn(_) { "Unable to decode event journal." })
}

fn encode_notes_source(source: types.NotesSource) -> json.Json {
  case source {
    types.NotesFile(path) ->
      json.object([#("kind", json.string("file")), #("path", json.string(path))])
    types.InlineNotes(path) ->
      json.object([
        #("kind", json.string("inline")),
        #("path", json.string(path)),
      ])
  }
}

fn encode_recorded_decision(decision: types.RecordedDecision) -> json.Json {
  json.object([
    #("key", json.string(decision.key)),
    #("question", json.string(decision.question)),
    #("answer", json.string(decision.answer)),
    #("answered_at", json.string(decision.answered_at)),
  ])
}

fn encode_planning_provenance(provenance: types.PlanningProvenance) -> json.Json {
  case provenance {
    types.NotesOnly(notes_source) ->
      json.object([
        #("kind", json.string("notes_only")),
        #("notes_source", encode_notes_source(notes_source)),
      ])
    types.ReviewsOnly -> json.object([#("kind", json.string("reviews_only"))])
    types.ReviewsAndNotes(notes_source) ->
      json.object([
        #("kind", json.string("reviews_and_notes")),
        #("notes_source", encode_notes_source(notes_source)),
      ])
  }
}

fn encode_repo_state_snapshot(snapshot: types.RepoStateSnapshot) -> json.Json {
  json.object([
    #("captured_at", json.string(snapshot.captured_at)),
    #("digest", json.string(snapshot.digest)),
    #(
      "open_pull_requests",
      json.array(snapshot.open_pull_requests, encode_repo_pull_request_snapshot),
    ),
  ])
}

fn encode_repo_pull_request_snapshot(
  snapshot: types.RepoPullRequestSnapshot,
) -> json.Json {
  json.object([
    #("number", json.int(snapshot.number)),
    #("title", json.string(snapshot.title)),
    #("url", json.string(snapshot.url)),
    #("head_ref_name", json.string(snapshot.head_ref_name)),
    #("base_ref_name", json.string(snapshot.base_ref_name)),
    #("review_decision", json.string(snapshot.review_decision)),
    #("failing_checks", json.array(snapshot.failing_checks, json.string)),
    #("review_comments", json.array(snapshot.review_comments, json.string)),
    #("actionable", json.bool(snapshot.actionable)),
    #("impacted", json.bool(snapshot.impacted)),
  ])
}

fn encode_resolved_agent(agent: types.ResolvedAgentConfig) -> json.Json {
  json.object([
    #("profile_name", json.string(agent.profile_name)),
    #("provider", json.string(types.provider_to_string(agent.provider))),
    #("model", json.nullable(from: agent.model, of: json.string)),
    #(
      "reasoning",
      json.nullable(from: agent.reasoning, of: fn(level) {
        json.string(types.reasoning_to_string(level))
      }),
    ),
    #(
      "provider_overrides",
      json.array(agent.provider_overrides, encode_provider_override),
    ),
  ])
}

fn encode_provider_override(override: types.ProviderOverride) -> json.Json {
  json.object([
    #("key", json.string(override.key)),
    #("value", json.string(override.value)),
  ])
}

fn encode_task(task: types.Task) -> json.Json {
  json.object([
    #("id", json.string(task.id)),
    #("title", json.string(task.title)),
    #("description", json.string(task.description)),
    #("dependencies", json.array(task.dependencies, json.string)),
    #("acceptance", json.array(task.acceptance, json.string)),
    #("demo_plan", json.array(task.demo_plan, json.string)),
    #(
      "decision_requests",
      json.array(task.decision_requests, encode_decision_request),
    ),
    #("superseded_pr_numbers", json.array(task.superseded_pr_numbers, json.int)),
    #("task_kind", json.string(types.task_kind_to_string(task.kind))),
    #(
      "execution_mode",
      json.string(types.execution_mode_to_string(task.execution_mode)),
    ),
    #("state", json.string(types.task_state_to_string(task.state))),
    #("worktree_path", json.string(task.worktree_path)),
    #("branch_name", json.string(task.branch_name)),
    #("pr_number", json.string(task.pr_number)),
    #("summary", json.string(task.summary)),
  ])
}

fn encode_decision_request(request: types.DecisionRequest) -> json.Json {
  json.object([
    #("key", json.string(request.key)),
    #("question", json.string(request.question)),
    #("rationale", json.string(request.rationale)),
    #("options", json.array(request.options, encode_decision_option)),
    #(
      "recommended_option",
      json.nullable(from: request.recommended_option, of: json.string),
    ),
    #("allow_freeform", json.bool(request.allow_freeform)),
  ])
}

fn encode_decision_option(option: types.DecisionOption) -> json.Json {
  json.object([
    #("label", json.string(option.label)),
    #("description", json.string(option.description)),
  ])
}

fn run_decoder() -> decode.Decoder(types.RunRecord) {
  use run_id <- decode.field("run_id", decode.string)
  use repo_root <- decode.field("repo_root", decode.string)
  use run_path <- decode.field("run_path", decode.string)
  use brief_path <- decode.field("brief_path", decode.string)
  use state_path <- decode.field("state_path", decode.string)
  use events_path <- decode.field("events_path", decode.string)
  use report_path <- decode.field("report_path", decode.string)
  use lock_path <- decode.field("lock_path", decode.string)
  use planning_agent <- decode.field("planning_agent", resolved_agent_decoder())
  use execution_agent <- decode.field(
    "execution_agent",
    resolved_agent_decoder(),
  )
  use maybe_environment_name <- decode.field(
    "environment_name",
    decode.optional(decode.string),
  )
  use max_workers <- decode.field("max_workers", decode.int)
  use notes_source <- decode.optional_field(
    "notes_source",
    None,
    decode.optional(notes_source_decoder()),
  )
  use planning_provenance <- decode.optional_field(
    "planning_provenance",
    None,
    decode.optional(planning_provenance_decoder()),
  )
  use repo_state_snapshot <- decode.optional_field(
    "repo_state_snapshot",
    None,
    decode.optional(repo_state_snapshot_decoder()),
  )
  use decisions <- decode.optional_field(
    "decisions",
    None,
    decode.optional(decode.list(recorded_decision_decoder())),
  )
  use planning_dirty <- decode.optional_field(
    "planning_dirty",
    None,
    decode.optional(decode.bool),
  )
  use status <- decode.field("status", run_status_decoder())
  use created_at <- decode.field("created_at", decode.string)
  use updated_at <- decode.field("updated_at", decode.string)
  use tasks <- decode.field("tasks", decode.list(task_decoder()))
  decode.success(types.RunRecord(
    run_id: run_id,
    repo_root: repo_root,
    run_path: run_path,
    brief_path: brief_path,
    state_path: state_path,
    events_path: events_path,
    report_path: report_path,
    lock_path: lock_path,
    planning_agent: planning_agent,
    execution_agent: execution_agent,
    environment_name: case maybe_environment_name {
      Some(name) -> name
      None -> ""
    },
    max_workers: max_workers,
    notes_source: notes_source,
    planning_provenance: case planning_provenance {
      Some(provenance) -> Some(provenance)
      None ->
        case notes_source {
          Some(source) -> Some(types.NotesOnly(source))
          None -> None
        }
    },
    repo_state_snapshot: repo_state_snapshot,
    decisions: case decisions {
      Some(entries) -> entries
      None -> []
    },
    planning_dirty: case planning_dirty {
      Some(value) -> value
      None -> False
    },
    status: status,
    created_at: created_at,
    updated_at: updated_at,
    tasks: tasks,
  ))
}

fn legacy_run_decoder() -> decode.Decoder(types.RunRecord) {
  use run_id <- decode.field("run_id", decode.string)
  use repo_root <- decode.field("repo_root", decode.string)
  use run_path <- decode.field("run_path", decode.string)
  use brief_path <- decode.field("brief_path", decode.string)
  use state_path <- decode.field("state_path", decode.string)
  use events_path <- decode.field("events_path", decode.string)
  use report_path <- decode.field("report_path", decode.string)
  use lock_path <- decode.field("lock_path", decode.string)
  use provider <- decode.field("harness", legacy_provider_decoder())
  use max_workers <- decode.field("max_workers", decode.int)
  use status <- decode.field("status", run_status_decoder())
  use created_at <- decode.field("created_at", decode.string)
  use updated_at <- decode.field("updated_at", decode.string)
  use tasks <- decode.field("tasks", decode.list(task_decoder()))
  let resolved_agent = types.resolved_agent_from_provider(provider)
  decode.success(types.RunRecord(
    run_id: run_id,
    repo_root: repo_root,
    run_path: run_path,
    brief_path: brief_path,
    state_path: state_path,
    events_path: events_path,
    report_path: report_path,
    lock_path: lock_path,
    planning_agent: resolved_agent,
    execution_agent: resolved_agent,
    environment_name: "",
    max_workers: max_workers,
    notes_source: None,
    planning_provenance: None,
    repo_state_snapshot: None,
    decisions: [],
    planning_dirty: False,
    status: status,
    created_at: created_at,
    updated_at: updated_at,
    tasks: tasks,
  ))
}

fn resolved_agent_decoder() -> decode.Decoder(types.ResolvedAgentConfig) {
  use profile_name <- decode.field("profile_name", decode.string)
  use provider <- decode.field("provider", provider_decoder())
  use model <- decode.field("model", decode.optional(decode.string))
  use reasoning <- decode.field(
    "reasoning",
    decode.optional(reasoning_decoder()),
  )
  use provider_overrides <- decode.field(
    "provider_overrides",
    decode.list(provider_override_decoder()),
  )
  decode.success(types.ResolvedAgentConfig(
    profile_name: profile_name,
    provider: provider,
    model: model,
    reasoning: reasoning,
    provider_overrides: provider_overrides,
  ))
}

fn provider_override_decoder() -> decode.Decoder(types.ProviderOverride) {
  use key <- decode.field("key", decode.string)
  use value <- decode.field("value", decode.string)
  decode.success(types.ProviderOverride(key: key, value: value))
}

fn provider_decoder() -> decode.Decoder(types.Provider) {
  use raw <- decode.then(decode.string)
  case types.provider_from_string(raw) {
    Ok(provider) -> decode.success(provider)
    Error(_) -> decode.failure(types.Codex, "Provider")
  }
}

fn legacy_provider_decoder() -> decode.Decoder(types.Provider) {
  use raw <- decode.then(decode.string)
  case types.provider_from_string(raw) {
    Ok(provider) -> decode.success(provider)
    Error(_) -> decode.failure(types.Codex, "Provider")
  }
}

fn reasoning_decoder() -> decode.Decoder(types.ReasoningLevel) {
  use raw <- decode.then(decode.string)
  case types.reasoning_from_string(raw) {
    Ok(reasoning) -> decode.success(reasoning)
    Error(_) -> decode.failure(types.Medium, "ReasoningLevel")
  }
}

fn task_decoder() -> decode.Decoder(types.Task) {
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
  use execution_mode <- decode.then(task_execution_mode_decoder())
  use state <- decode.field("state", task_state_decoder())
  use worktree_path <- decode.field("worktree_path", decode.string)
  use branch_name <- decode.field("branch_name", decode.string)
  use pr_number <- decode.field("pr_number", decode.string)
  use summary <- decode.field("summary", decode.string)
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
    state: state,
    worktree_path: worktree_path,
    branch_name: branch_name,
    pr_number: pr_number,
    summary: summary,
  ))
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

fn recorded_decision_decoder() -> decode.Decoder(types.RecordedDecision) {
  use key <- decode.field("key", decode.string)
  use question <- decode.field("question", decode.string)
  use answer <- decode.field("answer", decode.string)
  use answered_at <- decode.field("answered_at", decode.string)
  decode.success(types.RecordedDecision(
    key: key,
    question: question,
    answer: answer,
    answered_at: answered_at,
  ))
}

fn notes_source_decoder() -> decode.Decoder(types.NotesSource) {
  use kind <- decode.field("kind", decode.string)
  use path <- decode.field("path", decode.string)
  case kind {
    "file" -> decode.success(types.NotesFile(path))
    "inline" -> decode.success(types.InlineNotes(path))
    _ -> decode.failure(types.NotesFile(path), "NotesSource")
  }
}

fn planning_provenance_decoder() -> decode.Decoder(types.PlanningProvenance) {
  use kind <- decode.field("kind", decode.string)
  use notes_source <- decode.optional_field(
    "notes_source",
    None,
    decode.optional(notes_source_decoder()),
  )
  case kind, notes_source {
    "notes_only", Some(source) -> decode.success(types.NotesOnly(source))
    "reviews_only", _ -> decode.success(types.ReviewsOnly)
    "reviews_and_notes", Some(source) ->
      decode.success(types.ReviewsAndNotes(source))
    _, _ -> decode.failure(types.ReviewsOnly, "PlanningProvenance")
  }
}

fn repo_state_snapshot_decoder() -> decode.Decoder(types.RepoStateSnapshot) {
  use captured_at <- decode.field("captured_at", decode.string)
  use digest <- decode.field("digest", decode.string)
  use open_pull_requests <- decode.field(
    "open_pull_requests",
    decode.list(repo_pull_request_snapshot_decoder()),
  )
  decode.success(types.RepoStateSnapshot(
    captured_at: captured_at,
    digest: digest,
    open_pull_requests: open_pull_requests,
  ))
}

fn repo_pull_request_snapshot_decoder() -> decode.Decoder(
  types.RepoPullRequestSnapshot,
) {
  use number <- decode.field("number", decode.int)
  use title <- decode.field("title", decode.string)
  use url <- decode.field("url", decode.string)
  use head_ref_name <- decode.field("head_ref_name", decode.string)
  use base_ref_name <- decode.field("base_ref_name", decode.string)
  use review_decision <- decode.field("review_decision", decode.string)
  use failing_checks <- decode.field(
    "failing_checks",
    decode.list(decode.string),
  )
  use review_comments <- decode.field(
    "review_comments",
    decode.list(decode.string),
  )
  use actionable <- decode.field("actionable", decode.bool)
  use impacted <- decode.field("impacted", decode.bool)
  decode.success(types.RepoPullRequestSnapshot(
    number: number,
    title: title,
    url: url,
    head_ref_name: head_ref_name,
    base_ref_name: base_ref_name,
    review_decision: review_decision,
    failing_checks: failing_checks,
    review_comments: review_comments,
    actionable: actionable,
    impacted: impacted,
  ))
}

fn task_execution_mode_decoder() -> decode.Decoder(types.ExecutionMode) {
  decode.one_of(task_mode_field_decoder(), or: [task_parallel_safe_decoder()])
}

fn task_kind_decoder() -> decode.Decoder(types.TaskKind) {
  decode.one_of(task_kind_field_decoder(), or: [legacy_task_kind_decoder()])
}

fn task_kind_field_decoder() -> decode.Decoder(types.TaskKind) {
  use raw <- decode.field("task_kind", decode.string)
  case types.task_kind_from_string(raw) {
    Ok(kind) -> decode.success(kind)
    Error(_) -> decode.failure(types.ImplementationTask, "TaskKind")
  }
}

fn legacy_task_kind_decoder() -> decode.Decoder(types.TaskKind) {
  decode.success(types.ImplementationTask)
}

fn task_mode_field_decoder() -> decode.Decoder(types.ExecutionMode) {
  use raw <- decode.field("execution_mode", decode.string)
  case types.execution_mode_from_string(raw) {
    Ok(mode) -> decode.success(mode)
    Error(_) -> decode.failure(types.Serial, "ExecutionMode")
  }
}

fn task_parallel_safe_decoder() -> decode.Decoder(types.ExecutionMode) {
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

fn event_decoder() -> decode.Decoder(types.RunEvent) {
  use kind <- decode.field("kind", decode.string)
  use at <- decode.field("at", decode.string)
  use message <- decode.field("message", decode.string)
  use task_id <- decode.field("task_id", decode.optional(decode.string))
  decode.success(types.RunEvent(
    kind: kind,
    at: at,
    message: message,
    task_id: task_id,
  ))
}

fn run_status_decoder() -> decode.Decoder(types.RunStatus) {
  use raw <- decode.then(decode.string)
  case raw {
    "pending" -> decode.success(types.RunPending)
    "active" -> decode.success(types.RunActive)
    "completed" -> decode.success(types.RunCompleted)
    "blocked" -> decode.success(types.RunBlocked)
    "failed" -> decode.success(types.RunFailed)
    _ -> decode.failure(types.RunPending, "RunStatus")
  }
}

fn task_state_decoder() -> decode.Decoder(types.TaskState) {
  use raw <- decode.then(decode.string)
  case raw {
    "queued" -> decode.success(types.Queued)
    "ready" -> decode.success(types.Ready)
    "running" -> decode.success(types.Running)
    "blocked" -> decode.success(types.Blocked)
    "completed" -> decode.success(types.Completed)
    "failed" -> decode.success(types.Failed)
    "manual_attention" -> decode.success(types.ManualAttention)
    _ -> decode.failure(types.Queued, "TaskState")
  }
}
