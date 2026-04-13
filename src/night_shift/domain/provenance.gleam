import filepath
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/config
import night_shift/domain/confidence
import night_shift/project
import night_shift/repo_state_runtime
import night_shift/types
import simplifile

pub fn artifact_path(run: types.RunRecord) -> String {
  filepath.join(run.run_path, "provenance.json")
}

pub fn write_persisted(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> Result(Nil, String) {
  let verification_commands = load_verification_commands(run.repo_root)
  let repo_state_view = None
  let assessment = confidence.assess(run, events, repo_state_view)
  let manifest =
    manifest_json(run, events, repo_state_view, verification_commands, assessment)
  write_file(artifact_path(run), json.to_string(manifest))
}

pub fn render(
  run: types.RunRecord,
  events: List(types.RunEvent),
  repo_state_view: Option(repo_state_runtime.RepoStateView),
  task_filter: Option(String),
  format: types.ProvenanceFormat,
  verification_commands: List(String),
) -> Result(String, String) {
  use filtered_tasks <- result.try(filter_tasks(run.tasks, task_filter))
  let filtered_run = types.RunRecord(..run, tasks: filtered_tasks)
  let filtered_events = filter_events(events, task_filter)
  let assessment = confidence.assess(filtered_run, filtered_events, repo_state_view)

  Ok(case format {
    types.ProvenanceJson ->
      manifest_json(
        filtered_run,
        filtered_events,
        repo_state_view,
        verification_commands,
        assessment,
      )
      |> json.to_string
    types.ProvenanceMarkdown ->
      render_markdown(
        filtered_run,
        filtered_events,
        repo_state_view,
        verification_commands,
        assessment,
      )
  })
}

fn render_markdown(
  run: types.RunRecord,
  events: List(types.RunEvent),
  repo_state_view: Option(repo_state_runtime.RepoStateView),
  verification_commands: List(String),
  assessment: types.ConfidenceAssessment,
) -> String {
  [
    "# Night Shift Provenance",
    "",
    "## Run",
    "- Run ID: " <> run.run_id,
    "- Status: " <> types.run_status_to_string(run.status),
    "- Brief: " <> run.brief_path,
    "- Report: " <> run.report_path,
    "- Provenance artifact: " <> artifact_path(run),
    "- Confidence posture: "
      <> types.confidence_posture_to_string(assessment.posture),
    "- Confidence reasons: " <> confidence.reasons_summary(assessment),
    "- Planning provenance: " <> render_planning_provenance(run.planning_provenance),
    "- Notes source: " <> render_notes_source(run.notes_source),
    "- Planning artifacts: " <> render_string_list(planning_artifact_paths(run, events)),
    "- Planner prompt: " <> render_optional_path(planner_prompt_path(run.run_path)),
    "- Planner log: " <> render_optional_path(planner_log_path(run.run_path)),
    render_review_state_markdown(run, repo_state_view),
    "",
    "## Tasks",
    render_task_sections(run, events, verification_commands),
    "",
    "## Event References",
    render_event_refs(events),
  ]
  |> list.filter(fn(line) { line != "" })
  |> string.join(with: "\n")
}

fn manifest_json(
  run: types.RunRecord,
  events: List(types.RunEvent),
  repo_state_view: Option(repo_state_runtime.RepoStateView),
  verification_commands: List(String),
  assessment: types.ConfidenceAssessment,
) -> json.Json {
  json.object([
    #(
      "run",
      json.object([
        #("run_id", json.string(run.run_id)),
        #("status", json.string(types.run_status_to_string(run.status))),
        #("repo_root", json.string(run.repo_root)),
        #("run_path", json.string(run.run_path)),
        #("brief_path", json.string(run.brief_path)),
        #("report_path", json.string(run.report_path)),
        #("provenance_path", json.string(artifact_path(run))),
        #("planning_agent", agent_json(run.planning_agent)),
        #("execution_agent", agent_json(run.execution_agent)),
        #("planning_provenance", json.string(render_planning_provenance(
          run.planning_provenance,
        ))),
        #("notes_source", json.string(render_notes_source(run.notes_source))),
        #(
          "planning_artifacts",
          json.array(planning_artifact_paths(run, events), json.string),
        ),
        #(
          "planner_prompt_path",
          json.nullable(from: planner_prompt_path(run.run_path), of: json.string),
        ),
        #(
          "planner_log_path",
          json.nullable(from: planner_log_path(run.run_path), of: json.string),
        ),
      ]),
    ),
    #(
      "confidence_posture",
      json.object([
        #(
          "level",
          json.string(types.confidence_posture_to_string(assessment.posture)),
        ),
        #("reasons", json.array(assessment.reasons, json.string)),
      ]),
    ),
    #(
      "review_state",
      json.nullable(
        from: review_state_json(run, repo_state_view),
        of: identity_json,
      ),
    ),
    #("tasks", json.array(run.tasks, task_json(_, run, events, verification_commands))),
    #("event_refs", json.array(events, event_ref_json)),
  ])
}

