import filepath
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import night_shift/config
import night_shift/dashboard
import night_shift/domain/repo_state
import night_shift/journal
import night_shift/orchestrator
import night_shift/project
import night_shift/shell
import night_shift/system
import night_shift/types
import simplifile

pub fn absolute_path(path: String) -> String {
  case string.starts_with(path, "/") {
    True -> path
    False -> filepath.join(system.cwd(), path)
  }
}

pub fn initialize_project_home(
  repo_root: String,
) -> Result(Nil, simplifile.FileError) {
  use _ <- result.try(simplifile.create_directory_all(project.home(repo_root)))
  use _ <- result.try(simplifile.write(
    config.render(types.default_config()),
    to: project.config_path(repo_root),
  ))
  simplifile.write(
    "*\n!config.toml\n!worktree-setup.toml\n!.gitignore\n",
    to: project.gitignore_path(repo_root),
  )
}

pub fn local_demo_command() -> String {
  let cwd = system.cwd()
  let erlang_root = filepath.join(cwd, "build/dev/erlang")
  let ebin_paths = [
    filepath.join(erlang_root, "night_shift/ebin"),
    filepath.join(erlang_root, "gleam_stdlib/ebin"),
    filepath.join(erlang_root, "gleam_json/ebin"),
    filepath.join(erlang_root, "filepath/ebin"),
    filepath.join(erlang_root, "simplifile/ebin"),
    filepath.join(erlang_root, "gleeunit/ebin"),
  ]

  "erl"
  <> {
    ebin_paths
    |> list.map(fn(path) { " -pa " <> shell.quote(path) })
    |> string.join(with: "")
  }
  <> " -noshell -eval "
  <> shell.quote("'night_shift@@main':run(night_shift).")
  <> " -extra"
}

pub fn script_capture_command(command: String) -> String {
  case system.os_name() {
    "linux" -> "script -q -c " <> shell.quote(command) <> " /dev/null"
    _ -> "script -q /dev/null sh -lc " <> shell.quote(command)
  }
}

pub fn run_local_cli_command(
  args: List(String),
  cwd: String,
  log_path: String,
) -> Result(String, String) {
  let command = local_demo_command()
  let result =
    shell.run(
      "cd "
        <> shell.quote(cwd)
        <> " && "
        <> "NIGHT_SHIFT_REPO_ROOT="
        <> shell.quote(cwd)
        <> " "
        <> command
        <> " "
        <> {
        args
        |> list.map(shell.quote)
        |> string.join(with: " ")
      },
      cwd,
      log_path,
    )

  case shell.succeeded(result) {
    True -> Ok(result.output)
    False -> Error("CLI command failed. See " <> log_path <> ".")
  }
}

pub fn run_local_cli_tty_command_with_input(
  args: List(String),
  input: String,
  cwd: String,
  log_path: String,
) -> Result(String, String) {
  let input_path = log_path <> ".stdin"
  let command =
    "cd "
    <> shell.quote(cwd)
    <> " && "
    <> "NIGHT_SHIFT_ASSUME_TTY=1 "
    <> "NIGHT_SHIFT_SCRIPTED_INPUT_FILE="
    <> shell.quote(input_path)
    <> " "
    <> "NIGHT_SHIFT_REPO_ROOT="
    <> shell.quote(cwd)
    <> " "
    <> local_demo_command()
    <> " "
    <> {
      args
      |> list.map(shell.quote)
      |> string.join(with: " ")
    }
  let _ = simplifile.write(input, to: input_path)
  let result = shell.run(command, cwd, log_path)

  case shell.succeeded(result) {
    True -> Ok(result.output)
    False -> Error("TTY CLI command failed. See " <> log_path <> ".")
  }
}

pub fn agent_for(provider_name: types.Provider) -> types.ResolvedAgentConfig {
  types.resolved_agent_from_provider(provider_name)
}

pub fn sample_repo_state_snapshot() -> repo_state.RepoStateSnapshot {
  repo_state.snapshot("2026-04-13T16:30:00Z", [
    repo_state.RepoPullRequestSnapshot(
      number: 11,
      title: "Rewrite the root document",
      url: "https://example.com/pr/11",
      head_ref_name: "night-shift/root",
      base_ref_name: "main",
      review_decision: "",
      failing_checks: [],
      review_comments: [
        "Review COMMENTED: Please make QA_NOTES.md the canonical doc.",
        "Comment: This invalidates the current stack.",
      ],
      actionable: True,
      impacted: True,
    ),
    repo_state.RepoPullRequestSnapshot(
      number: 12,
      title: "Update docs navigation",
      url: "https://example.com/pr/12",
      head_ref_name: "night-shift/child",
      base_ref_name: "night-shift/root",
      review_decision: "",
      failing_checks: [],
      review_comments: [],
      actionable: False,
      impacted: True,
    ),
    repo_state.RepoPullRequestSnapshot(
      number: 13,
      title: "Add references page",
      url: "https://example.com/pr/13",
      head_ref_name: "night-shift/leaf",
      base_ref_name: "night-shift/child",
      review_decision: "",
      failing_checks: [],
      review_comments: [],
      actionable: False,
      impacted: True,
    ),
  ])
}

pub fn start_run(
  repo_root: String,
  brief_path: String,
  provider_name: types.Provider,
  max_workers: Int,
) -> Result(types.RunRecord, String) {
  start_run_in_environment(
    repo_root,
    brief_path,
    provider_name,
    "",
    max_workers,
  )
}

pub fn planned_run(
  repo_root: String,
  brief_path: String,
  provider_name: types.Provider,
  max_workers: Int,
) -> Result(types.RunRecord, String) {
  planned_run_in_environment(
    repo_root,
    brief_path,
    provider_name,
    "",
    max_workers,
  )
}

pub fn start_run_in_environment(
  repo_root: String,
  brief_path: String,
  provider_name: types.Provider,
  environment_name: String,
  max_workers: Int,
) -> Result(types.RunRecord, String) {
  journal.start_run(
    repo_root,
    brief_path,
    agent_for(provider_name),
    agent_for(provider_name),
    environment_name,
    max_workers,
  )
}

