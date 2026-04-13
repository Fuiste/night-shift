import filepath
import gleam/list
import gleam/result
import gleam/string
import night_shift/dashboard
import night_shift/project
import night_shift/shell
import night_shift/system
import simplifile

pub fn run(ui_enabled: Bool) -> Result(String, String) {
  let host_state_dir = stable_demo_state_root()
  let demo_root = filepath.join(host_state_dir, "night-shift-demo")
  let repo_root = filepath.join(demo_root, "repo")
  let remote_root = filepath.join(demo_root, "remote.git")
  let bin_dir = filepath.join(demo_root, "bin")
  let brief_path = project.default_brief_path(repo_root)
  let fake_provider = filepath.join(bin_dir, "fake-provider")
  let fake_gh = filepath.join(bin_dir, "gh")
  let demo_state_home = filepath.join(demo_root, "state")
  let old_path = system.get_env("PATH")
  let old_gh_bin = system.get_env("NIGHT_SHIFT_GH_BIN")
  let old_fake_provider = system.get_env("NIGHT_SHIFT_FAKE_PROVIDER")
  let old_demo_command = system.get_env("NIGHT_SHIFT_DEMO_COMMAND")
  let old_state_home = system.get_env("XDG_STATE_HOME")
  let old_repo_override = system.get_env("NIGHT_SHIFT_REPO_ROOT")

  use _ <- result.try(create_directory(host_state_dir))
  use _ <- result.try(reset_demo_root(host_state_dir, demo_root))

  use _ <- result.try(setup_demo_environment(
    demo_root: demo_root,
    repo_root: repo_root,
    remote_root: remote_root,
    bin_dir: bin_dir,
    brief_path: brief_path,
    fake_provider: fake_provider,
    fake_gh: fake_gh,
  ))

  system.set_env("NIGHT_SHIFT_FAKE_PROVIDER", fake_provider)
  system.set_env("PATH", bin_dir <> ":" <> old_path)
  system.set_env("NIGHT_SHIFT_GH_BIN", fake_gh)
  system.set_env("XDG_STATE_HOME", demo_state_home)
  system.set_env("NIGHT_SHIFT_REPO_ROOT", repo_root)

  let outcome = case ui_enabled {
    True -> run_ui_demo(repo_root, demo_root)
    False -> run_headless_demo(repo_root, demo_root)
  }

  restore_env("PATH", old_path)
  restore_env("NIGHT_SHIFT_GH_BIN", old_gh_bin)
  restore_env("NIGHT_SHIFT_FAKE_PROVIDER", old_fake_provider)
  restore_env("NIGHT_SHIFT_DEMO_COMMAND", old_demo_command)
  restore_env("XDG_STATE_HOME", old_state_home)
  restore_env("NIGHT_SHIFT_REPO_ROOT", old_repo_override)
  outcome
}

pub fn demo_root() -> String {
  filepath.join(stable_demo_state_root(), "night-shift-demo")
}

fn stable_demo_state_root() -> String {
  filepath.join(system.home_directory(), ".local/state")
}

fn run_headless_demo(
  repo_root: String,
  demo_root: String,
) -> Result(String, String) {
  use _plan_output <- result.try(run_cli_command(
    ["plan", "--notes", "Implement the demo task with a proof file."],
    repo_root,
    filepath.join(demo_root, "headless-plan.log"),
    "Headless demo failed while running `plan`.",
  ))

  use _start_output <- result.try(run_cli_command(
    ["start"],
    repo_root,
    filepath.join(demo_root, "headless-start.log"),
    "Headless demo failed while running `start`.",
  ))

  use _status_output <- result.try(wait_for_completed_status(
    repo_root,
    filepath.join(demo_root, "headless-status.log"),
    20,
    "Headless demo failed while waiting for `status` to show a completed run.",
  ))

  use report_output <- result.try(run_cli_command(
    ["report"],
    repo_root,
    filepath.join(demo_root, "headless-report.log"),
    "Headless demo failed while running `report`.",
  ))
  use _ <- result.try(assert_contains(
    report_output,
    "Night Shift Report",
    "Headless demo report flow did not render the report.",
  ))
  use _ <- result.try(assert_contains(
    report_output,
    "- Status: completed",
    "Headless demo report did not show a completed run.",
  ))
  use _ <- result.try(assert_contains(
    report_output,
    "Implement demo task",
    "Headless demo report did not include the fixture task entry.",
  ))

  Ok(
    "Demo succeeded.\n"
    <> "Validated CLI flows: plan, start, status, report\n"
    <> "Proof file: "
    <> filepath.join(repo_root, "IMPLEMENTED.md")
    <> "\n"
    <> "Artifacts: "
    <> demo_root
    <> "\n"
    <> "Logs: "
    <> filepath.join(demo_root, "headless-plan.log")
    <> ", "
    <> filepath.join(demo_root, "headless-start.log")
    <> ", "
    <> filepath.join(demo_root, "headless-status.log")
    <> ", "
    <> filepath.join(demo_root, "headless-report.log"),
  )
}

