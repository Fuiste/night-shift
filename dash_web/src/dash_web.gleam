import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect
import lustre/element/html
import lustre/event

@external(javascript, "./browser_ffi.mjs", "fetchWorkspace")
fn fetch_workspace_raw(
  target_run: String,
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./browser_ffi.mjs", "fetchModels")
fn fetch_models_raw(
  provider: String,
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./browser_ffi.mjs", "postJson")
fn post_json_raw(
  path: String,
  payload: String,
  on_success: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./browser_ffi.mjs", "openEventStream")
fn open_event_stream_raw(
  target_run: String,
  on_open: fn(String) -> Nil,
  on_message: fn(String) -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil

@external(javascript, "./browser_ffi.mjs", "initialRunTarget")
fn initial_run_target() -> String

pub fn main() -> Nil {
  let app = lustre.application(init, update, view)
  let _ = lustre.start(app, "#app", Nil)
  Nil
}

type Model {
  Model(
    workspace: Option(Workspace),
    connection: String,
    selected_run: String,
    selected_task: Option(String),
    active_tab: String,
    init_form: InitForm,
    plan_form: PlanForm,
    decision_answers: List(#(String, String)),
    notice: Option(Notice),
    last_stream_target: String,
  )
}

type Notice {
  Notice(kind: String, message: String)
}

type InitForm {
  InitForm(
    provider: String,
    model: String,
    reasoning: String,
    generate_setup: Bool,
    models: List(ProviderModel),
  )
}

type PlanForm {
  PlanForm(notes: String, doc_path: String)
}

type Workspace {
  Workspace(
    repo_root: String,
    initialized: Bool,
    default_profile: String,
    providers: List(String),
    runs: List(RunSummary),
    selected_run_id: Option(String),
    command_state: Option(CommandState),
    run: Option(RunView),
  )
}

type RunSummary {
  RunSummary(
    run_id: String,
    status: String,
    created_at: String,
    updated_at: String,
    task_count: Int,
  )
}

type CommandState {
  CommandState(
    name: String,
    run_id: Option(String),
    started_at: String,
    summary: String,
  )
}

type RunView {
  RunView(
    run_id: String,
    status: String,
    created_at: String,
    updated_at: String,
    next_action: String,
    planning_label: String,
    uses_reviews: Bool,
    notes_label: String,
    confidence_level: String,
    confidence_reasons: List(String),
    tasks: List(TaskView),
    dag_nodes: List(DagNode),
    dag_edges: List(DagEdge),
    decisions: List(PendingDecision),
    repo_state: Option(RepoStateView),
    timeline: List(TimelineEntry),
    report_markdown: String,
    provenance_markdown: String,
    delivery: List(DeliveryView),
    setup_blocker: Option(RecoveryBlocker),
    implementation_blockers: List(TaskView),
    report_url: String,
    provenance_url: String,
  )
}

type DagNode {
  DagNode(
    id: String,
    title: String,
    state: String,
    kind: String,
    branch_name: String,
    pr_number: String,
    pr_url: Option(String),
  )
}

type DagEdge {
  DagEdge(from: String, to: String)
}

type TaskView {
  TaskView(
    id: String,
    title: String,
    description: String,
    summary: String,
    state: String,
    kind: String,
    execution_mode: String,
    dependencies: List(String),
    acceptance: List(String),
    demo_plan: List(String),
    branch_name: String,
    pr_number: String,
    pr_url: Option(String),
    superseded_pr_numbers: List(Int),
    worktree_path: String,
    task_log_url: String,
    verify_log_url: String,
  )
}

type PendingDecision {
  PendingDecision(task_id: String, task_title: String, request: DecisionRequest)
}

type DecisionRequest {
  DecisionRequest(
    key: String,
    question: String,
    rationale: String,
    options: List(DecisionOption),
    recommended_option: Option(String),
    allow_freeform: Bool,
  )
}

type DecisionOption {
  DecisionOption(label: String, description: String)
}

type RepoStateView {
  RepoStateView(
    snapshot_captured_at: String,
    drift: String,
    actionable_pull_requests: List(PullRequestView),
    impacted_pull_requests: List(PullRequestView),
    replacement_lineage: List(LineageView),
  )
}

type PullRequestView {
  PullRequestView(number: Int, title: String, branch_name: String, url: String)
}

type LineageView {
  LineageView(
    task_id: String,
    superseded_pr_numbers: List(Int),
    replacement_pr_number: Option(String),
  )
}

type TimelineEntry {
  TimelineEntry(
    kind: String,
    at: String,
    message: String,
    task_id: Option(String),
  )
}

type DeliveryView {
  DeliveryView(
    task_id: String,
    task_title: String,
    pr_number: String,
    pr_url: String,
  )
}

type RecoveryBlocker {
  RecoveryBlocker(
    kind: String,
    phase: String,
    task_id: Option(String),
    message: String,
    log_path: String,
    disposition: String,
  )
}

type ProviderModel {
  ProviderModel(id: String, label: String, is_default: Bool)
}

type ActionResponse {
  ActionResponse(summary: String, next_action: String, run_id: Option(String))
}

type Msg {
  WorkspaceLoaded(String)
  WorkspaceLoadFailed(String)
  StreamOpened
  StreamMessage(String)
  StreamErrored
  SelectRun(String)
  SelectTask(String)
  SelectTab(String)
  UpdateInitProvider(String)
  UpdateInitModel(String)
  UpdateInitReasoning(String)
  ToggleGenerateSetup(Bool)
  ModelsLoaded(String)
  ModelsLoadFailed(String)
  SubmitInit
  UpdateNotes(String)
  UpdateDocPath(String)
  SubmitPlan
  SubmitPlanFromReviews
  StartRun
  ResumeRun
  UpdateDecisionAnswer(String, String)
  SubmitDecisions
  RecoveryAction(String, Option(String))
  ActionSucceeded(String)
  ActionFailed(String)
}

fn init(_) -> #(Model, effect.Effect(Msg)) {
  let target_run = initial_run_target()
  let init_form =
    InitForm(
      provider: "codex",
      model: "",
      reasoning: "",
      generate_setup: False,
      models: [],
    )
  #(
    Model(
      workspace: None,
      connection: "connecting",
      selected_run: target_run,
      selected_task: None,
      active_tab: "graph",
      init_form: init_form,
      plan_form: PlanForm(notes: "", doc_path: ""),
      decision_answers: [],
      notice: None,
      last_stream_target: "",
    ),
    effect.batch([
      fetch_workspace_effect(target_run),
      open_stream_effect(target_run),
      fetch_models_effect("codex"),
    ]),
  )
}

fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    WorkspaceLoaded(payload) ->
      case decode_workspace(payload) {
        Ok(workspace) -> {
          let selected_task =
            resolve_selected_task(model.selected_task, workspace)
          let next_stream_target =
            selected_run_target(workspace.selected_run_id)
          let tab = suggest_tab(model.active_tab, workspace)
          let next_model =
            Model(
              ..model,
              workspace: Some(workspace),
              selected_run: next_stream_target,
              selected_task: selected_task,
              active_tab: tab,
              connection: "connected",
            )
          let stream_effect = case
            next_stream_target != model.last_stream_target
          {
            True -> open_stream_effect(next_stream_target)
            False -> effect.none()
          }
          #(
            Model(..next_model, last_stream_target: next_stream_target),
            stream_effect,
          )
        }
        Error(message) -> #(
          Model(..model, notice: Some(Notice("error", message))),
          effect.none(),
        )
      }
    WorkspaceLoadFailed(message) -> #(
      Model(
        ..model,
        connection: "disconnected",
        notice: Some(Notice("error", message)),
      ),
      effect.none(),
    )
    StreamOpened -> #(Model(..model, connection: "connected"), effect.none())
    StreamMessage(_) -> #(model, fetch_workspace_effect(model.selected_run))
    StreamErrored -> #(
      Model(..model, connection: "disconnected"),
      effect.none(),
    )
    SelectRun(run_id) -> #(
      Model(
        ..model,
        selected_run: run_id,
        selected_task: None,
        active_tab: "graph",
      ),
      effect.batch([fetch_workspace_effect(run_id), open_stream_effect(run_id)]),
    )
    SelectTask(task_id) -> #(
      Model(..model, selected_task: Some(task_id)),
      effect.none(),
    )
    SelectTab(tab) -> #(
      Model(..model, active_tab: tab),
      effect.none(),
    )
    UpdateInitProvider(provider) -> #(
      Model(
        ..model,
        init_form: InitForm(
          ..model.init_form,
          provider: provider,
          model: "",
          models: [],
        ),
      ),
      fetch_models_effect(provider),
    )
    UpdateInitModel(value) -> #(
      Model(..model, init_form: InitForm(..model.init_form, model: value)),
      effect.none(),
    )
    UpdateInitReasoning(value) -> #(
      Model(..model, init_form: InitForm(..model.init_form, reasoning: value)),
      effect.none(),
    )
    ToggleGenerateSetup(value) -> #(
      Model(
        ..model,
        init_form: InitForm(..model.init_form, generate_setup: value),
      ),
      effect.none(),
    )
    ModelsLoaded(payload) ->
      case decode_models(payload) {
        Ok(models) -> {
          let selected = default_model_id(models, model.init_form.model)
          #(
            Model(
              ..model,
              init_form: InitForm(
                ..model.init_form,
                models: models,
                model: selected,
              ),
            ),
            effect.none(),
          )
        }
        Error(message) -> #(
          Model(..model, notice: Some(Notice("error", message))),
          effect.none(),
        )
      }
    ModelsLoadFailed(message) -> #(
      Model(..model, notice: Some(Notice("error", message))),
      effect.none(),
    )
    SubmitInit -> #(
      model,
      post_effect("/api/init", init_payload(model.init_form)),
    )
    UpdateNotes(value) -> #(
      Model(..model, plan_form: PlanForm(..model.plan_form, notes: value)),
      effect.none(),
    )
    UpdateDocPath(value) -> #(
      Model(..model, plan_form: PlanForm(..model.plan_form, doc_path: value)),
      effect.none(),
    )
    SubmitPlan -> #(
      model,
      post_effect("/api/plans", plan_payload(model.plan_form)),
    )
    SubmitPlanFromReviews -> #(
      model,
      post_effect("/api/plans/from-reviews", plan_payload(model.plan_form)),
    )
    StartRun ->
      case selected_run(model.workspace) {
        Some(run) -> #(
          model,
          post_effect("/api/runs/" <> run.run_id <> "/start", "{}"),
        )
        None -> #(model, effect.none())
      }
    ResumeRun ->
      case selected_run(model.workspace) {
        Some(run) -> #(
          model,
          post_effect("/api/runs/" <> run.run_id <> "/resume", "{}"),
        )
        None -> #(model, effect.none())
      }
    UpdateDecisionAnswer(key, value) -> #(
      Model(
        ..model,
        decision_answers: put_answer(model.decision_answers, key, value),
      ),
      effect.none(),
    )
    SubmitDecisions ->
      case selected_run(model.workspace) {
        Some(run) -> #(
          model,
          post_effect(
            "/api/runs/" <> run.run_id <> "/resolve/decisions",
            decisions_payload(model.decision_answers, run.decisions),
          ),
        )
        None -> #(model, effect.none())
      }
    RecoveryAction(action, task_id) ->
      case selected_run(model.workspace) {
        Some(run) -> #(
          model,
          post_effect(
            "/api/runs/" <> run.run_id <> "/recovery/" <> action,
            recovery_payload(task_id),
          ),
        )
        None -> #(model, effect.none())
      }
    ActionSucceeded(payload) ->
      case decode_action_response(payload) {
        Ok(response) -> #(
          Model(
            ..model,
            notice: Some(Notice(
              "success",
              response.summary <> " Next: " <> response.next_action,
            )),
          ),
          fetch_workspace_effect(model.selected_run),
        )
        Error(message) -> #(
          Model(..model, notice: Some(Notice("error", message))),
          effect.none(),
        )
      }
    ActionFailed(message) -> #(
      Model(..model, notice: Some(Notice("error", message))),
      effect.none(),
    )
  }
}

