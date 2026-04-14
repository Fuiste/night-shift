//// Repo-local Dash state and command surface for Night Shift.

import filepath
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/agent_config
import night_shift/config
import night_shift/dashboard_view
import night_shift/domain/confidence
import night_shift/domain/decisions as decision_domain
import night_shift/domain/provenance
import night_shift/domain/repo_state
import night_shift/domain/review_run_projection
import night_shift/journal
import night_shift/project
import night_shift/provider_models
import night_shift/repo_state_runtime
import night_shift/report
import night_shift/system
import night_shift/types
import night_shift/usecase/init as init_usecase
import night_shift/usecase/plan as plan_usecase
import night_shift/usecase/resolve as resolve_usecase
import night_shift/usecase/result as workflow
import night_shift/usecase/resume as resume_usecase
import night_shift/usecase/start as start_usecase
import simplifile

pub type Session {
  Session(url: String, handle: String)
}

type RepoConfiguration {
  RepoConfiguration(
    initialized: Bool,
    config_result: Result(types.Config, String),
  )
}

type RawInitRequest {
  RawInitRequest(
    profile: String,
    provider: String,
    model: String,
    reasoning: String,
    generate_setup: Bool,
  )
}

type RawPlanRequest {
  RawPlanRequest(
    run_id: String,
    notes: String,
    doc_path: String,
    profile: String,
    provider: String,
    model: String,
    reasoning: String,
  )
}

type RawRunRequest {
  RawRunRequest(run_id: String)
}

type RawResolveRequest {
  RawResolveRequest(run_id: String, answers: List(RawDecisionAnswer))
}

type RawDecisionAnswer {
  RawDecisionAnswer(key: String, answer: String)
}

type DeliveredPrLink {
  DeliveredPrLink(
    number: String,
    url: Option(String),
    handoff_state: Option(types.TaskHandoffState),
  )
}

@external(erlang, "night_shift_dashboard_server", "start_session")
pub fn start_session(repo_root: String) -> Result(Session, String)

@external(erlang, "night_shift_dashboard_server", "stop_session")
pub fn stop_session(session: Session) -> Nil

@external(erlang, "night_shift_dashboard_server", "http_get")
pub fn http_get(url: String) -> Result(String, String)

@external(erlang, "night_shift_dashboard_server", "http_post")
pub fn http_post(url: String, body: String) -> Result(String, String)

pub fn start_view_session(
  repo_root: String,
  _initial_run_id: String,
) -> Result(Session, String) {
  start_session(repo_root)
}

pub fn start_start_session(
  repo_root: String,
  _initial_run_id: String,
  _run: types.RunRecord,
  _config: types.Config,
) -> Result(Session, String) {
  start_session(repo_root)
}

pub fn start_resume_session(
  repo_root: String,
  _initial_run_id: String,
  _run: types.RunRecord,
  _config: types.Config,
) -> Result(Session, String) {
  start_session(repo_root)
}

pub fn index_html(_initial_run_id: String) -> String {
  dashboard_view.index_html()
}

pub fn bootstrap_json(
  repo_root: String,
  requested_run_id: String,
) -> Result(String, String) {
  Ok(
    bootstrap_payload(repo_root, run_id_option(requested_run_id))
    |> json.to_string,
  )
}

pub fn audit_json(
  repo_root: String,
  requested_run_id: String,
) -> Result(String, String) {
  Ok(
    json.object([
      #(
        "run",
        json.nullable(
          from: selected_run_payload(repo_root, run_id_option(requested_run_id)),
          of: identity_json,
        ),
      ),
    ])
    |> json.to_string,
  )
}

pub fn provider_models_json(
  repo_root: String,
  provider_name: String,
) -> Result(String, String) {
  use provider <- result.try(
    parse_provider(provider_name)
    |> result.map_error(fn(message) {
      command_error_json(repo_root, "provider-models", message, None)
    }),
  )
  case provider_models.list_models(provider, repo_root) {
    Ok(models) ->
      Ok(
        json.object([
          #("provider", json.string(types.provider_to_string(provider))),
          #("models", json.array(models, provider_model_json)),
        ])
        |> json.to_string,
      )
    Error(message) ->
      Error(command_error_json(repo_root, "provider-models", message, None))
  }
}

pub fn command_json(
  repo_root: String,
  command: String,
  body: String,
) -> Result(String, String) {
  case command {
    "init" -> init_command_json(repo_root, body)
    "plan" -> plan_command_json(repo_root, body, False)
    "plan-from-reviews" -> plan_command_json(repo_root, body, True)
    "resolve" -> resolve_command_json(repo_root, body)
    "start" -> start_command_json(repo_root, body)
    "resume" -> resume_command_json(repo_root, body)
    _ ->
      Error(command_error_json(
        repo_root,
        command,
        "Unsupported dash command: " <> command,
        None,
      ))
  }
}

pub fn runs_json(repo_root: String) -> Result(String, String) {
  Ok(
    list_runs_or_empty(repo_root)
    |> list.map(run_summary_json)
    |> json.array(identity_json)
    |> json.to_string,
  )
}

pub fn run_json(repo_root: String, run_id: String) -> Result(String, String) {
  case load_run_details(repo_root, types.RunId(run_id)) {
    Ok(#(run, events, configuration)) -> {
      let repo_state_view = repo_state_view(run, configuration)
      let rendered_report = report.render_live(run, events, repo_state_view)
      Ok(
        json.object([
          #("run", run_payload_json(run, events, configuration)),
          #("events", json.array(events, event_json)),
          #("report", json.string(rendered_report)),
        ])
        |> json.to_string,
      )
    }
    Error(message) -> Error(message)
  }
}

