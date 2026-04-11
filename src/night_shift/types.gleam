import gleam/list
import gleam/option.{type Option, None}

pub const default_brief_filename = "execution-brief.md"

pub type Provider {
  Codex
  Cursor
}

pub fn provider_from_string(value: String) -> Result(Provider, String) {
  case value {
    "codex" -> Ok(Codex)
    "cursor" -> Ok(Cursor)
    _ -> Error("Unsupported provider: " <> value)
  }
}

pub fn provider_to_string(provider: Provider) -> String {
  case provider {
    Codex -> "codex"
    Cursor -> "cursor"
  }
}

pub type ReasoningLevel {
  Low
  Medium
  High
  ExtraHigh
}

pub fn reasoning_from_string(value: String) -> Result(ReasoningLevel, String) {
  case value {
    "low" -> Ok(Low)
    "medium" -> Ok(Medium)
    "high" -> Ok(High)
    "xhigh" -> Ok(ExtraHigh)
    _ -> Error("Unsupported reasoning level: " <> value)
  }
}

pub fn reasoning_to_string(reasoning: ReasoningLevel) -> String {
  case reasoning {
    Low -> "low"
    Medium -> "medium"
    High -> "high"
    ExtraHigh -> "xhigh"
  }
}

pub type ProviderOverride {
  ProviderOverride(key: String, value: String)
}

pub type AgentProfile {
  AgentProfile(
    name: String,
    provider: Provider,
    model: Option(String),
    reasoning: Option(ReasoningLevel),
    provider_overrides: List(ProviderOverride),
  )
}

pub fn default_agent_profile() -> AgentProfile {
  AgentProfile(
    name: "default",
    provider: Codex,
    model: None,
    reasoning: None,
    provider_overrides: [],
  )
}

pub type ResolvedAgentConfig {
  ResolvedAgentConfig(
    profile_name: String,
    provider: Provider,
    model: Option(String),
    reasoning: Option(ReasoningLevel),
    provider_overrides: List(ProviderOverride),
  )
}

pub fn resolved_agent_from_provider(provider: Provider) -> ResolvedAgentConfig {
  ResolvedAgentConfig(
    profile_name: "legacy",
    provider: provider,
    model: None,
    reasoning: None,
    provider_overrides: [],
  )
}

pub type AgentOverrides {
  AgentOverrides(
    profile: Option(String),
    provider: Option(Provider),
    model: Option(String),
    reasoning: Option(ReasoningLevel),
  )
}

pub fn empty_agent_overrides() -> AgentOverrides {
  AgentOverrides(profile: None, provider: None, model: None, reasoning: None)
}

pub type NotifierName {
  ConsoleNotifier
  ReportFileNotifier
}

pub fn notifier_from_string(value: String) -> Result(NotifierName, String) {
  case value {
    "console" -> Ok(ConsoleNotifier)
    "report_file" -> Ok(ReportFileNotifier)
    _ -> Error("Unsupported notifier: " <> value)
  }
}

pub fn notifier_to_string(notifier: NotifierName) -> String {
  case notifier {
    ConsoleNotifier -> "console"
    ReportFileNotifier -> "report_file"
  }
}

pub type TaskState {
  Queued
  Ready
  Running
  Blocked
  Completed
  Failed
  ManualAttention
}

pub fn task_state_to_string(state: TaskState) -> String {
  case state {
    Queued -> "queued"
    Ready -> "ready"
    Running -> "running"
    Blocked -> "blocked"
    Completed -> "completed"
    Failed -> "failed"
    ManualAttention -> "manual_attention"
  }
}

pub type ExecutionMode {
  Parallel
  Serial
  Exclusive
}

pub fn execution_mode_from_string(value: String) -> Result(ExecutionMode, String) {
  case value {
    "parallel" -> Ok(Parallel)
    "serial" -> Ok(Serial)
    "exclusive" -> Ok(Exclusive)
    _ -> Error("Unsupported execution mode: " <> value)
  }
}

pub fn execution_mode_to_string(mode: ExecutionMode) -> String {
  case mode {
    Parallel -> "parallel"
    Serial -> "serial"
    Exclusive -> "exclusive"
  }
}

pub type TaskKind {
  ImplementationTask
  ManualAttentionTask
}

pub fn task_kind_from_string(value: String) -> Result(TaskKind, String) {
  case value {
    "implementation" -> Ok(ImplementationTask)
    "manual_attention" -> Ok(ManualAttentionTask)
    _ -> Error("Unsupported task kind: " <> value)
  }
}

pub fn task_kind_to_string(kind: TaskKind) -> String {
  case kind {
    ImplementationTask -> "implementation"
    ManualAttentionTask -> "manual_attention"
  }
}

pub type DecisionOption {
  DecisionOption(label: String, description: String)
}

pub type DecisionRequest {
  DecisionRequest(
    key: String,
    question: String,
    rationale: String,
    options: List(DecisionOption),
    recommended_option: Option(String),
    allow_freeform: Bool,
  )
}

pub type RecordedDecision {
  RecordedDecision(
    key: String,
    question: String,
    answer: String,
    answered_at: String,
  )
}

