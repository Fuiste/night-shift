import filepath
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/project
import night_shift/shell
import night_shift/types
import simplifile

@external(erlang, "night_shift_runtime_identity_ffi", "sha256_hex")
fn sha256_hex(value: String) -> String

@external(erlang, "night_shift_runtime_identity_ffi", "sha256_mod")
fn sha256_mod(value: String, modulus: Int) -> Int

@external(erlang, "night_shift_runtime_identity_ffi", "normalize_port_name")
fn normalize_port_name_ffi(value: String) -> String

@external(erlang, "night_shift_runtime_identity_ffi", "sanitize_task_slug")
fn sanitize_task_slug(value: String) -> String

pub fn normalize_port_name(value: String) -> Result(String, String) {
  let normalized = normalize_port_name_ffi(value)
  case normalized {
    "" ->
      Error(
        "Runtime named_ports entries must normalize to an identifier like web or api_port.",
      )
    _ -> Ok(normalized)
  }
}

pub fn build_context(
  run_path: String,
  run_id: String,
  task_id: String,
  task_title: String,
  port_base: Int,
  named_port_names: List(String),
) -> Result(types.RuntimeContext, String) {
  use named_ports <- result.try(build_named_ports(
    run_id,
    task_id,
    named_port_names,
  ))
  use _ <- result.try(validate_port_base(port_base))
  let runtime_dir = project.task_runtime_root(run_path, task_id)
  let digest = sha256_hex(run_id <> ":" <> task_id)
  let hash_prefix = string.drop_end(digest, string.length(digest) - 8)
  let worktree_id = sanitize_task_slug(task_title) <> "-" <> hash_prefix
  let compose_project = "ns-" <> worktree_id

  Ok(types.RuntimeContext(
    worktree_id: worktree_id,
    compose_project: compose_project,
    port_base: port_base,
    named_ports: assign_port_values(port_base, named_ports, 0, []),
    runtime_dir: runtime_dir,
    env_file_path: filepath.join(runtime_dir, "night-shift.env"),
    manifest_path: filepath.join(runtime_dir, "night-shift.runtime.json"),
    handoff_path: filepath.join(runtime_dir, "night-shift.handoff.md"),
  ))
}

pub fn env_vars(context: types.RuntimeContext) -> List(#(String, String)) {
  let fixed = [
    #("NIGHT_SHIFT_WORKTREE_ID", context.worktree_id),
    #("NIGHT_SHIFT_COMPOSE_PROJECT", context.compose_project),
    #("NIGHT_SHIFT_PORT_BASE", int.to_string(context.port_base)),
    #("NIGHT_SHIFT_RUNTIME_DIR", context.runtime_dir),
    #("NIGHT_SHIFT_RUNTIME_ENV_FILE", context.env_file_path),
    #("NIGHT_SHIFT_RUNTIME_MANIFEST", context.manifest_path),
    #("NIGHT_SHIFT_HANDOFF_FILE", context.handoff_path),
  ]

  list.append(
    fixed,
    context.named_ports
      |> list.map(fn(port) {
        #(
          "NIGHT_SHIFT_PORT_" <> string.uppercase(port.name),
          int.to_string(port.value),
        )
      }),
  )
}

pub fn ensure_artifacts(
  context: types.RuntimeContext,
  task: types.Task,
  worktree_path: String,
  branch_name: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    simplifile.create_directory_all(context.runtime_dir)
    |> result.map_error(describe_write_error(
      "create runtime identity directory",
    )),
  )
  use _ <- result.try(write_file(
    context.env_file_path,
    render_env_file(context),
  ))
  use _ <- result.try(write_file(
    context.manifest_path,
    render_manifest(context, task, worktree_path, branch_name),
  ))
  write_file(
    context.handoff_path,
    render_handoff(context, task, worktree_path, branch_name),
  )
}

pub fn summary(context: types.RuntimeContext) -> String {
  let ports = case context.named_ports {
    [] -> "base " <> int.to_string(context.port_base)
    named_ports ->
      named_ports
      |> list.map(fn(port) { port.name <> "=" <> int.to_string(port.value) })
      |> string.join(with: ", ")
  }

  "ID: "
  <> context.worktree_id
  <> " | Compose: "
  <> context.compose_project
  <> " | Ports: "
  <> ports
}