fn view(model: Model) {
  html.main([attribute.class("dash-shell")], [
    header_view(model),
    body_view(model),
  ])
}

fn header_view(model: Model) {
  html.header([attribute.class("hero")], [
    html.div([attribute.class("hero-copy")], [
      html.h1([], [html.text("Night Shift Dash")]),
      html.p([attribute.class("muted")], [
        html.text(
          "Browser-native planning, execution, recovery, and audit for the current repository.",
        ),
      ]),
    ]),
    html.div([attribute.class("hero-meta")], [
      meta_card("Connection", model.connection),
      meta_card("Selected run", model.selected_run),
      meta_card("Command", case active_command(model.workspace) {
        Some(command) -> command.name <> " @ " <> command.started_at
        None -> "idle"
      }),
    ]),
  ])
}

fn body_view(model: Model) {
  html.div([attribute.class("workspace")], [
    sidebar_view(model),
    main_panel_view(model),
  ])
}

fn sidebar_view(model: Model) {
  html.aside([attribute.class("sidebar panel")], [
    html.h2([], [html.text("Runs")]),
    html.ul([attribute.class("history-list")], case model.workspace {
      Some(workspace) ->
        case workspace.runs {
          [] -> [html.li([], [html.text("No runs yet.")])]
          runs -> runs |> list.map(run_button(_, model.selected_run))
        }
      None -> [html.li([], [html.text("Loading workspace...")])]
    }),
  ])
}

