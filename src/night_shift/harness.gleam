import filepath
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import night_shift/shell
import night_shift/system
import night_shift/types
import simplifile

const start_marker = "NIGHT_SHIFT_RESULT_START"
const end_marker = "NIGHT_SHIFT_RESULT_END"

pub type TaskRun {
  TaskRun(
    task: types.Task,
    handle: shell.JobHandle,
    worktree_path: String,
    log_path: String,
    branch_name: String,
    base_ref: String,
  )
}

pub fn plan_tasks(
  harness: types.Harness,
  repo_root: String,
  brief_path: String,
  run_path: String,
) -> Result(List(types.Task), String) {
  let prompt_path = filepath.join(run_path, "planner.prompt.md")
  let log_path = filepath.join(run_path, "logs/planner.log")
  use brief_contents <- result.try(read_file(brief_path))
  use _ <- result.try(write_file(prompt_path, planner_prompt(brief_contents)))
  let command = planner_command(harness, repo_root, prompt_path)
  let result = shell.run(command, repo_root, log_path)

  case shell.succeeded(result) {
    True -> {
      use payload <- result.try(extract_json_payload(result.output))
      json.parse(payload, planner_decoder())
      |> result.map_error(fn(_) { "Unable to decode planner output." })
    }
    False -> Error("Planner harness failed. See " <> log_path)
  }
}

pub fn start_task(
  harness: types.Harness,
  repo_root: String,
  run_path: String,
  task: types.Task,
  worktree_path: String,
  branch_name: String,
  base_ref: String,
) -> Result(TaskRun, String) {
  let prompt_path = filepath.join(run_path, "logs/" <> task.id <> ".prompt.md")
  let log_path = filepath.join(run_path, "logs/" <> task.id <> ".log")
  use _ <- result.try(write_file(prompt_path, execution_prompt(task)))
  let handle =
    shell.start(
      executor_command(harness, repo_root, worktree_path, prompt_path),
      worktree_path,
      log_path,
    )

  Ok(
    TaskRun(
      task: task,
      handle: handle,
      worktree_path: worktree_path,
      log_path: log_path,
      branch_name: branch_name,
      base_ref: base_ref,
    ),
  )
}

pub fn await_task(run: TaskRun) -> Result(types.ExecutionResult, String) {
  let result = shell.wait(run.handle)
  case shell.succeeded(result) {
    True -> {
      use payload <- result.try(extract_json_payload(result.output))
      json.parse(payload, execution_decoder())
      |> result.map_error(fn(_) { "Unable to decode execution output for task " <> run.task.id <> "." })
    }
    False -> Error("Harness execution failed for task " <> run.task.id <> ". See " <> run.log_path)
  }
}

pub fn repair_task(
  harness: types.Harness,
  repo_root: String,
  worktree_path: String,
  run_path: String,
  task: types.Task,
  verification_output: String,
) -> Result(types.ExecutionResult, String) {
  let prompt_path = filepath.join(run_path, "logs/" <> task.id <> ".repair.prompt.md")
  let log_path = filepath.join(run_path, "logs/" <> task.id <> ".repair.log")
  use _ <- result.try(write_file(prompt_path, repair_prompt(task, verification_output)))
  let result =
    shell.run(
      executor_command(harness, repo_root, worktree_path, prompt_path),
      worktree_path,
      log_path,
    )

  case shell.succeeded(result) {
    True -> {
      use payload <- result.try(extract_json_payload(result.output))
      json.parse(payload, execution_decoder())
      |> result.map_error(fn(_) { "Unable to decode repair output for task " <> task.id <> "." })
    }
    False -> Error("Repair harness failed for task " <> task.id <> ". See " <> log_path)
  }
}

fn planner_command(harness: types.Harness, repo_root: String, prompt_path: String) -> String {
  let fake_harness = system.get_env("NIGHT_SHIFT_FAKE_HARNESS")
  case fake_harness {
    "" -> real_command(harness, repo_root, prompt_path)
    command ->
      command
      <> " plan "
      <> shell.quote(prompt_path)
  }
}

