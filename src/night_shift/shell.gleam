import gleam/list
import gleam/string

pub type CommandResult {
  CommandResult(exit_code: Int, output: String)
}

pub type JobHandle {
  JobHandle(id: String)
}

pub type StreamMetadata {
  StreamMetadata(
    label: String,
    prompt_path: String,
    harness: String,
    phase: String,
  )
}

@external(erlang, "night_shift_shell", "run")
fn run_raw(command: String, cwd: String, log_path: String) -> #(Int, String)

@external(erlang, "night_shift_shell", "run_streaming")
fn run_streaming_raw(
  command: String,
  cwd: String,
  log_path: String,
  label: String,
  prompt_path: String,
  harness: String,
  phase: String,
) -> #(Int, String)

@external(erlang, "night_shift_shell", "start")
fn start_raw(command: String, cwd: String, log_path: String) -> String

@external(erlang, "night_shift_shell", "start_streaming")
fn start_streaming_raw(
  command: String,
  cwd: String,
  log_path: String,
  label: String,
  prompt_path: String,
  harness: String,
  phase: String,
) -> String

@external(erlang, "night_shift_shell", "wait")
fn wait_raw(handle_id: String) -> #(Int, String)

pub fn run(command: String, cwd: String, log_path: String) -> CommandResult {
  let #(exit_code, output) = run_raw(command, cwd, log_path)
  CommandResult(exit_code: exit_code, output: output)
}

pub fn run_streaming(
  command: String,
  cwd: String,
  log_path: String,
  metadata: StreamMetadata,
) -> CommandResult {
  let #(exit_code, output) =
    run_streaming_raw(
      command,
      cwd,
      log_path,
      metadata.label,
      metadata.prompt_path,
      metadata.harness,
      metadata.phase,
    )
  CommandResult(exit_code: exit_code, output: output)
}

pub fn start(command: String, cwd: String, log_path: String) -> JobHandle {
  JobHandle(start_raw(command, cwd, log_path))
}

pub fn start_streaming(
  command: String,
  cwd: String,
  log_path: String,
  metadata: StreamMetadata,
) -> JobHandle {
  JobHandle(start_streaming_raw(
    command,
    cwd,
    log_path,
    metadata.label,
    metadata.prompt_path,
    metadata.harness,
    metadata.phase,
  ))
}

pub fn wait(handle: JobHandle) -> CommandResult {
  let #(exit_code, output) = wait_raw(handle.id)
  CommandResult(exit_code: exit_code, output: output)
}

pub fn succeeded(result: CommandResult) -> Bool {
  result.exit_code == 0
}

pub fn quote(value: String) -> String {
  "'" <> string.replace(in: value, each: "'", with: "'\"'\"'") <> "'"
}

pub fn with_env(command: String, env_vars: List(#(String, String))) -> String {
  case env_vars {
    [] -> command
    _ ->
      "env "
      <> {
        env_vars
        |> list.map(fn(entry) { entry.0 <> "=" <> quote(entry.1) })
        |> string.join(with: " ")
      }
      <> " "
      <> command
  }
}

pub fn stream_metadata(
  label label: String,
  prompt_path prompt_path: String,
  harness harness: String,
  phase phase: String,
) -> StreamMetadata {
  StreamMetadata(
    label: label,
    prompt_path: prompt_path,
    harness: harness,
    phase: phase,
  )
}