fn bootstrap_payload(
  repo_root: String,
  requested_run_id: Option(String),
) -> json.Json {
  let configuration = repo_configuration(repo_root)
  let runs = list_runs_or_empty(repo_root)
  let active_run_id = active_run_id_or_none(repo_root)
  let latest_run_id = latest_run_id(runs)
  let selected_run_id =
    choose_selected_run_id(requested_run_id, active_run_id, runs)

  json.object([
    #("mode", json.string("dash")),
    #("repo_root", json.string(repo_root)),
    #("initialized", json.bool(configuration.initialized)),
    #("config_path", json.string(project.config_path(repo_root))),
    #(
      "worktree_setup_path",
      json.string(project.worktree_setup_path(repo_root)),
    ),
    #(
      "config_error",
      json.nullable(from: repo_config_error(configuration), of: json.string),
    ),
    #("commands", command_catalog_json(configuration.initialized)),
    #(
      "urls",
      json.object([
        #("bootstrap", json.string("/api/bootstrap")),
        #("events", json.string("/api/events")),
        #("audit", json.string("/api/audit?run_id={run_id}")),
        #(
          "provider_models",
          json.string("/api/provider-models?provider={provider}"),
        ),
        #("artifact", json.string("/api/artifacts?path={path}")),
      ]),
    ),
    #(
      "runs",
      json.object([
        #("active_run_id", json.nullable(from: active_run_id, of: json.string)),
        #("latest_run_id", json.nullable(from: latest_run_id, of: json.string)),
        #(
          "selected_run_id",
          json.nullable(from: selected_run_id, of: json.string),
        ),
        #(
          "active_run",
          json.nullable(
            from: find_run_by_id(runs, active_run_id),
            of: run_summary_json,
          ),
        ),
        #(
          "latest_run",
          json.nullable(
            from: find_run_by_id(runs, latest_run_id),
            of: run_summary_json,
          ),
        ),
        #("items", json.array(runs, run_summary_json)),
      ]),
    ),
    #(
      "selected_run",
      json.nullable(
        from: selected_run_payload(repo_root, selected_run_id),
        of: identity_json,
      ),
    ),
  ])
}

fn selected_run_payload(
  repo_root: String,
  requested_run_id: Option(String),
) -> Option(json.Json) {
  case selected_run_selector(repo_root, requested_run_id) {
    Some(selector) ->
      case load_run_details(repo_root, selector) {
        Ok(#(run, events, configuration)) ->
          Some(run_payload_json(run, events, configuration))
        Error(_) -> None
      }
    None -> None
  }
}

fn run_payload_json(
  run: types.RunRecord,
  events: List(types.RunEvent),
  configuration: RepoConfiguration,
) -> json.Json {
  let repo_state_view = repo_state_view(run, configuration)
  let review_projection =
    review_run_projection.build(run, events, repo_state_view)
  let confidence_assessment = confidence.assess(run, events, repo_state_view)
  let rendered_report = report.render_live(run, events, repo_state_view)
  let pending_decisions =
    decision_domain.pending_decision_prompts(run.decisions, run.tasks)

  json.object([
    #("run_id", json.string(run.run_id)),
    #("repo_root", json.string(run.repo_root)),
    #("run_path", json.string(run.run_path)),
    #("brief_path", json.string(run.brief_path)),
    #("report_path", json.string(run.report_path)),
    #("provenance_path", json.string(provenance.artifact_path(run))),
    #("state_path", json.string(run.state_path)),
    #("events_path", json.string(run.events_path)),
    #("lock_path", json.string(run.lock_path)),
    #("planning_agent", agent_json(run.planning_agent)),
    #("execution_agent", agent_json(run.execution_agent)),
    #("environment_name", json.string(run.environment_name)),
    #("max_workers", json.int(run.max_workers)),
    #("planning_dirty", json.bool(run.planning_dirty)),
    #("status", json.string(types.run_status_to_string(run.status))),
    #("created_at", json.string(run.created_at)),
    #("updated_at", json.string(run.updated_at)),
    #(
      "planning_provenance",
      json.nullable(from: run.planning_provenance, of: fn(value) {
        json.string(types.planning_provenance_label(value))
      }),
    ),
    #(
      "notes_source",
      json.nullable(from: run.notes_source, of: fn(value) {
        json.string(types.notes_source_label(value))
      }),
    ),
    #(
      "confidence_posture",
      json.string(types.confidence_posture_to_string(
        confidence_assessment.posture,
      )),
    ),
    #(
      "confidence_reasons",
      json.array(confidence_assessment.reasons, json.string),
    ),
    #("decision_requests", json.array(pending_decisions, pending_decision_json)),
    #("recorded_decisions", json.array(run.decisions, recorded_decision_json)),
    #(
      "repo_state",
      json.nullable(
        from: review_projection,
        of: review_projection_repo_state_json,
      ),
    ),
    #(
      "review_lineage",
      json.nullable(from: review_projection, of: review_projection_json),
    ),
    #("task_dag", task_dag_json(run.tasks)),
    #("tasks", json.array(run.tasks, task_json(_, run, events))),
    #("timeline", json.array(events, event_json)),
    #(
      "report",
      json.object([
        #("path", json.string(run.report_path)),
        #("route", json.string(artifact_route(run.report_path))),
        #("content", json.string(rendered_report)),
      ]),
    ),
    #(
      "provenance",
      json.object([
        #("path", json.string(provenance.artifact_path(run))),
        #("route", json.string(artifact_route(provenance.artifact_path(run)))),
      ]),
    ),
    #(
      "planning_artifacts",
      json.array(planning_artifact_paths(run, events), artifact_json),
    ),
    #(
      "planner_prompt",
      json.nullable(from: planner_prompt_path(run.run_path), of: artifact_json),
    ),
    #(
      "planner_log",
      json.nullable(from: planner_log_path(run.run_path), of: artifact_json),
    ),
    #("handoff_states", json.array(run.handoff_states, handoff_state_json)),
  ])
}