fn run_ui_demo(repo_root: String, demo_root: String) -> Result(String, String) {
  let log_path = filepath.join(demo_root, "ui-start.log")
  let pid_path = filepath.join(demo_root, "ui-start.pid")

  use _plan_output <- result.try(run_cli_command(
    ["plan", "--notes", "Implement the demo task with a proof file."],
    repo_root,
    filepath.join(demo_root, "ui-plan.log"),
    "UI demo failed while running `plan`.",
  ))
  use _ <- result.try(start_ui_command(repo_root, demo_root, log_path, pid_path))
  use #(url, run_id) <- result.try(wait_for_ui_details(log_path, 40))
  use payload <- result.try(wait_for_completed_dashboard_payload(
    url,
    run_id,
    40,
  ))
  use _ <- result.try(stop_ui_command(demo_root, pid_path))
  use _ <- result.try(assert_contains(
    payload,
    "\"status\":\"completed\"",
    "UI demo dashboard never showed a completed run.",
  ))
  use _ <- result.try(assert_contains(
    payload,
    "\"pr_number\":\"1\"",
    "UI demo dashboard never showed the delivered PR.",
  ))

  let status_output =
    wait_for_completed_status(
      repo_root,
      filepath.join(demo_root, "ui-status.log"),
      20,
      "UI demo failed while waiting for `status` to show a completed run after dashboard validation.",
    )

  case status_output {
    Ok(output) ->
      assert_contains(
        output,
        " is completed",
        "UI demo status flow did not report a completed run after validation.",
      )
    Error(message) -> Error(message)
  }
  |> result.map(fn(_) {
    "Demo succeeded.\n"
    <> "Validated UI flows: plan, start --ui, dashboard payload, status\n"
    <> "Dashboard: "
    <> url
    <> "\n"
    <> "Run: "
    <> run_id
    <> "\n"
    <> "Proof file: "
    <> filepath.join(repo_root, "IMPLEMENTED.md")
    <> "\n"
    <> "Artifacts: "
    <> demo_root
    <> "\n"
    <> "Logs: "
    <> filepath.join(demo_root, "ui-plan.log")
    <> ", "
    <> log_path
    <> ", "
    <> filepath.join(demo_root, "ui-status.log")
  })
}

fn setup_demo_environment(
  demo_root demo_root: String,
  repo_root repo_root: String,
  remote_root remote_root: String,
  bin_dir bin_dir: String,
  brief_path brief_path: String,
  fake_provider fake_provider: String,
  fake_gh fake_gh: String,
) -> Result(Nil, String) {
  use _ <- result.try(create_directory(demo_root))
  use _ <- result.try(create_directory(bin_dir))
  use _ <- result.try(create_directory(filepath.join(demo_root, "state")))
  use _ <- result.try(write_fake_provider(fake_provider))
  use _ <- result.try(write_fake_gh(fake_gh))
  use _ <- result.try(run_checked(
    "chmod +x " <> shell.quote(fake_provider) <> " " <> shell.quote(fake_gh),
    demo_root,
    filepath.join(demo_root, "chmod.log"),
    "Unable to make demo fixtures executable.",
  ))
  use _ <- result.try(run_checked(
    "git init --bare " <> shell.quote(remote_root),
    demo_root,
    filepath.join(demo_root, "remote.log"),
    "Unable to initialize the demo remote.",
  ))
  use _ <- result.try(run_checked(
    "git init --initial-branch=main " <> shell.quote(repo_root),
    demo_root,
    filepath.join(demo_root, "repo-init.log"),
    "Unable to initialize the demo repository.",
  ))
  use _ <- result.try(run_checked(
    "git config user.name 'Night Shift Demo'",
    repo_root,
    filepath.join(demo_root, "git-user.log"),
    "Unable to configure the demo git user.",
  ))
  use _ <- result.try(run_checked(
    "git config user.email 'night-shift-demo@example.com'",
    repo_root,
    filepath.join(demo_root, "git-email.log"),
    "Unable to configure the demo git email.",
  ))
  use _ <- result.try(create_directory(project.home(repo_root)))
  use _ <- result.try(write_file(brief_path, "# Demo\n"))
  use _ <- result.try(write_file(project.config_path(repo_root), ""))
  use _ <- result.try(write_file(
    project.gitignore_path(repo_root),
    "*\n!config.toml\n!worktree-setup.toml\n!.gitignore\n",
  ))
  use _ <- result.try(write_file(
    filepath.join(repo_root, "README.md"),
    "# Demo\n",
  ))
  use _ <- result.try(run_checked(
    "git add README.md .night-shift && git commit -m 'chore: seed demo repo'",
    repo_root,
    filepath.join(demo_root, "seed.log"),
    "Unable to create the demo seed commit.",
  ))
  use _ <- result.try(run_checked(
    "git remote add origin " <> shell.quote(remote_root),
    repo_root,
    filepath.join(demo_root, "remote-add.log"),
    "Unable to connect the demo remote.",
  ))
  run_checked(
    "git push -u origin main",
    repo_root,
    filepath.join(demo_root, "push-main.log"),
    "Unable to push the demo base branch.",
  )
}

