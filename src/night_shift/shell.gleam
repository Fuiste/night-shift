import gleam/string

pub type CommandResult {
  CommandResult(exit_code: Int, output: String)
}

pub type JobHandle {
  JobHandle(id: String)
}

@external(erlang, "night_shift_shell", "run")
fn run_raw(command: String, cwd: String, log_path: String) -> #(Int, String)

@external(erlang, "night_shift_shell", "start")
fn start_raw(command: String, cwd: String, log_path: String) -> String

@external(erlang, "night_shift_shell", "wait")
fn wait_raw(handle_id: String) -> #(Int, String)

pub fn run(command: String, cwd: String, log_path: String) -> CommandResult {
  let #(exit_code, output) = run_raw(command, cwd, log_path)
  CommandResult(exit_code: exit_code, output: output)
}

pub fn start(command: String, cwd: String, log_path: String) -> JobHandle {
  JobHandle(start_raw(command, cwd, log_path))
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
