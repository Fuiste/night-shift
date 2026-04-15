import filepath
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/dash/session
import night_shift/domain/confidence
import night_shift/domain/decisions as decision_domain
import night_shift/domain/provenance as provenance_domain
import night_shift/domain/repo_state
import night_shift/domain/review_run_projection
import night_shift/domain/summary as domain_summary
import night_shift/journal
import night_shift/repo_state_runtime
import night_shift/report
import night_shift/types
import night_shift/usecase/support/runs
import simplifile

pub fn workspace_json(
  repo_root: String,
  requested_run_id: Option(String),
  config: types.Config,
  initialized: Bool,
  command_state: Option(session.CommandState),
) -> Result(String, String) {
  use runs <- result.try(journal.list_runs(repo_root))
  let selected_run_id = choose_selected_run_id(runs, requested_run_id)
  let selected_run = case selected_run_id {
    Some(run_id) -> load_run_projection(repo_root, run_id, config)
    None -> Ok(None)
  }

  use run_projection <- result.try(selected_run)

  Ok(
    json.object([
      #("repo_root", json.string(repo_root)),
      #("initialized", json.bool(initialized)),
      #("config_present", json.bool(initialized)),
      #(
        "worktree_setup_present",
        json.bool(
          file_exists(filepath.join(
            repo_root,
            ".night-shift/worktree-setup.toml",
          )),
        ),
      ),
      #("default_profile", json.string(config.default_profile)),
      #("providers", json.array(provider_names(), json.string)),
      #(
        "selected_run_id",
        json.nullable(from: selected_run_id, of: json.string),
      ),
      #("runs", json.array(runs, run_summary_json)),
      #(
        "command_state",
        json.nullable(from: command_state, of: command_state_json),
      ),
      #("run", json.nullable(from: run_projection, of: identity_json)),
    ])
    |> json.to_string,
  )
}

pub fn load_run_projection(
  repo_root: String,
  run_id: String,
  config: types.Config,
) -> Result(Option(json.Json), String) {
  journal.load(repo_root, types.RunId(run_id))
  |> result.map(fn(run_and_events) {
    let #(run, events) = run_and_events
    Some(run_projection_json(run, events, config))
  })
}

fn run_projection_json(
  run: types.RunRecord,
  events: List(types.RunEvent),
  config: types.Config,
) -> json.Json {
  let inspection = repo_state_runtime.inspect(run, config.branch_prefix)
  let repo_state_view = inspection.view
  let review_projection =
    review_run_projection.build(run, events, repo_state_view)
  let confidence_assessment = confidence.assess(run, events, repo_state_view)
  let report_markdown = report.render_live(run, events, repo_state_view)
  let provenance_markdown =
    provenance_domain.render(
      run,
      events,
      repo_state_view,
      None,
      types.ProvenanceMarkdown,
      config.verification_commands,
    )
    |> result.unwrap(or: "Unable to render provenance.")
  let decision_prompts =
    decision_domain.pending_decision_prompts(run.decisions, run.tasks)
  let recovery_intro = domain_summary.setup_recovery_intro(run)
  let recovery_outcome_lines = domain_summary.setup_recovery_outcome_lines(run)

  json.object([
    #("run_id", json.string(run.run_id)),
    #("status", json.string(types.run_status_to_string(run.status))),
    #("created_at", json.string(run.created_at)),
    #("updated_at", json.string(run.updated_at)),
    #("brief_path", json.string(run.brief_path)),
    #("report_path", json.string(run.report_path)),
    #("provenance_path", json.string(provenance_domain.artifact_path(run))),
    #("next_action", json.string(runs.next_action_for_run(run))),
    #(
      "planning_provenance",
      json.nullable(from: run.planning_provenance, of: planning_provenance_json),
    ),
    #(
      "notes_source",
      json.nullable(from: run.notes_source, of: notes_source_json),
    ),
    #("planning_agent", agent_json(run.planning_agent)),
    #("execution_agent", agent_json(run.execution_agent)),
    #(
      "confidence",
      json.object([
        #(
          "level",
          json.string(types.confidence_posture_to_string(
            confidence_assessment.posture,
          )),
        ),
        #("reasons", json.array(confidence_assessment.reasons, json.string)),
      ]),
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
    #("dag", dag_json(run.tasks, events)),
    #("tasks", json.array(run.tasks, task_json(_, events, run))),
    #("decisions", json.array(decision_prompts, pending_decision_json)),
    #(
      "repo_state",
      json.nullable(from: review_projection, of: review_projection_json),
    ),
    #("timeline", json.array(events, event_json)),
    #("events", json.array(events, event_json)),
    #("report_markdown", json.string(report_markdown)),
    #("report", json.string(report_markdown)),
    #("provenance_markdown", json.string(provenance_markdown)),
    #(
      "artifacts",
      json.object([
        #("report_url", json.string(artifact_url(run.run_id, ["report.md"]))),
        #(
          "provenance_url",
          json.string(artifact_url(run.run_id, ["provenance.json"])),
        ),
      ]),
    ),
    #("delivery", json.array(delivery_rows(run.tasks, events), delivery_json)),
    #(
      "replacement_pr_numbers",
      json.array(replacement_pr_numbers(run.tasks), json.int),
    ),
    #("recovery_intro", json.string(recovery_intro)),
    #("recovery_outcome_lines", json.array(recovery_outcome_lines, json.string)),
    #(
      "recovery_blocker",
      json.nullable(from: run.recovery_blocker, of: recovery_blocker_json),
    ),
    #(
      "recovery",
      json.object([
        #(
          "setup_blocker",
          json.nullable(from: run.recovery_blocker, of: recovery_blocker_json),
        ),
        #(
          "implementation_blockers",
          json.array(
            decision_domain.implementation_blocking_tasks(run),
            task_json(_, events, run),
          ),
        ),
      ]),
    ),
  ])
}