fn init_command_json(repo_root: String, body: String) -> Result(String, String) {
  let configuration = repo_configuration(repo_root)
  use request <- result.try(
    decode_or_default(body, init_request_decoder(), default_init_request())
    |> result.map_error(fn(message) {
      command_error_json(repo_root, "init", decode_message(message), None)
    }),
  )
  use agent_overrides <- result.try(
    agent_overrides_from_strings(
      request.profile,
      request.provider,
      request.model,
      request.reasoning,
    )
    |> result.map_error(fn(message) {
      command_error_json(repo_root, "init", message, None)
    }),
  )
  use base_config <- result.try(
    configuration.config_result
    |> result.map_error(fn(message) {
      command_error_json(repo_root, "init", message, None)
    }),
  )

  case
    init_usecase.execute(
      repo_root,
      base_config,
      agent_overrides,
      request.generate_setup,
      True,
      dash_select_provider,
      dash_select_model,
      dash_choose_setup_request,
    )
  {
    Ok(view) ->
      Ok(command_success_json(
        repo_root,
        "init",
        "Initialized Night Shift for this repository.",
        None,
        Some(view.next_action),
      ))
    Error(message) ->
      Error(command_error_json(repo_root, "init", message, None))
  }
}

fn plan_command_json(
  repo_root: String,
  body: String,
  from_reviews: Bool,
) -> Result(String, String) {
  let command_name = case from_reviews {
    True -> "plan-from-reviews"
    False -> "plan"
  }
  use request <- result.try(
    decode_or_default(body, plan_request_decoder(), default_plan_request())
    |> result.map_error(fn(message) {
      command_error_json(repo_root, command_name, decode_message(message), None)
    }),
  )
  use configuration <- result.try(require_initialized_config(
    repo_root,
    command_name,
  ))
  use agent_overrides <- result.try(
    agent_overrides_from_strings(
      request.profile,
      request.provider,
      request.model,
      request.reasoning,
    )
    |> result.map_error(fn(message) {
      command_error_json(repo_root, command_name, message, None)
    }),
  )
  use planning_agent <- result.try(
    agent_config.resolve_plan_agent(
      extract_config(configuration),
      agent_overrides,
    )
    |> result.map_error(fn(message) {
      command_error_json(repo_root, command_name, message, None)
    }),
  )

  case
    plan_usecase.execute(
      repo_root,
      optional_string(request.notes),
      from_reviews,
      optional_string(request.doc_path),
      planning_agent,
      extract_config(configuration),
    )
  {
    Ok(view) ->
      Ok(command_success_json(
        repo_root,
        command_name,
        "Planned run " <> view.run.run_id <> ".",
        Some(view.run.run_id),
        Some(view.next_action),
      ))
    Error(message) ->
      Error(command_error_json(repo_root, command_name, message, None))
  }
}

fn resolve_command_json(
  repo_root: String,
  body: String,
) -> Result(String, String) {
  use request <- result.try(
    decode_or_default(
      body,
      resolve_request_decoder(),
      default_resolve_request(),
    )
    |> result.map_error(fn(message) {
      command_error_json(repo_root, "resolve", decode_message(message), None)
    }),
  )
  let selector = run_selector(request.run_id)

  case
    resolve_usecase.execute(repo_root, selector, fn(run, tasks) {
      collect_dash_decisions(run, tasks, request.answers)
    })
  {
    Ok(view) ->
      Ok(command_success_json(
        repo_root,
        "resolve",
        resolve_message(view),
        Some(view.run.run_id),
        Some(view.next_action),
      ))
    Error(message) ->
      Error(command_error_json(
        repo_root,
        "resolve",
        message,
        run_id_option(request.run_id),
      ))
  }
}

fn start_command_json(repo_root: String, body: String) -> Result(String, String) {
  use request <- result.try(
    decode_or_default(body, run_request_decoder(), RawRunRequest(run_id: ""))
    |> result.map_error(fn(message) {
      command_error_json(repo_root, "start", decode_message(message), None)
    }),
  )
  use configuration <- result.try(require_initialized_config(repo_root, "start"))

  case
    start_usecase.execute(
      repo_root,
      run_selector(request.run_id),
      extract_config(configuration),
    )
  {
    Ok(view) ->
      Ok(command_success_json(
        repo_root,
        "start",
        start_message(view),
        Some(view.run.run_id),
        Some(view.next_action),
      ))
    Error(message) ->
      Error(command_error_json(
        repo_root,
        "start",
        message,
        run_id_option(request.run_id),
      ))
  }
}

fn resume_command_json(
  repo_root: String,
  body: String,
) -> Result(String, String) {
  use request <- result.try(
    decode_or_default(body, run_request_decoder(), RawRunRequest(run_id: ""))
    |> result.map_error(fn(message) {
      command_error_json(repo_root, "resume", decode_message(message), None)
    }),
  )
  use configuration <- result.try(require_initialized_config(
    repo_root,
    "resume",
  ))

  case
    resume_usecase.execute(
      repo_root,
      run_selector(request.run_id),
      extract_config(configuration),
    )
  {
    Ok(view) ->
      Ok(command_success_json(
        repo_root,
        "resume",
        resume_message(view),
        Some(view.run.run_id),
        Some(view.next_action),
      ))
    Error(message) ->
      Error(command_error_json(
        repo_root,
        "resume",
        message,
        run_id_option(request.run_id),
      ))
  }
}

fn command_success_json(
  repo_root: String,
  command: String,
  message: String,
  run_id: Option(String),
  next_action: Option(String),
) -> String {
  json.object([
    #("ok", json.bool(True)),
    #("command", json.string(command)),
    #("message", json.string(message)),
    #("run_id", json.nullable(from: run_id, of: json.string)),
    #("next_action", json.nullable(from: next_action, of: json.string)),
    #("bootstrap", bootstrap_payload(repo_root, run_id)),
  ])
  |> json.to_string
}

