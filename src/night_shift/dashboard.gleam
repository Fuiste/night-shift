//// Minimal local dashboard surface for inspecting Night Shift runs.

import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import night_shift/config
import night_shift/domain/confidence
import night_shift/domain/provenance
import night_shift/domain/review_run_projection
import night_shift/journal
import night_shift/project
import night_shift/repo_state_runtime
import night_shift/report
import night_shift/types

/// A running local dashboard session.
pub type Session {
  Session(url: String, handle: String)
}

/// Start a read-only dashboard session for an existing run.
@external(erlang, "night_shift_dashboard_server", "start_view_session")
pub fn start_view_session(
  repo_root: String,
  initial_run_id: String,
) -> Result(Session, String)

/// Start a dashboard session that owns a live `start` invocation.
@external(erlang, "night_shift_dashboard_server", "start_start_session")
pub fn start_start_session(
  repo_root: String,
  initial_run_id: String,
  run: types.RunRecord,
  config: types.Config,
) -> Result(Session, String)

/// Start a dashboard session that owns a live `resume` invocation.
@external(erlang, "night_shift_dashboard_server", "start_resume_session")
pub fn start_resume_session(
  repo_root: String,
  initial_run_id: String,
  run: types.RunRecord,
  config: types.Config,
) -> Result(Session, String)

/// Stop a running dashboard session.
@external(erlang, "night_shift_dashboard_server", "stop_session")
pub fn stop_session(session: Session) -> Nil

/// Fetch a dashboard URL from the local server.
@external(erlang, "night_shift_dashboard_server", "http_get")
pub fn http_get(url: String) -> Result(String, String)