pub fn planned_run_in_environment(
  repo_root: String,
  brief_path: String,
  provider_name: types.Provider,
  environment_name: String,
  max_workers: Int,
) -> Result(types.RunRecord, String) {
  use pending_run <- result.try(journal.create_pending_run(
    repo_root,
    brief_path,
    agent_for(provider_name),
    agent_for(provider_name),
    environment_name,
    max_workers,
    None,
  ))
  orchestrator.plan(pending_run)
}

pub fn seed_git_repo(repo_root: String, base_dir: String) -> Nil {
  let _ =
    shell.run(
      "git init --initial-branch=main " <> shell.quote(repo_root),
      base_dir,
      filepath.join(base_dir, "repo-init.log"),
    )
  let _ =
    shell.run(
      "git config user.name 'Night Shift Test'",
      repo_root,
      filepath.join(base_dir, "git-user.log"),
    )
  let _ =
    shell.run(
      "git config user.email 'night-shift@example.com'",
      repo_root,
      filepath.join(base_dir, "git-email.log"),
    )
  let assert Ok(_) =
    simplifile.write("# Demo\n", to: filepath.join(repo_root, "README.md"))
  let _ =
    shell.run(
      "git add README.md && git commit -m 'chore: seed repo'",
      repo_root,
      filepath.join(base_dir, "seed.log"),
    )
  Nil
}

pub fn write_test_worktree_setup(
  path: String,
  setup_commands: List(String),
  maintenance_commands: List(String),
) -> Result(Nil, simplifile.FileError) {
  write_test_worktree_setup_with_preflight(
    path,
    [],
    setup_commands,
    maintenance_commands,
  )
}

pub fn write_test_worktree_setup_with_preflight(
  path: String,
  preflight_commands: List(String),
  setup_commands: List(String),
  maintenance_commands: List(String),
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "version = 1\n"
      <> "default_environment = \"default\"\n\n"
      <> "[environments.default.env]\n\n"
      <> "[environments.default.preflight]\n"
      <> "default = "
      <> render_command_list(preflight_commands)
      <> "\n"
      <> "macos = []\n"
      <> "linux = []\n"
      <> "windows = []\n\n"
      <> "[environments.default.setup]\n"
      <> "default = "
      <> render_command_list(setup_commands)
      <> "\n"
      <> "macos = []\n"
      <> "linux = []\n"
      <> "windows = []\n\n"
      <> "[environments.default.maintenance]\n"
      <> "default = "
      <> render_command_list(maintenance_commands)
      <> "\n"
      <> "macos = []\n"
      <> "linux = []\n"
      <> "windows = []\n",
    to: path,
  )
}

pub fn render_command_list(commands: List(String)) -> String {
  case commands {
    [] -> "[]"
    _ ->
      "["
      <> string.join(
        list.map(commands, fn(command) { "\"" <> command <> "\"" }),
        with: ", ",
      )
      <> "]"
  }
}