fn command_error_json(
  repo_root: String,
  command: String,
  message: String,
  run_id: Option(String),
) -> String {
  json.object([
    #("ok", json.bool(False)),
    #("command", json.string(command)),
    #("message", json.string(message)),
    #("run_id", json.nullable(from: run_id, of: json.string)),
    #("bootstrap", bootstrap_payload(repo_root, run_id)),
  ])
  |> json.to_string
}

fn command_catalog_json(initialized: Bool) -> json.Json {
  json.object([
    #("init", command_entry_json("/api/commands/init", True)),
    #("plan", command_entry_json("/api/commands/plan", initialized)),
    #(
      "plan_from_reviews",
      command_entry_json("/api/commands/plan-from-reviews", initialized),
    ),
    #("resolve", command_entry_json("/api/commands/resolve", initialized)),
    #("start", command_entry_json("/api/commands/start", initialized)),
    #("resume", command_entry_json("/api/commands/resume", initialized)),
  ])
}

fn command_entry_json(path: String, available: Bool) -> json.Json {
  json.object([
    #("method", json.string("POST")),
    #("path", json.string(path)),
    #("available", json.bool(available)),
  ])
}

fn run_summary_json(run: types.RunRecord) -> json.Json {
  json.object([
    #("run_id", json.string(run.run_id)),
    #("status", json.string(types.run_status_to_string(run.status))),
    #("planning_dirty", json.bool(run.planning_dirty)),
    #("created_at", json.string(run.created_at)),
    #("updated_at", json.string(run.updated_at)),
    #("brief_path", json.string(run.brief_path)),
    #("audit_route", json.string("/api/audit?run_id=" <> run.run_id)),
  ])
}

fn task_json(
  task: types.Task,
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> json.Json {
  let relevant_events =
    events
    |> list.filter(fn(event) { event.task_id == Some(task.id) })
  let delivered_link =
    delivered_pr_link(task, run.handoff_states, relevant_events)

  json.object([
    #("id", json.string(task.id)),
    #("title", json.string(task.title)),
    #("description", json.string(task.description)),
    #("dependencies", json.array(task.dependencies, json.string)),
    #("acceptance", json.array(task.acceptance, json.string)),
    #("demo_plan", json.array(task.demo_plan, json.string)),
    #(
      "decision_requests",
      json.array(task.decision_requests, decision_request_json),
    ),
    #(
      "unresolved_decision_requests",
      json.array(
        types.unresolved_decision_requests(run.decisions, task),
        decision_request_json,
      ),
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
    #(
      "runtime_context",
      json.nullable(from: task.runtime_context, of: runtime_context_json),
    ),
    #(
      "delivered_pr",
      json.nullable(from: delivered_link, of: delivered_pr_json),
    ),
    #(
      "artifacts",
      json.object([
        #(
          "prompts",
          json.array(task_prompt_paths(run.run_path, task.id), artifact_json),
        ),
        #(
          "logs",
          json.array(task_log_paths(run.run_path, task.id), artifact_json),
        ),
        #(
          "raw_payloads",
          json.array(raw_payload_paths(run.run_path, task.id), artifact_json),
        ),
        #(
          "sanitized_payloads",
          json.array(
            sanitized_payload_paths(run.run_path, task.id),
            artifact_json,
          ),
        ),
        #(
          "runtime_manifest",
          json.nullable(
            from: runtime_manifest_path(task.runtime_context),
            of: artifact_json,
          ),
        ),
        #(
          "runtime_handoff",
          json.nullable(
            from: runtime_handoff_path(task.runtime_context),
            of: artifact_json,
          ),
        ),
        #(
          "runtime_env",
          json.nullable(
            from: runtime_env_path(task.runtime_context),
            of: artifact_json,
          ),
        ),
      ]),
    ),
    #("timeline", json.array(relevant_events, event_json)),
  ])
}

fn task_dag_json(tasks: List(types.Task)) -> json.Json {
  json.object([
    #("task_count", json.int(list.length(tasks))),
    #(
      "ready_task_ids",
      json.array(
        tasks
          |> list.filter(fn(task) { task.state == types.Ready })
          |> list.map(fn(task) { task.id }),
        json.string,
      ),
    ),
    #(
      "running_task_ids",
      json.array(
        tasks
          |> list.filter(fn(task) { task.state == types.Running })
          |> list.map(fn(task) { task.id }),
        json.string,
      ),
    ),
    #(
      "blocked_task_ids",
      json.array(
        tasks
          |> list.filter(fn(task) {
            task.state == types.Blocked || task.state == types.ManualAttention
          })
          |> list.map(fn(task) { task.id }),
        json.string,
      ),
    ),
    #(
      "completed_task_ids",
      json.array(
        tasks
          |> list.filter(fn(task) { task.state == types.Completed })
          |> list.map(fn(task) { task.id }),
        json.string,
      ),
    ),
  ])
}

fn review_projection_json(
  projection: review_run_projection.ReviewRunProjection,
) -> json.Json {
  json.object([
    #("repo_state", review_projection_repo_state_json(projection)),
    #(
      "lineage_entries",
      json.array(projection.lineage_entries, lineage_entry_json),
    ),
    #(
      "supersession_outcomes",
      json.array(projection.supersession_outcomes, json.string),
    ),
    #(
      "supersession_warnings",
      json.array(projection.supersession_warnings, json.string),
    ),
  ])
}