fn build_named_ports(
  run_id: String,
  task_id: String,
  named_port_names: List(String),
) -> Result(List(types.RuntimePort), String) {
  let _ = run_id
  let _ = task_id
  Ok(
    named_port_names
    |> list.map(fn(name) { types.RuntimePort(name: name, value: 0) }),
  )
}

pub fn allocate_port_base(
  run_id: String,
  tasks: List(types.Task),
  reserved_port_bases: List(Int),
  task_id: String,
) -> Result(Int, String) {
  use reserved_slots <- result.try(
    normalize_reserved_slots(reserved_port_bases, []),
  )
  use assignments <- result.try(
    assign_port_bases(run_id, tasks, reserved_slots, []),
  )
  case find_assigned_port_base(assignments, task_id) {
    Some(port_base) -> Ok(port_base)
    None -> Error("Unable to allocate a runtime port base for task " <> task_id)
  }
}

fn assign_port_values(
  port_base: Int,
  named_ports: List(types.RuntimePort),
  offset: Int,
  acc: List(types.RuntimePort),
) -> List(types.RuntimePort) {
  case named_ports {
    [] -> list.reverse(acc)
    [port, ..rest] ->
      assign_port_values(port_base, rest, offset + 1, [
        types.RuntimePort(..port, value: port_base + offset),
        ..acc
      ])
  }
}

fn render_env_file(context: types.RuntimeContext) -> String {
  env_vars(context)
  |> list.map(fn(entry) { entry.0 <> "=" <> shell.quote(entry.1) })
  |> string.join(with: "\n")
  |> append_newline
}

