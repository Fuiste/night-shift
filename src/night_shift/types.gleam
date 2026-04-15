//// Shared domain types for Night Shift's CLI, planner, and runtime.
////
//// This module is the common language spoken across parsing, orchestration,
//// persistence, and provider integration layers.

import gleam/list
import gleam/option.{type Option, None, Some}
import night_shift/domain/repo_state

/// Default filename used for the repo-local execution brief.
pub const default_brief_filename = "execution-brief.md"

/// Supported external agent providers.
pub type Provider {
  Codex
  Cursor
}

/// Parse a provider identifier from configuration or CLI input.
pub fn provider_from_string(value: String) -> Result(Provider, String) {
  case value {
    "codex" -> Ok(Codex)
    "cursor" -> Ok(Cursor)
    _ -> Error("Unsupported provider: " <> value)
  }
}

/// Render a provider as its stable config and CLI identifier.
pub fn provider_to_string(provider: Provider) -> String {
  case provider {
    Codex -> "codex"
    Cursor -> "cursor"
  }
}

/// Supported reasoning presets for provider backends that expose them.
pub type ReasoningLevel {
  Low
  Medium
  High
  ExtraHigh
}

/// Parse a reasoning level from configuration or CLI input.
pub fn reasoning_from_string(value: String) -> Result(ReasoningLevel, String) {
  case value {
    "low" -> Ok(Low)
    "medium" -> Ok(Medium)
    "high" -> Ok(High)
    "xhigh" -> Ok(ExtraHigh)
    _ -> Error("Unsupported reasoning level: " <> value)
  }
}

/// Render a reasoning level as its stable config and CLI identifier.
pub fn reasoning_to_string(reasoning: ReasoningLevel) -> String {
  case reasoning {
    Low -> "low"
    Medium -> "medium"
    High -> "high"
    ExtraHigh -> "xhigh"
  }
}

/// Provider-specific configuration key-value pairs to pass through verbatim.
pub type ProviderOverride {
  ProviderOverride(key: String, value: String)
}

/// Named provider profile loaded from repo-local config.
pub type AgentProfile {
  AgentProfile(
    name: String,
    provider: Provider,
    model: Option(String),
    reasoning: Option(ReasoningLevel),
    provider_overrides: List(ProviderOverride),
  )
}

/// Construct the default agent profile used in new repositories.
pub fn default_agent_profile() -> AgentProfile {
  AgentProfile(
    name: "default",
    provider: Codex,
    model: None,
    reasoning: None,
    provider_overrides: [],
  )
}

/// Fully resolved provider configuration for a specific Night Shift phase.
pub type ResolvedAgentConfig {
  ResolvedAgentConfig(
    profile_name: String,
    provider: Provider,
    model: Option(String),
    reasoning: Option(ReasoningLevel),
    provider_overrides: List(ProviderOverride),
  )
}

/// Build a minimal resolved config from a provider when older flows only know
/// the provider identity.
pub fn resolved_agent_from_provider(provider: Provider) -> ResolvedAgentConfig {
  ResolvedAgentConfig(
    profile_name: "legacy",
    provider: provider,
    model: None,
    reasoning: None,
    provider_overrides: [],
  )
}

/// CLI-level overrides that can refine a chosen profile without rewriting it.
pub type AgentOverrides {
  AgentOverrides(
    profile: Option(String),
    provider: Option(Provider),
    model: Option(String),
    reasoning: Option(ReasoningLevel),
  )
}

/// Construct an empty set of CLI overrides.
pub fn empty_agent_overrides() -> AgentOverrides {
  AgentOverrides(profile: None, provider: None, model: None, reasoning: None)
}

/// Notification sinks that receive Night Shift progress updates.
pub type NotifierName {
  ConsoleNotifier
  ReportFileNotifier
}

/// Parse a notifier identifier from config.
pub fn notifier_from_string(value: String) -> Result(NotifierName, String) {
  case value {
    "console" -> Ok(ConsoleNotifier)
    "report_file" -> Ok(ReportFileNotifier)
    _ -> Error("Unsupported notifier: " <> value)
  }
}