/// Render the self-contained dashboard HTML shell.
pub fn index_html(initial_run_id: String) -> String {
  let initial_run_json = json.string(initial_run_id) |> json.to_string

  "<!doctype html>\n"
  <> "<html lang=\"en\">\n"
  <> "<head>\n"
  <> "  <meta charset=\"utf-8\">\n"
  <> "  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
  <> "  <title>Night Shift Dashboard</title>\n"
  <> "  <style>\n"
  <> "    :root { color-scheme: light; font-family: Georgia, 'Iowan Old Style', 'Palatino Linotype', serif; }\n"
  <> "    * { box-sizing: border-box; }\n"
  <> "    body { margin: 0; background: linear-gradient(180deg, #faf6ee 0%, #f2ede4 100%); color: #201a14; }\n"
  <> "    .shell { min-height: 100vh; padding: 24px; }\n"
  <> "    .hero { margin-bottom: 20px; padding: 20px 24px; border-radius: 18px; background: rgba(255, 252, 246, 0.88); border: 1px solid rgba(79, 56, 35, 0.12); box-shadow: 0 12px 40px rgba(64, 43, 24, 0.08); }\n"
  <> "    h1, h2, h3 { margin: 0; font-weight: 600; }\n"
  <> "    p { margin: 0; }\n"
  <> "    .grid { display: grid; gap: 20px; grid-template-columns: minmax(240px, 320px) minmax(0, 1fr); }\n"
  <> "    .panel { padding: 18px; border-radius: 18px; background: rgba(255, 253, 249, 0.94); border: 1px solid rgba(79, 56, 35, 0.12); box-shadow: 0 10px 30px rgba(64, 43, 24, 0.06); }\n"
  <> "    .stack { display: grid; gap: 20px; }\n"
  <> "    .history-list, .task-list, .event-list { margin: 0; padding: 0; list-style: none; display: grid; gap: 10px; }\n"
  <> "    button.run-link { width: 100%; padding: 12px 14px; border-radius: 12px; border: 1px solid rgba(79, 56, 35, 0.14); background: #fffaf2; text-align: left; cursor: pointer; color: inherit; }\n"
  <> "    button.run-link.active { background: #2f5a4a; color: #fff9ef; border-color: #2f5a4a; }\n"
  <> "    .meta { display: grid; gap: 8px; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); margin-top: 16px; }\n"
  <> "    .meta-card { padding: 12px 14px; border-radius: 14px; background: #f7f0e4; }\n"
  <> "    .label { font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.08em; opacity: 0.7; }\n"
  <> "    .value { margin-top: 4px; font-size: 0.98rem; word-break: break-word; }\n"
  <> "    .task-row, .event-row { padding: 12px 14px; border-radius: 14px; background: #f9f3e9; }\n"
  <> "    .task-header, .event-header { display: flex; flex-wrap: wrap; gap: 8px; align-items: baseline; justify-content: space-between; }\n"
  <> "    .state { display: inline-flex; align-items: center; padding: 4px 9px; border-radius: 999px; background: #e6dcc9; font-size: 0.78rem; text-transform: uppercase; letter-spacing: 0.08em; }\n"
  <> "    pre { margin: 0; white-space: pre-wrap; word-break: break-word; font-family: 'SFMono-Regular', 'Menlo', monospace; font-size: 0.88rem; }\n"
  <> "    .muted { opacity: 0.72; }\n"
  <> "    @media (max-width: 900px) { .shell { padding: 16px; } .grid { grid-template-columns: 1fr; } }\n"
  <> "  </style>\n"
  <> "</head>\n"
  <> "<body>\n"
  <> "  <div class=\"shell\">\n"
  <> "    <section class=\"hero\">\n"
  <> "      <h1>Night Shift Dashboard</h1>\n"
  <> "      <p class=\"muted\" id=\"status-line\">Loading run history...</p>\n"
  <> "      <div class=\"meta\" id=\"run-meta\"></div>\n"
  <> "    </section>\n"
  <> "    <section class=\"grid\">\n"
  <> "      <aside class=\"panel\">\n"
  <> "        <h2>Runs</h2>\n"
  <> "        <p class=\"muted\">Current repository only.</p>\n"
  <> "        <ul class=\"history-list\" id=\"history\"></ul>\n"
  <> "      </aside>\n"
  <> "      <div class=\"stack\">\n"
  <> "        <section class=\"panel\">\n"
  <> "          <h2>Tasks</h2>\n"
  <> "          <ul class=\"task-list\" id=\"tasks\"></ul>\n"
  <> "        </section>\n"
  <> "        <section class=\"panel\">\n"
  <> "          <h2>Timeline</h2>\n"
  <> "          <ul class=\"event-list\" id=\"events\"></ul>\n"
  <> "        </section>\n"
  <> "        <section class=\"panel\">\n"
  <> "          <h2>Report</h2>\n"
  <> "          <pre id=\"report\">Loading report...</pre>\n"
  <> "        </section>\n"
  <> "      </div>\n"
  <> "    </section>\n"
  <> "  </div>\n"
  <> "  <script>\n"
  <> "    const initialRunId = "
  <> initial_run_json
  <> ";\n"
  <> "    const terminalStates = new Set(['completed', 'blocked', 'failed']);\n"
  <> "    let selectedRunId = initialRunId;\n"
  <> "    let refreshTimer = null;\n"
  <> "    async function requestJson(path) {\n"
  <> "      const response = await fetch(path, { cache: 'no-store' });\n"
  <> "      if (!response.ok) throw new Error('Request failed: ' + response.status);\n"
  <> "      return response.json();\n"
  <> "    }\n"
  <> "    function renderMeta(run) {\n"
  <> "      const fields = [\n"
  <> "        ['Run ID', run.run_id], ['Status', run.status], ['Planning profile', run.planning_agent.profile_name], ['Planning provider', run.planning_agent.provider],\n"
  <> "        ['Planning model', run.planning_agent.model || 'default'], ['Planning reasoning', run.planning_agent.reasoning || 'default'], ['Execution profile', run.execution_agent.profile_name], ['Execution provider', run.execution_agent.provider],\n"
  <> "        ['Execution model', run.execution_agent.model || 'default'], ['Execution reasoning', run.execution_agent.reasoning || 'default'], ['Repo', run.repo_root], ['Created', run.created_at],\n"
  <> "        ['Updated', run.updated_at], ['Brief', run.brief_path], ['Provenance', run.provenance_path], ['Confidence', run.confidence_posture], ['Confidence reasons', (run.confidence_reasons || []).join(' | ') || '—'], ['Max workers', String(run.max_workers)]\n"
  <> "      ];\n"
  <> "      if (run.repo_state) {\n"
  <> "        fields.push(['Open PRs', String(run.repo_state.open_pr_count)]);\n"
  <> "        fields.push(['Actionable PRs', String(run.repo_state.actionable_pr_count)]);\n"
  <> "        fields.push(['Snapshot captured', run.repo_state.snapshot_captured_at]);\n"
  <> "        fields.push(['Drift', run.repo_state.drift]);\n"
  <> "      }\n"
  <> "      document.getElementById('run-meta').innerHTML = fields.map(([label, value]) => `<div class=\"meta-card\"><div class=\"label\">${label}</div><div class=\"value\"></div></div>`).join('');\n"
  <> "      Array.from(document.querySelectorAll('#run-meta .value')).forEach((node, index) => { node.textContent = fields[index][1] || '—'; });\n"
  <> "      document.getElementById('status-line').textContent = `Viewing run ${run.run_id} (${run.status}).`;\n"
  <> "    }\n"
  <> "    function renderHistory(runs) {\n"
  <> "      const container = document.getElementById('history');\n"
  <> "      container.innerHTML = '';\n"
  <> "      runs.forEach((run) => {\n"
  <> "        const item = document.createElement('li');\n"
  <> "        const button = document.createElement('button');\n"
  <> "        button.className = 'run-link' + (run.run_id === selectedRunId ? ' active' : '');\n"
  <> "        button.type = 'button';\n"
  <> "        button.innerHTML = `<strong>${run.run_id}</strong><br><span class=\"muted\">${run.status} · ${run.updated_at}</span>`;\n"
  <> "        button.addEventListener('click', () => { selectedRunId = run.run_id; loadRun(true); });\n"
  <> "        item.appendChild(button);\n"
  <> "        container.appendChild(item);\n"
  <> "      });\n"
  <> "    }\n"
  <> "    function renderTasks(tasks) {\n"
  <> "      const container = document.getElementById('tasks');\n"
  <> "      container.innerHTML = tasks.length === 0 ? '<li class=\"task-row muted\">No tasks have been planned yet.</li>' : '';\n"
  <> "      tasks.forEach((task) => {\n"
  <> "        const item = document.createElement('li');\n"
  <> "        item.className = 'task-row';\n"
  <> "        item.innerHTML = `<div class=\"task-header\"><strong>${task.title}</strong><span class=\"state\">${task.state}</span></div><p class=\"muted\">${task.id}</p><p>${task.summary || task.description || 'No summary yet.'}</p><p class=\"muted\">Branch: ${task.branch_name || '—'} · PR: ${task.pr_number || '—'}</p>`;\n"
  <> "        container.appendChild(item);\n"
  <> "      });\n"
  <> "    }\n"
  <> "    function renderEvents(events) {\n"
  <> "      const container = document.getElementById('events');\n"
  <> "      container.innerHTML = events.length === 0 ? '<li class=\"event-row muted\">No events recorded yet.</li>' : '';\n"
  <> "      events.forEach((event) => {\n"
  <> "        const item = document.createElement('li');\n"
  <> "        item.className = 'event-row';\n"
  <> "        item.innerHTML = `<div class=\"event-header\"><strong>${event.kind}</strong><span class=\"muted\">${event.at}</span></div><p>${event.message}</p><p class=\"muted\">Task: ${event.task_id || 'run-wide'}</p>`;\n"
  <> "        container.appendChild(item);\n"
  <> "      });\n"
  <> "    }\n"
  <> "    function scheduleRefresh(isActive) {\n"
  <> "      if (refreshTimer) clearTimeout(refreshTimer);\n"
  <> "      refreshTimer = setTimeout(() => loadRun(false), isActive ? 2000 : 10000);\n"
  <> "    }\n"
  <> "    async function loadRun(forceHistoryRefresh) {\n"
  <> "      const runs = await requestJson('/api/runs');\n"
  <> "      if (!selectedRunId && runs.length > 0) selectedRunId = runs[0].run_id;\n"
  <> "      if (!selectedRunId) {\n"
  <> "        document.getElementById('status-line').textContent = 'No runs found for this repository.';\n"
  <> "        document.getElementById('history').innerHTML = '';\n"
  <> "        document.getElementById('tasks').innerHTML = '';\n"
  <> "        document.getElementById('events').innerHTML = '';\n"
  <> "        document.getElementById('report').textContent = 'No report available.';\n"
  <> "        scheduleRefresh(false);\n"
  <> "        return;\n"
  <> "      }\n"
  <> "      if (forceHistoryRefresh || !runs.some((run) => run.run_id === selectedRunId)) {\n"
  <> "        selectedRunId = runs[0].run_id;\n"
  <> "      }\n"
  <> "      renderHistory(runs);\n"
  <> "      const payload = await requestJson('/api/runs/' + encodeURIComponent(selectedRunId));\n"
  <> "      renderMeta(payload.run);\n"
  <> "      renderTasks(payload.run.tasks);\n"
  <> "      renderEvents(payload.events);\n"
  <> "      document.getElementById('report').textContent = payload.report;\n"
  <> "      scheduleRefresh(!terminalStates.has(payload.run.status));\n"
  <> "    }\n"
  <> "    loadRun(true).catch((error) => { document.getElementById('status-line').textContent = error.message; scheduleRefresh(false); });\n"
  <> "  </script>\n"
  <> "</body>\n"
  <> "</html>\n"
}