fn review_projection_repo_state_json(
  projection: review_run_projection.ReviewRunProjection,
) -> json.Json {
  let summary = projection.repo_state

  json.object([
    #("captured_open_pr_count", json.int(summary.captured_open_pr_count)),
    #(
      "captured_actionable_pr_count",
      json.int(summary.captured_actionable_pr_count),
    ),
    #("snapshot_captured_at", json.string(summary.snapshot_captured_at)),
    #(
      "current_open_pr_count",
      json.nullable(from: summary.current_open_pr_count, of: json.int),
    ),
    #(
      "current_actionable_pr_count",
      json.nullable(from: summary.current_actionable_pr_count, of: json.int),
    ),
    #("drift", json.nullable(from: summary.drift, of: json.string)),
    #(
      "drift_details",
      json.nullable(from: summary.drift_details, of: json.string),
    ),
    #(
      "actionable_pull_requests",
      json.array(summary.actionable_pull_requests, repo_pull_request_json),
    ),
    #(
      "impacted_pull_requests",
      json.array(summary.impacted_pull_requests, repo_pull_request_json),
    ),
  ])
}

fn repo_pull_request_json(pr: repo_state.RepoPullRequestSnapshot) -> json.Json {
  json.object([
    #("number", json.int(pr.number)),
    #("title", json.string(pr.title)),
    #("url", json.string(pr.url)),
    #("head_ref_name", json.string(pr.head_ref_name)),
    #("base_ref_name", json.string(pr.base_ref_name)),
    #("review_decision", json.string(pr.review_decision)),
    #("review_comments", json.array(pr.review_comments, json.string)),
    #("actionable", json.bool(pr.actionable)),
    #("impacted", json.bool(pr.impacted)),
  ])
}

fn lineage_entry_json(
  entry: review_run_projection.ReplacementLineageEntry,
) -> json.Json {
  json.object([
    #("task_id", json.string(entry.task_id)),
    #(
      "superseded_pr_numbers",
      json.array(entry.superseded_pr_numbers, json.int),
    ),
    #(
      "replacement_pr_number",
      json.nullable(from: entry.replacement_pr_number, of: json.string),
    ),
  ])
}

fn runtime_context_json(context: types.RuntimeContext) -> json.Json {
  json.object([
    #("worktree_id", json.string(context.worktree_id)),
    #("compose_project", json.string(context.compose_project)),
    #("port_base", json.int(context.port_base)),
    #(
      "named_ports",
      json.array(context.named_ports, fn(port) {
        json.object([
          #("name", json.string(port.name)),
          #("value", json.int(port.value)),
        ])
      }),
    ),
    #("runtime_dir", json.string(context.runtime_dir)),
    #("env_file_path", json.string(context.env_file_path)),
    #("manifest_path", json.string(context.manifest_path)),
    #("handoff_path", json.string(context.handoff_path)),
  ])
}

fn delivered_pr_json(link: DeliveredPrLink) -> json.Json {
  json.object([
    #("number", json.string(link.number)),
    #("url", json.nullable(from: link.url, of: json.string)),
    #(
      "handoff_state",
      json.nullable(from: link.handoff_state, of: handoff_state_json),
    ),
  ])
}

fn handoff_state_json(state: types.TaskHandoffState) -> json.Json {
  json.object([
    #("task_id", json.string(state.task_id)),
    #("delivered_pr_number", json.string(state.delivered_pr_number)),
    #("last_delivered_commit_sha", json.string(state.last_delivered_commit_sha)),
    #("last_handoff_files", json.array(state.last_handoff_files, json.string)),
    #("last_verification_digest", json.string(state.last_verification_digest)),
    #("last_risks", json.array(state.last_risks, json.string)),
    #("last_handoff_updated_at", json.string(state.last_handoff_updated_at)),
    #("body_region_present", json.bool(state.body_region_present)),
    #("managed_comment_present", json.bool(state.managed_comment_present)),
  ])
}

fn provider_model_json(model: provider_models.ProviderModel) -> json.Json {
  json.object([
    #("id", json.string(model.id)),
    #("label", json.string(model.label)),
    #("is_default", json.bool(model.is_default)),
  ])
}

fn event_json(event: types.RunEvent) -> json.Json {
  json.object([
    #("kind", json.string(event.kind)),
    #("at", json.string(event.at)),
    #("message", json.string(event.message)),
    #("task_id", json.nullable(from: event.task_id, of: json.string)),
  ])
}

fn artifact_json(path: String) -> json.Json {
  json.object([
    #("path", json.string(path)),
    #("route", json.string(artifact_route(path))),
  ])
}

fn pending_decision_json(
  prompt: #(types.Task, types.DecisionRequest),
) -> json.Json {
  let #(task, request) = prompt
  json.object([
    #("task_id", json.string(task.id)),
    #("task_title", json.string(task.title)),
    #("request", decision_request_json(request)),
  ])
}

fn decision_request_json(request: types.DecisionRequest) -> json.Json {
  json.object([
    #("key", json.string(request.key)),
    #("question", json.string(request.question)),
    #("rationale", json.string(request.rationale)),
    #(
      "options",
      json.array(request.options, fn(option) {
        json.object([
          #("label", json.string(option.label)),
          #("description", json.string(option.description)),
        ])
      }),
    ),
    #(
      "recommended_option",
      json.nullable(from: request.recommended_option, of: json.string),
    ),
    #("allow_freeform", json.bool(request.allow_freeform)),
  ])
}

fn recorded_decision_json(decision: types.RecordedDecision) -> json.Json {
  json.object([
    #("key", json.string(decision.key)),
    #("question", json.string(decision.question)),
    #("answer", json.string(decision.answer)),
    #("answered_at", json.string(decision.answered_at)),
  ])
}

fn repo_configuration(repo_root: String) -> RepoConfiguration {
  let config_path = project.config_path(repo_root)
  let initialized = file_exists(config_path)
  RepoConfiguration(initialized: initialized, config_result: case initialized {
    True -> config.load(config_path)
    False -> Ok(types.default_config())
  })
}