fn executor_command(
  harness: types.Harness,
  repo_root: String,
  worktree_path: String,
  prompt_path: String,
) -> String {
  let fake_harness = system.get_env("NIGHT_SHIFT_FAKE_HARNESS")
  case fake_harness {
    "" ->
      case harness {
        types.Codex ->
          "PROMPT=$(cat "
          <> shell.quote(prompt_path)
          <> "); codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox \"$PROMPT\""
        types.Cursor ->
          "PROMPT=$(cat "
          <> shell.quote(prompt_path)
          <> "); cursor-agent --print --output-format text --force --trust --workspace "
          <> shell.quote(worktree_path)
          <> " \"$PROMPT\""
      }
    command ->
      command
      <> " execute "
      <> shell.quote(prompt_path)
      <> " "
      <> shell.quote(worktree_path)
      <> " "
      <> shell.quote(repo_root)
  }
}

fn real_command(harness: types.Harness, repo_root: String, prompt_path: String) -> String {
  case harness {
    types.Codex ->
      "PROMPT=$(cat "
      <> shell.quote(prompt_path)
      <> "); codex exec --skip-git-repo-check --dangerously-bypass-approvals-and-sandbox -C "
      <> shell.quote(repo_root)
      <> " \"$PROMPT\""
    types.Cursor ->
      "PROMPT=$(cat "
      <> shell.quote(prompt_path)
      <> "); cursor-agent --print --output-format text --force --trust --workspace "
      <> shell.quote(repo_root)
      <> " \"$PROMPT\""
  }
}

fn planner_prompt(brief_contents: String) -> String {
  "You are Night Shift's planning harness.\n"
  <> "Break the supplied brief into a task DAG.\n"
  <> "Stay strictly within the brief. Do not create adjacent scope.\n"
  <> "If ambiguity would change public behavior, create a single task whose description asks for manual attention.\n"
  <> "Return only one JSON object between the exact sentinel markers below.\n"
  <> "Each task must include: id, title, description, dependencies, acceptance, demo_plan, parallel_safe.\n"
  <> "Use lowercase kebab-case ids.\n"
  <> "\n"
  <> start_marker
  <> "\n"
  <> "{\"tasks\":[...]}\n"
  <> end_marker
  <> "\n"
  <> "\n"
  <> "Brief:\n"
  <> brief_contents
}

fn execution_prompt(task: types.Task) -> String {
  "You are Night Shift's execution harness.\n"
  <> "Implement the task in the current git worktree.\n"
  <> "Run your own validation before responding.\n"
  <> "Do not exceed the task scope.\n"
  <> "Return only one JSON object between the exact sentinel markers below.\n"
  <> "Status must be one of: completed, blocked, failed, manual_attention.\n"
  <> "The JSON shape is:\n"
  <> start_marker
  <> "\n"
  <> "{\"status\":\"completed\",\"summary\":\"...\",\"files_touched\":[\"...\"],\"demo_evidence\":[\"...\"],\"pr\":{\"title\":\"...\",\"summary\":\"...\",\"demo\":[\"...\"],\"risks\":[\"...\"]},\"follow_up_tasks\":[{\"id\":\"...\",\"title\":\"...\",\"description\":\"...\",\"dependencies\":[\"...\"],\"acceptance\":[\"...\"],\"demo_plan\":[\"...\"],\"parallel_safe\":false}]}\n"
  <> end_marker
  <> "\n"
  <> "\n"
  <> "Task:\n"
  <> render_task(task)
}

fn repair_prompt(task: types.Task, verification_output: String) -> String {
  execution_prompt(task)
  <> "\n\n"
  <> "Repair this task using the failing verification output below.\n"
  <> verification_output
}

fn render_task(task: types.Task) -> String {
  "- ID: "
  <> task.id
  <> "\n- Title: "
  <> task.title
  <> "\n- Description: "
  <> task.description
  <> "\n- Acceptance:\n"
  <> render_lines(task.acceptance)
  <> "\n- Demo plan:\n"
  <> render_lines(task.demo_plan)
}

fn render_lines(lines: List(String)) -> String {
  case lines {
    [] -> "  - None supplied"
    _ ->
      lines
      |> list.map(fn(line) { "  - " <> line })
      |> string.join(with: "\n")
  }
}