fn run_summary_json(run: types.RunRecord) -> json.Json {
  json.object([
    #("run_id", json.string(run.run_id)),
    #("status", json.string(types.run_status_to_string(run.status))),
    #("created_at", json.string(run.created_at)),
    #("updated_at", json.string(run.updated_at)),
    #("task_count", json.int(list.length(run.tasks))),
    #("planning_dirty", json.bool(run.planning_dirty)),
  ])
}

fn agent_json(agent: types.ResolvedAgentConfig) -> json.Json {
  json.object([
    #("profile_name", json.string(agent.profile_name)),
    #("provider", json.string(types.provider_to_string(agent.provider))),
    #("model", json.nullable(from: agent.model, of: json.string)),
    #(
      "reasoning",
      json.nullable(from: agent.reasoning, of: fn(reasoning) {
        json.string(types.reasoning_to_string(reasoning))
      }),
    ),
  ])
}

fn planning_provenance_json(provenance: types.PlanningProvenance) -> json.Json {
  json.object([
    #("label", json.string(types.planning_provenance_label(provenance))),
    #(
      "uses_reviews",
      json.bool(types.planning_provenance_uses_reviews(provenance)),
    ),
    #(
      "notes_source",
      json.nullable(
        from: types.planning_provenance_notes_source(provenance),
        of: notes_source_json,
      ),
    ),
  ])
}

fn notes_source_json(source: types.NotesSource) -> json.Json {
  json.object([
    #("label", json.string(types.notes_source_label(source))),
    #(
      "kind",
      json.string(case source {
        types.NotesFile(_) -> "file"
        types.InlineNotes(_) -> "inline"
      }),
    ),
    #(
      "path",
      json.string(case source {
        types.NotesFile(path) | types.InlineNotes(path) -> path
      }),
    ),
  ])
}

fn dag_json(tasks: List(types.Task), events: List(types.RunEvent)) -> json.Json {
  json.object([
    #("nodes", json.array(tasks, dag_node_json(_, events))),
    #("edges", json.array(tasks |> dag_edges, dag_edge_json)),
  ])
}

fn dag_node_json(task: types.Task, events: List(types.RunEvent)) -> json.Json {
  json.object([
    #("id", json.string(task.id)),
    #("title", json.string(task.title)),
    #("state", json.string(types.task_state_to_string(task.state))),
    #("kind", json.string(types.task_kind_to_string(task.kind))),
    #("branch_name", json.string(task.branch_name)),
    #("pr_number", json.string(task.pr_number)),
    #(
      "pr_url",
      json.nullable(from: task_pr_url(events, task.id), of: json.string),
    ),
  ])
}