fn run_button(run: RunSummary, selected_run: String) {
  html.li([], [
    html.button(
      [
        attribute.class(
          "run-link"
          <> case run.run_id == selected_run {
            True -> " active"
            False -> ""
          },
        ),
        event.on_click(SelectRun(run.run_id)),
      ],
      [
        html.strong([], [html.text(run.run_id)]),
        html.p([attribute.class("muted")], [
          html.text(
            run.status
            <> " · "
            <> run.updated_at
            <> " · "
            <> int_to_string(run.task_count)
            <> " tasks",
          ),
        ]),
      ],
    ),
  ])
}

fn main_panel_view(model: Model) {
  html.section([attribute.class("main-stack")], [
    notice_view(model.notice),
    repo_panel(model),
    actions_panel(model),
    case model.workspace {
      Some(workspace) ->
        case workspace.run {
          Some(run) ->
            html.div([attribute.class("panel-grid")], [
              dag_panel(run, model.selected_task),
              task_panel(run, model.selected_task),
              decision_panel(run, model.decision_answers),
              recovery_panel(run),
              repo_state_panel(run),
              delivery_panel(run),
              timeline_panel(run),
              markdown_panel("Report", run.report_markdown, run.report_url),
              markdown_panel(
                "Provenance",
                run.provenance_markdown,
                run.provenance_url,
              ),
            ])
          None ->
            html.section([attribute.class("panel")], [
              html.text("No run selected yet."),
            ])
        }
      None ->
        html.section([attribute.class("panel")], [
          html.text("Loading workspace..."),
        ])
    },
  ])
}

fn repo_panel(model: Model) {
  case model.workspace {
    Some(workspace) ->
      html.section([attribute.class("panel")], [
        html.h2([], [html.text("Workspace")]),
        html.p([], [html.text(workspace.repo_root)]),
        html.p([attribute.class("muted")], [
          html.text(case workspace.initialized {
            True ->
              "Initialized. Default profile: " <> workspace.default_profile
            False ->
              "Not initialized yet. Configure provider, model, and setup here."
          }),
        ]),
        case workspace.initialized {
          True -> plan_form_view(model)
          False -> init_form_view(model, workspace.providers)
        },
      ])
    None ->
      html.section([attribute.class("panel")], [
        html.text("Loading workspace..."),
      ])
  }
}

fn init_form_view(model: Model, providers: List(String)) {
  html.div([attribute.class("form-stack")], [
    select_field(
      "Provider",
      providers,
      model.init_form.provider,
      UpdateInitProvider,
    ),
    select_models_field(model.init_form.models, model.init_form.model),
    text_field(
      "Reasoning",
      "low | medium | high | xhigh",
      model.init_form.reasoning,
      UpdateInitReasoning,
    ),
    checkbox_field(
      "Generate setup from provider",
      model.init_form.generate_setup,
    ),
    html.button([attribute.class("primary"), event.on_click(SubmitInit)], [
      html.text("Initialize"),
    ]),
  ])
}

fn plan_form_view(model: Model) {
  html.div([attribute.class("form-stack")], [
    html.textarea(
      [
        attribute.class("notes-input"),
        attribute.placeholder("Paste planning notes or a short operator brief"),
        attribute.value(model.plan_form.notes),
        event.on_input(UpdateNotes),
      ],
      model.plan_form.notes,
    ),
    text_field(
      "Optional doc path",
      "./notes.md",
      model.plan_form.doc_path,
      UpdateDocPath,
    ),
    html.div([attribute.class("button-row")], [
      html.button([attribute.class("primary"), event.on_click(SubmitPlan)], [
        html.text("Plan"),
      ]),
      html.button([event.on_click(SubmitPlanFromReviews)], [
        html.text("Plan From Reviews"),
      ]),
      html.button([event.on_click(StartRun)], [html.text("Start")]),
      html.button([event.on_click(ResumeRun)], [html.text("Resume")]),
    ]),
  ])
}

fn actions_panel(model: Model) {
  case selected_run(model.workspace) {
    Some(run) ->
      html.section([attribute.class("panel action-summary")], [
        html.h2([], [html.text("Run Summary")]),
        html.p([], [html.text(run.run_id <> " · " <> run.status)]),
        html.p([attribute.class("muted")], [
          html.text("Next action: " <> run.next_action),
        ]),
        html.div([attribute.class("hero-meta")], [
          meta_card("Planning input", run.planning_label),
          meta_card("Confidence", run.confidence_level),
          meta_card("Updated", run.updated_at),
        ]),
      ])
    None -> html.section([], [])
  }
}

fn dag_panel(run: RunView, selected_task_id: Option(String)) {
  html.section([attribute.class("panel")], [
    html.h2([], [html.text("DAG")]),
    html.div(
      [attribute.class("dag-graph")],
      run.dag_nodes
        |> list.map(fn(node) {
          let layer = node_layer(node.id, run.tasks)
          html.button(
            [
              attribute.class(
                "dag-node"
                <> case selected_task_id == Some(node.id) {
                  True -> " active"
                  False -> ""
                },
              ),
              attribute.style("grid-column", layer),
              event.on_click(SelectTask(node.id)),
            ],
            [
              html.strong([], [html.text(node.title)]),
              html.span([attribute.class("muted")], [html.text(node.state)]),
            ],
          )
        }),
    ),
  ])
}