pub fn extract_json_payload(output: String) -> Result(String, String) {
  use #(_, after_start) <- result.try(
    string.split_once(output, start_marker)
    |> result.map_error(fn(_) { "Harness output did not contain the start marker." })
  )

  use #(payload, _) <- result.try(
    string.split_once(after_start, end_marker)
    |> result.map_error(fn(_) { "Harness output did not contain the end marker." })
  )

  Ok(string.trim(payload))
}

fn planner_decoder() -> decode.Decoder(List(types.Task)) {
  use tasks <- decode.field("tasks", decode.list(planned_task_decoder()))
  decode.success(tasks)
}

fn planned_task_decoder() -> decode.Decoder(types.Task) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use description <- decode.field("description", decode.string)
  use dependencies <- decode.field("dependencies", decode.list(decode.string))
  use acceptance <- decode.field("acceptance", decode.list(decode.string))
  use demo_plan <- decode.field("demo_plan", decode.list(decode.string))
  use parallel_safe <- decode.field("parallel_safe", decode.bool)
  decode.success(
    types.Task(
      id: id,
      title: title,
      description: description,
      dependencies: dependencies,
      acceptance: acceptance,
      demo_plan: demo_plan,
      parallel_safe: parallel_safe,
      state: types.Queued,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      summary: "",
    ),
  )
}

fn execution_decoder() -> decode.Decoder(types.ExecutionResult) {
  use status <- decode.field("status", execution_status_decoder())
  use summary <- decode.field("summary", decode.string)
  use files_touched <- decode.field("files_touched", decode.list(decode.string))
  use demo_evidence <- decode.field("demo_evidence", decode.list(decode.string))
  use pr <- decode.field("pr", pr_decoder())
  use follow_up_tasks <- decode.field("follow_up_tasks", decode.list(follow_up_task_decoder()))
  decode.success(
    types.ExecutionResult(
      status: status,
      summary: summary,
      files_touched: files_touched,
      demo_evidence: demo_evidence,
      pr: pr,
      follow_up_tasks: follow_up_tasks,
    ),
  )
}

fn pr_decoder() -> decode.Decoder(types.PrPlan) {
  use title <- decode.field("title", decode.string)
  use summary <- decode.field("summary", decode.string)
  use demo <- decode.field("demo", decode.list(decode.string))
  use risks <- decode.field("risks", decode.list(decode.string))
  decode.success(types.PrPlan(title: title, summary: summary, demo: demo, risks: risks))
}

fn follow_up_task_decoder() -> decode.Decoder(types.FollowUpTask) {
  use id <- decode.field("id", decode.string)
  use title <- decode.field("title", decode.string)
  use description <- decode.field("description", decode.string)
  use dependencies <- decode.field("dependencies", decode.list(decode.string))
  use acceptance <- decode.field("acceptance", decode.list(decode.string))
  use demo_plan <- decode.field("demo_plan", decode.list(decode.string))
  use parallel_safe <- decode.field("parallel_safe", decode.bool)
  decode.success(
    types.FollowUpTask(
      id: id,
      title: title,
      description: description,
      dependencies: dependencies,
      acceptance: acceptance,
      demo_plan: demo_plan,
      parallel_safe: parallel_safe,
    ),
  )
}

fn execution_status_decoder() -> decode.Decoder(types.TaskState) {
  use status <- decode.then(decode.string)
  case status {
    "completed" -> decode.success(types.Completed)
    "blocked" -> decode.success(types.Blocked)
    "failed" -> decode.success(types.Failed)
    "manual_attention" -> decode.success(types.ManualAttention)
    _ -> decode.failure(types.Failed, "ExecutionStatus")
  }
}

fn write_file(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.write(contents, to: path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> Error("Unable to write " <> path <> ": " <> simplifile.describe_error(error))
  }
}

fn read_file(path: String) -> Result(String, String) {
  case simplifile.read(path) {
    Ok(contents) -> Ok(contents)
    Error(error) -> Error("Unable to read " <> path <> ": " <> simplifile.describe_error(error))
  }
}