pub fn write_fake_provider(path: String) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "PROMPT_FILE=$2\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Implement demo task\",\"description\":\"Create a file to prove execution\",\"dependencies\":[],\"acceptance\":[\"Create IMPLEMENTED.md\"],\"demo_plan\":[\"Show the new file\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  if grep -q 'fail-plan-doc-exit' \"$PROMPT_FILE\"; then\n"
      <> "    printf 'forced failure\\n' >&2\n"
      <> "    exit 1\n"
      <> "  fi\n"
      <> "  if grep -q 'fail-plan-doc-no-marker' \"$PROMPT_FILE\"; then\n"
      <> "    printf 'planning-doc without markers\\n'\n"
      <> "    exit 0\n"
      <> "  fi\n"
      <> "  if grep -q 'fail-plan-doc-empty' \"$PROMPT_FILE\"; then\n"
      <> "    printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "    exit 0\n"
      <> "  fi\n"
      <> "  if grep -q 'Beta task' \"$PROMPT_FILE\"; then\n"
      <> "    grep -q 'Alpha task' \"$PROMPT_FILE\" || exit 1\n"
      <> "    printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nPrepare the combined work for execution.\\n## Scope\\n- Alpha task\\n- Beta task\\n## Constraints\\n- Keep the brief cumulative.\\n## Deliverables\\n- Alpha implementation plan\\n- Beta implementation plan\\n## Acceptance Criteria\\n- Alpha task documented\\n- Beta task documented\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "    exit 0\n"
      <> "  fi\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nPrepare the first work item for execution.\\n## Scope\\n- Alpha task\\n## Constraints\\n- Keep the brief cumulative.\\n## Deliverables\\n- Alpha implementation plan\\n## Acceptance Criteria\\n- Alpha task documented\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "  exit 0\n"
      <> "else\n"
      <> "  echo 'completed by fake provider' > IMPLEMENTED.md\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Implemented demo task\",\"files_touched\":[\"IMPLEMENTED.md\"],\"demo_evidence\":[\"IMPLEMENTED.md created\"],\"pr\":{\"title\":\"[night-shift] Implement demo task\",\"summary\":\"Implemented the fake provider task.\",\"demo\":[\"IMPLEMENTED.md created\"],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_recoverable_execution_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Recoverable task\",\"description\":\"Recover a malformed payload.\",\"dependencies\":[],\"acceptance\":[\"Recover the execution payload.\"],\"demo_plan\":[\"Show the recovered result.\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Recovered demo task\",\"files_touched\":[],\"demo_evidence\":[\"Recovered from trailing junk\"],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[]}}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_absolute_files_touched_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Absolute path task\",\"description\":\"Return absolute paths inside the task worktree.\",\"dependencies\":[],\"acceptance\":[\"Normalize files_touched.\"],\"demo_plan\":[\"Show EXECUTED.txt.\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'executed in worktree\\n' > EXECUTED.txt\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Absolute path demo task\",\"files_touched\":[\"%s/EXECUTED.txt\"],\"demo_evidence\":[\"EXECUTED.txt created\"],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n' \"$(pwd)\"\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_outside_files_touched_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Outside path task\",\"description\":\"Return absolute paths outside the task worktree.\",\"dependencies\":[],\"acceptance\":[\"Reject files_touched.\"],\"demo_plan\":[\"Reject /tmp/outside.txt.\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Outside path demo task\",\"files_touched\":[\"/tmp/outside.txt\"],\"demo_evidence\":[\"Outside path\"],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_recoverable_delivery_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Recoverable delivery task\",\"description\":\"Write a file and return a noisy but recoverable payload.\",\"dependencies\":[],\"acceptance\":[\"Create IMPLEMENTED.md.\"],\"demo_plan\":[\"Show IMPLEMENTED.md.\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'recovered change\\n' > IMPLEMENTED.md\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Recovered delivery task\",\"files_touched\":[\"IMPLEMENTED.md\"],\"demo_evidence\":[\"IMPLEMENTED.md created\"],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[]}}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_invalid_execution_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Invalid result task\",\"description\":\"Return an invalid execution payload.\",\"dependencies\":[],\"acceptance\":[\"Night Shift reports a decode failure.\"],\"demo_plan\":[\"Inspect the task failure.\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Broken payload\",\"files_touched\":[],\"demo_evidence\":[],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_dirty_invalid_execution_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Dirty invalid result task\",\"description\":\"Write a file and then return malformed JSON.\",\"dependencies\":[],\"acceptance\":[\"Night Shift preserves the worktree for inspection.\"],\"demo_plan\":[\"Inspect BROKEN.md in the task worktree.\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'decode fallback\\n' > BROKEN.md\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Broken payload with changes\",\"files_touched\":[\"BROKEN.md\"],\"demo_evidence\":[\"BROKEN.md created\"],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_payload_repair_success_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "PROMPT_FILE=$2\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Payload repair task\",\"description\":\"Write a file and recover from malformed execution JSON.\",\"dependencies\":[],\"acceptance\":[\"Create REPAIRED.md.\"],\"demo_plan\":[\"Show REPAIRED.md.\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif grep -q 'captured task worktree changes' \"$PROMPT_FILE\"; then\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Payload repaired successfully\",\"files_touched\":[\"REPAIRED.md\"],\"demo_evidence\":[\"REPAIRED.md created\"],\"pr\":{\"title\":\"Repair payload task\",\"summary\":\"Keep the repaired documentation update.\",\"demo\":[\"REPAIRED.md created\"],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'payload repair success\\n' > REPAIRED.md\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Broken payload with changes\",\"files_touched\":[\"REPAIRED.md\"],\"demo_evidence\":[\"REPAIRED.md created\"],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_payload_repair_warning_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "PROMPT_FILE=$2\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Payload repair warning task\",\"description\":\"Return recoverable trailing junk during payload repair.\",\"dependencies\":[],\"acceptance\":[\"Create REPAIRED.md.\"],\"demo_plan\":[\"Show REPAIRED.md.\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif grep -q 'captured task worktree changes' \"$PROMPT_FILE\"; then\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Payload repaired with trailing junk\",\"files_touched\":[\"REPAIRED.md\"],\"demo_evidence\":[\"REPAIRED.md created\"],\"pr\":{\"title\":\"Repair payload task\",\"summary\":\"Recovered a noisy payload.\",\"demo\":[\"REPAIRED.md created\"],\"risks\":[]},\"follow_up_tasks\":[]}}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'payload repair warning\\n' > REPAIRED.md\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Broken payload with changes\",\"files_touched\":[\"REPAIRED.md\"],\"demo_evidence\":[\"REPAIRED.md created\"],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_payload_repair_unsafe_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "PROMPT_FILE=$2\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Unsafe payload repair task\",\"description\":\"Return an unsafe repaired path.\",\"dependencies\":[],\"acceptance\":[\"Reject unsafe repaired files_touched.\"],\"demo_plan\":[\"Reject /tmp/outside.txt.\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif grep -q 'captured task worktree changes' \"$PROMPT_FILE\"; then\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Unsafe payload repair\",\"files_touched\":[\"/tmp/outside.txt\"],\"demo_evidence\":[\"Unsafe path\"],\"pr\":{\"title\":\"Unsafe repair\",\"summary\":\"Unsafe path\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'payload repair unsafe\\n' > REPAIRED.md\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Broken payload with changes\",\"files_touched\":[\"REPAIRED.md\"],\"demo_evidence\":[\"REPAIRED.md created\"],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_invalid_follow_up_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Combinators page\",\"description\":\"Create the combinators page and return an invalid follow-up dependency.\",\"dependencies\":[],\"acceptance\":[\"Create docs/wiki/combinators.md\"],\"demo_plan\":[\"Inspect the new docs page.\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  mkdir -p docs/wiki\n"
      <> "  printf '# combinators\\n\\n- guard\\n- at\\n- index\\n- each\\n' > docs/wiki/combinators.md\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Created combinators page\",\"files_touched\":[\"docs/wiki/combinators.md\"],\"demo_evidence\":[\"Created docs/wiki/combinators.md\"],\"pr\":{\"title\":\"Create combinators page\",\"summary\":\"Add the first-pass combinators docs.\",\"demo\":[\"docs/wiki/combinators.md created\"],\"risks\":[]},\"follow_up_tasks\":[{\"id\":\"create-combinators-page-smoke\",\"title\":\"Manual docs render sanity check\",\"description\":\"Verify rendered markdown.\",\"dependencies\":[\"docs/wiki/combinators.md\"],\"acceptance\":[\"Rendered markdown looks correct.\"],\"demo_plan\":[\"Preview the new page.\"],\"decision_requests\":[],\"task_kind\":\"implementation\",\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_invalid_plan_dependency_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"create-wiki-first-pass-pages\",\"title\":\"Create wiki pages\",\"description\":\"Create the first-pass docs pages.\",\"dependencies\":[\"docs/wiki/index.md\"],\"acceptance\":[\"Create the first-pass docs.\"],\"demo_plan\":[\"Inspect the new docs tree.\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"noop\",\"files_touched\":[],\"demo_evidence\":[],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_batch_decode_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "PROMPT_FILE=$2\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"bad-task\",\"title\":\"Bad task\",\"description\":\"Return malformed JSON.\",\"dependencies\":[],\"acceptance\":[\"Night Shift marks this failed.\"],\"demo_plan\":[\"Inspect bad-task.\"],\"execution_mode\":\"parallel\"},{\"id\":\"fail-task\",\"title\":\"Fail task\",\"description\":\"Return a valid failed result.\",\"dependencies\":[],\"acceptance\":[\"Night Shift marks this failed too.\"],\"demo_plan\":[\"Inspect fail-task.\"],\"execution_mode\":\"parallel\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif grep -q 'ID: bad-task' \"$PROMPT_FILE\"; then\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Bad task broke JSON\",\"files_touched\":[],\"demo_evidence\":[],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"failed\",\"summary\":\"Provider intentionally blocked the task.\",\"files_touched\":[],\"demo_evidence\":[],\"pr\":{\"title\":\"t\",\"summary\":\"s\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_partial_delivery_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "PROMPT_FILE=$2\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"alpha-task\",\"title\":\"Alpha task\",\"description\":\"Deliver alpha docs.\",\"dependencies\":[],\"acceptance\":[\"Create ALPHA.md\"],\"demo_plan\":[\"Show ALPHA.md.\"],\"execution_mode\":\"parallel\"},{\"id\":\"beta-task\",\"title\":\"Beta task\",\"description\":\"Deliver beta docs.\",\"dependencies\":[],\"acceptance\":[\"Create BETA.md\"],\"demo_plan\":[\"Show BETA.md.\"],\"execution_mode\":\"parallel\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Brief\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif grep -q 'ID: alpha-task' \"$PROMPT_FILE\"; then\n"
      <> "  printf 'alpha\\n' > ALPHA.md\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Alpha delivered\",\"files_touched\":[\"ALPHA.md\"],\"demo_evidence\":[\"ALPHA.md created\"],\"pr\":{\"title\":\"alpha\",\"summary\":\"alpha\",\"demo\":[\"ALPHA.md created\"],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'beta\\n' > BETA.md\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Beta delivered\",\"files_touched\":[\"BETA.md\"],\"demo_evidence\":[\"BETA.md created\"],\"pr\":{\"title\":\"beta\",\"summary\":\"beta\",\"demo\":[\"BETA.md created\"],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_committing_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "PROMPT_FILE=$2\n"
      <> "WORKTREE=$3\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Implement demo task\",\"description\":\"Create a file to prove execution\",\"dependencies\":[],\"acceptance\":[\"Create IMPLEMENTED.md\"],\"demo_plan\":[\"Show the new file\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nPrepare the first work item for execution.\\n## Scope\\n- Alpha task\\n## Constraints\\n- Keep the brief cumulative.\\n## Deliverables\\n- Alpha implementation plan\\n## Acceptance Criteria\\n- Alpha task documented\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "  exit 0\n"
      <> "else\n"
      <> "  cd \"$WORKTREE\" || exit 1\n"
      <> "  echo 'completed by fake provider' > IMPLEMENTED.md\n"
      <> "  git add IMPLEMENTED.md && git commit -m 'feat: provider created commit' >/dev/null 2>&1 || exit 1\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Implemented demo task\",\"files_touched\":[\"IMPLEMENTED.md\"],\"demo_evidence\":[\"IMPLEMENTED.md created\"],\"pr\":{\"title\":\"[night-shift] Implement demo task\",\"summary\":\"Implemented the fake provider task.\",\"demo\":[\"IMPLEMENTED.md created\"],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_manual_attention_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"confirm-public-docs-structure\",\"title\":\"Confirm docs structure\",\"description\":\"Choose the canonical public docs structure before implementation continues.\",\"dependencies\":[],\"acceptance\":[\"A human confirms the docs structure.\"],\"demo_plan\":[\"Record the chosen structure in the brief.\"],\"task_kind\":\"manual_attention\",\"execution_mode\":\"exclusive\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nConfirm the docs structure.\\n## Scope\\n- Decide the public docs structure.\\n## Constraints\\n- Wait for a human decision before editing code.\\n## Deliverables\\n- A confirmed direction.\\n## Acceptance Criteria\\n- The docs structure is explicitly chosen.\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  printf 'manual-attention execution should not start\\n' >&2\n"
      <> "  exit 1\n"
      <> "fi\n",
    to: path,
  )
}