fn require_initialized_config(
  repo_root: String,
  command: String,
) -> Result(RepoConfiguration, String) {
  let configuration = repo_configuration(repo_root)
  case configuration.initialized, configuration.config_result {
    False, _ ->
      Error(command_error_json(
        repo_root,
        command,
        "Night Shift is not initialized for this repository. Run `night-shift init` or POST `/api/commands/init` first.",
        None,
      ))
    True, Ok(_) -> Ok(configuration)
    True, Error(message) ->
      Error(command_error_json(repo_root, command, message, None))
  }
}

fn extract_config(configuration: RepoConfiguration) -> types.Config {
  case configuration.config_result {
    Ok(config) -> config
    Error(_) -> types.default_config()
  }
}

fn repo_config_error(configuration: RepoConfiguration) -> Option(String) {
  case configuration.config_result {
    Ok(_) -> None
    Error(message) -> Some(message)
  }
}

fn list_runs_or_empty(repo_root: String) -> List(types.RunRecord) {
  case journal.list_runs(repo_root) {
    Ok(runs) -> runs
    Error(_) -> []
  }
}

fn load_run_details(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(#(types.RunRecord, List(types.RunEvent), RepoConfiguration), String) {
  let configuration = repo_configuration(repo_root)
  journal.load(repo_root, selector)
  |> result.map(fn(value) {
    let #(run, events) = value
    #(run, events, configuration)
  })
}

fn active_run_id_or_none(repo_root: String) -> Option(String) {
  case journal.active_run_id(repo_root) {
    Ok(run_id) -> Some(run_id)
    Error(_) -> None
  }
}

fn latest_run_id(runs: List(types.RunRecord)) -> Option(String) {
  case runs {
    [run, ..] -> Some(run.run_id)
    [] -> None
  }
}

fn choose_selected_run_id(
  requested: Option(String),
  active: Option(String),
  runs: List(types.RunRecord),
) -> Option(String) {
  case requested {
    Some(run_id) -> Some(run_id)
    None ->
      case active {
        Some(run_id) -> Some(run_id)
        None -> latest_run_id(runs)
      }
  }
}

fn selected_run_selector(
  repo_root: String,
  requested_run_id: Option(String),
) -> Option(types.RunSelector) {
  let runs = list_runs_or_empty(repo_root)
  let active = active_run_id_or_none(repo_root)
  case choose_selected_run_id(requested_run_id, active, runs) {
    Some(run_id) -> Some(types.RunId(run_id))
    None -> None
  }
}

fn find_run_by_id(
  runs: List(types.RunRecord),
  run_id: Option(String),
) -> Option(types.RunRecord) {
  case run_id {
    Some(target) ->
      case list.find(runs, fn(run) { run.run_id == target }) {
        Ok(run) -> Some(run)
        Error(_) -> None
      }
    None -> None
  }
}

fn repo_state_view(
  run: types.RunRecord,
  configuration: RepoConfiguration,
) -> Option(repo_state_runtime.RepoStateView) {
  case configuration.config_result {
    Ok(config) -> repo_state_runtime.inspect(run, config.branch_prefix).view
    Error(_) -> None
  }
}

fn run_selector(run_id: String) -> types.RunSelector {
  case optional_string(run_id) {
    Some(value) -> types.RunId(value)
    None -> types.LatestRun
  }
}

fn run_id_option(run_id: String) -> Option(String) {
  optional_string(run_id)
}

fn optional_string(value: String) -> Option(String) {
  case string.trim(value) {
    "" -> None
    trimmed -> Some(trimmed)
  }
}

fn artifact_route(path: String) -> String {
  "/api/artifacts?path=" <> path
}

fn decode_or_default(
  body: String,
  decoder: decode.Decoder(a),
  default: a,
) -> Result(a, json.DecodeError) {
  case string.trim(body) {
    "" -> Ok(default)
    _ -> json.parse(body, decoder)
  }
}

fn init_request_decoder() -> decode.Decoder(RawInitRequest) {
  use profile <- decode.optional_field("profile", "", decode.string)
  use provider <- decode.optional_field("provider", "", decode.string)
  use model <- decode.optional_field("model", "", decode.string)
  use reasoning <- decode.optional_field("reasoning", "", decode.string)
  use generate_setup <- decode.optional_field(
    "generate_setup",
    False,
    decode.bool,
  )
  decode.success(RawInitRequest(
    profile: profile,
    provider: provider,
    model: model,
    reasoning: reasoning,
    generate_setup: generate_setup,
  ))
}

fn default_init_request() -> RawInitRequest {
  RawInitRequest(
    profile: "",
    provider: "",
    model: "",
    reasoning: "",
    generate_setup: False,
  )
}

fn plan_request_decoder() -> decode.Decoder(RawPlanRequest) {
  use run_id <- decode.optional_field("run_id", "", decode.string)
  use notes <- decode.optional_field("notes", "", decode.string)
  use doc_path <- decode.optional_field("doc_path", "", decode.string)
  use profile <- decode.optional_field("profile", "", decode.string)
  use provider <- decode.optional_field("provider", "", decode.string)
  use model <- decode.optional_field("model", "", decode.string)
  use reasoning <- decode.optional_field("reasoning", "", decode.string)
  decode.success(RawPlanRequest(
    run_id: run_id,
    notes: notes,
    doc_path: doc_path,
    profile: profile,
    provider: provider,
    model: model,
    reasoning: reasoning,
  ))
}

fn default_plan_request() -> RawPlanRequest {
  RawPlanRequest(
    run_id: "",
    notes: "",
    doc_path: "",
    profile: "",
    provider: "",
    model: "",
    reasoning: "",
  )
}

fn run_request_decoder() -> decode.Decoder(RawRunRequest) {
  use run_id <- decode.optional_field("run_id", "", decode.string)
  decode.success(RawRunRequest(run_id: run_id))
}

fn resolve_request_decoder() -> decode.Decoder(RawResolveRequest) {
  use run_id <- decode.optional_field("run_id", "", decode.string)
  use answers <- decode.optional_field(
    "answers",
    [],
    decode.list(decision_answer_decoder()),
  )
  decode.success(RawResolveRequest(run_id: run_id, answers: answers))
}

fn default_resolve_request() -> RawResolveRequest {
  RawResolveRequest(run_id: "", answers: [])
}

fn decision_answer_decoder() -> decode.Decoder(RawDecisionAnswer) {
  use key <- decode.field("key", decode.string)
  use answer <- decode.field("answer", decode.string)
  decode.success(RawDecisionAnswer(key: key, answer: answer))
}

fn decode_message(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput ->
      "Invalid JSON payload: unexpected end of input."
    json.UnexpectedByte(byte) ->
      "Invalid JSON payload: unexpected byte `" <> byte <> "`."
    json.UnexpectedSequence(sequence) ->
      "Invalid JSON payload: unexpected sequence `" <> sequence <> "`."
    json.UnableToDecode(_) ->
      "Invalid JSON payload: structure did not match the expected command shape."
  }
}

