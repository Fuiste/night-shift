import gleam/list
import gleam/option.{type Option, None}

pub const default_brief_filename = "night-shift.md"

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

pub type FollowUpTask {
  FollowUpTask(
    id: String,
    title: String,
    description: String,
    dependencies: List(String),
    acceptance: List(String),
    demo_plan: List(String),
    parallel_safe: Bool,
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
    parallel_safe: Bool,
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
    max_workers: Int,
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
  Start(
    brief_path: Option(String),
    agent_overrides: AgentOverrides,
    max_workers: Result(Int, Nil),
    ui_enabled: Bool,
  )
  Plan(
    notes_path: String,
    doc_path: Option(String),
    agent_overrides: AgentOverrides,
  )
  Status(run: RunSelector)
  Report(run: RunSelector)
  Resume(run: RunSelector, ui_enabled: Bool)
  Review(agent_overrides: AgentOverrides)
  Demo(ui_enabled: Bool)
  Help
}