fn task_panel(run: RunView, selected_task_id: Option(String)) {
  html.section([attribute.class("panel")], [
    html.h2([], [html.text("Task Detail")]),
    case selected_task(run.tasks, selected_task_id) {
      Some(task) ->
        html.div([attribute.class("task-detail")], [
          html.h3([], [html.text(task.title)]),
          html.p([attribute.class("muted")], [
            html.text(task.id <> " · " <> task.state <> " · " <> task.kind),
          ]),
          html.p([], [html.text(non_empty(task.summary, task.description))]),
          link_line("Task log", task.task_log_url),
          link_line("Verify log", task.verify_log_url),
          text_line("Worktree", task.worktree_path),
          text_line("Branch", task.branch_name),
          maybe_link_line("PR", task.pr_url, task.pr_number),
          text_line("Supersedes", render_pr_numbers(task.superseded_pr_numbers)),
        ])
      None -> html.p([], [html.text("Select a task to inspect its details.")])
    },
  ])
}

fn decision_panel(run: RunView, answers: List(#(String, String))) {
  html.section([attribute.class("panel")], [
    html.h2([], [html.text("Resolve Decisions")]),
    case run.decisions {
      [] ->
        html.p([attribute.class("muted")], [
          html.text("No unresolved planning decisions."),
        ])
      decisions ->
        html.div(
          [attribute.class("form-stack")],
          list.append(
            decisions
              |> list.map(fn(item) { decision_request_view(item, answers) }),
            [
              html.button(
                [attribute.class("primary"), event.on_click(SubmitDecisions)],
                [html.text("Submit Decisions")],
              ),
            ],
          ),
        )
    },
  ])
}

fn recovery_panel(run: RunView) {
  html.section([attribute.class("panel")], [
    html.h2([], [html.text("Recovery")]),
    case run.setup_blocker {
      Some(blocker) ->
        html.div([attribute.class("form-stack")], [
          html.p([], [
            html.text(
              "Blocked during " <> blocker.phase <> " " <> blocker.kind <> ".",
            ),
          ]),
          html.p([attribute.class("muted")], [html.text(blocker.message)]),
          text_line("Log", blocker.log_path),
          html.div([attribute.class("button-row")], [
            html.button([event.on_click(RecoveryAction("inspect", None))], [
              html.text("Inspect"),
            ]),
            html.button(
              [
                attribute.class("primary"),
                event.on_click(RecoveryAction("continue", None)),
              ],
              [html.text("Continue")],
            ),
            html.button([event.on_click(RecoveryAction("abandon", None))], [
              html.text("Abandon"),
            ]),
          ]),
        ])
      None ->
        case run.implementation_blockers {
          [] ->
            html.p([attribute.class("muted")], [
              html.text("No recovery blockers are active."),
            ])
          [task, ..] ->
            html.div([attribute.class("form-stack")], [
              html.p([], [
                html.text(
                  "Interrupted implementation work is waiting on operator input.",
                ),
              ]),
              html.p([attribute.class("muted")], [
                html.text(task.title <> " · " <> task.worktree_path),
              ]),
              html.div([attribute.class("button-row")], [
                html.button(
                  [event.on_click(RecoveryAction("inspect", Some(task.id)))],
                  [html.text("Inspect")],
                ),
                html.button(
                  [
                    attribute.class("primary"),
                    event.on_click(RecoveryAction("continue", Some(task.id))),
                  ],
                  [html.text("Continue")],
                ),
                html.button(
                  [event.on_click(RecoveryAction("complete", Some(task.id)))],
                  [html.text("Complete")],
                ),
                html.button(
                  [event.on_click(RecoveryAction("abandon", Some(task.id)))],
                  [html.text("Abandon")],
                ),
              ]),
            ])
        }
    },
  ])
}

fn repo_state_panel(run: RunView) {
  html.section([attribute.class("panel")], [
    html.h2([], [html.text("Repo State")]),
    case run.repo_state {
      Some(repo_state) ->
        html.div([attribute.class("form-stack")], [
          text_line("Snapshot", repo_state.snapshot_captured_at),
          text_line("Drift", repo_state.drift),
          html.h3([], [html.text("Actionable PRs")]),
          pr_list(repo_state.actionable_pull_requests),
          html.h3([], [html.text("Impacted PRs")]),
          pr_list(repo_state.impacted_pull_requests),
          html.h3([], [html.text("Replacement lineage")]),
          html.ul([], repo_state.replacement_lineage |> list.map(lineage_item)),
        ])
      None ->
        html.p([attribute.class("muted")], [
          html.text("This run was not planned from review context."),
        ])
    },
  ])
}

fn delivery_panel(run: RunView) {
  html.section([attribute.class("panel")], [
    html.h2([], [html.text("Delivery")]),
    case run.delivery {
      [] ->
        html.p([attribute.class("muted")], [html.text("No delivered PRs yet.")])
      rows ->
        html.ul(
          [],
          rows
            |> list.map(fn(row) {
              html.li([], [
                html.a(
                  [
                    attribute.href(row.pr_url),
                    attribute.target("_blank"),
                    attribute.rel("noreferrer"),
                  ],
                  [html.text(row.task_title <> " · PR #" <> row.pr_number)],
                ),
              ])
            }),
        )
    },
  ])
}

fn timeline_panel(run: RunView) {
  html.section([attribute.class("panel")], [
    html.h2([], [html.text("Timeline")]),
    html.ul(
      [attribute.class("timeline")],
      run.timeline
        |> list.map(fn(entry) {
          html.li([], [
            html.strong([], [html.text(entry.kind)]),
            html.p([attribute.class("muted")], [html.text(entry.at)]),
            html.p([], [html.text(entry.message)]),
          ])
        }),
    ),
  ])
}

fn markdown_panel(title: String, markdown: String, url: String) {
  html.section([attribute.class("panel")], [
    html.div([attribute.class("panel-head")], [
      html.h2([], [html.text(title)]),
      html.a(
        [
          attribute.href(url),
          attribute.target("_blank"),
          attribute.rel("noreferrer"),
        ],
        [html.text("Open artifact")],
      ),
    ]),
    html.pre([attribute.class("markdown")], [html.text(markdown)]),
  ])
}

fn notice_view(notice: Option(Notice)) {
  case notice {
    Some(notice) ->
      html.section([attribute.class("notice " <> notice.kind)], [
        html.text(notice.message),
      ])
    None -> html.section([], [])
  }
}

fn decision_request_view(
  item: PendingDecision,
  answers: List(#(String, String)),
) {
  html.div([attribute.class("decision-block")], [
    html.h3([], [html.text(item.task_title)]),
    html.p([], [html.text(item.request.question)]),
    html.p([attribute.class("muted")], [html.text(item.request.rationale)]),
    html.textarea(
      [
        attribute.placeholder("Answer"),
        attribute.value(answer_for(answers, item.request.key)),
        event.on_input(fn(value) {
          UpdateDecisionAnswer(item.request.key, value)
        }),
      ],
      answer_for(answers, item.request.key),
    ),
    html.ul([], item.request.options |> list.map(decision_option_view)),
  ])
}

fn decision_option_view(option: DecisionOption) {
  html.li([], [html.text(option.label <> ": " <> option.description)])
}

fn pr_list(rows: List(PullRequestView)) {
  case rows {
    [] -> html.p([attribute.class("muted")], [html.text("None.")])
    _ ->
      html.ul(
        [],
        rows
          |> list.map(fn(pr) {
            html.li([], [
              html.a(
                [
                  attribute.href(pr.url),
                  attribute.target("_blank"),
                  attribute.rel("noreferrer"),
                ],
                [html.text("#" <> int_to_string(pr.number) <> " " <> pr.title)],
              ),
            ])
          }),
      )
  }
}

fn lineage_item(item: LineageView) {
  html.li([], [
    html.text(
      item.task_id
      <> " supersedes "
      <> render_pr_numbers(item.superseded_pr_numbers)
      <> case item.replacement_pr_number {
        Some(pr_number) -> " -> #" <> pr_number
        None -> ""
      },
    ),
  ])
}

fn text_field(
  label: String,
  placeholder: String,
  value: String,
  to_msg: fn(String) -> Msg,
) {
  html.label([attribute.class("field")], [
    html.span([], [html.text(label)]),
    html.input([
      attribute.type_("text"),
      attribute.placeholder(placeholder),
      attribute.value(value),
      event.on_input(to_msg),
    ]),
  ])
}

fn select_field(
  label: String,
  options: List(String),
  selected: String,
  to_msg: fn(String) -> Msg,
) {
  html.label([attribute.class("field")], [
    html.span([], [html.text(label)]),
    html.select(
      [event.on_change(to_msg)],
      options
        |> list.map(fn(option) {
          html.option(
            [attribute.value(option), attribute.selected(option == selected)],
            option,
          )
        }),
    ),
  ])
}

fn select_models_field(models: List(ProviderModel), selected: String) {
  html.label([attribute.class("field")], [
    html.span([], [html.text("Model")]),
    html.select([event.on_change(UpdateInitModel)], case models {
      [] -> [html.option([attribute.value("")], "Discovering models...")]
      _ ->
        models
        |> list.map(fn(model) {
          html.option(
            [
              attribute.value(model.id),
              attribute.selected(model.id == selected),
            ],
            model.label,
          )
        })
    }),
  ])
}

fn checkbox_field(label: String, value: Bool) {
  html.label([attribute.class("checkbox")], [
    html.input([
      attribute.type_("checkbox"),
      attribute.checked(value),
      event.on_check(ToggleGenerateSetup),
    ]),
    html.span([], [html.text(label)]),
  ])
}

fn meta_card(label: String, value: String) {
  html.div([attribute.class("meta-card")], [
    html.span([attribute.class("muted")], [html.text(label)]),
    html.strong([], [html.text(value)]),
  ])
}

fn text_line(label: String, value: String) {
  html.p([], [
    html.strong([], [html.text(label <> ": ")]),
    html.text(non_empty(value, "—")),
  ])
}

fn link_line(label: String, url: String) {
  html.p([], [
    html.strong([], [html.text(label <> ": ")]),
    html.a(
      [
        attribute.href(url),
        attribute.target("_blank"),
        attribute.rel("noreferrer"),
      ],
      [html.text(url)],
    ),
  ])
}

fn maybe_link_line(label: String, url: Option(String), fallback: String) {
  case url {
    Some(link) ->
      html.p([], [
        html.strong([], [html.text(label <> ": ")]),
        html.a(
          [
            attribute.href(link),
            attribute.target("_blank"),
            attribute.rel("noreferrer"),
          ],
          [html.text(non_empty(fallback, link))],
        ),
      ])
    None -> text_line(label, fallback)
  }
}

fn selected_run(workspace: Option(Workspace)) -> Option(RunView) {
  case workspace {
    Some(workspace) -> workspace.run
    None -> None
  }
}

fn active_command(workspace: Option(Workspace)) -> Option(CommandState) {
  case workspace {
    Some(workspace) -> workspace.command_state
    None -> None
  }
}

fn selected_task(
  tasks: List(TaskView),
  selected_task_id: Option(String),
) -> Option(TaskView) {
  case selected_task_id {
    Some(task_id) -> find_task(tasks, task_id)
    None ->
      case tasks {
        [task, ..] -> Some(task)
        [] -> None
      }
  }
}

fn find_task(tasks: List(TaskView), task_id: String) -> Option(TaskView) {
  case tasks {
    [] -> None
    [task, ..rest] ->
      case task.id == task_id {
        True -> Some(task)
        False -> find_task(rest, task_id)
      }
  }
}

fn resolve_selected_task(
  current: Option(String),
  workspace: Workspace,
) -> Option(String) {
  case workspace.run {
    Some(run) ->
      case current {
        Some(task_id) ->
          case find_task(run.tasks, task_id) {
            Some(_) -> Some(task_id)
            None -> first_task_id(run.tasks)
          }
        None -> first_task_id(run.tasks)
      }
    None -> None
  }
}

fn first_task_id(tasks: List(TaskView)) -> Option(String) {
  case tasks {
    [task, ..] -> Some(task.id)
    [] -> None
  }
}

fn fetch_workspace_effect(target_run: String) -> effect.Effect(Msg) {
  effect.from(fn(dispatch) {
    fetch_workspace_raw(
      target_run,
      fn(payload) { dispatch(WorkspaceLoaded(payload)) },
      fn(message) { dispatch(WorkspaceLoadFailed(message)) },
    )
  })
}

fn fetch_models_effect(provider: String) -> effect.Effect(Msg) {
  effect.from(fn(dispatch) {
    fetch_models_raw(
      provider,
      fn(payload) { dispatch(ModelsLoaded(payload)) },
      fn(message) { dispatch(ModelsLoadFailed(message)) },
    )
  })
}

fn open_stream_effect(target_run: String) -> effect.Effect(Msg) {
  effect.from(fn(dispatch) {
    open_event_stream_raw(
      target_run,
      fn(_) { dispatch(StreamOpened) },
      fn(payload) { dispatch(StreamMessage(payload)) },
      fn(_) { dispatch(StreamErrored) },
    )
  })
}

fn post_effect(path: String, payload: String) -> effect.Effect(Msg) {
  effect.from(fn(dispatch) {
    post_json_raw(
      path,
      payload,
      fn(response) { dispatch(ActionSucceeded(response)) },
      fn(message) { dispatch(ActionFailed(message)) },
    )
  })
}

fn selected_run_target(selected_run_id: Option(String)) -> String {
  case selected_run_id {
    Some(run_id) -> run_id
    None -> "latest"
  }
}

fn init_payload(form: InitForm) -> String {
  json.object([
    #("provider", json.string(form.provider)),
    #("model", json.string(form.model)),
    #("reasoning", nullable_string(form.reasoning)),
    #("generate_setup", json.bool(form.generate_setup)),
  ])
  |> json.to_string
}

fn plan_payload(form: PlanForm) -> String {
  json.object([
    #("notes", nullable_string(form.notes)),
    #("doc_path", nullable_string(form.doc_path)),
  ])
  |> json.to_string
}

fn decisions_payload(
  answers: List(#(String, String)),
  decisions: List(PendingDecision),
) -> String {
  json.object([
    #(
      "answers",
      json.array(decisions, fn(item) {
        json.object([
          #("key", json.string(item.request.key)),
          #("question", json.string(item.request.question)),
          #("answer", json.string(answer_for(answers, item.request.key))),
        ])
      }),
    ),
  ])
  |> json.to_string
}

fn recovery_payload(task_id: Option(String)) -> String {
  json.object([
    #("task_id", json.nullable(from: task_id, of: json.string)),
  ])
  |> json.to_string
}

fn nullable_string(value: String) -> json.Json {
  case string.trim(value) {
    "" -> json.null()
    trimmed -> json.string(trimmed)
  }
}

fn put_answer(
  answers: List(#(String, String)),
  key: String,
  value: String,
) -> List(#(String, String)) {
  case answers {
    [] -> [#(key, value)]
    [entry, ..rest] ->
      case entry.0 == key {
        True -> [#(key, value), ..rest]
        False -> [entry, ..put_answer(rest, key, value)]
      }
  }
}

fn answer_for(answers: List(#(String, String)), key: String) -> String {
  case answers {
    [] -> ""
    [entry, ..rest] ->
      case entry.0 == key {
        True -> entry.1
        False -> answer_for(rest, key)
      }
  }
}

fn decode_workspace(payload: String) -> Result(Workspace, String) {
  json.parse(payload, workspace_decoder())
  |> result.map_error(fn(_) { "Unable to decode workspace payload." })
}

fn decode_models(payload: String) -> Result(List(ProviderModel), String) {
  json.parse(payload, {
    use _provider <- decode.field("provider", decode.string)
    use models <- decode.field("models", decode.list(provider_model_decoder()))
    decode.success(models)
  })
  |> result.map_error(fn(_) { "Unable to decode model list." })
}

fn decode_action_response(payload: String) -> Result(ActionResponse, String) {
  json.parse(payload, action_response_decoder())
  |> result.map_error(fn(_) { "Unable to decode action response." })
}

fn workspace_decoder() -> decode.Decoder(Workspace) {
  use repo_root <- decode.field("repo_root", decode.string)
  use initialized <- decode.field("initialized", decode.bool)
  use default_profile <- decode.field("default_profile", decode.string)
  use providers <- decode.field("providers", decode.list(decode.string))
  use selected_run_id <- decode.optional_field(
    "selected_run_id",
    None,
    decode.optional(decode.string),
  )
  use runs <- decode.field("runs", decode.list(run_summary_decoder()))
  use command_state <- decode.optional_field(
    "command_state",
    None,
    decode.optional(command_state_decoder()),
  )
  use run <- decode.optional_field("run", None, decode.optional(run_decoder()))
  decode.success(Workspace(
    repo_root: repo_root,
    initialized: initialized,
    default_profile: default_profile,
    providers: providers,
    runs: runs,
    selected_run_id: selected_run_id,
    command_state: command_state,
    run: run,
  ))
}

fn run_summary_decoder() -> decode.Decoder(RunSummary) {
  use run_id <- decode.field("run_id", decode.string)
  use status <- decode.field("status", decode.string)
  use created_at <- decode.field("created_at", decode.string)
  use updated_at <- decode.field("updated_at", decode.string)
  use task_count <- decode.field("task_count", decode.int)
  decode.success(RunSummary(
    run_id: run_id,
    status: status,
    created_at: created_at,
    updated_at: updated_at,
    task_count: task_count,
  ))
}

fn command_state_decoder() -> decode.Decoder(CommandState) {
  use name <- decode.field("name", decode.string)
  use run_id <- decode.optional_field(
    "run_id",
    None,
    decode.optional(decode.string),
  )
  use started_at <- decode.field("started_at", decode.string)
  use summary <- decode.field("summary", decode.string)
  decode.success(CommandState(
    name: name,
    run_id: run_id,
    started_at: started_at,
    summary: summary,
  ))
}

fn run_decoder() -> decode.Decoder(RunView) {
  use run_id <- decode.field("run_id", decode.string)
  use status <- decode.field("status", decode.string)
  use created_at <- decode.field("created_at", decode.string)
  use updated_at <- decode.field("updated_at", decode.string)
  use next_action <- decode.field("next_action", decode.string)
  use planning_provenance <- decode.field(
    "planning_provenance",
    planning_projection_decoder(),
  )
  use notes_source <- decode.optional_field(
    "notes_source",
    None,
    decode.optional(notes_source_decoder()),
  )
  use confidence <- decode.field("confidence", confidence_decoder())
  use dag <- decode.field("dag", dag_decoder())
  use tasks <- decode.field("tasks", decode.list(task_decoder()))
  use decisions <- decode.field(
    "decisions",
    decode.list(pending_decision_decoder()),
  )
  use repo_state <- decode.optional_field(
    "repo_state",
    None,
    decode.optional(repo_state_decoder()),
  )
  use timeline <- decode.field(
    "timeline",
    decode.list(timeline_entry_decoder()),
  )
  use report_markdown <- decode.field("report_markdown", decode.string)
  use provenance_markdown <- decode.field("provenance_markdown", decode.string)
  use delivery <- decode.field("delivery", decode.list(delivery_decoder()))
  use recovery <- decode.field("recovery", recovery_decoder())
  use artifacts <- decode.field("artifacts", artifacts_decoder())
  decode.success(RunView(
    run_id: run_id,
    status: status,
    created_at: created_at,
    updated_at: updated_at,
    next_action: next_action,
    planning_label: planning_provenance.0,
    uses_reviews: planning_provenance.1,
    notes_label: case notes_source {
      Some(label) -> label
      None -> "—"
    },
    confidence_level: confidence.0,
    confidence_reasons: confidence.1,
    tasks: tasks,
    dag_nodes: dag.0,
    dag_edges: dag.1,
    decisions: decisions,
    repo_state: repo_state,
    timeline: timeline,
    report_markdown: report_markdown,
    provenance_markdown: provenance_markdown,
    delivery: delivery,
    setup_blocker: recovery.0,
    implementation_blockers: recovery.1,
    report_url: artifacts.0,
    provenance_url: artifacts.1,
  ))
}

fn planning_projection_decoder() -> decode.Decoder(#(String, Bool)) {
  use label <- decode.field("label", decode.string)
  use uses_reviews <- decode.field("uses_reviews", decode.bool)
  decode.success(#(label, uses_reviews))
}

fn notes_source_decoder() -> decode.Decoder(String) {
  use label <- decode.field("label", decode.string)
  decode.success(label)
}

fn confidence_decoder() -> decode.Decoder(#(String, List(String))) {
  use level <- decode.field("level", decode.string)
  use reasons <- decode.field("reasons", decode.list(decode.string))
  decode.success(#(level, reasons))
}

fn dag_decoder() -> decode.Decoder(#(List(DagNode), List(DagEdge))) {
  use nodes <- decode.field("nodes", decode.list(dag_node_decoder()))
  use edges <- decode.field("edges", decode.list(dag_edge_decoder()))
  decode.success(#(nodes, edges))
}

fn dag_node_decoder() -> decode.Decoder(DagNode) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use state <- decode.field("state", decode.string)
  use kind <- decode.field("kind", decode.string)
  use branch_name <- decode.field("branch_name", decode.string)
  use pr_number <- decode.field("pr_number", decode.string)
  use pr_url <- decode.optional_field(
    "pr_url",
    None,
    decode.optional(decode.string),
  )
  decode.success(DagNode(
    id: id,
    title: title,
    state: state,
    kind: kind,
    branch_name: branch_name,
    pr_number: pr_number,
    pr_url: pr_url,
  ))
}

fn dag_edge_decoder() -> decode.Decoder(DagEdge) {
  use from <- decode.field("from", decode.string)
  use to <- decode.field("to", decode.string)
  decode.success(DagEdge(from: from, to: to))
}

fn task_decoder() -> decode.Decoder(TaskView) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use description <- decode.field("description", decode.string)
  use summary <- decode.field("summary", decode.string)
  use state <- decode.field("state", decode.string)
  use kind <- decode.field("kind", decode.string)
  use execution_mode <- decode.field("execution_mode", decode.string)
  use dependencies <- decode.field("dependencies", decode.list(decode.string))
  use acceptance <- decode.field("acceptance", decode.list(decode.string))
  use demo_plan <- decode.field("demo_plan", decode.list(decode.string))
  use branch_name <- decode.field("branch_name", decode.string)
  use pr_number <- decode.field("pr_number", decode.string)
  use pr_url <- decode.optional_field(
    "pr_url",
    None,
    decode.optional(decode.string),
  )
  use superseded_pr_numbers <- decode.field(
    "superseded_pr_numbers",
    decode.list(decode.int),
  )
  use worktree_path <- decode.field("worktree_path", decode.string)
  use artifacts <- decode.field("artifacts", task_artifacts_decoder())
  decode.success(TaskView(
    id: id,
    title: title,
    description: description,
    summary: summary,
    state: state,
    kind: kind,
    execution_mode: execution_mode,
    dependencies: dependencies,
    acceptance: acceptance,
    demo_plan: demo_plan,
    branch_name: branch_name,
    pr_number: pr_number,
    pr_url: pr_url,
    superseded_pr_numbers: superseded_pr_numbers,
    worktree_path: worktree_path,
    task_log_url: artifacts.0,
    verify_log_url: artifacts.1,
  ))
}

fn task_artifacts_decoder() -> decode.Decoder(#(String, String)) {
  use task_log_url <- decode.field("task_log_url", decode.string)
  use verify_log_url <- decode.field("verify_log_url", decode.string)
  decode.success(#(task_log_url, verify_log_url))
}

fn pending_decision_decoder() -> decode.Decoder(PendingDecision) {
  use task_id <- decode.field("task_id", decode.string)
  use task_title <- decode.field("task_title", decode.string)
  use request <- decode.field("request", decision_request_decoder())
  decode.success(PendingDecision(
    task_id: task_id,
    task_title: task_title,
    request: request,
  ))
}

fn decision_request_decoder() -> decode.Decoder(DecisionRequest) {
  use key <- decode.field("key", decode.string)
  use question <- decode.field("question", decode.string)
  use rationale <- decode.field("rationale", decode.string)
  use options <- decode.field("options", decode.list(decision_option_decoder()))
  use recommended_option <- decode.optional_field(
    "recommended_option",
    None,
    decode.optional(decode.string),
  )
  use allow_freeform <- decode.field("allow_freeform", decode.bool)
  decode.success(DecisionRequest(
    key: key,
    question: question,
    rationale: rationale,
    options: options,
    recommended_option: recommended_option,
    allow_freeform: allow_freeform,
  ))
}

fn decision_option_decoder() -> decode.Decoder(DecisionOption) {
  use label <- decode.field("label", decode.string)
  use description <- decode.field("description", decode.string)
  decode.success(DecisionOption(label: label, description: description))
}

fn repo_state_decoder() -> decode.Decoder(RepoStateView) {
  use repo_state <- decode.field("repo_state", repo_state_summary_decoder())
  use replacement_lineage <- decode.field(
    "replacement_lineage",
    decode.list(lineage_decoder()),
  )
  decode.success(RepoStateView(
    snapshot_captured_at: repo_state.0,
    drift: repo_state.1,
    actionable_pull_requests: repo_state.2,
    impacted_pull_requests: repo_state.3,
    replacement_lineage: replacement_lineage,
  ))
}

fn repo_state_summary_decoder() -> decode.Decoder(
  #(String, String, List(PullRequestView), List(PullRequestView)),
) {
  use snapshot_captured_at <- decode.field(
    "snapshot_captured_at",
    decode.string,
  )
  use drift <- decode.optional_field("drift", "unknown", decode.string)
  use actionable_pull_requests <- decode.field(
    "actionable_pull_requests",
    decode.list(pull_request_decoder()),
  )
  use impacted_pull_requests <- decode.field(
    "impacted_pull_requests",
    decode.list(pull_request_decoder()),
  )
  decode.success(#(
    snapshot_captured_at,
    drift,
    actionable_pull_requests,
    impacted_pull_requests,
  ))
}

fn pull_request_decoder() -> decode.Decoder(PullRequestView) {
  use number <- decode.field("number", decode.int)
  use title <- decode.field("title", decode.string)
  use branch_name <- decode.field("branch_name", decode.string)
  use url <- decode.field("url", decode.string)
  decode.success(PullRequestView(
    number: number,
    title: title,
    branch_name: branch_name,
    url: url,
  ))
}

fn lineage_decoder() -> decode.Decoder(LineageView) {
  use task_id <- decode.field("task_id", decode.string)
  use superseded_pr_numbers <- decode.field(
    "superseded_pr_numbers",
    decode.list(decode.int),
  )
  use replacement_pr_number <- decode.optional_field(
    "replacement_pr_number",
    None,
    decode.optional(decode.string),
  )
  decode.success(LineageView(
    task_id: task_id,
    superseded_pr_numbers: superseded_pr_numbers,
    replacement_pr_number: replacement_pr_number,
  ))
}

fn timeline_entry_decoder() -> decode.Decoder(TimelineEntry) {
  use kind <- decode.field("kind", decode.string)
  use at <- decode.field("at", decode.string)
  use message <- decode.field("message", decode.string)
  use task_id <- decode.optional_field(
    "task_id",
    None,
    decode.optional(decode.string),
  )
  decode.success(TimelineEntry(
    kind: kind,
    at: at,
    message: message,
    task_id: task_id,
  ))
}

fn delivery_decoder() -> decode.Decoder(DeliveryView) {
  use task_id <- decode.field("task_id", decode.string)
  use task_title <- decode.field("task_title", decode.string)
  use pr_number <- decode.field("pr_number", decode.string)
  use pr_url <- decode.field("pr_url", decode.string)
  decode.success(DeliveryView(
    task_id: task_id,
    task_title: task_title,
    pr_number: pr_number,
    pr_url: pr_url,
  ))
}

fn recovery_decoder() -> decode.Decoder(
  #(Option(RecoveryBlocker), List(TaskView)),
) {
  use setup_blocker <- decode.optional_field(
    "setup_blocker",
    None,
    decode.optional(recovery_blocker_decoder()),
  )
  use implementation_blockers <- decode.field(
    "implementation_blockers",
    decode.list(task_decoder()),
  )
  decode.success(#(setup_blocker, implementation_blockers))
}

fn recovery_blocker_decoder() -> decode.Decoder(RecoveryBlocker) {
  use kind <- decode.field("kind", decode.string)
  use phase <- decode.field("phase", decode.string)
  use task_id <- decode.optional_field(
    "task_id",
    None,
    decode.optional(decode.string),
  )
  use message <- decode.field("message", decode.string)
  use log_path <- decode.field("log_path", decode.string)
  use disposition <- decode.field("disposition", decode.string)
  decode.success(RecoveryBlocker(
    kind: kind,
    phase: phase,
    task_id: task_id,
    message: message,
    log_path: log_path,
    disposition: disposition,
  ))
}

fn artifacts_decoder() -> decode.Decoder(#(String, String)) {
  use report_url <- decode.field("report_url", decode.string)
  use provenance_url <- decode.field("provenance_url", decode.string)
  decode.success(#(report_url, provenance_url))
}

fn provider_model_decoder() -> decode.Decoder(ProviderModel) {
  use id <- decode.field("id", decode.string)
  use label <- decode.field("label", decode.string)
  use is_default <- decode.field("is_default", decode.bool)
  decode.success(ProviderModel(id: id, label: label, is_default: is_default))
}

fn action_response_decoder() -> decode.Decoder(ActionResponse) {
  use summary <- decode.field("summary", decode.string)
  use next_action <- decode.field("next_action", decode.string)
  use run_id <- decode.optional_field(
    "run_id",
    None,
    decode.optional(decode.string),
  )
  decode.success(ActionResponse(
    summary: summary,
    next_action: next_action,
    run_id: run_id,
  ))
}

fn node_layer(task_id: String, tasks: List(TaskView)) -> String {
  int_to_string(1 + task_depth(task_id, tasks))
}

fn task_depth(task_id: String, tasks: List(TaskView)) -> Int {
  case find_task(tasks, task_id) {
    Some(task) ->
      case task.dependencies {
        [] -> 0
        dependencies -> max_depth(dependencies, tasks, 0)
      }
    None -> 0
  }
}

fn max_depth(
  dependencies: List(String),
  tasks: List(TaskView),
  current: Int,
) -> Int {
  case dependencies {
    [] -> current
    [dependency, ..rest] -> {
      let depth = 1 + task_depth(dependency, tasks)
      max_depth(rest, tasks, max_int(current, depth))
    }
  }
}

fn max_int(left: Int, right: Int) -> Int {
  case left > right {
    True -> left
    False -> right
  }
}

fn non_empty(value: String, fallback: String) -> String {
  case string.trim(value) {
    "" -> fallback
    trimmed -> trimmed
  }
}

fn render_pr_numbers(numbers: List(Int)) -> String {
  case numbers {
    [] -> "—"
    _ ->
      numbers
      |> list.map(fn(number) { "#" <> int_to_string(number) })
      |> string.join(with: ", ")
  }
}

fn default_model_id(models: List(ProviderModel), existing: String) -> String {
  case string.trim(existing) {
    "" ->
      case list.find(models, fn(model) { model.is_default }) {
        Ok(model) -> model.id
        Error(_) ->
          case models {
            [model, ..] -> model.id
            [] -> ""
          }
      }
    value -> value
  }
}

fn int_to_string(value: Int) -> String {
  int.to_string(value)
}

fn suggest_tab(current: String, workspace: Workspace) -> String {
  case current == "graph", workspace.run {
    True, Some(run) ->
      case run.decisions, run.setup_blocker, run.implementation_blockers {
        [_, ..], _, _ -> "decisions"
        _, Some(_), _ -> "recovery"
        _, _, [_, ..] -> "recovery"
        _, _, _ -> current
      }
    _, _ -> current
  }
}