fn agent_overrides_from_strings(
  profile: String,
  provider: String,
  model: String,
  reasoning: String,
) -> Result(types.AgentOverrides, String) {
  use parsed_provider <- result.try(optional_result(
    optional_string(provider),
    parse_provider,
  ))
  use parsed_reasoning <- result.try(optional_result(
    optional_string(reasoning),
    parse_reasoning,
  ))
  Ok(types.AgentOverrides(
    profile: optional_string(profile),
    provider: parsed_provider,
    model: optional_string(model),
    reasoning: parsed_reasoning,
  ))
}

fn optional_result(
  value: Option(a),
  parser: fn(a) -> Result(b, String),
) -> Result(Option(b), String) {
  case value {
    Some(inner) -> parser(inner) |> result.map(Some)
    None -> Ok(None)
  }
}

fn parse_provider(value: String) -> Result(types.Provider, String) {
  types.provider_from_string(string.trim(value))
}

fn parse_reasoning(value: String) -> Result(types.ReasoningLevel, String) {
  types.reasoning_from_string(string.trim(value))
}

fn dash_select_provider(
  _config: types.Config,
  agent_overrides: types.AgentOverrides,
) -> Result(types.Provider, String) {
  case agent_overrides.provider {
    Some(provider) -> Ok(provider)
    None ->
      Error(
        "Dash init requires `provider` when this repository has not been initialized yet.",
      )
  }
}

fn dash_select_model(
  _repo_root: String,
  _config: types.Config,
  _provider_name: types.Provider,
  agent_overrides: types.AgentOverrides,
) -> Result(String, String) {
  case agent_overrides.model {
    Some(model) -> Ok(model)
    None ->
      Error(
        "Dash init requires `model` when this repository has not been initialized yet.",
      )
  }
}

fn dash_choose_setup_request(
  generate_setup: Bool,
  _assume_yes: Bool,
  setup_exists: Bool,
) -> Result(Bool, String) {
  case setup_exists {
    True -> Ok(False)
    False -> Ok(generate_setup)
  }
}

fn collect_dash_decisions(
  run: types.RunRecord,
  tasks: List(types.Task),
  answers: List(RawDecisionAnswer),
) -> Result(#(List(types.RecordedDecision), List(types.RunEvent)), String) {
  let prompts = decision_domain.pending_decision_prompts(run.decisions, tasks)
  case prompts {
    [] ->
      Error("No unresolved manual-attention decisions were found for this run.")
    _ -> collect_dash_decisions_loop(prompts, answers, [], [])
  }
}

fn collect_dash_decisions_loop(
  prompts: List(#(types.Task, types.DecisionRequest)),
  answers: List(RawDecisionAnswer),
  recorded: List(types.RecordedDecision),
  warnings: List(types.RunEvent),
) -> Result(#(List(types.RecordedDecision), List(types.RunEvent)), String) {
  case prompts {
    [] -> Ok(#(list.reverse(recorded), list.reverse(warnings)))
    [#(task, request), ..rest] -> {
      use #(answer, warning) <- result.try(resolve_dash_answer(
        task,
        request,
        answers,
      ))
      let next_recorded =
        types.RecordedDecision(
          key: request.key,
          question: request.question,
          answer: answer,
          answered_at: system.timestamp(),
        )
      let next_warnings = case warning {
        Some(event) -> [event, ..warnings]
        None -> warnings
      }
      collect_dash_decisions_loop(
        rest,
        answers,
        [next_recorded, ..recorded],
        next_warnings,
      )
    }
  }
}

fn resolve_dash_answer(
  task: types.Task,
  request: types.DecisionRequest,
  answers: List(RawDecisionAnswer),
) -> Result(#(String, Option(types.RunEvent)), String) {
  use answer <- result.try(find_decision_answer(answers, request.key))
  case request.options {
    [] ->
      Ok(
        #(answer, case request.allow_freeform {
          True -> None
          False -> Some(decision_contract_warning_event(task, request))
        }),
      )
    options ->
      case list.any(options, fn(option) { option.label == answer }) {
        True -> Ok(#(answer, None))
        False ->
          case request.allow_freeform {
            True -> Ok(#(answer, None))
            False ->
              Error(
                "Decision `"
                <> request.key
                <> "` requires one of the declared option labels.",
              )
          }
      }
  }
}

fn find_decision_answer(
  answers: List(RawDecisionAnswer),
  key: String,
) -> Result(String, String) {
  case list.find(answers, fn(answer) { answer.key == key }) {
    Ok(answer) -> Ok(answer.answer)
    Error(_) -> Error("Missing answer for decision `" <> key <> "`.")
  }
}

