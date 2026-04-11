import filepath
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/project
import night_shift/report
import night_shift/system
import night_shift/types
import simplifile

pub fn start_run(
  repo_root: String,
  brief_path: String,
  planning_agent: types.ResolvedAgentConfig,
  execution_agent: types.ResolvedAgentConfig,
  environment_name: String,
  max_workers: Int,
) -> Result(types.RunRecord, String) {
  use run <- result.try(create_pending_run(
    repo_root,
    brief_path,
    planning_agent,
    execution_agent,
    environment_name,
    max_workers,
    None,
  ))
  activate_run(run)
}

pub fn create_pending_run(
  repo_root: String,
  brief_path: String,
  planning_agent: types.ResolvedAgentConfig,
  execution_agent: types.ResolvedAgentConfig,
  environment_name: String,
  max_workers: Int,
  notes_source: Option(types.NotesSource),
) -> Result(types.RunRecord, String) {
  let run_id = make_run_id()
  let project_home = repo_state_path(repo_root)
  let runs_path = runs_root(repo_root)
  let run_path = filepath.join(runs_path, run_id)
  let brief_copy_path = filepath.join(run_path, "brief.md")
  let state_path = filepath.join(run_path, "state.json")
  let events_path = filepath.join(run_path, "events.jsonl")
  let report_path = filepath.join(run_path, "report.md")
  let lock_path = project.active_lock_path(repo_root)

  use _ <- result.try(ensure_repo_home_ready(repo_root, project_home, runs_path))
  use _ <- result.try(create_run_directories(run_path))
  use _ <- result.try(copy_brief(brief_path, brief_copy_path))

  let timestamp = system.timestamp()
  let run =
    types.RunRecord(
      run_id: run_id,
      repo_root: repo_root,
      run_path: run_path,
      brief_path: brief_copy_path,
      state_path: state_path,
      events_path: events_path,
      report_path: report_path,
      lock_path: lock_path,
      planning_agent: planning_agent,
      execution_agent: execution_agent,
      environment_name: environment_name,
      max_workers: max_workers,
      notes_source: notes_source,
      decisions: [],
      planning_dirty: False,
      status: types.RunPending,
      created_at: timestamp,
      updated_at: timestamp,
      tasks: [],
    )

  use _ <- result.try(save(run, []))
  Ok(run)
}

pub fn activate_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  use _ <- result.try(ensure_no_active_run(run.lock_path))
  use _ <- result.try(write_lock(run.lock_path, run.run_id))
  let event =
    types.RunEvent(
      kind: "run_started",
      at: system.timestamp(),
      message: "Night Shift started.",
      task_id: None,
    )
  let updated_run = types.RunRecord(
    ..run,
    status: types.RunActive,
    updated_at: event.at,
  )
  use existing_events <- result.try(read_events(run.events_path))
  use _ <- result.try(save(updated_run, list.append(existing_events, [event])))
  Ok(updated_run)
}

pub fn rewrite_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  use existing_events <- result.try(read_events(run.events_path))
  let updated_run = types.RunRecord(..run, updated_at: system.timestamp())
  use _ <- result.try(save(updated_run, existing_events))
  Ok(updated_run)
}

pub fn latest_reusable_run(
  repo_root: String,
) -> Result(Option(types.RunRecord), String) {
  case list_runs(repo_root) {
    Ok(runs) ->
      Ok(case list.find(runs, fn(run) { is_reusable_planning_run(run) }) {
        Ok(run) -> Some(run)
        Error(_) -> None
      })
    Error(_) -> Ok(None)
  }
}