pub fn write_resolve_loop_fake_provider(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "PROMPT_FILE=$2\n"
      <> "if [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nAdd a first-pass docs wiki.\\n## Scope\\n- Add docs.\\n## Constraints\\n- Keep the work docs-only.\\n## Deliverables\\n- New docs pages\\n## Acceptance Criteria\\n- Docs exist\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  if grep -q 'readme-distribution:' \"$PROMPT_FILE\"; then\n"
      <> "    printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"create-wiki-index-page\",\"title\":\"Create wiki entry point page\",\"description\":\"Create the docs entry page after decisions are settled.\",\"dependencies\":[],\"acceptance\":[\"Create the wiki entry page.\"],\"demo_plan\":[\"Show the new page.\"],\"decision_requests\":[],\"task_kind\":\"implementation\",\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "    exit 0\n"
      <> "  fi\n"
      <> "  if grep -q 'wiki-location:' \"$PROMPT_FILE\"; then\n"
      <> "    printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"decide-docs-scope-and-links\",\"title\":\"Resolve wiki layout and reference decisions\",\"description\":\"Set repository documentation placement and README distribution before writing docs.\",\"dependencies\":[],\"acceptance\":[\"README and wiki scope are chosen.\"],\"demo_plan\":[\"Record the chosen README/wiki split.\"],\"decision_requests\":[{\"key\":\"readme-distribution\",\"question\":\"Which README sections should stay in README vs move or duplicate to the wiki first-pass?\",\"rationale\":\"Night Shift needs one documented content split before it can author the entry pages.\",\"options\":[{\"label\":\"keep-core\",\"description\":\"Keep README short, discovery-focused, and link into the wiki.\"},{\"label\":\"keep-full\",\"description\":\"Keep most reference material in README for now.\"}],\"recommended_option\":\"keep-core\",\"allow_freeform\":false}],\"task_kind\":\"manual_attention\",\"execution_mode\":\"exclusive\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "    exit 0\n"
      <> "  fi\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"decide-docs-scope-and-links\",\"title\":\"Resolve wiki layout and reference decisions\",\"description\":\"Set repository documentation placement before writing docs.\",\"dependencies\":[],\"acceptance\":[\"Primary docs root path is chosen.\"],\"demo_plan\":[\"Record the docs root path.\"],\"decision_requests\":[{\"key\":\"wiki-location\",\"question\":\"Where should the new markdown wiki live?\",\"rationale\":\"All internal links depend on the chosen docs root.\",\"options\":[],\"recommended_option\":\"docs/wiki\",\"allow_freeform\":false}],\"task_kind\":\"manual_attention\",\"execution_mode\":\"exclusive\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"noop\",\"files_touched\":[],\"demo_evidence\":[],\"pr\":{\"title\":\"noop\",\"summary\":\"noop\",\"demo\":[],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n",
    to: path,
  )
}