fn task_json(
  task: types.Task,
  run: types.RunRecord,
  events: List(types.RunEvent),
  verification_commands: List(String),
) -> json.Json {
  let relevant_events =
    events
    |> list.filter(fn(event) { event.task_id == Some(task.id) })
  let verification_log = existing_file(verification_log_path(run.run_path, task.id))

  json.object([
    #("id", json.string(task.id)),
    #("title", json.string(task.title)),
    #("state", json.string(types.task_state_to_string(task.state))),
    #("summary", json.string(task.summary)),
    #("worktree_path", json.string(task.worktree_path)),
    #("branch_name", json.string(task.branch_name)),
    #("pr_number", json.string(task.pr_number)),
    #(
      "superseded_pr_numbers",
      json.array(task.superseded_pr_numbers, json.int),
    ),
    #("files_touched", json.array(parse_changed_files(task.summary), json.string)),
    #(
      "verification",
      json.object([
        #("commands", json.array(verification_commands, json.string)),
        #(
          "outcome",
          json.string(verification_outcome(task, relevant_events)),
        ),
        #(
          "log_path",
          json.nullable(from: verification_log, of: json.string),
        ),
      ]),
    ),
    #(
      "artifacts",
      json.object([
        #("prompt_paths", json.array(task_prompt_paths(run.run_path, task.id), json.string)),
        #("log_paths", json.array(task_log_paths(run.run_path, task.id), json.string)),
        #("raw_payload_paths", json.array(raw_payload_paths(run.run_path, task.id), json.string)),
        #(
          "sanitized_payload_paths",
          json.array(sanitized_payload_paths(run.run_path, task.id), json.string),
        ),
      ]),
    ),
    #("event_refs", json.array(relevant_events, event_ref_json)),
  ])
}

fn review_state_json(
  run: types.RunRecord,
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> Option(json.Json) {
  case run.repo_state_snapshot {
    None -> None
    Some(snapshot) ->
      Some(json.object([
        #("snapshot_captured_at", json.string(snapshot.captured_at)),
        #("captured_open_pr_count", json.int(list.length(snapshot.open_pull_requests))),
        #(
          "captured_actionable_pr_count",
          json.int(
            snapshot.open_pull_requests
            |> list.filter(fn(pr) { pr.actionable })
            |> list.length,
          ),
        ),
        #(
          "drift",
          json.string(case repo_state_view {
            Some(view) -> repo_state_runtime.drift_label(view.drift)
            None -> "unknown"
          }),
        ),
      ]))
  }
}

fn render_task_sections(
  run: types.RunRecord,
  events: List(types.RunEvent),
  verification_commands: List(String),
) -> String {
  case run.tasks {
    [] -> "- No tasks matched the provenance request."
    _ ->
      run.tasks
      |> list.map(fn(task) {
        let relevant_events =
          events
          |> list.filter(fn(event) { event.task_id == Some(task.id) })
        [
          "- "
            <> task.id
            <> " ("
            <> types.task_state_to_string(task.state)
            <> ")",
          "  Branch: " <> render_empty_as_dash(task.branch_name),
          "  PR: " <> render_empty_as_dash(task.pr_number),
          "  Worktree: " <> render_empty_as_dash(task.worktree_path),
          "  Files touched: " <> render_string_list(parse_changed_files(task.summary)),
          "  Verification commands: " <> render_string_list(verification_commands),
          "  Verification outcome: " <> verification_outcome(task, relevant_events),
          "  Prompt artifacts: " <> render_string_list(task_prompt_paths(run.run_path, task.id)),
          "  Log artifacts: " <> render_string_list(task_log_paths(run.run_path, task.id)),
          "  Raw payloads: " <> render_string_list(raw_payload_paths(run.run_path, task.id)),
          "  Sanitized payloads: "
            <> render_string_list(sanitized_payload_paths(run.run_path, task.id)),
          "  Event refs: "
            <> render_string_list(
              relevant_events |> list.map(render_event_ref_label),
            ),
        ]
        |> string.join(with: "\n")
      })
      |> string.join(with: "\n")
  }
}