pub fn load(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(#(types.RunRecord, List(types.RunEvent)), String) {
  let repo_path = runs_root(repo_root)

  use run_id <- result.try(case selector {
    types.LatestRun -> latest_run_id(repo_path)
    types.RunId(run_id) -> Ok(run_id)
  })

  let run_path = filepath.join(repo_path, run_id)
  let state_path = filepath.join(run_path, "state.json")
  let events_path = filepath.join(run_path, "events.jsonl")

  use run <- result.try(read_run(state_path))
  use events <- result.try(read_events(events_path))
  Ok(#(run, events))
}

pub fn list_runs(repo_root: String) -> Result(List(types.RunRecord), String) {
  let repo_path = runs_root(repo_root)
  use run_ids <- result.try(list_run_ids(repo_path))
  Ok(
    run_ids
    |> list.filter_map(fn(run_id) {
      let state_path =
        filepath.join(filepath.join(repo_path, run_id), "state.json")
      case read_run(state_path) {
        Ok(run) -> Ok(run)
        Error(_) -> Error(Nil)
      }
    }),
  )
}

pub fn save(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> Result(Nil, String) {
  use _ <- result.try(write_string(run.state_path, encode_run(run)))
  use _ <- result.try(write_events(run.events_path, events))
  write_string(run.report_path, report.render(run, events))
}

pub fn append_event(
  run: types.RunRecord,
  event: types.RunEvent,
) -> Result(types.RunRecord, String) {
  use existing_events <- result.try(read_events(run.events_path))
  let updated_run = types.RunRecord(..run, updated_at: event.at)
  use _ <- result.try(save(updated_run, list.append(existing_events, [event])))
  Ok(updated_run)
}

pub fn mark_status(
  run: types.RunRecord,
  status: types.RunStatus,
  message: String,
) -> Result(types.RunRecord, String) {
  let event =
    types.RunEvent(
      kind: status_event_kind(status),
      at: system.timestamp(),
      message: message,
      task_id: None,
    )

  let updated_run = types.RunRecord(..run, status: status, updated_at: event.at)

  use existing_events <- result.try(read_events(run.events_path))
  use _ <- result.try(save(updated_run, list.append(existing_events, [event])))
  case status {
    types.RunActive -> Ok(updated_run)
    _ -> {
      let _ = simplifile.delete_file(run.lock_path)
      Ok(updated_run)
    }
  }
}

pub fn read_report(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(String, String) {
  use #(run, _) <- result.try(load(repo_root, selector))
  read_string(run.report_path)
}

pub fn active_run_id(repo_root: String) -> Result(String, String) {
  let lock_path = project.active_lock_path(repo_root)
  case simplifile.read(lock_path) {
    Ok(run_id) -> Ok(string.trim(run_id))
    Error(_) ->
      Error("No active Night Shift run was found for this repository.")
  }
}

pub fn state_root() -> String {
  filepath.join(system.state_directory(), "night-shift")
}

pub fn repo_state_path_for(repo_root: String) -> String {
  repo_state_path(repo_root)
}

pub fn planning_root_for(repo_root: String) -> String {
  planning_root(repo_root)
}

fn ensure_repo_home_ready(
  repo_root: String,
  project_home: String,
  runs_path: String,
) -> Result(Nil, String) {
  use _ <- result.try(create_directory(project_home))
  use _ <- result.try(create_directory(runs_path))
  create_directory(planning_root(repo_root))
}

fn ensure_no_active_run(lock_path: String) -> Result(Nil, String) {
  case simplifile.read(lock_path) {
    Ok(existing_run) ->
      Error(
        "Night Shift already has an active run for this repo: "
        <> string.trim(existing_run),
      )
    Error(_) -> Ok(Nil)
  }
}

fn create_run_directories(run_path: String) -> Result(Nil, String) {
  use _ <- result.try(create_directory(run_path))
  create_directory(filepath.join(run_path, "logs"))
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

fn copy_brief(
  from source: String,
  to destination: String,
) -> Result(Nil, String) {
  case simplifile.copy_file(at: source, to: destination) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error("Unable to copy brief: " <> simplifile.describe_error(error))
  }
}

fn write_lock(lock_path: String, run_id: String) -> Result(Nil, String) {
  write_string(lock_path, run_id <> "\n")
}

fn write_string(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.write(contents, to: path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to write " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}

fn read_string(path: String) -> Result(String, String) {
  case simplifile.read(path) {
    Ok(contents) -> Ok(contents)
    Error(error) ->
      Error(
        "Unable to read " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}

fn write_events(
  path: String,
  events: List(types.RunEvent),
) -> Result(Nil, String) {
  let contents =
    events
    |> list.map(encode_event)
    |> string.join(with: "\n")

  write_string(path, case contents {
    "" -> ""
    _ -> contents <> "\n"
  })
}

fn read_events(path: String) -> Result(List(types.RunEvent), String) {
  case simplifile.read(path) {
    Ok(contents) ->
      case string.trim(contents) {
        "" -> Ok([])
        trimmed ->
          trimmed
          |> string.split("\n")
          |> list.try_map(decode_event)
      }
    Error(_) -> Ok([])
  }
}

fn latest_run_id(repo_path: String) -> Result(String, String) {
  use run_ids <- result.try(list_run_ids(repo_path))
  case run_ids {
    [latest, ..] -> Ok(latest)
    [] -> Error("No Night Shift runs were found for this repository.")
  }
}

fn list_run_ids(repo_path: String) -> Result(List(String), String) {
  case simplifile.read_directory(at: repo_path) {
    Ok(entries) ->
      Ok(
        entries
        |> list.filter(fn(entry) { entry != "active.lock" })
        |> list.sort(fn(left, right) {
          string.compare(sortable_run_id(left), sortable_run_id(right))
        })
        |> list.reverse,
      )
    Error(_) -> Error("No Night Shift runs were found for this repository.")
  }
}

fn sortable_run_id(run_id: String) -> String {
  case list.reverse(string.split(run_id, "-")) {
    [suffix, ..rest] ->
      string.join(list.reverse(rest), "-") <> "-" <> left_pad_suffix(suffix, 8)
    [] -> run_id
  }
}

fn left_pad_suffix(value: String, width: Int) -> String {
  case string.length(value) >= width {
    True -> value
    False -> left_pad_suffix("0" <> value, width)
  }
}

fn read_run(path: String) -> Result(types.RunRecord, String) {
  use contents <- result.try(read_string(path))
  let decoder = case
    string.contains(does: contents, contain: "\"planning_agent\"")
  {
    True -> run_decoder()
    False -> legacy_run_decoder()
  }

  json.parse(contents, decoder)
  |> result.map_error(fn(_) { "Unable to decode stored run state." })
}

fn make_run_id() -> String {
  system.timestamp()
  |> string.replace(each: ":", with: "-")
  |> string.replace(each: "T", with: "_")
  |> string.replace(each: "+", with: "_")
  |> string.replace(each: "Z", with: "")
  |> string.append("-")
  |> string.append(system.unique_id())
}

fn repo_state_path(repo_root: String) -> String {
  project.home(repo_root)
}

fn runs_root(repo_root: String) -> String {
  project.runs_root(repo_root)
}

fn planning_root(repo_root: String) -> String {
  project.planning_root(repo_root)
}

fn status_event_kind(status: types.RunStatus) -> String {
  case status {
    types.RunPending -> "run_pending"
    types.RunActive -> "run_started"
    types.RunCompleted -> "run_completed"
    types.RunBlocked -> "run_blocked"
    types.RunFailed -> "run_failed"
  }
}

fn encode_run(run: types.RunRecord) -> String {
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
    #("notes_source", json.nullable(from: run.notes_source, of: encode_notes_source)),
    #("decisions", json.array(run.decisions, encode_recorded_decision)),
    #("planning_dirty", json.bool(run.planning_dirty)),
    #("status", json.string(types.run_status_to_string(run.status))),
    #("created_at", json.string(run.created_at)),
    #("updated_at", json.string(run.updated_at)),
    #("tasks", json.array(run.tasks, encode_task)),
  ])
  |> json.to_string
}

fn encode_notes_source(source: types.NotesSource) -> json.Json {
  case source {
    types.NotesFile(path) ->
      json.object([#("kind", json.string("file")), #("path", json.string(path))])
    types.InlineNotes(path) ->
      json.object([#("kind", json.string("inline")), #("path", json.string(path))])
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
    #("task_kind", json.string(types.task_kind_to_string(task.kind))),
    #("execution_mode", json.string(types.execution_mode_to_string(task.execution_mode))),
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

fn encode_event(event: types.RunEvent) -> String {
  json.object([
    #("kind", json.string(event.kind)),
    #("at", json.string(event.at)),
    #("message", json.string(event.message)),
    #("task_id", json.nullable(from: event.task_id, of: json.string)),
  ])
  |> json.to_string
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
  use notes_source <- decode.field(
    "notes_source",
    decode.optional(notes_source_decoder()),
  )
  use decisions <- decode.field(
    "decisions",
    decode.optional(decode.list(recorded_decision_decoder())),
  )
  use planning_dirty <- decode.field(
    "planning_dirty",
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

fn is_reusable_planning_run(run: types.RunRecord) -> Bool {
  case run.status {
    types.RunPending | types.RunBlocked ->
      !list.any(run.tasks, fn(task) {
        task.state == types.Completed
        || task.state == types.Running
        || task.pr_number != ""
        || task.worktree_path != ""
      })
    _ -> False
  }
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

fn optional_decision_requests_decoder() -> decode.Decoder(List(types.DecisionRequest)) {
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

fn optional_decision_options_decoder() -> decode.Decoder(List(types.DecisionOption)) {
  decode.one_of(
    {
      use options <- decode.field("options", decode.list(decision_option_decoder()))
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

fn decode_event(line: String) -> Result(types.RunEvent, String) {
  json.parse(line, event_decoder())
  |> result.map_error(fn(_) { "Unable to decode event journal." })
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