fn dag_edges(tasks: List(types.Task)) -> List(#(String, String)) {
  tasks
  |> list.map(fn(task) {
    task.dependencies |> list.map(fn(dep) { #(dep, task.id) })
  })
  |> list.flatten
}

fn dag_edge_json(edge: #(String, String)) -> json.Json {
  json.object([
    #("from", json.string(edge.0)),
    #("to", json.string(edge.1)),
  ])
}

fn task_json(
  task: types.Task,
  events: List(types.RunEvent),
  run: types.RunRecord,
) -> json.Json {
  json.object([
    #("id", json.string(task.id)),
    #("title", json.string(task.title)),
    #("description", json.string(task.description)),
    #("summary", json.string(task.summary)),
    #("state", json.string(types.task_state_to_string(task.state))),
    #("kind", json.string(types.task_kind_to_string(task.kind))),
    #(
      "execution_mode",
      json.string(types.execution_mode_to_string(task.execution_mode)),
    ),
    #("dependencies", json.array(task.dependencies, json.string)),
    #("acceptance", json.array(task.acceptance, json.string)),
    #("demo_plan", json.array(task.demo_plan, json.string)),
    #("branch_name", json.string(task.branch_name)),
    #("pr_number", json.string(task.pr_number)),
    #(
      "pr_url",
      json.nullable(from: task_pr_url(events, task.id), of: json.string),
    ),
    #("superseded_pr_numbers", json.array(task.superseded_pr_numbers, json.int)),
    #("worktree_path", json.string(task.worktree_path)),
    #(
      "runtime_context",
      json.nullable(from: task.runtime_context, of: runtime_context_json),
    ),
    #(
      "decision_requests",
      json.array(task.decision_requests, decision_request_json),
    ),
    #(
      "artifacts",
      json.object([
        #(
          "task_log_url",
          json.string(artifact_url(run.run_id, ["logs", task.id <> ".log"])),
        ),
        #(
          "verify_log_url",
          json.string(
            artifact_url(run.run_id, ["logs", task.id <> ".verify.log"]),
          ),
        ),
      ]),
    ),
  ])
}

fn runtime_context_json(context: types.RuntimeContext) -> json.Json {
  json.object([
    #("worktree_id", json.string(context.worktree_id)),
    #("compose_project", json.string(context.compose_project)),
    #("port_base", json.int(context.port_base)),
    #("runtime_dir", json.string(context.runtime_dir)),
    #("env_file_path", json.string(context.env_file_path)),
    #("manifest_path", json.string(context.manifest_path)),
    #("handoff_path", json.string(context.handoff_path)),
    #("named_ports", json.array(context.named_ports, runtime_port_json)),
  ])
}

fn runtime_port_json(port: types.RuntimePort) -> json.Json {
  json.object([
    #("name", json.string(port.name)),
    #("value", json.int(port.value)),
  ])
}

fn decision_request_json(request: types.DecisionRequest) -> json.Json {
  json.object([
    #("key", json.string(request.key)),
    #("question", json.string(request.question)),
    #("rationale", json.string(request.rationale)),
    #("allow_freeform", json.bool(request.allow_freeform)),
    #(
      "recommended_option",
      json.nullable(from: request.recommended_option, of: json.string),
    ),
    #("options", json.array(request.options, decision_option_json)),
  ])
}

fn decision_option_json(option: types.DecisionOption) -> json.Json {
  json.object([
    #("label", json.string(option.label)),
    #("description", json.string(option.description)),
  ])
}

fn pending_decision_json(
  prompt: #(types.Task, types.DecisionRequest),
) -> json.Json {
  json.object([
    #("task_id", json.string(prompt.0.id)),
    #("task_title", json.string(prompt.0.title)),
    #("request", decision_request_json(prompt.1)),
  ])
}

fn review_projection_json(
  projection: review_run_projection.ReviewRunProjection,
) -> json.Json {
  json.object([
    #(
      "repo_state",
      json.object([
        #(
          "captured_open_pr_count",
          json.int(projection.repo_state.captured_open_pr_count),
        ),
        #(
          "captured_actionable_pr_count",
          json.int(projection.repo_state.captured_actionable_pr_count),
        ),
        #(
          "snapshot_captured_at",
          json.string(projection.repo_state.snapshot_captured_at),
        ),
        #(
          "current_open_pr_count",
          json.nullable(
            from: projection.repo_state.current_open_pr_count,
            of: json.int,
          ),
        ),
        #(
          "current_actionable_pr_count",
          json.nullable(
            from: projection.repo_state.current_actionable_pr_count,
            of: json.int,
          ),
        ),
        #(
          "drift",
          json.nullable(from: projection.repo_state.drift, of: json.string),
        ),
        #(
          "drift_details",
          json.nullable(
            from: projection.repo_state.drift_details,
            of: json.string,
          ),
        ),
        #(
          "actionable_pull_requests",
          json.array(
            projection.repo_state.actionable_pull_requests,
            pull_request_json,
          ),
        ),
        #(
          "impacted_pull_requests",
          json.array(
            projection.repo_state.impacted_pull_requests,
            pull_request_json,
          ),
        ),
      ]),
    ),
    #(
      "replacement_lineage",
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