pub fn write_empty_worktree_setup_codex(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" != \"exec\" ]; then\n"
      <> "  printf 'unexpected codex subcommand: %s\\n' \"$1\" >&2\n"
      <> "  exit 1\n"
      <> "fi\n"
      <> "printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n\\nNIGHT_SHIFT_RESULT_END\\n'\n",
    to: path,
  )
}

pub fn write_fake_codex(path: String) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" != \"exec\" ]; then\n"
      <> "  printf 'unexpected codex subcommand: %s\\n' \"$1\" >&2\n"
      <> "  exit 1\n"
      <> "fi\n"
      <> "shift\n"
      <> "while [ $# -gt 0 ]; do\n"
      <> "  case \"$1\" in\n"
      <> "    --skip-git-repo-check|--dangerously-bypass-approvals-and-sandbox|--json)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "    --color)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    --sandbox)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -C)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -m)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -c)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -)\n"
      <> "      INPUT=$(cat)\n"
      <> "      printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\n'\n"
      <> "      if printf '%s' \"$INPUT\" | grep -q 'add a hello script'; then\n"
      <> "        printf 'Add the hello script.\\n'\n"
      <> "      else\n"
      <> "        printf 'Missing notes.\\n'\n"
      <> "      fi\n"
      <> "      printf '## Scope\\n- Add a hello script.\\n## Constraints\\n- Keep scope tight.\\n## Deliverables\\n- hello script\\n## Acceptance Criteria\\n- script exists\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "      exit 0\n"
      <> "      ;;\n"
      <> "    *)\n"
      <> "      printf 'expected prompt on stdin, got positional argument: %s\\n' \"$1\" >&2\n"
      <> "      exit 7\n"
      <> "      ;;\n"
      <> "  esac\n"
      <> "done\n"
      <> "printf 'missing stdin prompt sentinel\\n' >&2\n"
      <> "exit 8\n",
    to: path,
  )
}

pub fn write_fake_streaming_codex(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" != \"exec\" ]; then\n"
      <> "  printf 'unexpected codex subcommand: %s\\n' \"$1\" >&2\n"
      <> "  exit 1\n"
      <> "fi\n"
      <> "shift\n"
      <> "while [ $# -gt 0 ]; do\n"
      <> "  case \"$1\" in\n"
      <> "    --skip-git-repo-check|--dangerously-bypass-approvals-and-sandbox|--json)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "    --color|--sandbox|-C)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -)\n"
      <> "      INPUT=$(cat)\n"
      <> "      if printf '%s' \"$INPUT\" | grep -q 'cumulative Night Shift brief'; then\n"
      <> "        printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"brief\"}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nPolish the harness streaming UI.\\n## Scope\\n- Replace raw line dumps with formatted stream output.\\n## Constraints\\n- Keep raw artifacts for debugging.\\n## Deliverables\\n- Improved stream presentation\\n## Acceptance Criteria\\n- Prompt is hidden in the live stream.\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "        exit 0\n"
      <> "      fi\n"
      <> "      if printf '%s' \"$INPUT\" | grep -q 'Break the supplied brief into a task DAG.'; then\n"
      <> "        printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"planner\"}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n{\\\"tasks\\\":[{\\\"id\\\":\\\"alpha\\\",\\\"title\\\":\\\"Alpha task\\\",\\\"description\\\":\\\"Create alpha proof\\\",\\\"dependencies\\\":[],\\\"acceptance\\\":[\\\"Create ALPHA.txt\\\"],\\\"demo_plan\\\":[\\\"Show ALPHA.txt\\\"],\\\"execution_mode\\\":\\\"parallel\\\"},{\\\"id\\\":\\\"beta\\\",\\\"title\\\":\\\"Beta task\\\",\\\"description\\\":\\\"Create beta proof\\\",\\\"dependencies\\\":[],\\\"acceptance\\\":[\\\"Create BETA.txt\\\"],\\\"demo_plan\\\":[\\\"Show BETA.txt\\\"],\\\"execution_mode\\\":\\\"parallel\\\"}]}\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "        exit 0\n"
      <> "      fi\n"
      <> "      if printf '%s' \"$INPUT\" | grep -q 'ID: alpha'; then\n"
      <> "        printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"alpha\"}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.started\",\"item\":{\"id\":\"item_1\",\"type\":\"command_execution\",\"command\":\"echo alpha > ALPHA.txt\",\"aggregated_output\":\"\",\"exit_code\":null,\"status\":\"in_progress\"}}'\n"
      <> "        sleep 0.1\n"
      <> "        printf 'alpha\\n' > ALPHA.txt\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_1\",\"type\":\"command_execution\",\"command\":\"echo alpha > ALPHA.txt\",\"aggregated_output\":\"alpha\\n\",\"exit_code\":0,\"status\":\"completed\"}}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_2\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n{\\\"status\\\":\\\"completed\\\",\\\"summary\\\":\\\"alpha ok\\\",\\\"files_touched\\\":[\\\"ALPHA.txt\\\"],\\\"demo_evidence\\\":[\\\"ALPHA.txt created\\\"],\\\"pr\\\":{\\\"title\\\":\\\"alpha\\\",\\\"summary\\\":\\\"alpha\\\",\\\"demo\\\":[\\\"ALPHA.txt created\\\"],\\\"risks\\\":[]},\\\"follow_up_tasks\\\":[]}\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "        exit 0\n"
      <> "      fi\n"
      <> "      if printf '%s' \"$INPUT\" | grep -q 'ID: beta'; then\n"
      <> "        printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"beta\"}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.started\",\"item\":{\"id\":\"item_1\",\"type\":\"command_execution\",\"command\":\"echo beta > BETA.txt\",\"aggregated_output\":\"\",\"exit_code\":null,\"status\":\"in_progress\"}}'\n"
      <> "        sleep 0.1\n"
      <> "        printf 'beta\\n' > BETA.txt\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_1\",\"type\":\"command_execution\",\"command\":\"echo beta > BETA.txt\",\"aggregated_output\":\"beta\\n\",\"exit_code\":0,\"status\":\"completed\"}}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_2\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n{\\\"status\\\":\\\"completed\\\",\\\"summary\\\":\\\"beta ok\\\",\\\"files_touched\\\":[\\\"BETA.txt\\\"],\\\"demo_evidence\\\":[\\\"BETA.txt created\\\"],\\\"pr\\\":{\\\"title\\\":\\\"beta\\\",\\\"summary\\\":\\\"beta\\\",\\\"demo\\\":[\\\"BETA.txt created\\\"],\\\"risks\\\":[]},\\\"follow_up_tasks\\\":[]}\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "        exit 0\n"
      <> "      fi\n"
      <> "      printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"fallback\"}'\n"
      <> "      printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n{\\\"status\\\":\\\"completed\\\",\\\"summary\\\":\\\"ok\\\",\\\"files_touched\\\":[],\\\"demo_evidence\\\":[],\\\"pr\\\":{\\\"title\\\":\\\"t\\\",\\\"summary\\\":\\\"s\\\",\\\"demo\\\":[],\\\"risks\\\":[]},\\\"follow_up_tasks\\\":[]}\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "      exit 0\n"
      <> "      ;;\n"
      <> "    *)\n"
      <> "      printf 'expected prompt on stdin, got positional argument: %s\\n' \"$1\" >&2\n"
      <> "      exit 7\n"
      <> "      ;;\n"
      <> "  esac\n"
      <> "done\n"
      <> "printf 'missing stdin prompt sentinel\\n' >&2\n"
      <> "exit 8\n",
    to: path,
  )
}