/// Encode the repository's run history as dashboard JSON.
pub fn runs_json(repo_root: String) -> Result(String, String) {
  use runs <- result.try(journal.list_runs(repo_root))
  Ok(
    runs
    |> list.map(run_summary_json)
    |> json.array(identity)
    |> json.to_string,
  )
}

/// Encode one run, its events, and its report as dashboard JSON.
pub fn run_json(repo_root: String, run_id: String) -> Result(String, String) {
  use #(run, events) <- result.try(journal.load(repo_root, types.RunId(run_id)))
  let repo_state_view = load_repo_state_view(run)
  let review_projection =
    review_run_projection.build(run, events, repo_state_view)
  let confidence_assessment = confidence.assess(run, events, repo_state_view)
  let rendered_report = report.render_live(run, events, repo_state_view)
  Ok(
    json.object([
      #("run", run_detail_json(run, review_projection, confidence_assessment)),
      #("events", json.array(events, event_json)),
      #("report", json.string(rendered_report)),
    ])
    |> json.to_string,
  )
}

fn run_summary_json(run: types.RunRecord) -> json.Json {
  json.object([
    #("run_id", json.string(run.run_id)),
    #("status", json.string(types.run_status_to_string(run.status))),
    #("planning_agent", agent_json(run.planning_agent)),
    #("execution_agent", agent_json(run.execution_agent)),
    #("created_at", json.string(run.created_at)),
    #("updated_at", json.string(run.updated_at)),
    #("brief_path", json.string(run.brief_path)),
  ])
}