fn decision_contract_warning_event(
  task: types.Task,
  request: types.DecisionRequest,
) -> types.RunEvent {
  types.RunEvent(
    kind: "decision_contract_warning",
    at: system.timestamp(),
    message: "Coerced `"
      <> request.key
      <> "` into a freeform prompt because the planner returned no options and disallowed freeform input.",
    task_id: Some(task.id),
  )
}

fn resolve_message(view: workflow.ResolveResult) -> String {
  case view.summary {
    Some(summary) -> summary
    None -> "Resolved run " <> view.run.run_id <> "."
  }
}

fn start_message(view: workflow.StartResult) -> String {
  "Start completed for run "
  <> view.run.run_id
  <> " with status "
  <> types.run_status_to_string(view.run.status)
  <> "."
}

fn resume_message(view: workflow.ResumeResult) -> String {
  "Resume completed for run "
  <> view.run.run_id
  <> " with status "
  <> types.run_status_to_string(view.run.status)
  <> "."
}

fn delivered_pr_link(
  task: types.Task,
  handoff_states: List(types.TaskHandoffState),
  events: List(types.RunEvent),
) -> Option(DeliveredPrLink) {
  let handoff_state = types.task_handoff_state(handoff_states, task.id)
  let pr_number = case string.trim(task.pr_number) {
    "" ->
      case handoff_state {
        Some(state) -> state.delivered_pr_number
        None -> ""
      }
    value -> value
  }

  case pr_number {
    "" -> None
    _ ->
      Some(DeliveredPrLink(
        number: pr_number,
        url: latest_pr_url(events),
        handoff_state: handoff_state,
      ))
  }
}

fn latest_pr_url(events: List(types.RunEvent)) -> Option(String) {
  case
    events
    |> list.filter(fn(event) { event.kind == "pr_opened" })
    |> list.reverse
  {
    [event, ..] -> Some(event.message)
    [] -> None
  }
}

fn planning_artifact_paths(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> List(String) {
  let event_paths =
    events
    |> list.filter(fn(event) { event.kind == "planning_artifacts_recorded" })
    |> list.filter_map(fn(event) {
      case string.split_once(event.message, "Planning artifacts: ") {
        Ok(#(_, path)) ->
          case string.trim(path) {
            "" -> Error(Nil)
            trimmed -> Ok(trimmed)
          }
        Error(_) -> Error(Nil)
      }
    })

  let candidate_paths = case run.notes_source {
    Some(types.InlineNotes(path)) -> [path, ..event_paths]
    _ -> event_paths
  }

  candidate_paths |> list.filter(file_or_directory_exists)
}

fn planner_prompt_path(run_path: String) -> Option(String) {
  existing_file(filepath.join(run_path, "planner.prompt.md"))
}

fn planner_log_path(run_path: String) -> Option(String) {
  existing_file(filepath.join(run_path, "logs/planner.log"))
}

fn task_prompt_paths(run_path: String, task_id: String) -> List(String) {
  [
    filepath.join(run_path, "logs/" <> task_id <> ".prompt.md"),
    filepath.join(run_path, "logs/" <> task_id <> ".repair.prompt.md"),
    filepath.join(run_path, "logs/" <> task_id <> ".payload-repair.prompt.md"),
  ]
  |> existing_files
}

fn task_log_paths(run_path: String, task_id: String) -> List(String) {
  [
    filepath.join(run_path, "logs/" <> task_id <> ".log"),
    filepath.join(run_path, "logs/" <> task_id <> ".repair.log"),
    filepath.join(run_path, "logs/" <> task_id <> ".payload-repair.log"),
    filepath.join(run_path, "logs/" <> task_id <> ".verify.log"),
    filepath.join(run_path, "logs/" <> task_id <> ".git.log"),
    filepath.join(run_path, "logs/" <> task_id <> ".env.log"),
  ]
  |> existing_files
}

fn raw_payload_paths(run_path: String, task_id: String) -> List(String) {
  [
    filepath.join(run_path, "logs/" <> task_id <> ".result.raw.jsonish"),
    filepath.join(
      run_path,
      "logs/" <> task_id <> ".payload-repair.result.raw.jsonish",
    ),
  ]
  |> existing_files
}

fn sanitized_payload_paths(run_path: String, task_id: String) -> List(String) {
  [
    filepath.join(run_path, "logs/" <> task_id <> ".result.sanitized.json"),
    filepath.join(
      run_path,
      "logs/" <> task_id <> ".payload-repair.result.sanitized.json",
    ),
  ]
  |> existing_files
}

fn runtime_manifest_path(
  context: Option(types.RuntimeContext),
) -> Option(String) {
  case context {
    Some(value) -> existing_file(value.manifest_path)
    None -> None
  }
}

fn runtime_handoff_path(context: Option(types.RuntimeContext)) -> Option(String) {
  case context {
    Some(value) -> existing_file(value.handoff_path)
    None -> None
  }
}

fn runtime_env_path(context: Option(types.RuntimeContext)) -> Option(String) {
  case context {
    Some(value) -> existing_file(value.env_file_path)
    None -> None
  }
}

fn existing_files(paths: List(String)) -> List(String) {
  paths
  |> list.filter_map(fn(path) {
    case existing_file(path) {
      Some(value) -> Ok(value)
      None -> Error(Nil)
    }
  })
}

fn existing_file(path: String) -> Option(String) {
  case simplifile.read(path) {
    Ok(_) -> Some(path)
    Error(_) -> None
  }
}

fn file_exists(path: String) -> Bool {
  case simplifile.read(path) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn file_or_directory_exists(path: String) -> Bool {
  case simplifile.read(path) {
    Ok(_) -> True
    Error(_) ->
      case simplifile.read_directory(at: path) {
        Ok(_) -> True
        Error(_) -> False
      }
  }
}

fn agent_json(agent: types.ResolvedAgentConfig) -> json.Json {
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
  ])
}

fn identity_json(value: json.Json) -> json.Json {
  value
}