pub fn write_fake_streaming_utf8_codex(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  let long_output = repeat_text("a", 156) <> "\\u2014tail\\n"

  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" != \"exec\" ]; then\n"
      <> "  printf 'unexpected codex subcommand: %s\\n' \"$1\" >&2\n"
      <> "  exit 1\n"
      <> "fi\n"
      <> "shift\n"
      <> "while [ $# -gt 0 ]; do\n"
      <> "  case \"$1\" in\n"
      <> "    --skip-git-repo-check|--dangerously-bypass-approvals-and-sandbox|--json)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "    --color|--sandbox|-C|-m|-c)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -)\n"
      <> "      INPUT=$(cat)\n"
      <> "      if printf '%s' \"$INPUT\" | grep -q 'Break the supplied brief into a task DAG.'; then\n"
      <> "        printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"planner\"}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n{\\\"tasks\\\":[{\\\"id\\\":\\\"alpha\\\",\\\"title\\\":\\\"Alpha task\\\",\\\"description\\\":\\\"Create alpha proof\\\",\\\"dependencies\\\":[],\\\"acceptance\\\":[\\\"Create ALPHA.txt\\\"],\\\"demo_plan\\\":[\\\"Show ALPHA.txt\\\"],\\\"execution_mode\\\":\\\"serial\\\"}]}\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "        exit 0\n"
      <> "      else\n"
      <> "        printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"brief\"}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"Checking the docs surface before returning the brief.\"}}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_1\",\"type\":\"command_execution\",\"command\":\"sed -n '\\''320,420p'\\'' README.md\",\"aggregated_output\":\""
      <> long_output
      <> "\",\"exit_code\":0,\"status\":\"completed\"}}'\n"
      <> "        printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_2\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nAdd the hello script.\\n## Scope\\n- Add a hello script.\\n## Constraints\\n- Keep scope tight.\\n## Deliverables\\n- hello script\\n## Acceptance Criteria\\n- script exists\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "        exit 0\n"
      <> "      fi\n"
      <> "      printf 'unexpected prompt\\n' >&2\n"
      <> "      exit 9\n"
      <> "      ;;\n"
      <> "    *)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "  esac\n"
      <> "done\n"
      <> "printf 'missing stdin prompt sentinel\\n' >&2\n"
      <> "exit 8\n",
    to: path,
  )
}

pub fn repeat_text(value: String, count: Int) -> String {
  case count <= 0 {
    True -> ""
    False -> value <> repeat_text(value, count - 1)
  }
}

pub fn write_worktree_execution_codex(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" != \"exec\" ]; then\n"
      <> "  printf 'unexpected codex subcommand: %s\\n' \"$1\" >&2\n"
      <> "  exit 1\n"
      <> "fi\n"
      <> "shift\n"
      <> "TARGET_DIR=''\n"
      <> "while [ $# -gt 0 ]; do\n"
      <> "  case \"$1\" in\n"
      <> "    --skip-git-repo-check|--dangerously-bypass-approvals-and-sandbox|--json)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "    --color|-m)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -c)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -C)\n"
      <> "      TARGET_DIR=$2\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -)\n"
      <> "      INPUT=$(cat)\n"
      <> "      cd /tmp || exit 1\n"
      <> "      if [ -n \"$TARGET_DIR\" ]; then\n"
      <> "        cd \"$TARGET_DIR\" || exit 1\n"
      <> "      fi\n"
      <> "      printf 'executed in worktree\\n' > EXECUTED.txt\n"
      <> "      printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"exec\"}'\n"
      <> "      printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"NIGHT_SHIFT_RESULT_START\\n{\\\"status\\\":\\\"completed\\\",\\\"summary\\\":\\\"ok\\\",\\\"files_touched\\\":[\\\"EXECUTED.txt\\\"],\\\"demo_evidence\\\":[\\\"EXECUTED.txt created\\\"],\\\"pr\\\":{\\\"title\\\":\\\"t\\\",\\\"summary\\\":\\\"s\\\",\\\"demo\\\":[],\\\"risks\\\":[]},\\\"follow_up_tasks\\\":[]}\\nNIGHT_SHIFT_RESULT_END\"}}'\n"
      <> "      exit 0\n"
      <> "      ;;\n"
      <> "    *)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "  esac\n"
      <> "done\n"
      <> "printf 'missing stdin prompt sentinel\\n' >&2\n"
      <> "exit 8\n",
    to: path,
  )
}