pub type NotesSource {
  NotesFile(path: String)
  InlineNotes(path: String)
}

pub fn notes_source_label(source: NotesSource) -> String {
  case source {
    NotesFile(path) -> "file: " <> path
    InlineNotes(path) -> "inline: " <> path
  }
}

pub type FollowUpTask {
  FollowUpTask(
    id: String,
    title: String,
    description: String,
    dependencies: List(String),
    acceptance: List(String),
    demo_plan: List(String),
    decision_requests: List(DecisionRequest),
    kind: TaskKind,
    execution_mode: ExecutionMode,
  )
}

pub type Task {
  Task(
    id: String,
    title: String,
    description: String,
    dependencies: List(String),
    acceptance: List(String),
    demo_plan: List(String),
    decision_requests: List(DecisionRequest),
    kind: TaskKind,
    execution_mode: ExecutionMode,
    state: TaskState,
    worktree_path: String,
    branch_name: String,
    pr_number: String,
    summary: String,
  )
}

pub fn is_task_ready(task: Task, completed_ids: List(String)) -> Bool {
  case task.state {
    Queued ->
      list.all(task.dependencies, fn(dependency) {
        list.contains(completed_ids, dependency)
      })
    Ready -> True
    _ -> False
  }
}

pub fn decision_recorded(
  decisions: List(RecordedDecision),
  key: String,
) -> Bool {
  list.any(decisions, fn(decision) { decision.key == key })
}

pub fn unresolved_decision_requests(
  decisions: List(RecordedDecision),
  task: Task,
) -> List(DecisionRequest) {
  case task.decision_requests {
    [] ->
      [
        DecisionRequest(
          key: "task:" <> task.id,
          question: task.title,
          rationale: task.description,
          options: [],
          recommended_option: None,
          allow_freeform: True,
        ),
      ]
    requests ->
      requests
      |> list.filter(fn(request) { !decision_recorded(decisions, request.key) })
  }
}

pub fn task_requires_manual_attention(
  decisions: List(RecordedDecision),
  task: Task,
) -> Bool {
  task.kind == ManualAttentionTask
  && unresolved_decision_requests(decisions, task) != []
}

pub type PrPlan {
  PrPlan(
    title: String,
    summary: String,
    demo: List(String),
    risks: List(String),
  )
}

pub type ExecutionResult {
  ExecutionResult(
    status: TaskState,
    summary: String,
    files_touched: List(String),
    demo_evidence: List(String),
    pr: PrPlan,
    follow_up_tasks: List(FollowUpTask),
  )
}

pub type RunStatus {
  RunPending
  RunActive
  RunCompleted
  RunBlocked
  RunFailed
}

pub fn run_status_to_string(status: RunStatus) -> String {
  case status {
    RunPending -> "pending"
    RunActive -> "active"
    RunCompleted -> "completed"
    RunBlocked -> "blocked"
    RunFailed -> "failed"
  }
}

pub type RunEvent {
  RunEvent(kind: String, at: String, message: String, task_id: Option(String))
}

pub type RunRecord {
  RunRecord(
    run_id: String,
    repo_root: String,
    run_path: String,
    brief_path: String,
    state_path: String,
    events_path: String,
    report_path: String,
    lock_path: String,
    planning_agent: ResolvedAgentConfig,
    execution_agent: ResolvedAgentConfig,
    environment_name: String,
    max_workers: Int,
    notes_source: Option(NotesSource),
    decisions: List(RecordedDecision),
    status: RunStatus,
    created_at: String,
    updated_at: String,
    tasks: List(Task),
  )
}

pub type RunSelector {
  LatestRun
  RunId(String)
}

pub type Config {
  Config(
    base_branch: String,
    default_profile: String,
    planning_profile: String,
    execution_profile: String,
    review_profile: String,
    profiles: List(AgentProfile),
    max_workers: Int,
    branch_prefix: String,
    pr_title_prefix: String,
    verification_commands: List(String),
    notifiers: List(NotifierName),
  )
}

pub fn default_config() -> Config {
  Config(
    base_branch: "main",
    default_profile: "default",
    planning_profile: "",
    execution_profile: "",
    review_profile: "",
    profiles: [default_agent_profile()],
    max_workers: 4,
    branch_prefix: "night-shift",
    pr_title_prefix: "[night-shift]",
    verification_commands: [],
    notifiers: [ConsoleNotifier, ReportFileNotifier],
  )
}

pub type Command {
  Start(run: RunSelector, ui_enabled: Bool)
  Init(
    agent_overrides: AgentOverrides,
    generate_setup: Bool,
    assume_yes: Bool,
  )
  Plan(
    notes_value: String,
    doc_path: Option(String),
    agent_overrides: AgentOverrides,
  )
  Status(run: RunSelector)
  Report(run: RunSelector)
  Resolve(run: RunSelector)
  Resume(run: RunSelector, ui_enabled: Bool)
  Review(agent_overrides: AgentOverrides, environment_name: Option(String))
  Demo(ui_enabled: Bool)
  Help
}