fn run_cli_command(
  args: List(String),
  cwd: String,
  log_path: String,
  error_message: String,
) -> Result(String, String) {
  let command = build_cli_command(args)
  let command_result = shell.run(command, cwd, log_path)
  case shell.succeeded(command_result) {
    True -> Ok(command_result.output)
    False -> Error(error_message <> " See " <> log_path <> ".")
  }
}

fn start_ui_command(
  repo_root: String,
  demo_root: String,
  log_path: String,
  pid_path: String,
) -> Result(Nil, String) {
  let command =
    "nohup "
    <> build_cli_command(["start", "--ui"])
    <> " > "
    <> shell.quote(log_path)
    <> " 2>&1 & echo $! > "
    <> shell.quote(pid_path)

  run_checked(
    command,
    repo_root,
    filepath.join(demo_root, "ui-launch.log"),
    "Unable to launch the UI demo command.",
  )
}

fn stop_ui_command(demo_root: String, pid_path: String) -> Result(Nil, String) {
  run_checked(
    "kill $(cat " <> shell.quote(pid_path) <> ")",
    demo_root,
    filepath.join(demo_root, "ui-stop.log"),
    "Unable to stop the UI demo command.",
  )
}

fn wait_for_ui_details(
  log_path: String,
  attempts: Int,
) -> Result(#(String, String), String) {
  case attempts {
    value if value <= 0 ->
      Error("UI demo did not publish a dashboard URL in time.")
    _ ->
      case simplifile.read(log_path) {
        Ok(contents) ->
          case
            extract_prefixed_line(contents, "Dashboard: "),
            extract_prefixed_line(contents, "Run: ")
          {
            Ok(url), Ok(run_id) -> Ok(#(url, run_id))
            _, _ -> {
              system.sleep(150)
              wait_for_ui_details(log_path, attempts - 1)
            }
          }
        Error(_) -> {
          system.sleep(150)
          wait_for_ui_details(log_path, attempts - 1)
        }
      }
  }
}

fn wait_for_completed_status(
  repo_root: String,
  log_path: String,
  attempts: Int,
  error_message: String,
) -> Result(String, String) {
  let status_output =
    run_cli_command(["status"], repo_root, log_path, error_message)

  case status_output {
    Ok(output) ->
      case string.contains(does: output, contain: " is completed") {
        True -> Ok(output)
        False ->
          case attempts <= 0 {
            True -> Error(error_message)
            False -> {
              system.sleep(150)
              wait_for_completed_status(
                repo_root,
                log_path,
                attempts - 1,
                error_message,
              )
            }
          }
      }
    Error(message) ->
      case attempts <= 0 {
        True -> Error(message)
        False -> {
          system.sleep(150)
          wait_for_completed_status(
            repo_root,
            log_path,
            attempts - 1,
            error_message,
          )
        }
      }
  }
}

fn wait_for_completed_dashboard_payload(
  url: String,
  run_id: String,
  attempts: Int,
) -> Result(String, String) {
  let endpoint = url <> "/api/runs/" <> run_id
  case attempts {
    value if value <= 0 ->
      Error("UI demo dashboard never reached a completed state.")
    _ ->
      case dashboard.http_get(endpoint) {
        Ok(payload) ->
          case
            string.contains(does: payload, contain: "\"status\":\"completed\"")
          {
            True -> Ok(payload)
            False -> {
              system.sleep(150)
              wait_for_completed_dashboard_payload(url, run_id, attempts - 1)
            }
          }
        Error(_) -> {
          system.sleep(150)
          wait_for_completed_dashboard_payload(url, run_id, attempts - 1)
        }
      }
  }
}

fn extract_prefixed_line(
  contents: String,
  prefix: String,
) -> Result(String, Nil) {
  contents
  |> string.trim
  |> string.split("\n")
  |> find_prefixed_line(prefix)
}

fn find_prefixed_line(
  lines: List(String),
  prefix: String,
) -> Result(String, Nil) {
  case lines {
    [] -> Error(Nil)
    [line, ..rest] ->
      case string.starts_with(line, prefix) {
        True -> Ok(string.drop_start(line, string.length(prefix)))
        False -> find_prefixed_line(rest, prefix)
      }
  }
}

fn build_cli_command(args: List(String)) -> String {
  let base = case system.get_env("NIGHT_SHIFT_DEMO_COMMAND") {
    "" -> "night-shift"
    command -> command
  }

  base
  <> " "
  <> {
    args
    |> list.map(shell.quote)
    |> string.join(with: " ")
  }
}

fn assert_contains(
  output: String,
  expected: String,
  message: String,
) -> Result(Nil, String) {
  case string.contains(does: output, contain: expected) {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

fn restore_env(name: String, value: String) -> Nil {
  case value {
    "" -> system.unset_env(name)
    _ -> system.set_env(name, value)
  }
}

fn create_directory(path: String) -> Result(Nil, String) {
  case simplifile.create_directory_all(path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to create directory "
        <> path
        <> ": "
        <> simplifile.describe_error(error),
      )
  }
}

fn write_file(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.write(contents, to: path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to write " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}

fn run_checked(
  command: String,
  cwd: String,
  log_path: String,
  error_message: String,
) -> Result(Nil, String) {
  let command_result = shell.run(command, cwd, log_path)
  case shell.succeeded(command_result) {
    True -> Ok(Nil)
    False -> Error(error_message <> " See " <> log_path <> ".")
  }
}

fn reset_demo_root(
  host_state_dir: String,
  demo_root: String,
) -> Result(Nil, String) {
  run_checked(
    "rm -rf " <> shell.quote(demo_root),
    host_state_dir,
    filepath.join(host_state_dir, "night-shift-demo-reset.log"),
    "Unable to reset the demo workspace.",
  )
}

fn write_fake_provider(path: String) -> Result(Nil, String) {
  write_file(
    path,
    "#!/bin/sh\n"
      <> "MODE=$1\n"
      <> "PROMPT_FILE=$2\n"
      <> "if [ \"$MODE\" = \"plan\" ]; then\n"
      <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Implement demo task\",\"description\":\"Create a file to prove execution\",\"dependencies\":[],\"acceptance\":[\"Create IMPLEMENTED.md\"],\"demo_plan\":[\"Show the new file\"],\"execution_mode\":\"serial\"}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "elif [ \"$MODE\" = \"plan-doc\" ]; then\n"
      <> "  printf 'planning-doc\\nNIGHT_SHIFT_RESULT_START\\n# Night Shift Brief\\n## Objective\\nShip the demo task.\\n## Scope\\n- Implement the demo task fixture.\\n## Constraints\\n- Stay within the fake provider contract.\\n## Deliverables\\n- Create IMPLEMENTED.md.\\n## Acceptance Criteria\\n- IMPLEMENTED.md exists after execution.\\n## Risks and Open Questions\\n- None.\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "else\n"
      <> "  echo 'completed by fake provider' > IMPLEMENTED.md\n"
      <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Implemented demo task\",\"files_touched\":[\"IMPLEMENTED.md\"],\"demo_evidence\":[\"IMPLEMENTED.md created\"],\"pr\":{\"title\":\"[night-shift] Implement demo task\",\"summary\":\"Implemented the fake provider task.\",\"demo\":[\"IMPLEMENTED.md created\"],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
      <> "fi\n",
  )
}

fn write_fake_gh(path: String) -> Result(Nil, String) {
  write_file(
    path,
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
      <> "  BRANCH=$(git rev-parse --abbrev-ref HEAD)\n"
      <> "  printf '{\"number\":1,\"title\":\"Night Shift PR\",\"body\":\"Review body\",\"headRefName\":\"%s\",\"baseRefName\":\"main\",\"url\":\"https://example.test/pr/1\",\"reviewDecision\":\"REVIEW_REQUIRED\",\"statusCheckRollup\":[],\"reviews\":[],\"comments\":[]}' \"$BRANCH\"\n"
      <> "  exit 0\n"
      <> "fi\n"
      <> "printf 'unsupported gh invocation: %s %s\\n' \"$1\" \"$2\" >&2\n"
      <> "exit 1\n",
  )
}