pub fn write_large_streaming_codex(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" != \"exec\" ]; then\n"
      <> "  printf 'unexpected codex subcommand: %s\\n' \"$1\" >&2\n"
      <> "  exit 1\n"
      <> "fi\n"
      <> "shift\n"
      <> "while [ $# -gt 0 ]; do\n"
      <> "  case \"$1\" in\n"
      <> "    --skip-git-repo-check|--dangerously-bypass-approvals-and-sandbox|--json)\n"
      <> "      shift\n"
      <> "      ;;\n"
      <> "    --color|--sandbox|-C)\n"
      <> "      shift 2\n"
      <> "      ;;\n"
      <> "    -)\n"
      <> "      python3 - <<'PY'\n"
      <> "import json, sys\n"
      <> "sys.stdin.read()\n"
      <> "large_block = 'A' * 17050\n"
      <> "brief = '# Night Shift Brief\\n## Objective\\nLarge streaming payload\\n## Scope\\n- ' + large_block + '\\n## Constraints\\n- Keep structured mode active.\\n## Deliverables\\n- Large line preserved\\n## Acceptance Criteria\\n- Full payload parsed\\n## Risks and Open Questions\\n- None.'\n"
      <> "print(json.dumps({\"type\": \"thread.started\", \"thread_id\": \"large\"}))\n"
      <> "print(json.dumps({\"type\": \"item.completed\", \"item\": {\"id\": \"item_0\", \"type\": \"agent_message\", \"text\": 'NIGHT_SHIFT_RESULT_START\\n' + brief + '\\nNIGHT_SHIFT_RESULT_END'}}))\n"
      <> "PY\n"
      <> "      exit 0\n"
      <> "      ;;\n"
      <> "    *)\n"
      <> "      printf 'expected prompt on stdin, got positional argument: %s\\n' \"$1\" >&2\n"
      <> "      exit 7\n"
      <> "      ;;\n"
      <> "  esac\n"
      <> "done\n"
      <> "printf 'missing stdin prompt sentinel\\n' >&2\n"
      <> "exit 8\n",
    to: path,
  )
}

pub fn restore_env(name: String, value: String) -> Nil {
  case value {
    "" -> system.unset_env(name)
    _ -> system.set_env(name, value)
  }
}

pub fn wait_for_run_payload(
  base_url: String,
  run_id: String,
  attempts: Int,
) -> String {
  let url = base_url <> "/api/runs/" <> run_id
  case attempts {
    value if value <= 0 ->
      dashboard.http_get(url)
      |> result.unwrap(or: "Unable to fetch dashboard payload.")
    _ ->
      case dashboard.http_get(url) {
        Ok(payload) ->
          case
            string.contains(does: payload, contain: "\"status\":\"completed\"")
          {
            True -> payload
            False -> {
              system.sleep(150)
              wait_for_run_payload(base_url, run_id, attempts - 1)
            }
          }
        Error(_) -> {
          system.sleep(150)
          wait_for_run_payload(base_url, run_id, attempts - 1)
        }
      }
  }
}

pub fn write_fake_gh(path: String) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"list\" ]; then\n"
      <> "  BRANCH=$(git rev-parse --abbrev-ref HEAD)\n"
      <> "  printf '[{\"number\":1,\"url\":\"https://example.test/pr/1\",\"headRefName\":\"%s\",\"title\":\"Night Shift PR\"}]\\n' \"$BRANCH\"\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"edit\" ]; then\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"create\" ]; then\n"
      <> "  printf 'https://example.test/pr/1\\n'\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"view\" ]; then\n"
      <> "  printf '{\"number\":1,\"title\":\"Night Shift PR\",\"body\":\"Review body\",\"headRefName\":\"night-shift/demo\",\"baseRefName\":\"main\",\"url\":\"https://example.test/pr/1\",\"reviewDecision\":\"REVIEW_REQUIRED\",\"statusCheckRollup\":[],\"reviews\":[],\"comments\":[]}'\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "printf 'unsupported gh invocation: %s %s\\n' \"$1\" \"$2\" >&2\n"
      <> "exit 1\n",
    to: path,
  )
}

pub fn write_supersession_fake_gh(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"comment\" ]; then\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"close\" ]; then\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "printf 'unsupported gh invocation: %s %s\\n' \"$1\" \"$2\" >&2\n"
      <> "exit 1\n",
    to: path,
  )
}

pub fn write_review_fake_gh(path: String) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"list\" ]; then\n"
      <> "  printf '[{\"number\":1,\"url\":\"https://example.test/pr/1\",\"headRefName\":\"night-shift/demo\",\"title\":\"Night Shift PR\"}]\\n'\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"edit\" ]; then\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"view\" ]; then\n"
      <> "  printf '{\"number\":1,\"title\":\"Night Shift PR\",\"body\":\"Review body\",\"headRefName\":\"night-shift/demo\",\"baseRefName\":\"main\",\"url\":\"https://example.test/pr/1\",\"reviewDecision\":\"REVIEW_REQUIRED\",\"statusCheckRollup\":[],\"reviews\":[{\"state\":\"COMMENTED\",\"body\":\"Please make the note a little more specific.\"}],\"comments\":[]}'\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "printf 'unsupported gh invocation: %s %s\\n' \"$1\" \"$2\" >&2\n"
      <> "exit 1\n",
    to: path,
  )
}

pub fn write_delayed_listing_fake_gh(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"list\" ]; then\n"
      <> "  printf '[]\\n'\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"create\" ]; then\n"
      <> "  printf 'https://example.test/pr/42\\n'\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "printf 'unsupported gh invocation: %s %s\\n' \"$1\" \"$2\" >&2\n"
      <> "exit 1\n",
    to: path,
  )
}