fn run_detail_json(
  run: types.RunRecord,
  review_projection: Option(review_run_projection.ReviewRunProjection),
  confidence_assessment: types.ConfidenceAssessment,
) -> json.Json {
  json.object([
    #("run_id", json.string(run.run_id)),
    #("repo_root", json.string(run.repo_root)),
    #("run_path", json.string(run.run_path)),
    #("brief_path", json.string(run.brief_path)),
    #("report_path", json.string(run.report_path)),
    #("provenance_path", json.string(provenance.artifact_path(run))),
    #("planning_agent", agent_json(run.planning_agent)),
    #("execution_agent", agent_json(run.execution_agent)),
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
    #("max_workers", json.int(run.max_workers)),
    #("status", json.string(types.run_status_to_string(run.status))),
    #("created_at", json.string(run.created_at)),
    #("updated_at", json.string(run.updated_at)),
    #(
      "repo_state",
      json.nullable(
        from: projection_repo_state(review_projection),
        of: repo_state_json,
      ),
    ),
    #("tasks", json.array(run.tasks, task_json)),
  ])
}

fn task_json(task: types.Task) -> json.Json {
  json.object([
    #("id", json.string(task.id)),
    #("title", json.string(task.title)),
    #("description", json.string(task.description)),
    #("state", json.string(types.task_state_to_string(task.state))),
    #("branch_name", json.string(task.branch_name)),
    #("pr_number", json.string(task.pr_number)),
    #("summary", json.string(task.summary)),
  ])
}

fn load_repo_state_view(
  run: types.RunRecord,
) -> Option(repo_state_runtime.RepoStateView) {
  case config.load(project.config_path(run.repo_root)) {
    Ok(loaded_config) ->
      repo_state_runtime.inspect(run, loaded_config.branch_prefix).view
    Error(_) -> None
  }
}

fn repo_state_json(summary: review_run_projection.RepoStateSummary) -> json.Json {
  json.object([
    #("snapshot_captured_at", json.string(summary.snapshot_captured_at)),
    #(
      "open_pr_count",
      json.int(review_run_projection.current_or_captured_open_count(summary)),
    ),
    #(
      "actionable_pr_count",
      json.int(review_run_projection.current_or_captured_actionable_count(
        summary,
      )),
    ),
    #(
      "drift",
      json.string(case summary.drift {
        Some(drift) -> drift
        None -> "unknown"
      }),
    ),
  ])
}

fn projection_repo_state(
  review_projection: Option(review_run_projection.ReviewRunProjection),
) -> Option(review_run_projection.RepoStateSummary) {
  case review_projection {
    Some(projection) -> Some(projection.repo_state)
    None -> None
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

fn event_json(event: types.RunEvent) -> json.Json {
  json.object([
    #("kind", json.string(event.kind)),
    #("at", json.string(event.at)),
    #("message", json.string(event.message)),
    #("task_id", case event.task_id {
      Some(task_id) -> json.string(task_id)
      None -> json.null()
    }),
  ])
}

fn identity(value: json.Json) -> json.Json {
  value
}
