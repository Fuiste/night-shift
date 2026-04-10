import gleam/list

pub type Harness {
  Codex
  Cursor
}

pub fn harness_from_string(value: String) -> Result(Harness, String) {
  case value {
    "codex" -> Ok(Codex)
    "cursor" -> Ok(Cursor)
    _ -> Error("Unsupported harness: " <> value)
  }
}

pub fn harness_to_string(harness: Harness) -> String {
  case harness {
    Codex -> "codex"
    Cursor -> "cursor"
  }
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

pub type RunSelector {
  LatestRun
  RunId(String)
}

pub type Config {
  Config(
    base_branch: String,
    default_harness: Harness,
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
    default_harness: Codex,
    max_workers: 4,
    branch_prefix: "night-shift",
    pr_title_prefix: "[night-shift]",
    verification_commands: [],
    notifiers: [ConsoleNotifier, ReportFileNotifier],
  )
}

pub type Command {
  Start(brief_path: String, harness: Result(Harness, Nil), max_workers: Result(Int, Nil))
  Status(run: RunSelector)
  Report(run: RunSelector)
  Resume(run: RunSelector)
  Review(harness: Result(Harness, Nil))
  Help
}