pub fn write_branch_sensitive_fake_gh(
  path: String,
) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"list\" ]; then\n"
      <> "  printf '[]\\n'\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"edit\" ]; then\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"create\" ]; then\n"
      <> "  BRANCH=''\n"
      <> "  shift 2\n"
      <> "  while [ $# -gt 0 ]; do\n"
      <> "    case \"$1\" in\n"
      <> "      --head)\n"
      <> "        BRANCH=$2\n"
      <> "        shift 2\n"
      <> "        ;;\n"
      <> "      *)\n"
      <> "        shift\n"
      <> "        ;;\n"
      <> "    esac\n"
      <> "  done\n"
      <> "  case \"$BRANCH\" in\n"
      <> "    *alpha-task)\n"
      <> "      printf 'https://example.test/pr/1\\n'\n"
      <> "      exit 0\n"
      <> "      ;;\n"
      <> "    *beta-task)\n"
      <> "      printf 'simulated PR delivery failure for %s\\n' \"$BRANCH\" >&2\n"
      <> "      exit 1\n"
      <> "      ;;\n"
      <> "  esac\n"
      <> "fi\n"
      <> "printf 'unsupported gh invocation: %s %s\\n' \"$1\" \"$2\" >&2\n"
      <> "exit 1\n",
    to: path,
  )
}

pub fn write_handoff_fake_gh(path: String) -> Result(Nil, simplifile.FileError) {
  simplifile.write(
    "#!/bin/sh\n"
      <> "BODY_FILE=\"$0.body.txt\"\n"
      <> "COMMENT_FILE=\"$0.comment.txt\"\n"
      <> "COMMENT_PAGES_FILE=\"$0.comment-pages.json\"\n"
      <> "if [ ! -f \"$BODY_FILE\" ]; then\n"
      <> "  printf 'Legacy body\\n' > \"$BODY_FILE\"\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"list\" ]; then\n"
      <> "  BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'night-shift/demo')\n"
      <> "  printf '[{\"number\":1,\"url\":\"https://example.test/pr/1\",\"headRefName\":\"%s\",\"title\":\"Night Shift PR\"}]\\n' \"$BRANCH\"\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"view\" ]; then\n"
      <> "  if [ \"$4\" = \"--json\" ] && [ \"$5\" = \"body\" ]; then\n"
      <> "    python3 - <<'PY' \"$BODY_FILE\"\n"
      <> "import json, sys\n"
      <> "body = open(sys.argv[1]).read()\n"
      <> "print(json.dumps({'body': body}))\n"
      <> "PY\n"
      <> "    exit 0\n"
      <> "  fi\n"
      <> "  printf '{\"number\":1,\"title\":\"Night Shift PR\",\"body\":\"Review body\",\"headRefName\":\"night-shift/demo\",\"baseRefName\":\"main\",\"url\":\"https://example.test/pr/1\",\"reviewDecision\":\"REVIEW_REQUIRED\",\"statusCheckRollup\":[],\"reviews\":[],\"comments\":[]}'\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"edit\" ]; then\n"
      <> "  shift 2\n"
      <> "  while [ $# -gt 0 ]; do\n"
      <> "    case \"$1\" in\n"
      <> "      --body-file)\n"
      <> "        cp \"$2\" \"$BODY_FILE\"\n"
      <> "        shift 2\n"
      <> "        ;;\n"
      <> "      *)\n"
      <> "        shift\n"
      <> "        ;;\n"
      <> "    esac\n"
      <> "  done\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "if [ \"$1\" = \"api\" ]; then\n"
      <> "  PATH_ARG=$2\n"
      <> "  METHOD=GET\n"
      <> "  BODY=''\n"
      <> "  shift 2\n"
      <> "  while [ $# -gt 0 ]; do\n"
      <> "    case \"$1\" in\n"
      <> "      --method)\n"
      <> "        METHOD=$2\n"
      <> "        shift 2\n"
      <> "        ;;\n"
      <> "      --raw-field)\n"
      <> "        BODY=${2#body=}\n"
      <> "        shift 2\n"
      <> "        ;;\n"
      <> "      *)\n"
      <> "        shift\n"
      <> "        ;;\n"
      <> "    esac\n"
      <> "  done\n"
      <> "  case \"$METHOD:$PATH_ARG\" in\n"
      <> "    GET:repos/:owner/:repo/issues/1/comments*)\n"
      <> "      python3 - <<'PY' \"$COMMENT_FILE\" \"$COMMENT_PAGES_FILE\" \"$PATH_ARG\"\n"
      <> "import json, os, sys, urllib.parse\n"
      <> "comment_path, pages_path, path_arg = sys.argv[1:4]\n"
      <> "parsed = urllib.parse.urlparse('https://example.test/' + path_arg)\n"
      <> "page = urllib.parse.parse_qs(parsed.query).get('page', ['1'])[0]\n"
      <> "if os.path.exists(pages_path):\n"
      <> "    pages = json.load(open(pages_path))\n"
      <> "    print(json.dumps(pages.get(page, [])))\n"
      <> "elif not os.path.exists(comment_path):\n"
      <> "    print('[]')\n"
      <> "else:\n"
      <> "    body = open(comment_path).read()\n"
      <> "    print(json.dumps([{'id': 1, 'body': body}]))\n"
      <> "PY\n"
      <> "      exit 0\n"
      <> "      ;;\n"
      <> "    POST:repos/:owner/:repo/issues/1/comments)\n"
      <> "      printf '%s' \"$BODY\" > \"$COMMENT_FILE\"\n"
      <> "      exit 0\n"
      <> "      ;;\n"
      <> "    PATCH:repos/:owner/:repo/issues/comments/*)\n"
      <> "      printf '%s' \"$BODY\" > \"$COMMENT_FILE\"\n"
      <> "      exit 0\n"
      <> "      ;;\n"
      <> "  esac\n"
      <> "fi\n"
      <> "printf 'unsupported gh invocation: %s %s\\n' \"$1\" \"$2\" >&2\n"
      <> "exit 1\n",
    to: path,
  )
}