fn render_manifest(
  context: types.RuntimeContext,
  task: types.Task,
  worktree_path: String,
  branch_name: String,
) -> String {
  json.object([
    #("task_id", json.string(task.id)),
    #("task_title", json.string(task.title)),
    #("branch_name", json.string(branch_name)),
    #("worktree_path", json.string(worktree_path)),
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
  |> json.to_string
}

fn render_handoff(
  context: types.RuntimeContext,
  task: types.Task,
  worktree_path: String,
  branch_name: String,
) -> String {
  [
    "# Night Shift Runtime Handoff",
    "",
    "- Task: " <> task.title <> " (`" <> task.id <> "`)",
    "- Worktree: " <> worktree_path,
    "- Branch: " <> branch_name,
    "- Runtime ID: " <> context.worktree_id,
    "- Compose project: " <> context.compose_project,
    "- Port base: " <> int.to_string(context.port_base),
    "- Env file: " <> context.env_file_path,
    "- Manifest: " <> context.manifest_path,
    "- Handoff: " <> context.handoff_path,
    render_port_section(context.named_ports),
  ]
  |> string.join(with: "\n")
  |> append_newline
}

fn render_port_section(named_ports: List(types.RuntimePort)) -> String {
  case named_ports {
    [] -> "- Named ports: none"
    _ ->
      "- Named ports:\n"
      <> {
        named_ports
        |> list.map(fn(port) {
          "  - " <> port.name <> ": " <> int.to_string(port.value)
        })
        |> string.join(with: "\n")
      }
  }
}

fn append_newline(value: String) -> String {
  case string.ends_with(value, "\n") {
    True -> value
    False -> value <> "\n"
  }
}

fn write_file(path: String, contents: String) -> Result(Nil, String) {
  simplifile.write(contents, to: path)
  |> result.map_error(describe_write_error("write " <> path))
}

fn describe_write_error(action: String) -> fn(simplifile.FileError) -> String {
  fn(error) {
    "Unable to " <> action <> ": " <> simplifile.describe_error(error)
  }
}

fn assign_port_bases(
  run_id: String,
  tasks: List(types.Task),
  occupied_slots: List(Int),
  assignments: List(#(String, Int)),
) -> Result(List(#(String, Int)), String) {
  case tasks {
    [] -> Ok(assignments)
    [task, ..rest] ->
      case task.runtime_context {
        Some(context) -> {
          use slot <- result.try(port_slot_from_base(context.port_base))
          case list.contains(occupied_slots, slot) {
            True ->
              case assignment_matches(assignments, task.id, context.port_base) {
                True ->
                  assign_port_bases(run_id, rest, occupied_slots, assignments)
                False ->
                  Error(
                    "Runtime port base collision detected for persisted task "
                    <> task.id
                    <> ".",
                  )
              }
            False ->
              assign_port_bases(run_id, rest, [slot, ..occupied_slots], [
                #(task.id, context.port_base),
                ..assignments
              ])
          }
        }
        None -> {
          let preferred_slot =
            sha256_mod(run_id <> ":" <> task.id, port_slot_count())
          use slot <- result.try(next_free_slot(
            preferred_slot,
            occupied_slots,
            0,
          ))
          let port_base = port_base_for_slot(slot)
          assign_port_bases(run_id, rest, [slot, ..occupied_slots], [
            #(task.id, port_base),
            ..assignments
          ])
        }
      }
  }
}

fn assignment_matches(
  assignments: List(#(String, Int)),
  task_id: String,
  port_base: Int,
) -> Bool {
  case find_assigned_port_base(assignments, task_id) {
    Some(existing) -> existing == port_base
    None -> False
  }
}

fn find_assigned_port_base(
  assignments: List(#(String, Int)),
  task_id: String,
) -> Option(Int) {
  case assignments {
    [] -> None
    [assignment, ..rest] ->
      case assignment.0 == task_id {
        True -> Some(assignment.1)
        False -> find_assigned_port_base(rest, task_id)
      }
  }
}

fn normalize_reserved_slots(
  reserved_port_bases: List(Int),
  occupied_slots: List(Int),
) -> Result(List(Int), String) {
  case reserved_port_bases {
    [] -> Ok(occupied_slots)
    [port_base, ..rest] -> {
      use slot <- result.try(port_slot_from_base(port_base))
      case list.contains(occupied_slots, slot) {
        True -> normalize_reserved_slots(rest, occupied_slots)
        False -> normalize_reserved_slots(rest, [slot, ..occupied_slots])
      }
    }
  }
}

fn next_free_slot(
  slot: Int,
  occupied_slots: List(Int),
  attempts: Int,
) -> Result(Int, String) {
  case attempts >= port_slot_count() {
    True ->
      Error(
        "Night Shift ran out of runtime port blocks. Reduce retained worktrees or task count.",
      )
    False ->
      case list.contains(occupied_slots, slot) {
        False -> Ok(slot)
        True ->
          next_free_slot(wrap_slot(slot + 1), occupied_slots, attempts + 1)
      }
  }
}

fn validate_port_base(port_base: Int) -> Result(Nil, String) {
  use _ <- result.try(port_slot_from_base(port_base))
  Ok(Nil)
}

fn port_slot_from_base(port_base: Int) -> Result(Int, String) {
  let first = first_port_base()
  case port_base < first {
    True ->
      Error(
        "Runtime port base "
        <> int.to_string(port_base)
        <> " is below the supported range.",
      )
    False -> locate_port_slot(port_base, first, 0)
  }
}

fn locate_port_slot(
  port_base: Int,
  current_base: Int,
  slot: Int,
) -> Result(Int, String) {
  case current_base == port_base {
    True -> Ok(slot)
    False ->
      case slot + 1 >= port_slot_count() {
        True ->
          Error(
            "Runtime port base "
            <> int.to_string(port_base)
            <> " is outside Night Shift's supported port blocks.",
          )
        False ->
          locate_port_slot(
            port_base,
            current_base + port_block_size(),
            slot + 1,
          )
      }
  }
}

fn port_base_for_slot(slot: Int) -> Int {
  first_port_base() + slot * port_block_size()
}

fn first_port_base() -> Int {
  40_000
}

fn port_block_size() -> Int {
  20
}

fn port_slot_count() -> Int {
  1277
}

fn wrap_slot(slot: Int) -> Int {
  case slot >= port_slot_count() {
    True -> 0
    False -> slot
  }
}