/// Render a notifier as its stable config identifier.
pub fn notifier_to_string(notifier: NotifierName) -> String {
  case notifier {
    ConsoleNotifier -> "console"
    ReportFileNotifier -> "report_file"
  }
}

/// Lifecycle states for individual tasks within a run.
pub type TaskState {
  Queued
  Ready
  Running
  Blocked
  Completed
  Failed
  ManualAttention
}

/// Render a task state for persistence and user-facing output.
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

/// Scheduling discipline for a planned task.
pub type ExecutionMode {
  Parallel
  Serial
  Exclusive
}

/// Parse an execution mode from planner output.
pub fn execution_mode_from_string(
  value: String,
) -> Result(ExecutionMode, String) {
  case value {
    "parallel" -> Ok(Parallel)
    "serial" -> Ok(Serial)
    "exclusive" -> Ok(Exclusive)
    _ -> Error("Unsupported execution mode: " <> value)
  }
}

/// Render an execution mode for persistence and planner prompts.
pub fn execution_mode_to_string(mode: ExecutionMode) -> String {
  case mode {
    Parallel -> "parallel"
    Serial -> "serial"
    Exclusive -> "exclusive"
  }
}

/// High-level task classes understood by the orchestrator.
pub type TaskKind {
  ImplementationTask
  ManualAttentionTask
}

/// Parse a task kind from planner output.
pub fn task_kind_from_string(value: String) -> Result(TaskKind, String) {
  case value {
    "implementation" -> Ok(ImplementationTask)
    "manual_attention" -> Ok(ManualAttentionTask)
    _ -> Error("Unsupported task kind: " <> value)
  }
}

/// Render a task kind for persistence and planner prompts.
pub fn task_kind_to_string(kind: TaskKind) -> String {
  case kind {
    ImplementationTask -> "implementation"
    ManualAttentionTask -> "manual_attention"
  }
}

/// A single structured answer option for a manual planning decision.
pub type DecisionOption {
  DecisionOption(label: String, description: String)
}

/// A planner request for human input before execution can continue.
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

/// A recorded operator answer to a previous `DecisionRequest`.
pub type RecordedDecision {
  RecordedDecision(
    key: String,
    question: String,
    answer: String,
    answered_at: String,
  )
}

/// Origin metadata for the notes used to produce an execution brief.
pub type NotesSource {
  NotesFile(path: String)
  InlineNotes(path: String)
}

/// Render a short operator-facing label for a notes source.
pub fn notes_source_label(source: NotesSource) -> String {
  case source {
    NotesFile(path) -> "file: " <> path
    InlineNotes(path) -> "inline: " <> path
  }
}

/// Provenance for the planning inputs that produced a run's brief and DAG.
pub type PlanningProvenance {
  NotesOnly(notes_source: NotesSource)
  ReviewsOnly
  ReviewsAndNotes(notes_source: NotesSource)
}

pub fn planning_provenance_label(provenance: PlanningProvenance) -> String {
  case provenance {
    NotesOnly(_) -> "notes only"
    ReviewsOnly -> "reviews only"
    ReviewsAndNotes(_) -> "reviews + notes"
  }
}

pub fn planning_provenance_notes_source(
  provenance: PlanningProvenance,
) -> Option(NotesSource) {
  case provenance {
    NotesOnly(notes_source) -> Some(notes_source)
    ReviewsOnly -> None
    ReviewsAndNotes(notes_source) -> Some(notes_source)
  }
}

pub fn planning_provenance_uses_reviews(provenance: PlanningProvenance) -> Bool {
  case provenance {
    NotesOnly(_) -> False
    ReviewsOnly | ReviewsAndNotes(_) -> True
  }
}

/// A planner-emitted task that should be merged into a running graph later.
pub type FollowUpTask {
  FollowUpTask(
    id: String,
    title: String,
    description: String,
    dependencies: List(String),
    acceptance: List(String),
    demo_plan: List(String),
    decision_requests: List(DecisionRequest),
    superseded_pr_numbers: List(Int),
    kind: TaskKind,
    execution_mode: ExecutionMode,
  )
}