fn render_event_refs(events: List(types.RunEvent)) -> String {
  case events {
    [] -> "- No events recorded yet."
    _ ->
      events
      |> list.map(fn(event) {
        "- "
        <> render_event_ref_label(event)
        <> " "
        <> string.replace(in: event.message, each: "\n", with: " ")
      })
      |> string.join(with: "\n")
  }
}

fn render_review_state_markdown(
  run: types.RunRecord,
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> String {
  case review_state_json(run, repo_state_view) {
    Some(_) ->
      "## Review State\n"
      <> "- Snapshot captured: "
      <> case run.repo_state_snapshot {
        Some(snapshot) -> snapshot.captured_at
        None -> "—"
      }
      <> "\n- Drift: "
      <> case repo_state_view {
        Some(view) -> repo_state_runtime.drift_label(view.drift)
        None -> "unknown"
      }
    None -> ""
  }
}

fn filter_tasks(
  tasks: List(types.Task),
  task_filter: Option(String),
) -> Result(List(types.Task), String) {
  case task_filter {
    None -> Ok(tasks)
    Some(task_id) ->
      case list.filter(tasks, fn(task) { task.id == task_id }) {
        [] -> Error("No task matched provenance filter `" <> task_id <> "`.")
        filtered -> Ok(filtered)
      }
  }
}

fn filter_events(
  events: List(types.RunEvent),
  task_filter: Option(String),
) -> List(types.RunEvent) {
  case task_filter {
    None -> events
    Some(task_id) ->
      events
      |> list.filter(fn(event) {
        event.task_id == Some(task_id) || event.task_id == None
      })
  }
}

fn load_verification_commands(repo_root: String) -> List(String) {
  case config.load(project.config_path(repo_root)) {
    Ok(loaded_config) -> loaded_config.verification_commands
    Error(_) -> []
  }
}

fn planning_artifact_paths(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> List(String) {
  let event_paths =
    events
    |> list.filter(fn(event) { event.kind == "planning_artifacts_recorded" })
    |> list.map(fn(event) { event.message })
    |> list.filter_map(extract_path_from_event)

  let candidate_paths = case run.notes_source {
    Some(types.InlineNotes(path)) -> [path, ..event_paths]
    _ -> event_paths
  }

  candidate_paths
  |> list.filter(file_or_directory_exists)
}

fn extract_path_from_event(message: String) -> Result(String, Nil) {
  case string.split_once(message, "Planning artifacts: ") {
    Ok(#(_, path)) -> Ok(string.trim(path))
    Error(_) -> Error(Nil)
  }
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
    execution_log_path(run_path, task_id),
    repair_log_path(run_path, task_id),
    payload_repair_log_path(run_path, task_id),
    verification_log_path(run_path, task_id),
    filepath.join(run_path, "logs/" <> task_id <> ".git.log"),
    filepath.join(run_path, "logs/" <> task_id <> ".env.log"),
  ]
  |> existing_files
}

fn raw_payload_paths(run_path: String, task_id: String) -> List(String) {
  [
    filepath.join(run_path, "logs/" <> task_id <> ".result.raw.jsonish"),
    filepath.join(run_path, "logs/" <> task_id <> ".payload-repair.result.raw.jsonish"),
  ]
  |> existing_files
}

fn sanitized_payload_paths(run_path: String, task_id: String) -> List(String) {
  [
    filepath.join(run_path, "logs/" <> task_id <> ".result.sanitized.json"),
    filepath.join(run_path, "logs/" <> task_id <> ".payload-repair.result.sanitized.json"),
  ]
  |> existing_files
}

fn verification_log_path(run_path: String, task_id: String) -> String {
  filepath.join(run_path, "logs/" <> task_id <> ".verify.log")
}

fn execution_log_path(run_path: String, task_id: String) -> String {
  filepath.join(run_path, "logs/" <> task_id <> ".log")
}

fn repair_log_path(run_path: String, task_id: String) -> String {
  filepath.join(run_path, "logs/" <> task_id <> ".repair.log")
}

fn payload_repair_log_path(run_path: String, task_id: String) -> String {
  filepath.join(run_path, "logs/" <> task_id <> ".payload-repair.log")
}

fn verification_outcome(
  task: types.Task,
  events: List(types.RunEvent),
) -> String {
  case list.any(events, fn(event) { event.kind == "task_verified" }) {
    True -> "passed"
    False ->
      case task.state {
        types.Failed ->
          case string.contains(does: task.summary, contain: "verification failed") {
            True -> "failed"
            False -> "not_recorded"
          }
        _ -> "not_recorded"
      }
  }
}

fn parse_changed_files(summary: String) -> List(String) {
  case string.split_once(summary, " Changed files: ") {
    Ok(#(_, changed_files)) ->
      changed_files
      |> string.split(",")
      |> list.filter_map(fn(entry) {
        case string.trim(entry) {
          "" -> Error(Nil)
          path -> Ok(path)
        }
      })
    Error(_) -> []
  }
}

fn event_ref_json(event: types.RunEvent) -> json.Json {
  json.object([
    #("event_id", json.string(event_id(event))),
    #("kind", json.string(event.kind)),
    #("at", json.string(event.at)),
    #("task_id", case event.task_id {
      Some(task_id) -> json.string(task_id)
      None -> json.null()
    }),
    #("message", json.string(event.message)),
  ])
}

fn render_event_ref_label(event: types.RunEvent) -> String {
  event_id(event) <> "@" <> event.at
}

fn event_id(event: types.RunEvent) -> String {
  case event.task_id {
    Some(task_id) -> event.kind <> ":" <> task_id
    None -> event.kind <> ":run"
  }
}

fn agent_json(agent: types.ResolvedAgentConfig) -> json.Json {
  json.object([
    #("profile_name", json.string(agent.profile_name)),
    #("provider", json.string(types.provider_to_string(agent.provider))),
    #("model", case agent.model {
      Some(model) -> json.string(model)
      None -> json.null()
    }),
    #("reasoning", case agent.reasoning {
      Some(reasoning) -> json.string(types.reasoning_to_string(reasoning))
      None -> json.null()
    }),
  ])
}