fn pull_request_json(pr: repo_state.RepoPullRequestSnapshot) -> json.Json {
  json.object([
    #("number", json.int(pr.number)),
    #("title", json.string(pr.title)),
    #("branch_name", json.string(pr.head_ref_name)),
    #("url", json.string(pr.url)),
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

fn event_json(event: types.RunEvent) -> json.Json {
  json.object([
    #("kind", json.string(event.kind)),
    #("at", json.string(event.at)),
    #("message", json.string(event.message)),
    #("task_id", json.nullable(from: event.task_id, of: json.string)),
  ])
}

fn delivery_rows(
  tasks: List(types.Task),
  events: List(types.RunEvent),
) -> List(#(types.Task, String)) {
  tasks
  |> list.filter_map(fn(task) {
    case task.pr_number, task_pr_url(events, task.id) {
      "", _ -> Error(Nil)
      _, None -> Error(Nil)
      _, Some(pr_url) -> Ok(#(task, pr_url))
    }
  })
}

fn delivery_json(row: #(types.Task, String)) -> json.Json {
  json.object([
    #("task_id", json.string(row.0.id)),
    #("task_title", json.string(row.0.title)),
    #("pr_number", json.string(row.0.pr_number)),
    #("pr_url", json.string(row.1)),
  ])
}

fn replacement_pr_numbers(tasks: List(types.Task)) -> List(Int) {
  unique_pr_numbers(
    tasks |> list.flat_map(fn(task) { task.superseded_pr_numbers }),
    [],
  )
}

fn unique_pr_numbers(values: List(Int), acc: List(Int)) -> List(Int) {
  case values {
    [] -> list.reverse(acc)
    [value, ..rest] ->
      case list.contains(acc, value) {
        True -> unique_pr_numbers(rest, acc)
        False -> unique_pr_numbers(rest, [value, ..acc])
      }
  }
}

fn recovery_blocker_json(blocker: types.RecoveryBlocker) -> json.Json {
  json.object([
    #(
      "kind",
      json.string(case blocker.kind {
        types.EnvironmentPreflightBlocker -> "environment_preflight"
        types.TaskSetupBlocker -> "task_setup"
      }),
    ),
    #(
      "phase",
      json.string(case blocker.phase {
        types.PreflightPhase -> "preflight"
        types.SetupPhase -> "setup"
        types.MaintenancePhase -> "maintenance"
      }),
    ),
    #("task_id", json.nullable(from: blocker.task_id, of: json.string)),
    #("message", json.string(blocker.message)),
    #("log_path", json.string(blocker.log_path)),
    #("no_changes_produced", json.bool(blocker.no_changes_produced)),
    #(
      "disposition",
      json.string(case blocker.disposition {
        types.RecoveryBlocking -> "blocking"
        types.RecoveryWaivedOnce -> "waived_once"
      }),
    ),
  ])
}

fn command_state_json(state: session.CommandState) -> json.Json {
  json.object([
    #("name", json.string(state.name)),
    #("run_id", json.nullable(from: state.run_id, of: json.string)),
    #("started_at", json.string(state.started_at)),
    #("summary", json.string(state.summary)),
  ])
}

fn choose_selected_run_id(
  runs: List(types.RunRecord),
  requested_run_id: Option(String),
) -> Option(String) {
  case requested_run_id {
    Some(run_id) ->
      case list.any(runs, fn(run) { run.run_id == run_id }) {
        True -> Some(run_id)
        False -> fallback_run_id(runs)
      }
    None -> fallback_run_id(runs)
  }
}

fn fallback_run_id(runs: List(types.RunRecord)) -> Option(String) {
  case runs {
    [run, ..] -> Some(run.run_id)
    [] -> None
  }
}

fn provider_names() -> List(String) {
  ["codex", "cursor"]
}

fn task_pr_url(events: List(types.RunEvent), task_id: String) -> Option(String) {
  find_task_pr_url(list.reverse(events), task_id)
}

fn artifact_url(run_id: String, path_segments: List(String)) -> String {
  "/artifacts/runs/" <> run_id <> "/" <> string.join(path_segments, with: "/")
}

fn file_exists(path: String) -> Bool {
  case simplifile.read(path) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn find_task_pr_url(
  events: List(types.RunEvent),
  task_id: String,
) -> Option(String) {
  case events {
    [] -> None
    [event, ..rest] ->
      case event.kind == "pr_opened" && event.task_id == Some(task_id) {
        True -> Some(event.message)
        False -> find_task_pr_url(rest, task_id)
      }
  }
}

fn identity_json(value: json.Json) -> json.Json {
  value
}