/// One named derived port exposed to a task runtime.
pub type RuntimePort {
  RuntimePort(name: String, value: Int)
}

/// Persisted runtime identity for one task worktree.
pub type RuntimeContext {
  RuntimeContext(
    worktree_id: String,
    compose_project: String,
    port_base: Int,
    named_ports: List(RuntimePort),
    runtime_dir: String,
    env_file_path: String,
    manifest_path: String,
    handoff_path: String,
  )
}

/// A scheduled unit of work inside a Night Shift run.
pub type Task {
  Task(
    id: String,
    title: String,
    description: String,
    dependencies: List(String),
    acceptance: List(String),
    demo_plan: List(String),
    decision_requests: List(DecisionRequest),
    superseded_pr_numbers: List(Int),
    kind: TaskKind,
    execution_mode: ExecutionMode,
    state: TaskState,
    worktree_path: String,
    branch_name: String,
    pr_number: String,
    summary: String,
    runtime_context: Option(RuntimeContext),
  )
}

/// Return `True` when a queued task's dependencies have all completed.
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

pub fn decision_recorded(decisions: List(RecordedDecision), key: String) -> Bool {
  list.any(decisions, fn(decision) { decision.key == key })
}

/// Return the subset of decision requests that still need operator input.
///
/// Manual-attention tasks without explicit requests are coerced into one
/// synthetic request so the rest of the pipeline can stay uniform.
pub fn unresolved_decision_requests(
  decisions: List(RecordedDecision),
  task: Task,
) -> List(DecisionRequest) {
  case task.decision_requests {
    [] -> [
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

/// Return `True` when a task should pause the run for manual intervention.
pub fn task_requires_manual_attention(
  decisions: List(RecordedDecision),
  task: Task,
) -> Bool {
  task.kind == ManualAttentionTask
  && unresolved_decision_requests(decisions, task) != []
}

/// Pull request delivery plan returned by an executor.
pub type PrPlan {
  PrPlan(
    title: String,
    summary: String,
    demo: List(String),
    risks: List(String),
  )
}

/// Structured result emitted by provider execution.
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

/// Lifecycle states for a Night Shift run.
pub type RunStatus {
  RunPending
  RunActive
  RunCompleted
  RunBlocked
  RunFailed
}

/// Render a run status for persistence and user-facing output.
pub fn run_status_to_string(status: RunStatus) -> String {
  case status {
    RunPending -> "pending"
    RunActive -> "active"
    RunCompleted -> "completed"
    RunBlocked -> "blocked"
    RunFailed -> "failed"
  }
}

/// A timestamped event recorded in the run journal.
pub type RunEvent {
  RunEvent(kind: String, at: String, message: String, task_id: Option(String))
}

pub type RecoveryBlockerKind {
  EnvironmentPreflightBlocker
  TaskSetupBlocker
}

pub fn recovery_blocker_kind_to_string(kind: RecoveryBlockerKind) -> String {
  case kind {
    EnvironmentPreflightBlocker -> "environment_preflight"
    TaskSetupBlocker -> "task_setup"
  }
}

pub fn recovery_blocker_kind_from_string(
  value: String,
) -> Result(RecoveryBlockerKind, String) {
  case value {
    "environment_preflight" -> Ok(EnvironmentPreflightBlocker)
    "task_setup" -> Ok(TaskSetupBlocker)
    _ -> Error("Unsupported recovery blocker kind: " <> value)
  }
}

pub type RecoveryBlockerPhase {
  PreflightPhase
  SetupPhase
  MaintenancePhase
}

pub fn recovery_blocker_phase_to_string(phase: RecoveryBlockerPhase) -> String {
  case phase {
    PreflightPhase -> "preflight"
    SetupPhase -> "setup"
    MaintenancePhase -> "maintenance"
  }
}

pub fn recovery_blocker_phase_from_string(
  value: String,
) -> Result(RecoveryBlockerPhase, String) {
  case value {
    "preflight" -> Ok(PreflightPhase)
    "setup" -> Ok(SetupPhase)
    "maintenance" -> Ok(MaintenancePhase)
    _ -> Error("Unsupported recovery blocker phase: " <> value)
  }
}

pub type RecoveryBlockerDisposition {
  RecoveryBlocking
  RecoveryWaivedOnce
}

pub fn recovery_blocker_disposition_to_string(
  disposition: RecoveryBlockerDisposition,
) -> String {
  case disposition {
    RecoveryBlocking -> "blocking"
    RecoveryWaivedOnce -> "waived_once"
  }
}

pub fn recovery_blocker_disposition_from_string(
  value: String,
) -> Result(RecoveryBlockerDisposition, String) {
  case value {
    "blocking" -> Ok(RecoveryBlocking)
    "waived_once" -> Ok(RecoveryWaivedOnce)
    _ -> Error("Unsupported recovery blocker disposition: " <> value)
  }
}

pub type RecoveryBlocker {
  RecoveryBlocker(
    kind: RecoveryBlockerKind,
    phase: RecoveryBlockerPhase,
    task_id: Option(String),
    message: String,
    log_path: String,
    no_changes_produced: Bool,
    disposition: RecoveryBlockerDisposition,
  )
}

pub fn recovery_blocker_is_active(blocker: RecoveryBlocker) -> Bool {
  blocker.disposition == RecoveryBlocking
}

/// Persistent record for one Night Shift run.
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
    planning_provenance: Option(PlanningProvenance),
    repo_state_snapshot: Option(repo_state.RepoStateSnapshot),
    decisions: List(RecordedDecision),
    planning_dirty: Bool,
    status: RunStatus,
    created_at: String,
    updated_at: String,
    recovery_blocker: Option(RecoveryBlocker),
    tasks: List(Task),
    handoff_states: List(TaskHandoffState),
  )
}

/// Selector syntax used by CLI commands that operate on existing runs.
pub type RunSelector {
  LatestRun
  RunId(String)
}

pub type ConfidencePosture {
  ConfidenceHigh
  ConfidenceGuarded
  ConfidenceLow
}

pub fn confidence_posture_to_string(posture: ConfidencePosture) -> String {
  case posture {
    ConfidenceHigh -> "high"
    ConfidenceGuarded -> "guarded"
    ConfidenceLow -> "low"
  }
}

pub type ConfidenceAssessment {
  ConfidenceAssessment(posture: ConfidencePosture, reasons: List(String))
}

pub type RecoveryClassification {
  SafeToResume
  ResumeWithWarning
  RecoveryManualAttention
  RecoveryIrrecoverable
}

pub fn recovery_classification_to_string(
  classification: RecoveryClassification,
) -> String {
  case classification {
    SafeToResume -> "safe_to_resume"
    ResumeWithWarning -> "resume_with_warning"
    RecoveryManualAttention -> "manual_attention"
    RecoveryIrrecoverable -> "irrecoverable"
  }
}

pub type ProvenanceFormat {
  ProvenanceJson
  ProvenanceMarkdown
}

pub type HandoffBodyMode {
  HandoffBodyOff
  HandoffBodyAppend
  HandoffBodyPrepend
}

pub fn handoff_body_mode_from_string(
  value: String,
) -> Result(HandoffBodyMode, String) {
  case value {
    "off" -> Ok(HandoffBodyOff)
    "append" -> Ok(HandoffBodyAppend)
    "prepend" -> Ok(HandoffBodyPrepend)
    _ -> Error("Unsupported handoff PR body mode: " <> value)
  }
}

pub fn handoff_body_mode_to_string(mode: HandoffBodyMode) -> String {
  case mode {
    HandoffBodyOff -> "off"
    HandoffBodyAppend -> "append"
    HandoffBodyPrepend -> "prepend"
  }
}

pub type HandoffProvenance {
  HandoffProvenanceMinimal
  HandoffProvenanceLight
  HandoffProvenanceStructured
}

pub fn handoff_provenance_from_string(
  value: String,
) -> Result(HandoffProvenance, String) {
  case value {
    "minimal" -> Ok(HandoffProvenanceMinimal)
    "light" -> Ok(HandoffProvenanceLight)
    "structured" -> Ok(HandoffProvenanceStructured)
    _ -> Error("Unsupported handoff provenance level: " <> value)
  }
}

pub fn handoff_provenance_to_string(level: HandoffProvenance) -> String {
  case level {
    HandoffProvenanceMinimal -> "minimal"
    HandoffProvenanceLight -> "light"
    HandoffProvenanceStructured -> "structured"
  }
}

pub type HandoffConfig {
  HandoffConfig(
    enabled: Bool,
    pr_body_mode: HandoffBodyMode,
    managed_comment: Bool,
    provenance: HandoffProvenance,
    include_files_touched: Bool,
    include_acceptance: Bool,
    include_stack_context: Bool,
    include_verification_summary: Bool,
    pr_body_prefix_path: Option(String),
    pr_body_suffix_path: Option(String),
    comment_prefix_path: Option(String),
    comment_suffix_path: Option(String),
  )
}

pub fn default_handoff_config() -> HandoffConfig {
  HandoffConfig(
    enabled: True,
    pr_body_mode: HandoffBodyAppend,
    managed_comment: False,
    provenance: HandoffProvenanceStructured,
    include_files_touched: True,
    include_acceptance: False,
    include_stack_context: True,
    include_verification_summary: True,
    pr_body_prefix_path: None,
    pr_body_suffix_path: None,
    comment_prefix_path: None,
    comment_suffix_path: None,
  )
}

pub type TaskHandoffState {
  TaskHandoffState(
    task_id: String,
    delivered_pr_number: String,
    last_delivered_commit_sha: String,
    last_handoff_files: List(String),
    last_verification_digest: String,
    last_risks: List(String),
    last_handoff_updated_at: String,
    body_region_present: Bool,
    managed_comment_present: Bool,
  )
}

pub fn task_handoff_state(
  handoff_states: List(TaskHandoffState),
  task_id: String,
) -> Option(TaskHandoffState) {
  case handoff_states |> list.find(fn(state) { state.task_id == task_id }) {
    Ok(state) -> Some(state)
    Error(_) -> None
  }
}

pub fn replace_task_handoff_state(
  handoff_states: List(TaskHandoffState),
  next_state: TaskHandoffState,
) -> List(TaskHandoffState) {
  case handoff_states {
    [] -> [next_state]
    [state, ..rest] if state.task_id == next_state.task_id -> [
      next_state,
      ..rest
    ]
    [state, ..rest] -> [state, ..replace_task_handoff_state(rest, next_state)]
  }
}

/// Repo-local operator configuration for Night Shift.
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
    handoff: HandoffConfig,
  )
}

/// Construct the default config used before a repo writes its own file.
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
    handoff: default_handoff_config(),
  )
}

/// Parsed CLI commands for the operator-facing executable.
pub type Command {
  Start(run: RunSelector)
  Dash(run: RunSelector)
  Init(agent_overrides: AgentOverrides, generate_setup: Bool, assume_yes: Bool)
  Reset(assume_yes: Bool, force: Bool)
  Plan(
    notes_value: Option(String),
    doc_path: Option(String),
    from_reviews: Bool,
    agent_overrides: AgentOverrides,
  )
  Status(run: RunSelector)
  Report(run: RunSelector)
  Provenance(
    run: RunSelector,
    task_id: Option(String),
    format: ProvenanceFormat,
  )
  Doctor(run: RunSelector)
  Resolve(
    run: RunSelector,
    task_id: Option(String),
    action: Option(ResolveAction),
  )
  Resume(run: RunSelector, explain_only: Bool)
  Demo(ui_enabled: Bool)
  Help
}

pub type ResolveAction {
  ResolveInspect
  ResolveContinue
  ResolveComplete
  ResolveAbandon
}
