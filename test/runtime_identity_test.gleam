import filepath
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import night_shift/runtime_identity
import night_shift/system
import night_shift/types
import night_shift/worktree_setup
import simplifile

pub fn worktree_setup_parse_defaults_runtime_named_ports_when_absent_test() {
  let contents =
    "version = 1\n"
    <> "default_environment = \"default\"\n\n"
    <> "[environments.default.env]\n\n"
    <> "[environments.default.preflight]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n\n"
    <> "[environments.default.setup]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n\n"
    <> "[environments.default.maintenance]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n"

  let assert Ok(config) = worktree_setup.parse(contents)
  let assert Ok(environment) =
    worktree_setup.find_environment(config, "default")

  assert environment.runtime.named_ports == []
}

pub fn worktree_setup_parse_accepts_runtime_named_ports_test() {
  let contents =
    "version = 1\n"
    <> "default_environment = \"default\"\n\n"
    <> "[environments.default.env]\n\n"
    <> "[environments.default.runtime]\n"
    <> "named_ports = [\"web\", \"API Port\"]\n\n"
    <> "[environments.default.preflight]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n\n"
    <> "[environments.default.setup]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n\n"
    <> "[environments.default.maintenance]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n"

  let assert Ok(config) = worktree_setup.parse(contents)
  let assert Ok(environment) =
    worktree_setup.find_environment(config, "default")

  assert environment.runtime.named_ports == ["web", "api_port"]
}

pub fn worktree_setup_parse_rejects_reserved_night_shift_env_var_test() {
  let contents =
    "version = 1\n"
    <> "default_environment = \"default\"\n\n"
    <> "[environments.default.env]\n"
    <> "NIGHT_SHIFT_PORT_BASE = \"41000\"\n\n"
    <> "[environments.default.preflight]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n\n"
    <> "[environments.default.setup]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n\n"
    <> "[environments.default.maintenance]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n"

  let assert Error(message) = worktree_setup.parse(contents)

  assert string.contains(does: message, contain: "reserved NIGHT_SHIFT_ prefix")
}

pub fn worktree_setup_parse_rejects_duplicate_named_ports_after_normalization_test() {
  let contents =
    "version = 1\n"
    <> "default_environment = \"default\"\n\n"
    <> "[environments.default.env]\n\n"
    <> "[environments.default.runtime]\n"
    <> "named_ports = [\"API Port\", \"api-port\"]\n\n"
    <> "[environments.default.preflight]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n\n"
    <> "[environments.default.setup]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n\n"
    <> "[environments.default.maintenance]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n"

  let assert Error(message) = worktree_setup.parse(contents)

  assert string.contains(does: message, contain: "unique after normalization")
}

pub fn worktree_setup_parse_rejects_too_many_named_ports_test() {
  let contents =
    "version = 1\n"
    <> "default_environment = \"default\"\n\n"
    <> "[environments.default.env]\n\n"
    <> "[environments.default.runtime]\n"
    <> "named_ports = "
    <> render_port_list(build_port_names(17, []))
    <> "\n\n"
    <> "[environments.default.preflight]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n\n"
    <> "[environments.default.setup]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n\n"
    <> "[environments.default.maintenance]\n"
    <> "default = []\n"
    <> "macos = []\n"
    <> "linux = []\n"
    <> "windows = []\n"

  let assert Error(message) = worktree_setup.parse(contents)

  assert string.contains(does: message, contain: "at most 16 entries")
}

pub fn runtime_identity_build_context_is_deterministic_test() {
  let assert Ok(first) =
    runtime_identity.build_context(
      "/tmp/run",
      "run-123",
      "demo-task",
      "Demo Task",
      41_000,
      ["web", "api"],
    )
  let assert Ok(second) =
    runtime_identity.build_context(
      "/tmp/run",
      "run-123",
      "demo-task",
      "Demo Task",
      41_000,
      ["web", "api"],
    )

  assert first.worktree_id == second.worktree_id
  assert first.compose_project == second.compose_project
  assert first.port_base == second.port_base
  assert first.named_ports == second.named_ports
  assert string.starts_with(first.compose_project, "ns-")
}