fn render_planning_provenance(
  provenance: Option(types.PlanningProvenance),
) -> String {
  case provenance {
    Some(value) -> types.planning_provenance_label(value)
    None -> "(legacy)"
  }
}

fn render_notes_source(notes_source: Option(types.NotesSource)) -> String {
  case notes_source {
    Some(source) -> types.notes_source_label(source)
    None -> "(none)"
  }
}

fn render_string_list(values: List(String)) -> String {
  case values {
    [] -> "none"
    _ -> string.join(values, with: ", ")
  }
}

fn render_optional_path(path: Option(String)) -> String {
  case path {
    Some(value) -> value
    None -> "none"
  }
}

fn render_empty_as_dash(value: String) -> String {
  case string.trim(value) {
    "" -> "—"
    _ -> value
  }
}

fn identity_json(value: json.Json) -> json.Json {
  value
}

fn existing_files(paths: List(String)) -> List(String) {
  paths
  |> list.filter(file_exists)
}

fn existing_file(path: String) -> Option(String) {
  case file_exists(path) {
    True -> Some(path)
    False -> None
  }
}

fn file_exists(path: String) -> Bool {
  case simplifile.read(path) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn file_or_directory_exists(path: String) -> Bool {
  file_exists(path)
  || case simplifile.read_directory(at: path) {
    Ok(_) -> True
    Error(_) -> False
  }
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