pub fn runtime_identity_ensure_artifacts_writes_env_manifest_and_handoff_test() {
  let unique = system.unique_id()
  let base_dir =
    filepath.join(
      system.state_directory(),
      "night shift runtime identity " <> unique,
    )
  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(context) =
    runtime_identity.build_context(
      filepath.join(base_dir, "run"),
      "run-456",
      "demo-task",
      "Demo Task",
      41_020,
      ["web"],
    )
  let task =
    types.Task(
      id: "demo-task",
      title: "Demo Task",
      description: "Demo",
      dependencies: [],
      acceptance: [],
      demo_plan: [],
      decision_requests: [],
      superseded_pr_numbers: [],
      kind: types.ImplementationTask,
      execution_mode: types.Serial,
      state: types.Ready,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      summary: "",
      runtime_context: None,
    )

  let assert Ok(_) =
    runtime_identity.ensure_artifacts(
      context,
      task,
      filepath.join(base_dir, "worktree"),
      "night-shift/demo-task",
    )
  let assert Ok(env_contents) = simplifile.read(context.env_file_path)
  let assert Ok(manifest_contents) = simplifile.read(context.manifest_path)
  let assert Ok(handoff_contents) = simplifile.read(context.handoff_path)

  assert string.contains(
    does: env_contents,
    contain: "NIGHT_SHIFT_COMPOSE_PROJECT='",
  )
  assert string.contains(
    does: env_contents,
    contain: "NIGHT_SHIFT_RUNTIME_DIR='" <> context.runtime_dir <> "'",
  )
  assert string.contains(
    does: manifest_contents,
    contain: "\"compose_project\"",
  )
  assert string.contains(does: handoff_contents, contain: "Compose project")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}

pub fn runtime_identity_allocate_port_base_is_unique_within_run_test() {
  let tasks = [
    task_fixture("task-a"),
    task_fixture("task-b"),
    task_fixture("task-c"),
    task_fixture("task-d"),
  ]

  let assert Ok(port_base_a) =
    runtime_identity.allocate_port_base("run-ports", tasks, [], "task-a")
  let assert Ok(port_base_b) =
    runtime_identity.allocate_port_base("run-ports", tasks, [], "task-b")
  let assert Ok(port_base_c) =
    runtime_identity.allocate_port_base("run-ports", tasks, [], "task-c")
  let assert Ok(port_base_d) =
    runtime_identity.allocate_port_base("run-ports", tasks, [], "task-d")

  assert unique_int_count(
      [port_base_a, port_base_b, port_base_c, port_base_d],
      [],
    )
    == 4
}

pub fn runtime_identity_allocate_port_base_skips_reserved_blocks_test() {
  let tasks = [task_fixture("task-a"), task_fixture("task-b")]

  let assert Ok(port_base_a) =
    runtime_identity.allocate_port_base(
      "run-reserved",
      tasks,
      [40_000],
      "task-a",
    )

  assert port_base_a != 40_000
}

fn build_port_names(count: Int, acc: List(String)) -> List(String) {
  case count <= 0 {
    True -> list.reverse(acc)
    False ->
      build_port_names(count - 1, ["port" <> int.to_string(count), ..acc])
  }
}

fn render_port_list(values: List(String)) -> String {
  "["
  <> {
    values
    |> list.map(fn(value) { "\"" <> value <> "\"" })
    |> string.join(with: ", ")
  }
  <> "]"
}

fn task_fixture(task_id: String) -> types.Task {
  types.Task(
    id: task_id,
    title: task_id,
    description: "",
    dependencies: [],
    acceptance: [],
    demo_plan: [],
    decision_requests: [],
    superseded_pr_numbers: [],
    kind: types.ImplementationTask,
    execution_mode: types.Serial,
    state: types.Ready,
    worktree_path: "",
    branch_name: "",
    pr_number: "",
    summary: "",
    runtime_context: None,
  )
}

fn unique_int_count(values: List(Int), seen: List(Int)) -> Int {
  case values {
    [] -> list.length(seen)
    [value, ..rest] ->
      case list.contains(seen, value) {
        True -> unique_int_count(rest, seen)
        False -> unique_int_count(rest, [value, ..seen])
      }
  }
}
